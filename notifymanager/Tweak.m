// Tweak.m — 注入 SpringBoard，hook 通知展示 (iOS 16.6)
// 总开关:   NCNotificationDispatcher -postNotificationWithRequest:
//           同时在此做: 关键词过滤 / 隐藏预览
// 横幅:     SBDashBoardNotificationPresenter -presentModalBannerAndExpandForNotificationRequest:
// 声音:     SBNCSoundController -canPlaySoundForNotificationRequest:
// 角标:     SBApplication -setBadgeValue: (含 仅隐藏角标)
// 列表:     NCNotificationStructuredListViewController / NCNotificationCombinedListViewController -insertNotificationRequest...
// 后台断网: App 进程内监听 UIApplication 前后台通知 → NetGuard 关闭/拒绝本进程的远端连接
//          （iOS 16 的 FBSceneManager 已无 _noteSceneMovedTo*，旧 hook 静默失败；
//            SpringBoard 进程也缺 data-allowed-write 权限，写不了系统数据策略）
// 配置镜像: 第三方 App 沙盒读不到面板 suite（cfprefsd 隔离），SpringBoard 转写到
//          各 App 容器 Library/ntm_config.plist，App 端镜像优先读取（2.3.23）
// 设置面板通过 NSUserDefaults suiteName 通信
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach/mach.h>
// libproc.h 和 sys/proc_info.h 均仅存在于 macOS，iOS SDK 不提供。
// proc_pidpath 在 iOS 上作为私有 API 可用，手动声明即可。
#ifndef PROC_PIDPATHINFO_MAXSIZE
#define PROC_PIDPATHINFO_MAXSIZE 4096
#endif
extern int proc_pidpath(pid_t pid, char *buf, uint32_t size);

// NetGuard.m（同一 dylib）：后台断网的进程内拦截开关 + 面板「断网」状态刷新
extern void NG_setBgBlocked(BOOL on);
extern void NG_refresh(void);

static NSString *NTM_suiteName = @"com.ntm.notifymanager";

// 共享 NSUserDefaults 单例，避免每次通知到达都新建实例
static NSUserDefaults *NTM_prefs(void) {
    static NSUserDefaults *prefs = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        prefs = [[NSUserDefaults alloc] initWithSuiteName:NTM_suiteName];
    });
    return prefs;
}

// ===== 2.3.30 新增：诊断日志 =====
// 用户可通过 Settings → 面板 查看 hook 触发记录，定位为什么弹窗仍出现。
// 存到 NSUserDefaults suite，最多保留 50 条。
static void NTM_diagLog(NSString *msg) {
    @try {
        NSMutableArray *log = [[NTM_prefs() objectForKey:@"NTM_diagLog"] mutableCopy] ?: [NSMutableArray array];
        NSString *stamp = [NSString stringWithFormat:@"%@ %@",
                           [NSDateFormatter localizedStringFromDate:[NSDate date]
                                                            dateStyle:NSDateFormatterNoStyle
                                                           timeStyle:NSDateFormatterShortStyle],
                           msg];
        // SpringBoard 进程名前缀
        NSString *procName = [[[NSProcessInfo processInfo] arguments] objectAtIndex:0];
        stamp = [NSString stringWithFormat:@"[%@] %@", procName, stamp];
        [log insertObject:stamp atIndex:0];
        if (log.count > 50) [log setArray:[log subarrayWithRange:NSMakeRange(log.count - 50, 50)]];
        [[NTM_prefs()] setObject:log forKey:@"NTM_diagLog"];
    } @catch(NSException *e) {}
}
}

// 内存缓存：key=NTM_<dim>_<appId> -> NSNumber，通知到达时零 I/O 读取
static NSMutableDictionary *NTM_cache(void) {
    static NSMutableDictionary *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [NSMutableDictionary dictionary];
    });
    return cache;
}

// ===== 配置镜像（2.3.23）=====
// 实测：第三方 App 沙盒完全读不到面板 suite 的持久化配置（cfprefsd 隔离，
// NSUserDefaults / CFPreferences / 直读 plist 三条路全失败），而 SpringBoard 不受限。
// 方案：SpringBoard 把配置按 bundle id 转写到各 App 容器 Library/ntm_config.plist
// （见文件底部 NTM_writeMirrors），写完广播 mirrorUpdated；App 端读配置时
// 镜像优先、suite 兜底（SpringBoard 不读镜像，直接走 suite）。
static NSDictionary *g_mirror = nil;
static BOOL g_mirrorLoaded = NO;

// 进程判定缓存：构造期 mainBundle 偶发未就绪，取不到 bundle id 时不缓存、下次再判
static BOOL NTM_isSpringBoard(void) {
    @synchronized (NTM_cache()) {
        static NSNumber *cached = nil;
        if (!cached) {
            NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
            if (bid.length) cached = @([bid isEqualToString:@"com.apple.springboard"]);
        }
        return cached.boolValue;
    }
}

// 本进程容器里的配置镜像（懒加载，收到 mirrorUpdated 后重读）
static NSDictionary *NTM_mirror(void) {
    @synchronized (NTM_cache()) {
        if (!g_mirrorLoaded) {
            g_mirrorLoaded = YES;
            NSDictionary *d = nil;
            if (!NTM_isSpringBoard()) {
                NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/ntm_config.plist"];
                d = [NSDictionary dictionaryWithContentsOfFile:path];
            }
            g_mirror = d ?: @{};
        }
        return g_mirror;
    }
}

// 重读镜像 + 清配置缓存（收到 mirrorUpdated，或前后台决策点防挂起期间错过通知）
static void NTM_mirrorInvalidate(void) {
    @synchronized (NTM_cache()) {
        g_mirror = nil;
        g_mirrorLoaded = NO;
        [NTM_cache() removeAllObjects];
    }
}

// 面板改配置 → SpringBoard 重写完各 App 容器后广播此通知
static void NTM_mirrorUpdatedCb(CFNotificationCenterRef center, void *observer,
                                CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    NTM_mirrorInvalidate();
    NG_refresh(); // 同一 dylib 的 NetGuard：刷新面板「断网」的 g_blocked
}

static void NTM_scheduleMirror(void); // 定义见文件底部（仅 SpringBoard 执行）

// 设置面板写配置后发 Darwin 通知，这里清空缓存保证读取到最新值
static void NTM_cacheInvalidated(CFNotificationCenterRef center, void *observer,
                                 CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    @synchronized(NTM_cache()) {
        [NTM_cache() removeAllObjects];
    }
    NTM_scheduleMirror(); // SpringBoard：把最新配置转写进各 App 容器（其他进程空转）
}

// 配置读取入口：镜像优先（App 沙盒内唯一可信来源），再回退本进程 suite。
// 同一 dylib 的 NetGuard.m 也用它读 NTM_net_<bundleId>。
id NTM_prefObject(NSString *key) {
    if (!key.length) return nil;
    if (!NTM_isSpringBoard()) {
        id m = NTM_mirror()[key];
        if (m) return m;
    }
    return [NTM_prefs() objectForKey:key];
}

static BOOL NTM_raw(NSString *appId, NSString *key, BOOL def) {
    if (!appId.length) return def;
    NSString *k = [NSString stringWithFormat:@"NTM_%@_%@", key, appId];
    @synchronized(NTM_cache()) {
        NSNumber *cached = NTM_cache()[k];
        if (cached) return [cached boolValue];
        id val = NTM_prefObject(k);
        BOOL v = val ? [val boolValue] : def;
        NTM_cache()[k] = @(v);
        return v;
    }
}

// 开关类：未设置时默认开启（总开关/分项）
static BOOL NTM_on(NSString *appId, NSString *dim) {
    return NTM_raw(appId, dim, YES);
}
// 增强类开关：未设置时默认关闭（隐藏角标/隐藏预览/后台断网）
static BOOL NTM_feat(NSString *appId, NSString *key) {
    return NTM_raw(appId, key, NO);
}

