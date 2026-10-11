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
static NSUInteger hook_shouldShowLaunchAlert(id self, SEL _cmd, id app) {
    NSString *bid = NTM_appBundleId(app);
    // 断网 或 开启了后台断网 → 不展示（后台断网的App回前台时也会触发这个评估，需要一并拦住）
    if (bid.length && (NTM_netRead(bid) == 1 || NTM_bgNetOn(bid))) return 0;
    if (orig_shouldShowLaunchAlert) return orig_shouldShowLaunchAlert(self, _cmd, app);
    return 0;
}
static void (*orig_showLaunchAlert)(id, SEL, NSUInteger, id);
static void hook_showLaunchAlert(id self, SEL _cmd, NSUInteger type, id app) {
    NSString *bid = NTM_appBundleId(app);
    // 断网 或 开启了后台断网 → 不展示
    if (bid.length && (NTM_netRead(bid) == 1 || NTM_bgNetOn(bid))) return;
    if (orig_showLaunchAlert) orig_showLaunchAlert(self, _cmd, type, app);
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
static void NTM_sendDenyReply(uint64_t replyPort) {
    if (!replyPort) return;
    struct {
        mach_msg_header_t header;
        uint32_t response;
    } msg = {0};
    msg.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSGH_BITS_ZERO);
    msg.header.msgh_size = (mach_msg_size_t)sizeof(msg); // 28
    msg.header.msgh_remote_port = (mach_port_t)replyPort;
    msg.header.msgh_id = 0;
    msg.response = 0; // 0 = Default = 「不允许」
    @try {
        mach_msg(&msg.header, MACH_SEND_MSG, (mach_msg_size_t)sizeof(msg),
                 0, MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
    } @catch (NSException *e) {}
}

// 「允许“微信”使用无线数据？」→ 微信
static NSString *NTM_appNameOfHeader(NSString *header) {
    if (!header.length) return nil;
    NSArray *quotes = @[@[@"\u201C", @"\u201D"], @[@"\"", @"\""]];
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

// 这条 CommCenter 请求是不是「面板里已断网的 App」
static BOOL NTM_shouldDenyWirelessAlert(id msg) {
    @try {
        if (!msg) return NO;
        NSString *src = [msg objectForKey:@"AlertSource"];
        if (![src isKindOfClass:[NSString class]] || ![src isEqualToString:@"CommCenter"]) return NO;
        NSString *hdr = [msg objectForKey:@"AlertHeader"];
        if (![hdr isKindOfClass:[NSString class]] || ![hdr containsString:@"使用无线数据"]) return NO;
        NSString *bid = NTM_bundleIdOfName(NTM_appNameOfHeader(hdr));
        if (!bid.length) return NO;
        // 与前面启动弹窗 hook 同一条件：断网 或 开了后台断网
        return (NTM_netRead(bid) == 1 || NTM_bgNetOn(bid));
    } @catch (NSException *e) { return NO; }
}

// auditToken 是结构体（>16 字节）时按指针传，这里统一用 void* 承接并原样透传
static void (*orig_dispatch)(id, SEL, id, uint64_t, uint64_t, void *);
static void hook_dispatch(id self, SEL _cmd, id msg, uint64_t flags,
                          uint64_t replyPort, void *auditToken) {
    if (NTM_shouldDenyWirelessAlert(msg)) {
        NTM_sendDenyReply(replyPort); // 回「不允许」，不创建弹窗
        return;
    }
    if (orig_dispatch) orig_dispatch(self, _cmd, msg, flags, replyPort, auditToken);
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
        // ===== 卡密验证（2.3.24 新增）=====
        // 读取保存的激活码
        NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:NTM_suiteName];
        NSString *savedKey = [d stringForKey:@"NTM_activation_key"];
        NSDate *verifyExpires = [d objectForKey:@"NTM_verify_expires"];
        NSString *verifyUdid = [d stringForKey:@"NTM_verify_udid"];
        
        // 读 UDID
        NSString *udid = nil;
        void *mg = dlopen("/System/Library/PrivateFrameworks/MobileGestalt.framework/MobileGestalt", RTLD_NOW);
        if (mg) {
            NSString *(*copyAnswer)(NSString *, NSDictionary *) = dlsym(mg, "MGCopyAnswer");
            if (copyAnswer) udid = copyAnswer(@"UniqueDeviceID", nil);
            dlclose(mg);
        }
        
        // 判断验证状态
        BOOL verified = NO;
        if (savedKey.length && verifyExpires) {
            // 本地有缓存 + 未过期
            if ([verifyExpires compare:[NSDate date]] != NSOrderedAscending) {
                // UDID 匹配（如果之前绑定过）
                if (!verifyUdid.length || !udid.length || [verifyUdid isEqualToString:udid]) {
                    verified = YES;
                }
            }
        }
        
        // 设置面板改了卡密 → 重新验证
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL, NTM_cacheInvalidated,
                                        CFSTR("com.ntm.notifymanager.activationChanged"),
                                        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        
        // 如果没验证通过，发异步请求验证服务器（不阻塞启动）— 正确 API
        if (!verified && savedKey.length) {
            NSString *udidStr = udid ?: @"";
            NSString *body = [NSString stringWithFormat:
                @"action=verify&device_id=%@&tweak_id=com.ntm.notifymanager",
                udidStr];
            NSMutableURLRequest *vreq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"http://101.200.189.251/verify.php"]];
            vreq.HTTPMethod = @"POST";
            vreq.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];
            [vreq setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
            vreq.timeoutInterval = 8;
            [NSURLConnection sendAsynchronousRequest:vreq queue:[NSOperationQueue mainQueue]
                                  completionHandler:^(NSURLResponse *resp, NSData *data, NSError *err) {
                if (!err && data) {
                    @try {
                        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                        if ([json isKindOfClass:[NSDictionary class]] && [json[@"authorized"] boolValue]) {
                            NSUserDefaults *dd = [[NSUserDefaults alloc] initWithSuiteName:NTM_suiteName];
                            NSNumber *expiryNum = json[@"expiry"];
                            NSDate *expDate;
                            if (expiryNum && [expiryNum longLongValue] > 0) {
                                expDate = [[NSDate dateWithTimeIntervalSince1970:[expiryNum doubleValue]] dateByAddingTimeInterval:7*86400];
                            } else {
                                expDate = [[NSDate date] dateByAddingTimeInterval:365*86400];
                            }
                            [dd setObject:expDate forKey:@"NTM_verify_expires"];
                            [dd setObject:udidStr forKey:@"NTM_verify_udid"];
                            [dd synchronize];
                            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                CFSTR("com.ntm.notifymanager.verifyResult"), NULL,
                                (__bridge CFDictionaryRef)@{@"valid": @YES}, YES);
                        } else {
                            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                CFSTR("com.ntm.notifymanager.verifyResult"), NULL,
                                (__bridge CFDictionaryRef)@{@"valid": @NO}, YES);
                        }
                    } @catch (NSException *e) {}
                }
            }];
        }
        
        // 未验证通过 → 跳过所有 hooks（功能等于没装）
        // 但注册 configChanged/mirrorUpdated 通知（设置面板还能用）
        if (!verified) {
            // 监听 activationChanged → 面板输入卡密后重走 init
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                            NULL, NTM_cacheInvalidated,
                                            CFSTR("com.ntm.notifymanager.configChanged"),
                                            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                            NULL, NTM_mirrorUpdatedCb,
                                            CFSTR("com.ntm.notifymanager.mirrorUpdated"),
                                            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
            
            // SpringBoard 进程：10s 后再次检查验证状态（面板可能刚激活了）
            if (NTM_isSpringBoard()) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    NSUserDefaults *dd = [[NSUserDefaults alloc] initWithSuiteName:NTM_suiteName];
                    NSString *k = [dd stringForKey:@"NTM_activation_key"];
                    NSDate *ex = [dd objectForKey:@"NTM_verify_expires"];
                    if (k.length && ex && [ex compare:[NSDate date]] != NSOrderedAscending) {
                        // 面板已激活，但 SpringBoard 进程 init() 已过，
                        // 这里发个 Darwin 通知让面板显示「请重启设备」
                        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                            CFSTR("com.ntm.notifymanager.needRestart"), NULL, NULL, YES);
                    }
                });
            }
            
            return; // ← 不验证通过就退出，下面的 tryHook 全跳过
        }
        
        // ===== 以下为 2.3.24 前的原始 init 逻辑，只在验证通过后执行 =====
        
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

        // SpringBoard 开机全量补写一次镜像（升级后没有配置变更也要生效）。
        // 延后 10s 避开启动高峰；NTM_writeMirrors 内部自判进程，非 SpringBoard 空转返回。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)),
                       NTM_mirrorQueue(), ^{ NTM_writeMirrors(); });

        // 自动授权通知默认开启：保证重装/抹除后打开 App 不再弹授权框（面板可手动关）
        [NTM_prefs() registerDefaults:@{@"NTM_autoAuth": @YES}];

        // ===== 所有 hooks =====

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
    }
}