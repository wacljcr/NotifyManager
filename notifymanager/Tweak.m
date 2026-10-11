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

// ===== 2.3.24 激活缓存：用 rootless 公共路径 JSON 文件（跨容器隔离）=====
// rootless 下 /var/jb/var/mobile/Library/ 所有进程都能读写，解决 Preferences 和 SpringBoard 容器隔离问题
static NSString *NTM_licensePath(void) {
    // rootless 路径优先；如果不存在用原版路径（非 rootless 兼容）
    static NSString *p = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        p = @"/var/jb/var/mobile/Library/NTM_license.json";
        // 确保目录存在
        [[NSFileManager defaultManager] createDirectoryAtPath:[p stringByDeletingLastPathComponent]
                                  withIntermediateDirectories:YES attributes:nil error:nil];
    });
    return p;
}

// 读激活缓存：返回 dict 或 nil
static NSDictionary *NTM_readLicense(void) {
    @autoreleasepool {
        NSString *path = NTM_licensePath();
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (!data) return nil;
        NSError *err = nil;
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
        if (err || ![json isKindOfClass:[NSDictionary class]]) return nil;
        return (NSDictionary *)json;
    }
}

// 写激活缓存
static void NTM_writeLicense(NSDictionary *dict) {
    @autoreleasepool {
        if (!dict) {
            [NSFileManager.defaultManager removeItemAtPath:NTM_licensePath() error:nil];
            return;
        }
        NSError *err = nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:0 error:&err];
        if (!err) [data writeToFile:NTM_licensePath() atomically:YES];
    }
}

static NSString *NTM_prefsFile(void) {
    // 旧的 NSUserDefaults suite 路径（用于兼容迁移）
    NSString *home = NSHomeDirectory();
    return [home stringByAppendingPathComponent:@"Library/Preferences/com.ntm.notifymanager.plist"];
}

// 迁移：如果公共 JSON 没有但 NSUserDefaults suite 有，迁移过来
static void NTM_migrateFromSuite(void) {
    @autoreleasepool {
        if (NTM_readLicense()) return; // 已有
        NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:NTM_suiteName];
        NSString *key = [d stringForKey:@"NTM_activation_key"];
        if (!key.length) return;
        NSDate *exp = [d objectForKey:@"NTM_verify_expires"];
        NSString *udid = [d stringForKey:@"NTM_verify_udid"];
        if (!exp) return;
        // 迁移到公共 JSON
        NTM_writeLicense(@{
            @"activation_key": key ?: @"",
            @"verify_expires": @([exp timeIntervalSince1970]),
            @"verify_udid": udid ?: @"",
        });
        fprintf(stderr, "[NTM] 迁移 NSUserDefaults → 公共 JSON OK\n");
    }
}


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

// ===== 2.3.24 验证核心 forward declaration（定义在文件底部）=====
static inline BOOL NTM_isAuthorized(void);
static void NTM_bgRefresh(void);
static inline NSString *NTM_readUdid(void);

#pragma mark - Hook NCNotificationDispatcher (总开关 + 关键词过滤 + 隐藏预览)
static void (*orig_postRequest)(id, SEL, id);
static void hook_postRequest(id self, SEL _cmd, id request) {
    if (!NTM_isAuthorized()) { if (orig_postRequest) orig_postRequest(self, _cmd, request); return; }
    NSString *sectionId = NTM_sectionOf(request);
    if (sectionId.length) {
        if (NTM_matchKeyword(sectionId, request)) return;
        if (!NTM_on(sectionId, @"en")) return;
        if (NTM_feat(sectionId, @"noPreview")) NTM_blankPreview(request);
    }
    if (orig_postRequest) orig_postRequest(self, _cmd, request);
}

#pragma mark - Hook SBDashBoardNotificationPresenter (横幅)
static void (*orig_presentBanner)(id, SEL, id);
static void hook_presentBanner(id self, SEL _cmd, id request) {
    if (!NTM_isAuthorized()) { if (orig_presentBanner) orig_presentBanner(self, _cmd, request); return; }
    NSString *sectionId = NTM_sectionOf(request);
    if (sectionId.length && NTM_shouldBlock(sectionId, @"banner")) return;
    if (orig_presentBanner) orig_presentBanner(self, _cmd, request);
}

#pragma mark - Hook SBNCSoundController (声音)
static BOOL (*orig_canPlaySound)(id, SEL, id);
static BOOL hook_canPlaySound(id self, SEL _cmd, id request) {
    if (!NTM_isAuthorized()) return orig_canPlaySound ? orig_canPlaySound(self, _cmd, request) : YES;
    NSString *sectionId = NTM_sectionOf(request);
    if (sectionId.length && NTM_shouldBlock(sectionId, @"sound")) return NO;
    return orig_canPlaySound ? orig_canPlaySound(self, _cmd, request) : YES;
}