// 子维度是否应拦截：总开关关闭 → 全部拦截；否则按该维度开关
static BOOL NTM_shouldBlock(NSString *appId, NSString *dim) {
    if (!NTM_on(appId, @"en")) return YES;
    return !NTM_on(appId, dim);
}

static NSString *NTM_sectionOf(id request) {
    if (!request) return nil;
    NSString *sectionId = nil;
    @try { sectionId = [request performSelector:@selector(sectionIdentifier)]; } @catch(NSException *e) {}
    return sectionId;
}

#pragma mark - 关键词过滤 (JSON 数组缓存)
static NSMutableDictionary *NTM_kwCache(void) {
    static NSMutableDictionary *kw = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ kw = [NSMutableDictionary dictionary]; });
    return kw;
}
// 命中任一关键词即返回该关键词；无关键词/未过滤返回 nil
static NSString *NTM_matchKeyword(NSString *appId, id request) {
    if (!appId.length) return nil;
    NSArray *kws = NTM_kwCache()[appId];
    if (!kws) {
        id v = [NTM_prefs() objectForKey:[NSString stringWithFormat:@"NTM_kw_%@", appId]];
        NSArray *arr = [v isKindOfClass:[NSArray class]] ? v : nil;
        if ([v isKindOfClass:[NSString class]]) {
            NSData *d = [(NSString *)v dataUsingEncoding:NSUTF8StringEncoding];
            id parsed = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
            if ([parsed isKindOfClass:[NSArray class]]) arr = parsed;
        }
        kws = arr ?: @[];
        if (kws.count) NTM_kwCache()[appId] = kws; // 空列表可直接短路
    }
    if (!kws.count) return nil;
    NSString *title = @"", *message = @"";
    @try {
        id content = [request performSelector:@selector(content)];
        if (content) {
            @try { title = [content performSelector:@selector(title)] ?: @""; } @catch(NSException *e) {}
            @try { message = [content performSelector:@selector(message)] ?: @""; } @catch(NSException *e) {}
        }
    } @catch(NSException *e) {}
    NSString *hay = [NSString stringWithFormat:@"%@ %@", title ?: @"", message ?: @""];
    for (NSString *kw in kws) {
        if (kw.length && [hay rangeOfString:kw].location != NSNotFound) return kw;
    }
    return nil;
}

#pragma mark - 隐藏预览 (只显示 App 名)
static void NTM_blankPreview(id request) {
    @try {
        id content = [request performSelector:@selector(content)];
        if (!content) return;
        @try { [content setValue:@"" forKey:@"title"]; } @catch(NSException *e) {}
        @try { [content setValue:@"" forKey:@"subtitle"]; } @catch(NSException *e) {}
        @try { [content setValue:@"" forKey:@"message"]; } @catch(NSException *e) {}
    } @catch(NSException *e) {}
}

#pragma mark - 面板网络配置读取
// policy: 0=wifi+流量 1=断网 2=打开wifi 3=流量（写入由设置面板在 Preferences 进程完成，
//         该进程才有 CommCenter 的 data-allowed-write 权限；Tweak 进程写会被静默拒绝）
static NSInteger NTM_netRead(NSString *appId) {
    id v = NTM_prefObject([NSString stringWithFormat:@"NTM_net_%@", appId]);
    return v ? [v integerValue] : 0;
}

#pragma mark - Hook NCNotificationDispatcher (总开关 + 关键词过滤 + 隐藏预览)
static void (*orig_postRequest)(id, SEL, id);
static void hook_postRequest(id self, SEL _cmd, id request) {
    NSString *sectionId = NTM_sectionOf(request);
    if (sectionId.length) {
        // 关键词过滤：优先于总开关（命中即丢弃该条）
        if (NTM_matchKeyword(sectionId, request)) return;
        if (!NTM_on(sectionId, @"en")) return; // 总开关关闭 → 拦截整个通知
        // 隐藏预览：只显示 App 名，不放行具体内容
        if (NTM_feat(sectionId, @"noPreview")) NTM_blankPreview(request);
    }
    if (orig_postRequest)
        orig_postRequest(self, _cmd, request);
}

#pragma mark - Hook SBDashBoardNotificationPresenter (横幅)
static void (*orig_presentBanner)(id, SEL, id);
static void hook_presentBanner(id self, SEL _cmd, id request) {
    NSString *sectionId = NTM_sectionOf(request);
    if (sectionId.length && NTM_shouldBlock(sectionId, @"banner")) return; // 拦截横幅
    if (orig_presentBanner)
        orig_presentBanner(self, _cmd, request);
}

#pragma mark - Hook SBNCSoundController (声音)
static BOOL (*orig_canPlaySound)(id, SEL, id);
static BOOL hook_canPlaySound(id self, SEL _cmd, id request) {
    NSString *sectionId = NTM_sectionOf(request);
    if (sectionId.length && NTM_shouldBlock(sectionId, @"sound")) return NO; // 拦截声音
    return orig_canPlaySound ? orig_canPlaySound(self, _cmd, request) : YES;
}

#pragma mark - Hook SBApplication (角标: 原标记开关 + 仅隐藏角标)
static void (*orig_setBadgeValue)(id, SEL, id);
static void hook_setBadgeValue(id self, SEL _cmd, id value) {
    NSString *bundleId = nil;
    @try { bundleId = [self performSelector:@selector(bundleIdentifier)]; } @catch(NSException *e) {}
    if (bundleId.length) {
        // 仅隐藏角标：保留全部通知，只藏桌面小红点
        BOOL noBadge = NTM_feat(bundleId, @"noBadge");
        if (noBadge || NTM_shouldBlock(bundleId, @"badge")) return; // 拦截角标更新
    }
    if (orig_setBadgeValue)
        orig_setBadgeValue(self, _cmd, value);
}

#pragma mark - Hook 通知列表插入 (锁屏/通知中心)
static BOOL (*orig_insertRequest)(id, SEL, id);
static BOOL hook_insertRequest(id self, SEL _cmd, id request) {
    NSString *sectionId = NTM_sectionOf(request);
    if (sectionId.length &&
        (NTM_shouldBlock(sectionId, @"lock") || NTM_shouldBlock(sectionId, @"nc")))
        return YES; // 拦截列表插入
    return orig_insertRequest ? orig_insertRequest(self, _cmd, request) : YES;
}

static BOOL (*orig_insertRequestCoalesced)(id, SEL, id, id);
static BOOL hook_insertRequestCoalesced(id self, SEL _cmd, id request, id coalesce) {
    NSString *sectionId = NTM_sectionOf(request);
    if (sectionId.length &&
        (NTM_shouldBlock(sectionId, @"lock") || NTM_shouldBlock(sectionId, @"nc")))
        return YES; // 拦截列表插入
    return orig_insertRequestCoalesced ? orig_insertRequestCoalesced(self, _cmd, request, coalesce) : YES;
}

#pragma mark - 自动授权通知权限 (抹除设置后免弹窗)
// 开启"自动授权"后：App 调用 requestAuthorization 时不再向系统(及 usernoted)发请求，
// 系统也就不会弹出"XX想给你发送通知"；直接按本插件里该 App 的总开关回调 granted/denied，
// 使"抹除手机设置"后的授权状态与插件配置一致（未配置的 App 默认授权）。
static BOOL NTM_autoAuthOn(void) {
    // 默认开启：装上即免弹窗，符合“抹除设置后打开 App 就不出现授权框”的使用预期。
    // 用户仍可在面板里手动关闭（关闭后恢复系统原生弹窗）。
    id v = NTM_prefObject(@"NTM_autoAuth");
    return v ? [v boolValue] : YES;
}

// 尽力把系统通知授权置为允许（与设置面板的 NTM_syncSystem 同理），让通知能真正送达。
// 无权限/失败时静默跳过，不影响"不弹窗"这一核心目标。
static void NTM_grantSystem(NSString *bid) {
    @try {
        Class cls = NSClassFromString(@"BBSettingsGateway");
        if (!cls) return;
        id gw = [[cls alloc] init];
        if (!gw) return;
        SEL s = NSSelectorFromString(@"sectionInfoForSectionID:");
        if (![gw respondsToSelector:s]) return;
        id info = [gw performSelector:s withObject:bid];
        if (!info) return;
        [info setValue:@(YES) forKey:@"allowsNotifications"];
        [info setValue:@(YES) forKey:@"showsInLockScreen"];
        [info setValue:@(YES) forKey:@"showsInNotificationCenter"];
        [info setValue:@(1) forKey:@"alertType"];
        [info setValue:@(63) forKey:@"pushSettings"]; // 声音+角标+横幅
        SEL set = NSSelectorFromString(@"setSectionInfo:forSectionID:");
        if ([gw respondsToSelector:set]) [gw performSelector:set withObject:info withObject:bid];
    } @catch(NSException *e) {}
}

static void (*orig_requestAuth)(id, SEL, unsigned long long, id);
static void hook_requestAuth(id self, SEL _cmd, unsigned long long options, id handler) {
    if (NTM_autoAuthOn()) {
        NSString *bid = nil;
        @try { bid = [[NSBundle mainBundle] bundleIdentifier]; } @catch(NSException *e) {}
        BOOL granted = NTM_on(bid, @"en"); // 总开关：开=授权 关=拒绝（未配置默认开）
        if (granted) NTM_grantSystem(bid); // 尽力让系统真正允许，通知能送达
        if (handler) {
            @try {
                void (^block)(BOOL, NSError *) = (void (^)(BOOL, NSError *))handler;
                block(granted, nil);
            } @catch(NSException *e) {}
        }
        return; // 不调用 original → 系统不会弹出授权框
    }
    if (orig_requestAuth) orig_requestAuth(self, _cmd, options, handler);
}

#pragma mark - 切后台自动断网 (App 进程内, 见文件底部 init 的通知注册)
// 是否开启"切后台自动断网"
static BOOL NTM_bgNetOn(NSString *appId) {
    return NTM_feat(appId, @"bgNet");
}
// 全局快路径：面板维护"是否有 App 开了后台断网"。
// 缺省按"有"处理（兼容旧数据，避免误跳过导致功能失效）；只有明确为关时才跳过后续判断。
static BOOL NTM_anyBgNet(void) {
    @synchronized(NTM_cache()) {
        NSNumber *c = NTM_cache()[@"_bgNetAny"];
        if (c) return [c boolValue];
    }
    id v = NTM_prefObject(@"NTM_anyBgNet");
    BOOL any = (v == nil) ? YES : [v boolValue];
    @synchronized(NTM_cache()) { NTM_cache()[@"_bgNetAny"] = @(any); }
    return any;
}

// 进后台：开了后台断网的 App 关掉已建立的远端连接并拒绝新建连接
static void NTM_onEnterBackground(void) {
    NTM_mirrorInvalidate(); // App 可能挂起期间错过 mirrorUpdated，决策点强制重读最新配置
    if (!NTM_anyBgNet()) return; // 没开任何后台断网 → 直接跳过
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if (bid.length && NTM_bgNetOn(bid)) NG_setBgBlocked(YES);
}
// 回前台：恢复放行；面板里显式设为「断网」的由 NetGuard 的 g_blocked 继续拦
static void NTM_onEnterForeground(void) {
    NTM_mirrorInvalidate(); // 同上：覆盖挂起期间错过的配置/镜像更新
    NG_refresh();
    NG_setBgBlocked(NO);
}

#pragma mark - 屏蔽「允许"XX"使用无线数据」启动弹窗
// 国行机在 App 蜂窝权限未确定时，App 一联网就弹「允许使用无线数据？」选择框。
// SpringBoard 在 App 进入前台时用 SBApplicationLaunchAlertEvaluatorForNetworkBasedAlertItems
// 评估要不要展示这类"网络类启动弹窗"。面板里设为「断网」的 App 直接判定为不展示，
// 达到「没网就是没网」，同时避免用户误点弹窗把权限改回允许、和面板设置对不上。
static NSString *NTM_appBundleId(id app) {
    NSString *bid = nil;
    @try { bid = [app bundleIdentifier]; } @catch(NSException *e) {}
    if (!bid.length) { @try { bid = [app valueForKeyPath:@"bundleIdentifier"]; } @catch(NSException *e) {} }
    return bid.length ? bid : nil;
}
static NSUInteger (*orig_shouldShowLaunchAlert)(id, SEL, id);
// 2.3.24 扩展：新安装 App 自动放行 WiFi+蜂窝（不弹系统选择框）
//  面板已配置的 App → 按配置走（断网=拦, 其他=让系统处理）
//  面板未配置的 App → 默认允许 WiFi+蜂窝（不弹窗, 回系统原始报文）
static BOOL NTM_isAppConfigured(NSString *bid) {
    if (!bid.length) return NO;
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:NTM_suiteName];
    [d synchronize];
    NSDictionary *cfg = [d persistentDomainForName:NTM_suiteName];
    if (![cfg isKindOfClass:[NSDictionary class]]) return NO;
    NSString *suffix = [@"_" stringByAppendingString:bid];
    for (NSString *k in cfg) {
        if ([k hasPrefix:@"NTM_"] && [k hasSuffix:suffix]) return YES;
    }
    return NO;
}
static NSUInteger hook_shouldShowLaunchAlert(id self, SEL _cmd, id app) {
    NSString *bid = NTM_appBundleId(app);
    if (!bid.length) {
        if (orig_shouldShowLaunchAlert) return orig_shouldShowLaunchAlert(self, _cmd, app);
        return 0;
    }
    NSInteger net = NTM_netRead(bid);
    BOOL bgNet = NTM_bgNetOn(bid);
    // 断网 / 后台断网 → 不展示（和原来一致）
    if (net == 1 || bgNet) return 0;
    // 面板已配置且非断网 → 让系统走原始逻辑（蜂窝策略已由面板写入系统）
    if (NTM_isAppConfigured(bid)) {
        if (orig_shouldShowLaunchAlert) return orig_shouldShowLaunchAlert(self, _cmd, app);
        return 0;
    }
    // 面板未配置（新安装 App）→ 默认允许 WiFi+蜂窝，不弹窗
    return 0;
}
static void (*orig_showLaunchAlert)(id, SEL, NSUInteger, id);
static void hook_showLaunchAlert(id self, SEL _cmd, NSUInteger type, id app) {
    NSString *bid = NTM_appBundleId(app);
    if (!bid.length) {
        if (orig_showLaunchAlert) orig_showLaunchAlert(self, _cmd, type, app);
        return;
    }
    NSInteger net = NTM_netRead(bid);
    BOOL bgNet = NTM_bgNetOn(bid);
    if (net == 1 || bgNet) return;
    if (NTM_isAppConfigured(bid)) {
        if (orig_showLaunchAlert) orig_showLaunchAlert(self, _cmd, type, app);
        return;
    }
    // 面板未配置（新安装 App）→ 不弹窗
}