#pragma mark - Hook SBApplication (角标)
static void (*orig_setBadgeValue)(id, SEL, id);
static void hook_setBadgeValue(id self, SEL _cmd, id value) {
    if (!NTM_isAuthorized()) { if (orig_setBadgeValue) orig_setBadgeValue(self, _cmd, value); return; }
    NSString *bundleId = nil;
    @try { bundleId = [self performSelector:@selector(bundleIdentifier)]; } @catch(NSException *e) {}
    if (bundleId.length) {
        BOOL noBadge = NTM_feat(bundleId, @"noBadge");
        if (noBadge || NTM_shouldBlock(bundleId, @"badge")) return;
    }
    if (orig_setBadgeValue) orig_setBadgeValue(self, _cmd, value);
}

#pragma mark - Hook 通知列表插入 (锁屏/通知中心)
static BOOL (*orig_insertRequest)(id, SEL, id);
static BOOL hook_insertRequest(id self, SEL _cmd, id request) {
    if (!NTM_isAuthorized()) return orig_insertRequest ? orig_insertRequest(self, _cmd, request) : YES;
    NSString *sectionId = NTM_sectionOf(request);
    if (sectionId.length &&
        (NTM_shouldBlock(sectionId, @"lock") || NTM_shouldBlock(sectionId, @"nc")))
        return YES;
    return orig_insertRequest ? orig_insertRequest(self, _cmd, request) : YES;
}

static BOOL (*orig_insertRequestCoalesced)(id, SEL, id, id);
static BOOL hook_insertRequestCoalesced(id self, SEL _cmd, id request, id coalesce) {
    if (!NTM_isAuthorized()) return orig_insertRequestCoalesced ? orig_insertRequestCoalesced(self, _cmd, request, coalesce) : YES;
    NSString *sectionId = NTM_sectionOf(request);
    if (sectionId.length &&
        (NTM_shouldBlock(sectionId, @"lock") || NTM_shouldBlock(sectionId, @"nc")))
        return YES;
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
    if (!NTM_isAuthorized()) { if (orig_requestAuth) orig_requestAuth(self, _cmd, options, handler); return; }
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
    if (!NTM_isAuthorized()) return orig_shouldShowLaunchAlert ? orig_shouldShowLaunchAlert(self, _cmd, app) : 0;
    NSString *bid = NTM_appBundleId(app);
    if (bid.length && (NTM_netRead(bid) == 1 || NTM_bgNetOn(bid))) return 0;
    if (orig_shouldShowLaunchAlert) return orig_shouldShowLaunchAlert(self, _cmd, app);
    return 0;
}
static void (*orig_showLaunchAlert)(id, SEL, NSUInteger, id);
static void hook_showLaunchAlert(id self, SEL _cmd, NSUInteger type, id app) {
    if (!NTM_isAuthorized()) { if (orig_showLaunchAlert) orig_showLaunchAlert(self, _cmd, type, app); return; }
    NSString *bid = NTM_appBundleId(app);
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
    if (!NTM_isAuthorized()) { if (orig_dispatch) orig_dispatch(self, _cmd, msg, flags, replyPort, auditToken); return; }
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

// ===== 2.3.24 验证核心（抄 CallAssist 架构：每 hook 入口验，非 init 一次性验）=====
static NSTimeInterval g_lastBgCheck = 0;

static inline NSString *NTM_readUdid(void) {
    NSString *udid = nil;
    void *mg = dlopen("/System/Library/PrivateFrameworks/MobileGestalt.framework/MobileGestalt", RTLD_NOW);
    if (mg) {
        NSString *(*copyAnswer)(NSString *, NSDictionary *) = dlsym(mg, "MGCopyAnswer");
        if (copyAnswer) udid = copyAnswer(@"UniqueDeviceID", nil);
        dlclose(mg);
    }
    return udid;
}

// 后台异步查服务器（不阻塞 hook 调用，30 秒一次）
static void NTM_bgRefresh(void) {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - g_lastBgCheck < 30) return; // 节流：30 秒
    g_lastBgCheck = now;
    
    NSDictionary *lic = NTM_readLicense();
    NSString *savedKey = lic[@"activation_key"];
    if (!savedKey.length) return;
    
    NSString *udidStr = NTM_readUdid() ?: @"";
    NSString *body = [NSString stringWithFormat:
        @"action=verify&device_id=%@&tweak_id=com.ntm.notifymanager", udidStr];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"http://101.200.189.251/verify.php"]];
    req.HTTPMethod = @"POST";
    req.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];
    [req setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    req.timeoutInterval = 8;
    
    // GCD：全局后台队列里同步请求（不阻塞主/当前线程）
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSURLResponse *resp = nil;
        NSError *nsErr = nil;
        NSData *respData = [NSURLConnection sendSynchronousRequest:req returningResponse:&resp error:&nsErr];
        if (!nsErr && respData) {
            @autoreleasepool {
                id jsonObj = [NSJSONSerialization JSONObjectWithData:respData options:0 error:nil];
                if ([jsonObj isKindOfClass:[NSDictionary class]]) {
                    NSDictionary *j = (NSDictionary *)jsonObj;
                    BOOL ok = [j[@"authorized"] boolValue];
                    if (!ok) {
                        // 服务器说 NO → 吊销/过期！删公共 JSON！
                        fprintf(stderr, "[NTM bg] verify.php 返回 false → NTM_writeLicense(nil)\n");
                        NTM_writeLicense(nil);
                    }
                }
            }
        }
        // nsErr 或 !respData → 服务器不可达 → 不动缓存（离线宽限继续）
    });
}