#pragma mark - 直接拦截 CommCenter 的「允许"XX"使用无线数据」请求（不弹窗）
// 实测(iOS 16.6)：该弹窗由 CommCenter 给 SpringBoard 发消息，经
// +[SBUserNotificationCenter dispatchUserNotification:flags:replyPort:auditToken:] 创建，
// 消息字典里只有 AlertSource / AlertHeader(App 中文名)，没有 bundle id。
// 前面 hook 的 SBApplicationLaunchAlertEvaluator* 只覆盖「App 启动评估」这条路，
// CommCenter 直发的请求不经过它，所以还会漏弹。
// 这里对面板里设为「断网」的 App 直接回一条「不允许」报文，不创建弹窗。
// 回「不允许」写的是系统数据策略，和面板 NTM_applyNetPolicy 同源，
// 解除断网后面板会把它同步回允许，不会留下和面板不一致的残留状态。
//
// 报文格式为实测值（frida 抓 mach_msg 得到）：
//   28 字节 = 24 字节头 + 4 字节体；msgh_bits=0x12(COPY_SEND)、msgh_id=0；
//   体为 uint32 响应码，0 = Default = 「不允许」。
// 断网/后台断网 → 回"不允许"报文; 新安装未配置 App → 回"允许"报文（自动授权）
// 报文格式：28 字节 = 24 字节头 + 4 字节体；response 0=不允许 1=允许
static void NTM_sendReply(uint64_t replyPort, uint32_t response) {
    if (!replyPort) return;
    struct {
        mach_msg_header_t header;
        uint32_t response;
    } msg = {0};
    msg.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSGH_BITS_ZERO);
    msg.header.msgh_size = (mach_msg_size_t)sizeof(msg);
    msg.header.msgh_remote_port = (mach_port_t)replyPort;
    msg.header.msgh_id = 0;
    msg.response = response; // 0=Default(不允许)  1=Allowed(允许)
    @try {
        mach_msg(&msg.header, MACH_SEND_MSG, (mach_msg_size_t)sizeof(msg),
                 0, MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
    } @catch (NSException *e) {}
}
static void NTM_sendDenyReply(uint64_t replyPort) { NTM_sendReply(replyPort, 0); }
static void NTM_sendAllowReply(uint64_t replyPort) { NTM_sendReply(replyPort, 1); }

// 「允许“微信”使用无线数据？」→ 微信
static NSString *NTM_appNameOfHeader(NSString *header) {
    if (!header.length) return nil;
    NSArray *quotes = @[@[@"\u201C", @"\u201D"], @[@"\u300C", @"\u300D"], @[@"\u300E", @"\u300F"], @[@"\"", @"\""]];
    for (NSArray *q in quotes) {
        NSRange l = [header rangeOfString:q[0]];
        if (l.location == NSNotFound) continue;
        NSUInteger from = NSMaxRange(l);
        if (from >= header.length) continue;
        NSRange r = [header rangeOfString:q[1]
                                  options:0
                                    range:NSMakeRange(from, header.length - from)];
        if (r.location == NSNotFound) continue;
        NSString *name = [header substringWithRange:NSMakeRange(from, r.location - from)];
        if (name.length) return name;
    }
    return nil;
}

// App 中文名 → bundle id：遍历已安装 App，优先精确匹配本地化名，
// 匹配不到再退回「本地化名是该名字的子串」中最长的那个。
static NSString *NTM_bundleIdOfName(NSString *name) {
    if (!name.length) return nil;
    @try {
        Class wsCls = NSClassFromString(@"LSApplicationWorkspace");
        SEL selWS = NSSelectorFromString(@"defaultWorkspace");
        if (!wsCls || ![wsCls respondsToSelector:selWS]) return nil;
        id ws = ((id (*)(id, SEL))objc_msgSend)(wsCls, selWS);
        SEL selAll = NSSelectorFromString(@"allInstalledApplications");
        if (!ws || ![ws respondsToSelector:selAll]) return nil;
        id arr = ((id (*)(id, SEL))objc_msgSend)(ws, selAll);
        if (!arr) return nil;
        NSUInteger n = [arr count];
        NSString *exact = nil, *partial = nil;
        NSUInteger partialLen = 0;
        for (NSUInteger i = 0; i < n; i++) {
            id proxy = [arr objectAtIndex:i];
            NSString *nm = nil, *bid = nil;
            SEL sName = NSSelectorFromString(@"localizedName");
            if ([proxy respondsToSelector:sName])
                nm = ((id (*)(id, SEL))objc_msgSend)(proxy, sName);
            SEL sBid = NSSelectorFromString(@"applicationIdentifier");
            if ([proxy respondsToSelector:sBid])
                bid = ((id (*)(id, SEL))objc_msgSend)(proxy, sBid);
            if (!nm.length || !bid.length) continue;
            if ([nm isEqualToString:name]) {
                if (!exact) exact = bid;
            } else if (nm.length > partialLen && [name rangeOfString:nm].location != NSNotFound) {
                partial = bid;
                partialLen = nm.length;
            }
            if (exact) break;
        }
        return exact ?: partial;
    } @catch (NSException *e) {}
    return nil;
}

// 2.3.25 新增：从 audit_token 直接提取 bundle id（最可靠，不依赖名字解析）
// auditToken 是触发弹窗的进程 audit token，包含 PID；通过 proc_pidpath 获取可执行文件路径，
// 再定位 .app 目录，用 NSBundle 取出 bundle id。若 PID 指向 CommCenter/SpringBoard 等系统进程
// 则返回 nil，让调用方回退到名字解析。
static NSString *NTM_bundleIdFromAuditToken(void *auditToken) {
    if (!auditToken) return nil;
    @try {
        // audit_token_t 在 iOS 上字段名与 macOS 不同，用偏移量直接读取。
        // 结构布局: uid(4)+gid(4)+ruid(4)+rgid(4)+pid(4)+ppid(4)+...
        // PID 位于第 4 个 uint32_t（offset 16）
        uint32_t *t32 = (uint32_t *)auditToken;
        pid_t pid = (pid_t)t32[4];
        if (pid <= 0) return nil;
        char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
        if (proc_pidpath(pid, path, sizeof(path)) <= 0) return nil;
        NSString *exePath = [NSString stringWithUTF8String:path];
        if (!exePath.length) return nil;
        // 跳过系统进程：CommCenter/SpringBoard 不是目标 App
        if ([exePath containsString:@"CommCenter"] ||
            [exePath containsString:@"SpringBoard"] ||
            [exePath hasPrefix:@"/usr/libexec/"] ||
            [exePath hasPrefix:@"/usr/sbin/"]) return nil;
        NSURL *exeURL = [NSURL fileURLWithPath:exePath];
        NSURL *appURL = [exeURL URLByDeletingLastPathComponent];
        if (![appURL.path hasSuffix:@".app"]) return nil;
        NSBundle *b = [NSBundle bundleWithURL:appURL];
        NSString *bid = b.bundleIdentifier;
        return bid.length ? bid : nil;
    } @catch (NSException *e) { return nil; }
}

// 这条 CommCenter 请求是不是「面板里已断网的 App」
// 返回值：-1=不处理(走原始逻辑), 0=回 deny(不允许), 1=回 allow(允许)
static int NTM_checkWirelessAlert(id msg) {
    @try {
        if (!msg) return -1;
        NSString *src = [msg objectForKey:@"AlertSource"];
        if (![src isKindOfClass:[NSString class]] || ![src isEqualToString:@"CommCenter"]) return -1;
        NSString *hdr = [msg objectForKey:@"AlertHeader"];
        if (![hdr isKindOfClass:[NSString class]] || ![hdr containsString:@"使用无线数据"]) return -1;
        NSString *bid = NTM_bundleIdOfName(NTM_appNameOfHeader(hdr));
        if (!bid.length) return -1;
        NSInteger net = NTM_netRead(bid);
        BOOL bgNet = NTM_bgNetOn(bid);
        if (net == 1 || bgNet) return 0;      // 断网/后台断网 → deny
        if (!NTM_isAppConfigured(bid)) return 1; // 新安装未配置 → allow
        return -1;                              // 面板已配置 → 原始逻辑
    } @catch (NSException *e) { return -1; }
}

// NTM_syncCellularSB 定义在文件后部，此处前向声明
static void NTM_syncCellularSB(NSString *bid, NSInteger policy);

static void (*orig_dispatch)(id, SEL, id, uint64_t, uint64_t, void *);
static void hook_dispatch(id self, SEL _cmd, id msg, uint64_t flags,
                          uint64_t replyPort, void *auditToken) {
    // 先确认是不是 CommCenter 的无线数据弹窗
    @try {
        NSString *src = [msg objectForKey:@"AlertSource"];
        if (![src isEqualToString:@"CommCenter"]) {
            if (orig_dispatch) orig_dispatch(self, _cmd, msg, flags, replyPort, auditToken);
            return;
        }
        NSString *hdr = [msg objectForKey:@"AlertHeader"] ?: @"";
        NSString *body = [msg objectForKey:@"AlertBody"] ?: [msg objectForKey:@"AlertText"] ?: @"";
        NSString *fullText = [NSString stringWithFormat:@"%@ %@", hdr, body];
        // 匹配各种中文变体：无线数据 / 蜂窝数据 / 数据访问
        BOOL isNetAlert = [fullText containsString:@"无线数据"] ||
                          [fullText containsString:@"蜂窝数据"] ||
                          [fullText containsString:@"使用数据"] ||
                          [fullText containsString:@"访问数据"];
        if (!isNetAlert) {
            if (orig_dispatch) orig_dispatch(self, _cmd, msg, flags, replyPort, auditToken);
            return;
        }
        // 优先用 auditToken 提取 bundle id（最可靠）
        NSString *bid = NTM_bundleIdFromAuditToken(auditToken);
        // 回退：从弹窗文本解析 App 名 → bundle id
        if (!bid.length) {
            NSString *appName = NTM_appNameOfHeader(fullText);
            if (appName.length) bid = NTM_bundleIdOfName(appName);
        }
        if (!bid.length) {
            if (orig_dispatch) orig_dispatch(self, _cmd, msg, flags, replyPort, auditToken);
            return;
        }
        NSInteger net = NTM_netRead(bid);
        BOOL bgNet = NTM_bgNetOn(bid);
        if (net == 1 || bgNet) { NTM_sendDenyReply(replyPort); return; }
        if (!NTM_isAppConfigured(bid)) {
            NTM_syncCellularSB(bid, 0); // 新安装 App 写入 allow 策略
            NTM_sendAllowReply(replyPort);
            return;
        }
    } @catch (NSException *e) {}
    if (orig_dispatch) orig_dispatch(self, _cmd, msg, flags, replyPort, auditToken);
}

// ===== 2.3.30 新增：iOS 16+ 系统级授权弹窗拦截 =====
// iOS 16+ 无线数据权限弹窗不走 dispatchUserNotification（旧通知 API），
// 走的是 SpringBoard 内部的 _UISystemAlertViewController / SBAuthorizationDialogController。
// 通用检测：文本含"无线数据/蜂窝数据/使用数据/访问数据"即为网络授权弹窗。
// 断网 App → 吞掉弹窗；新 App → 写策略后吞掉。
static BOOL NTM_isNetAuthPopup(NSString *full) {
    if (!full.length) return NO;
    return [full containsString:@"无线数据"] ||
           [full containsString:@"蜂窝数据"] ||
           [full containsString:@"使用数据"] ||
           [full containsString:@"访问数据"] ||
           [full containsString:@"无线局域网与蜂窝网络"];
}

// 从「允许"XX"使用无线数据？」提取 App 名（支持多种引号）
static NSString *NTM_extractNetAuthAppName(NSString *full) {
    if (!full.length) return nil;
    NSRange allow = [full rangeOfString:@"允许"];
    NSRange wireless = [full rangeOfString:@"使用无线数据"] ?: [full rangeOfString:@"使用蜂窝数据"] ?: [full rangeOfString:@"访问数据"];
    if (allow.location == NSNotFound || wireless.location == NSNotFound || wireless.location <= allow.location + allow.length) return nil;
    NSString *mid = [full substringWithRange:NSMakeRange(allow.location + allow.length, wireless.location - allow.location - allow.length)];
    // 尝试多种引号
    NSArray *pairs = @[
        @[@"\u201C", @"\u201D"],  // ""
        @[@"\u300C", @"\u300D"],  // 「」
        @[@"\u300E", @"\u300F"],  // 《》
        @[@"\"", @"\""]           // ""
    ];
    for (NSArray *p in pairs) {
        NSRange ro = [mid rangeOfString:p[0]];
        if (ro.location == NSNotFound) continue;
        NSString *after = [mid substringFromIndex:ro.location + 1];
        NSRange rc = [after rangeOfString:p[1]];
        if (rc.location != NSNotFound && rc.location > 0) {
            return [after substringToIndex:rc.location];
        }
    }
    return nil;
}

// 通用系统 alert hook：检查弹窗内容，如果是网络授权弹窗，按策略处理
// 用于 _UISystemAlertViewController showWithCompletion: 和 SBAuthorizationDialogController showWithCompletion:
static void (*orig_showAlertCompletion)(id, SEL, id);
static void hook_showAlertCompletion(id self, SEL _cmd, id completion) {
    NSString *text = nil, *info = nil;
    @try { text = [self valueForKey:@"text"]; } @catch(NSException *e) {}
    @try { info = [self valueForKey:@"informativeText"]; } @catch(NSException *e) {}
    // 有些类用 title/message
    if (!text) { @try { text = [self valueForKey:@"title"]; } @catch(NSException *e) {} }
    if (!info) { @try { info = [self valueForKey:@"message"]; } @catch(NSException *e) {} }
    NSString *full = [NSString stringWithFormat:@"%@ %@", text ?: @"", info ?: @""];
    BOOL isNetPopup = NTM_isNetAuthPopup(full);
    if (!isNetPopup) {
        if (orig_showAlertCompletion) orig_showAlertCompletion(self, _cmd, completion);
        return;
    }
    // 是网络权限弹窗
    NTM_diagLog([NSString stringWithFormat:@"netAuth INTERCEPT text=%@ info=%@", text, info]);
    // 尝试从消息文本提取 bundle id（auditToken 在此不可用，只能靠名字）
    NSString *bid = nil;
    @try {
        // 有些类有 auditToken 属性
        void *at = [self valueForKey:@"auditToken"];
        if (at) bid = NTM_bundleIdFromAuditToken(at);
    } @catch(NSException *e) {}
    // 回退：从文本解析 App 名
    if (!bid.length) {
        NSString *appName = NTM_extractNetAuthAppName(full);
        if (appName.length) bid = NTM_bundleIdOfName(appName);
    }
    if (!bid.length) {
        NTM_diagLog(@"netAuth FAIL noBundleId fallback");
        if (orig_showAlertCompletion) orig_showAlertCompletion(self, _cmd, completion);
        return;
    }
    NSInteger net = NTM_netRead(bid);
    BOOL bgNet = NTM_bgNetOn(bid);
    if (net == 1 || bgNet) {
        NTM_diagLog([NSString stringWithFormat:@"netAuth DENY bid=%@", bid]);
        return; // 断网 → 不展示
    }
    if (!NTM_isAppConfigured(bid)) {
        NTM_syncCellularSB(bid, 0); // 新 App 写入 allow 策略
        NTM_diagLog([NSString stringWithFormat:@"netAuth ALLOW+write bid=%@", bid]);
        return; // 写入策略后也不展示（策略已允许）
    }
    if (orig_showAlertCompletion) orig_showAlertCompletion(self, _cmd, completion);
}