// 核心：每个 hook 函数入口第一行就调这个
// 抄 CallAssist 的"每次功能启用前验签"思路
static inline BOOL NTM_isAuthorized(void) {
    @autoreleasepool {
        // 迁移兼容：旧 NSUserDefaults suite → 公共 JSON
        NTM_migrateFromSuite();
        
        NSDictionary *lic = NTM_readLicense();
        if (!lic) { NTM_bgRefresh(); return NO; }
        
        NSString *savedKey = lic[@"activation_key"];
        if (!savedKey.length) { NTM_bgRefresh(); return NO; }
        
        // 检查过期
        NSNumber *expNum = lic[@"verify_expires"];
        if (!expNum || [expNum doubleValue] <= 0 || [expNum doubleValue] < [[NSDate date] timeIntervalSince1970]) {
            NTM_bgRefresh(); return NO;
        }
        
        // UDID 匹配
        NSString *cachedUdid = lic[@"verify_udid"];
        if (cachedUdid.length) {
            NSString *curUdid = NTM_readUdid();
            if (curUdid.length && ![cachedUdid isEqualToString:curUdid]) {
                NTM_bgRefresh(); return NO; // 换设备了
            }
        }
        
        // 本地缓存 OK，后台异步刷新（不阻塞这次调用）
        NTM_bgRefresh();
        return YES;
    }
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
        // 暴力 marker 文件！让 ssh 直接 ls /tmp/ntm_* 看 init() 到底跑了什么
        // 文件名带进程名后缀，SpringBoard = /tmp/ntm_SpringBoard_*
        NSString *procName = [NSString stringWithUTF8String:NSProcessInfo.processInfo.processName.UTF8String ?: "unknown"];
        NSString *prefix = [NSString stringWithFormat:@"/tmp/ntm_%@", procName];
        NSFileManager *fm = NSFileManager.defaultManager;
        
        // 清理旧 marker（上次启动的）
        [fm removeItemAtPath:[prefix stringByAppendingString:@"_start"] error:nil];
        [fm removeItemAtPath:[prefix stringByAppendingString:@"_yes"] error:nil];
        [fm removeItemAtPath:[prefix stringByAppendingString:@"_no"] error:nil];
        [fm removeItemAtPath:[prefix stringByAppendingString:@"_hooked"] error:nil];
        
        // 写 init start marker
        [fm createFileAtPath:[prefix stringByAppendingString:@"_start"] contents:nil attributes:nil];
        fprintf(stderr, "[NTM] ===== init() start [%s] =====", procName.UTF8String);
        
        // ===== 卡密验证（2.3.24 新增，改公共 JSON 解决 rootless 容器隔离）=====
        NTM_migrateFromSuite(); // 旧 suite → 公共 JSON 迁移
        NSDictionary *lic = NTM_readLicense();
        NSString *savedKey = lic[@"activation_key"];
        NSNumber *verifyExpires = lic[@"verify_expires"];
        NSString *verifyUdid = lic[@"verify_udid"];
        
        char keyBuf[256] = "(nil)";
        if (savedKey.length) snprintf(keyBuf, sizeof(keyBuf), "%s", savedKey.UTF8String);
        char expBuf[128] = "(nil)";
        if (verifyExpires) snprintf(expBuf, sizeof(expBuf), "%.0f", verifyExpires.doubleValue);
        char udidBuf[64] = "(nil)";
        if (verifyUdid.length) snprintf(udidBuf, sizeof(udidBuf), "%s", verifyUdid.UTF8String);
        fprintf(stderr, "[NTM] savedKey=%s expires=%s udid_cached=%s path=%s",
                keyBuf, expBuf, udidBuf, [NTM_licensePath() UTF8String]);
        
        // 读 UDID
        NSString *udid = nil;
        void *mg = dlopen("/System/Library/PrivateFrameworks/MobileGestalt.framework/MobileGestalt", RTLD_NOW);
        if (mg) {
            NSString *(*copyAnswer)(NSString *, NSDictionary *) = dlsym(mg, "MGCopyAnswer");
            if (copyAnswer) udid = copyAnswer(@"UniqueDeviceID", nil);
            dlclose(mg);
        }
        fprintf(stderr, "[NTM] device UDID=%s", udid ? [udid UTF8String] : "(nil)");
        
        BOOL verified = NO;
        
        if (savedKey.length) {
            fprintf(stderr, "[NTM] savedKey found → requesting server verify.php ...");
            // 同步请求服务器（超时 5 秒，可接受）
            NSString *udidStr = udid ?: @"";
            NSString *body = [NSString stringWithFormat:
                @"action=verify&device_id=%@&tweak_id=com.ntm.notifymanager",
                udidStr];
            NSMutableURLRequest *vreq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"http://101.200.189.251/verify.php"]];
            vreq.HTTPMethod = @"POST";
            vreq.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];
            [vreq setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
            vreq.timeoutInterval = 5;
            
            NSURLResponse *resp = nil; NSError *serr = nil;
            NSData *sdata = [NSURLConnection sendSynchronousRequest:vreq returningResponse:&resp error:&serr];
            
            if (!serr && sdata) {
                NSString *respStr = [[NSString alloc] initWithData:sdata encoding:NSUTF8StringEncoding];
                fprintf(stderr, "[NTM] server response=%s", [respStr UTF8String]);
                // 服务器可达 → 听服务器的
                @try {
                    id json = [NSJSONSerialization JSONObjectWithData:sdata options:0 error:nil];
                    BOOL auth = [json isKindOfClass:[NSDictionary class]] && [json[@"authorized"] boolValue];
                    fprintf(stderr, "[NTM] parsed authorized=%d", auth);
                    if (auth) {
                        verified = YES;
                        // 更新公共 JSON 缓存
                        NSNumber *expiryNum = json[@"expiry"];
                        NSTimeInterval expTs = 0;
                        if (expiryNum && [expiryNum longLongValue] > 0) {
                            expTs = [expiryNum doubleValue] + 7*86400; // +7 天宽限
                        } else {
                            expTs = [[NSDate date] timeIntervalSince1970] + 365*86400;
                        }
                        NTM_writeLicense(@{
                            @"activation_key": savedKey,
                            @"verify_expires": @(expTs),
                            @"verify_udid": udidStr,
                        });
                        fprintf(stderr, "[NTM] ✅ 公共 JSON 已更新\n");
                    } else {
                        // 服务器说 NO → 删公共 JSON！
                        fprintf(stderr, "[NTM] ❌ 服务器拒绝 → NTM_writeLicense(nil)\n");
                        NTM_writeLicense(nil);
                    }
                } @catch (NSException *e) {
                    fprintf(stderr, "[NTM] JSON parse fail: %s", [e.reason UTF8String]);
                }
            } else {
                fprintf(stderr, "[NTM] server request error: %s", [serr.localizedDescription UTF8String]);
                // 服务器不可达 → 用本地缓存（离线宽限）
                NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
                if (verifyExpires && [verifyExpires doubleValue] > now) {
                    if (!verifyUdid.length || !udid.length || [verifyUdid isEqualToString:udid]) {
                        fprintf(stderr, "[NTM] 离线宽限 → verified=YES");
                        verified = YES;
                    }
                }
            }
        } else {
            fprintf(stderr, "[NTM] 无 savedKey → verified=NO（跳过验证请求）");
        }
        
        fprintf(stderr, "[NTM] ===== init verify done, cached verified=%d =====", verified);
        // init 里的同步验证只负责存/清缓存，不再决定装不装 hook
        // 每个 hook 函数入口自己调 NTM_isAuthorized() guard —— 抄 CallAssist 架构
        // tryHook 永远照装
        
        // ===== init 通知注册 + 默认配置（不管验证状态）=====
        
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

        // SpringBoard 开机全量补写一次镜像
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)),
                       NTM_mirrorQueue(), ^{ NTM_writeMirrors(); });

        // 自动授权通知默认开启
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
        
        // hook 全装完，写 marker
        [fm createFileAtPath:[prefix stringByAppendingString:@"_hooked"] contents:nil attributes:nil];
        fprintf(stderr, "[NTM] ===== ALL hooks installed =====");
    }
}