// 更激进：hook UIViewController 的 presentViewController:animated:completion:
// iOS 16 上系统级授权弹窗通过 UIAlertController + presentViewControllerAnimated: 展示
// 检测 toPresent 是否是 UIAlertController，且内容是网络授权弹窗
static void (*orig_presentVC)(id, SEL, id, BOOL, id);
static void hook_presentVC(id self, SEL _cmd, id toPresent, BOOL animated, id completion) {
    @try {
        // 只处理 UIAlertController
        if ([toPresent isKindOfClass:[UIAlertController class]]) {
            UIAlertController *ac = (UIAlertController *)toPresent;
            NSMutableString *text = [NSMutableString stringWithFormat:@"%@ %@",
                                     ac.title ?: @"", ac.message ?: @""];
            for (UIAlertAction *act in ac.actions) {
                [text appendFormat:@" %s ", act.title.UTF8String ?: ""];
            }
            for (UIAlertAction *sact in ac.actionSheetCustomActions) {
                [text appendFormat:@" %s ", sact.title.UTF8String ?: ""];
            }
            NSString *full = [text copy];
            if (NTM_isNetAuthPopup(full)) {
                NTM_diagLog([NSString stringWithFormat:@"presentVC INTERCEPT UIAlertController title=%@", ac.title]);
                NSString *appName = NTM_extractNetAuthAppName(ac.title ?: @"");
                NSString *bid = nil;
                if (appName.length) bid = NTM_bundleIdOfName(appName);
                if (!bid.length) {
                    if (orig_presentVC) orig_presentVC(self, _cmd, toPresent, animated, completion);
                    return;
                }
                NSInteger net = NTM_netRead(bid);
                BOOL bgNet = NTM_bgNetOn(bid);
                if (net == 1 || bgNet) {
                    NTM_diagLog([NSString stringWithFormat:@"presentVC DENY bid=%@", bid]);
                    return;
                }
                if (!NTM_isAppConfigured(bid)) {
                    NTM_syncCellularSB(bid, 0);
                    NTM_diagLog([NSString stringWithFormat:@"presentVC ALLOW+write bid=%@", bid]);
                    return;
                }
            }
        }
    } @catch(NSException *e) {
        NTM_diagLog([NSString stringWithFormat:@"presentVC EXC %@", e.reason]);
    }
    if (orig_presentVC) orig_presentVC(self, _cmd, toPresent, animated, completion);
}

static void tryHook(Class cls, SEL sel, IMP hook, IMP *orig) {
    if (!cls) return;
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    *orig = method_getImplementation(m);
    method_setImplementation(m, hook);
}

// 类方法版本（dispatchUserNotification 是 + 方法）
static void tryHookMeta(Class cls, SEL sel, IMP hook, IMP *orig) {
    if (!cls) return;
    Method m = class_getClassMethod(cls, sel);
    if (!m) return;
    *orig = method_getImplementation(m);
    method_setImplementation(m, hook);
}

#pragma mark - 镜像写入：SpringBoard → 各 App 容器（仅 SpringBoard 进程执行）
static dispatch_queue_t NTM_mirrorQueue(void) {
    static dispatch_queue_t q = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("com.ntm.mirror", DISPATCH_QUEUE_SERIAL); });
    return q;
}
static BOOL g_mirrorPending = NO;

// 把面板 suite 的配置按 bundle id 分发，写入各 App 容器 Library/ntm_config.plist，
// 写完广播 mirrorUpdated 让运行中的 App 重读。取不到容器（未启动过的 App 等）跳过，
// 这类 App 进程本来也读不到配置，行为与旧版一致。
static void NTM_writeMirrors(void) {
    if (!NTM_isSpringBoard()) return;
    @autoreleasepool {
        // 每次新建 suite 实例并 synchronize：强制从 cfprefsd 拉面板最新写入，
        // 避免复用单例的客户端缓存读到旧值
        NSUserDefaults *fresh = [[NSUserDefaults alloc] initWithSuiteName:NTM_suiteName];
        [fresh synchronize];
        NSDictionary *domain = [fresh persistentDomainForName:NTM_suiteName];
        NSDictionary *cfg = [domain isKindOfClass:[NSDictionary class]] ? domain : @{};
        NSFileManager *fm = [NSFileManager defaultManager];
        @try {
            Class wsCls = NSClassFromString(@"LSApplicationWorkspace");
            SEL selWS = NSSelectorFromString(@"defaultWorkspace");
            if (!wsCls || ![wsCls respondsToSelector:selWS]) return;
            id ws = ((id (*)(id, SEL))objc_msgSend)(wsCls, selWS);
            SEL selAll = NSSelectorFromString(@"allInstalledApplications");
            if (!ws || ![ws respondsToSelector:selAll]) return;
            id arr = ((id (*)(id, SEL))objc_msgSend)(ws, selAll);
            if (!arr) return;
            for (id proxy in arr) {
                @try {
                    NSString *bid = nil;
                    SEL sBid = NSSelectorFromString(@"applicationIdentifier");
                    if ([proxy respondsToSelector:sBid])
                        bid = ((id (*)(id, SEL))objc_msgSend)(proxy, sBid);
                    if (!bid.length) continue;
                    SEL sCtr = NSSelectorFromString(@"dataContainerURL");
                    if (![proxy respondsToSelector:sCtr]) continue;
                    NSURL *u = ((id (*)(id, SEL))objc_msgSend)(proxy, sCtr);
                    NSString *root = u.path;
                    if (!root.length || ![fm fileExistsAtPath:root]) continue;
                    // 该 App 的所有 NTM_<dim>_<bid> 配置 + 全局项（后台断网/自动授权）
                    NSString *suffix = [@"_" stringByAppendingString:bid];
                    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithCapacity:8];
                    id v = cfg[@"NTM_anyBgNet"]; if (v) d[@"NTM_anyBgNet"] = v;
                    v = cfg[@"NTM_autoAuth"];    if (v) d[@"NTM_autoAuth"] = v;
                    for (NSString *k in cfg) {
                        if ([k hasPrefix:@"NTM_"] && [k hasSuffix:suffix]) d[k] = cfg[k];
                    }
                    NSString *dir = [root stringByAppendingPathComponent:@"Library"];
                    if (![fm fileExistsAtPath:dir])
                        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
                    [d writeToFile:[dir stringByAppendingPathComponent:@"ntm_config.plist"] atomically:YES];
                } @catch (NSException *e) {}
            }
        } @catch (NSException *e) {}
        // 通知所有运行中的 App：镜像已更新，重读并清缓存
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFSTR("com.ntm.notifymanager.mirrorUpdated"),
                                             NULL, NULL, YES);
    }
}

// ===== 2.3.24 新增：SpringBoard 启动时重新应用系统蜂窝策略 =====
// 根因：iOS 注销/重启后会重置蜂窝策略为"允许 WiFi+蜂窝"，
// 但面板只在用户打开改设置时才调 NTM_syncCellular 写 PSAppDataUsagePolicyCache，
// SpringBoard init 完全没重新应用 → 注销后网络/通知设置全部还原。
// 修复：和 NTM_writeMirrors 同步，init 后 10s 遍历面板配置里所有 NTM_net_<bid>，
// 重新调 PSAppDataUsagePolicyCache 把系统策略写回去。

static void NTM_loadPolicyFramework(void) {
    static BOOL loaded = NO;
    if (loaded) return;
    if (NSClassFromString(@"PSAppDataUsagePolicyCache")) { loaded = YES; return; }
    dlopen("/System/Library/PrivateFrameworks/SettingsCellular.framework/SettingsCellular", RTLD_NOW);
    if (NSClassFromString(@"PSAppDataUsagePolicyCache")) { loaded = YES; return; }
    dlopen("/System/Library/PrivateFrameworks/Preferences.framework/Preferences", RTLD_NOW);
    if (NSClassFromString(@"PSAppDataUsagePolicyCache")) loaded = YES;
}

// 按面板配置写 PSAppDataUsagePolicyCache（和 NotifyManager.m 完全一致的调用路径）
// 2.3.30: 尝试多个可能的 API（不同 iOS 版本 API 名不同），加诊断日志
static void NTM_syncCellularSB(NSString *appId, NSInteger policy) {
    if (!appId.length) return;
    // policy: 0=wifi+流量 1=断网 2=只wifi 3=只流量；系统侧 1=允许 0=禁止
    long long cell = (policy == 0 || policy == 3) ? 1 : 0;
    long long wifi = (policy == 0 || policy == 2) ? 1 : 0;
    NTM_loadPolicyFramework();
    @try {
        Class cls = NSClassFromString(@"PSAppDataUsagePolicyCache");
        if (!cls) { NTM_diagLog([NSString stringWithFormat:@"syncPol SKIP noClass bid=%@", appId]); return; }
        id cache = ((id (*)(id, SEL))objc_msgSend)(cls, NSSelectorFromString(@"sharedInstance"));
        if (!cache) { NTM_diagLog([NSString stringWithFormat:@"syncPol SKIP noCache bid=%@", appId]); return; }
        id pol = nil;
        // 尝试多种 policiesFor 方法名
        SEL s1 = NSSelectorFromString(@"policiesFor:");
        SEL s2 = NSSelectorFromString(@"policiesForBundleIdentifier:");
        SEL s3 = NSSelectorFromString(@"policiesForApplicationID:");
        if ([cache respondsToSelector:s1]) pol = ((id (*)(id, SEL, id))objc_msgSend)(cache, s1, appId);
        if (!pol && [cache respondsToSelector:s2]) pol = ((id (*)(id, SEL, id))objc_msgSend)(cache, s2, appId);
        if (!pol && [cache respondsToSelector:s3]) pol = ((id (*)(id, SEL, id))objc_msgSend)(cache, s3, appId);
        if (pol) {
            SEL sCell = NSSelectorFromString(@"setCellular:");
            SEL sWifi = NSSelectorFromString(@"setWifi:");
            if ([pol respondsToSelector:sCell]) ((void (*)(id, SEL, long long))objc_msgSend)(pol, sCell, cell);
            if ([pol respondsToSelector:sWifi])  ((void (*)(id, SEL, long long))objc_msgSend)(pol, sWifi, wifi);
        } else {
            // 尝试多种 init 方法
            Class polCls = NSClassFromString(@"CTDataUsagePolicies");
            NSArray *inits3 = @[@"init:withCellularPolicy:andWifiPolicy:",
                                @"newPolicyWithCellularPolicy:andWifiPolicy:"];
            NSArray *inits1 = @[@"initWithApplicationID:",
                                @"initWithBundleIdentifier:",
                                @"newPolicyWithApplicationID:",
                                @"newPolicyForApplicationID:"];
            if (polCls) {
                for (NSString *n in inits3) {
                    SEL s = NSSelectorFromString(n);
                    if (![polCls instancesRespondToSelector:s]) continue;
                    id obj = ((id (*)(id, SEL))objc_msgSend)((id)polCls, NSSelectorFromString(@"alloc"));
                    pol = ((id (*)(id, SEL, id, long long, long long))objc_msgSend)(obj, s, appId, cell, wifi);
                    if (pol) break;
                }
                if (!pol) for (NSString *n in inits1) {
                    SEL s = NSSelectorFromString(n);
                    if (![polCls instancesRespondToSelector:s]) continue;
                    id obj = ((id (*)(id, SEL))objc_msgSend)((id)polCls, NSSelectorFromString(@"alloc"));
                    pol = ((id (*)(id, SEL, id))objc_msgSend)(obj, s, appId);
                    if (pol) {
                        SEL sCell = NSSelectorFromString(@"setCellular:");
                        SEL sWifi = NSSelectorFromString(@"setWifi:");
                        if ([pol respondsToSelector:sCell]) ((void (*)(id, SEL, long long))objc_msgSend)(pol, sCell, cell);
                        if ([pol respondsToSelector:sWifi])  ((void (*)(id, SEL, long long))objc_msgSend)(pol, sWifi, wifi);
                        break;
                    }
                }
            }
        }
        if (!pol) { NTM_diagLog([NSString stringWithFormat:@"syncPol FAIL noPol bid=%@", appId]); return; }
        // 尝试多种 setPolicy 方法名
        SEL setPol1 = NSSelectorFromString(@"setPolicies:completion:");
        SEL setPol2 = NSSelectorFromString(@"setPolicy:completion:");
        SEL setPol3 = NSSelectorFromString(@"setPolicies:");
        SEL setPol4 = NSSelectorFromString(@"setPolicy:");
        if ([cache respondsToSelector:setPol1]) {
            void (^done)(void) = ^{};
            ((void (*)(id, SEL, id, id))objc_msgSend)(cache, setPol1, pol, done);
            NTM_diagLog([NSString stringWithFormat:@"syncPol OK setPolicies bid=%@ cell=%lld wifi=%lld", appId, cell, wifi]);
        } else if ([cache respondsToSelector:setPol2]) {
            void (^done)(void) = ^{};
            ((void (*)(id, SEL, id, id))objc_msgSend)(cache, setPol2, pol, done);
            NTM_diagLog([NSString stringWithFormat:@"syncPol OK setPolicy bid=%@ cell=%lld wifi=%lld", appId, cell, wifi]);
        } else if ([cache respondsToSelector:setPol3]) {
            ((void (*)(id, SEL, id))objc_msgSend)(cache, setPol3, pol);
            NTM_diagLog([NSString stringWithFormat:@"syncPol OK setPolicies(sync) bid=%@", appId]);
        } else if ([cache respondsToSelector:setPol4]) {
            ((void (*)(id, SEL, id))objc_msgSend)(cache, setPol4, pol);
            NTM_diagLog([NSString stringWithFormat:@"syncPol OK setPolicy(sync) bid=%@", appId]);
        } else {
            NTM_diagLog([NSString stringWithFormat:@"syncPol FAIL noSetter bid=%@", appId]);
        }
    } @catch(NSException *e) {
        NTM_diagLog([NSString stringWithFormat:@"syncPol EXC %@", e.reason]);
    }
}

// ===== 2.3.25 新增：新安装 App 自动写入 allow 策略 =====
// 根因：新 App 首次联网时 CommCenter 查系统策略缓存发现无条目 → 触发弹窗。
// 弹窗被 hook 拦截后虽回 "allow"，但策略缓存仍为空，下次联网再次弹窗。
// 修复：SpringBoard 启动时遍历已安装 App，对面板未配置的（无 NTM_net_<bid>）写入
// 系统策略缓存 allow（WiFi+蜂窝），后续联网不再弹窗、不再无网。
// 跳过 com.apple.* 系统 App（它们有自己的策略，不该被覆盖）。
static void NTM_writeAllowPoliciesForUnconfiguredApps(NSDictionary *cfg) {
    NSMutableSet *configured = [NSMutableSet set];
    for (NSString *k in cfg) {
        if ([k hasPrefix:@"NTM_net_"]) {
            [configured addObject:[k substringFromIndex:@"NTM_net_".length]];
        }
    }
    Class wsCls = NSClassFromString(@"LSApplicationWorkspace");
    SEL selWS = NSSelectorFromString(@"defaultWorkspace");
    if (!wsCls || ![wsCls respondsToSelector:selWS]) return;
    id ws = ((id (*)(id, SEL))objc_msgSend)(wsCls, selWS);
    SEL selAll = NSSelectorFromString(@"allInstalledApplications");
    if (!ws || ![ws respondsToSelector:selAll]) return;
    id arr = ((id (*)(id, SEL))objc_msgSend)(ws, selAll);
    if (!arr) return;
    NSUInteger processed = 0;
    for (id proxy in arr) {
        @try {
            NSString *bid = nil;
            SEL sBid = NSSelectorFromString(@"applicationIdentifier");
            if ([proxy respondsToSelector:sBid])
                bid = ((id (*)(id, SEL))objc_msgSend)(proxy, sBid);
            if (!bid.length || [bid hasPrefix:@"com.apple."]) continue;
            if ([configured containsObject:bid]) continue;
            NTM_syncCellularSB(bid, 0); // policy=0 → allow WiFi+cellular
            processed++;
        } @catch(NSException *e) {}
    }
}

// SpringBoard 启动时全量重新应用系统蜂窝策略（和 NTM_writeMirrors 同步）
static void NTM_applyAllPolicies(void) {
    if (!NTM_isSpringBoard()) return;
    @autoreleasepool {
        NSUserDefaults *fresh = [[NSUserDefaults alloc] initWithSuiteName:NTM_suiteName];
        [fresh synchronize];
        NSDictionary *cfg = [[fresh persistentDomainForName:NTM_suiteName] isKindOfClass:[NSDictionary class]] ?
                           [fresh persistentDomainForName:NTM_suiteName] : @{};
        for (NSString *k in cfg) {
            if (![k hasPrefix:@"NTM_net_"]) continue;
            NSString *bid = [k substringFromIndex:@"NTM_net_".length];
            if (!bid.length) continue;
            NSInteger policy = [cfg[k] integerValue];
            NTM_syncCellularSB(bid, policy);
        }
        // 2.3.25: 为面板未配置的新安装 App 写入 allow 策略
        NTM_writeAllowPoliciesForUnconfiguredApps(cfg);
    }
}

// 防抖：面板批量开关会连发 configChanged，攒 0.3s 写一次（串行队列，避免并发写）
static void NTM_scheduleMirror(void) {
    if (!NTM_isSpringBoard()) return;
    @synchronized (NTM_cache()) {
        if (g_mirrorPending) return;
        g_mirrorPending = YES;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   NTM_mirrorQueue(), ^{
        @synchronized (NTM_cache()) { g_mirrorPending = NO; } // 写的过程中再有变更会重新排程
        NTM_writeMirrors();
    });
}

__attribute__((constructor)) static void init() {
    @autoreleasepool {
        // 监听设置面板的配置变更通知，清空内存缓存
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL, NTM_cacheInvalidated,
                                        CFSTR("com.ntm.notifymanager.configChanged"),
                                        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

        // SpringBoard 写完各 App 容器的配置镜像后广播 → 本进程（App 内）重读镜像并刷新 NetGuard
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL, NTM_mirrorUpdatedCb,
                                        CFSTR("com.ntm.notifymanager.mirrorUpdated"),
                                        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

        // SpringBoard 开机全量补写一次镜像 + 重新应用系统蜂窝策略（注销后系统会重置蜂窝策略！）
        // 2.3.25: 延迟从 10s 减到 2s，缩小注销后策略空窗期，App 启动前完成策略写入
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                       NTM_mirrorQueue(), ^{ NTM_writeMirrors(); NTM_applyAllPolicies(); });

        // 自动授权通知默认开启：保证重装/抹除后打开 App 不再弹授权框（面板可手动关）
        [NTM_prefs() registerDefaults:@{@"NTM_autoAuth": @YES}];

        // 总开关 + 关键词过滤 + 隐藏预览
        tryHook(objc_getClass("NCNotificationDispatcher"),
                sel_registerName("postNotificationWithRequest:"),
                (IMP)hook_postRequest, (IMP *)&orig_postRequest);

        // 横幅
        tryHook(objc_getClass("SBDashBoardNotificationPresenter"),
                sel_registerName("presentModalBannerAndExpandForNotificationRequest:"),
                (IMP)hook_presentBanner, (IMP *)&orig_presentBanner);

        // 声音
        tryHook(objc_getClass("SBNCSoundController"),
                sel_registerName("canPlaySoundForNotificationRequest:"),
                (IMP)hook_canPlaySound, (IMP *)&orig_canPlaySound);

        // 角标 (含 仅隐藏角标)
        tryHook(objc_getClass("SBApplication"),
                sel_registerName("setBadgeValue:"),
                (IMP)hook_setBadgeValue, (IMP *)&orig_setBadgeValue);

        // 列表 (锁屏/通知中心)
        tryHook(objc_getClass("NCNotificationStructuredListViewController"),
                sel_registerName("insertNotificationRequest:"),
                (IMP)hook_insertRequest, (IMP *)&orig_insertRequest);

        tryHook(objc_getClass("NCNotificationCombinedListViewController"),
                sel_registerName("insertNotificationRequest:forCoalescedNotification:"),
                (IMP)hook_insertRequestCoalesced, (IMP *)&orig_insertRequestCoalesced);

        // 切后台自动断网：在 App 自己进程里监听前后台（iOS 16 的 FBSceneManager 已无
        // _noteSceneMovedTo*，旧 hook 会静默失败；SpringBoard 也没有 data-allowed-write
        // 权限写不了系统数据策略，所以走 NetGuard 进程内拦截）
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationDidEnterBackgroundNotification
                        object:nil queue:nil
                    usingBlock:^(NSNotification *note) { NTM_onEnterBackground(); }];
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIApplicationWillEnterForegroundNotification
                        object:nil queue:nil
                    usingBlock:^(NSNotification *note) { NTM_onEnterForeground(); }];

        // 自动授权通知权限（注入 App 进程，需 Tweak.plist 含 Classes=UNUserNotificationCenter）
        tryHook(objc_getClass("UNUserNotificationCenter"),
                sel_registerName("requestAuthorizationWithOptions:completionHandler:"),
                (IMP)hook_requestAuth, (IMP *)&orig_requestAuth);

        // 屏蔽「允许"XX"使用无线数据」启动弹窗（面板里设为断网的 App）
        tryHook(objc_getClass("SBApplicationLaunchAlertEvaluatorForNetworkBasedAlertItems"),
                sel_registerName("shouldShowLaunchAlertForApplication:"),
                (IMP)hook_shouldShowLaunchAlert, (IMP *)&orig_shouldShowLaunchAlert);
        tryHook(objc_getClass("SBApplicationLaunchAlertService"),
                sel_registerName("showLaunchAlertOfType:forApplication:"),
                (IMP)hook_showLaunchAlert, (IMP *)&orig_showLaunchAlert);

        // 直接拦截 CommCenter 直发的「允许"XX"使用无线数据」请求（回「不允许」，不弹窗）
        tryHookMeta(objc_getClass("SBUserNotificationCenter"),
                    sel_registerName("dispatchUserNotification:flags:replyPort:auditToken:"),
                    (IMP)hook_dispatch, (IMP *)&orig_dispatch);

        // 2.3.25: 展示层兜底 —— 若 dispatchUserNotification 方法不存在，弹窗仍会经此展示
        tryHook(objc_getClass("SBSheetAlertController"),
                sel_registerName("showWithCompletion:"),
                (IMP)hook_showAlertCompletion, (IMP *)&orig_showAlertCompletion);

        // ===== 2.3.30: iOS 16+ 系统级授权弹窗拦截 =====
        // iOS 16+ 无线数据权限弹窗走的是 SpringBoard 内部的 _UISystemAlertViewController /
        // SBAuthorizationDialogController，不走通知系统的 dispatchUserNotification。
        // 这些类通过 showWithCompletion: 展示，复用 hook_showAlertCompletion 检测文本。
        // 如果某些版本这类走 UIAlertController 的 present API，也 hook 一下。
        // 如果某些版本这类走 UIAlertController 的 present API，也 hook 一下。
        tryHook(NSClassFromString(@"_UISystemAlertViewController"),
                sel_registerName(@"showWithCompletion:"),
                (IMP)hook_showAlertCompletion, (IMP *)&orig_showAlertCompletion);
        tryHook(NSClassFromString(@"SBAuthorizationDialogController"),
                sel_registerName(@"showWithCompletion:"),
                (IMP)hook_showAlertCompletion, (IMP *)&orig_showAlertCompletion);
        tryHook(NSClassFromString(@"SBAuthorizationDialogViewController"),
                sel_registerName(@"showWithCompletion:"),
                (IMP)hook_showAlertCompletion, (IMP *)&orig_showAlertCompletion);
        tryHook(NSClassFromString(@"_UIAlertControllerDialogViewController"),
                sel_registerName(@"showWithCompletion:"),
                (IMP)hook_showAlertCompletion, (IMP *)&orig_showAlertCompletion);
        // 更激进：hook UIViewController 的 presentViewController:animated:completion:
        // iOS 16+ 系统级授权弹窗通过 UIAlertController + presentViewControllerAnimated: 展示
        // 这是最通用的兜底，覆盖所有通过 present API 展示的 UIAlertController
        tryHook(objc_getClass("UIViewController"),
                sel_registerName("presentViewControllerAnimated:completion:"),
                (IMP)hook_presentVC, (IMP *)&orig_presentVC);
        // SpringBoard 的 UIViewController 子类（如 _SBSheetAlertController）也可能走这个 API
        // 但 SpringBoard 自己有个 presentVC 包装类，先跳过以免误伤系统其他弹窗

        // 诊断日志：记录 init 完成
        if (NTM_isSpringBoard()) {
            NTM_diagLog(@"init DONE v2.3.30");
        }
    }
}