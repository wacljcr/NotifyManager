// NotifyManager.m — 通知管理设置面板（自定义现代 UI）
// 枚举已安装 App，按分类(用户/巨魔/系统)展示
// 每个 App：总开关 + 锁定屏幕/通知中心/横幅/声音/标记 子开关 + 单应用重置
// 增强功能：仅隐藏角标 / 隐藏预览 / 后台自动断网 / 关键词过滤 / 分组
// 网络策略按钮：打开wifi/流量/wifi+流量/断网
// 顶部：模式快照 / 应用分组；批量开启/关闭/自定义；筛选；搜索
// 列表使用 UITableView 虚拟化，切换分类/搜索即时响应
// 配置保存到 NSUserDefaults suiteName，Tweak 读取并拦截通知/断网
// 设置变更时同步到系统通知设置 (BBSettingsGateway) 与蜂窝网络 (PSAppDataUsagePolicyCache)
// 断网落盘路径: policiesFor: -> setCellular:/setWifi: -> setPolicies:completion:
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

#pragma mark - 接口声明
// iOS 15/16/17 真实接口（无 setUsagePoliciesForBundle:cellular:wifi:）：
@interface PSAppDataUsagePolicyCache : NSObject
+ (instancetype)sharedInstance;
- (id)policiesFor:(NSString *)bundleId;                              // -> CTDataUsagePolicies
- (void)setPolicies:(id)policy completion:(void (^)(void))completion;
@end
@interface CTDataUsagePolicies : NSObject
- (instancetype)init:(NSString *)bundleId withCellularPolicy:(long long)cellular andWifiPolicy:(long long)wifi;
- (void)setCellular:(long long)cellular;                             // 1=允许 0=禁止
- (void)setWifi:(long long)wifi;                                     // 1=允许 0=禁止
@end

static NSDictionary *NTM_cellularPolicies(void);
static NSInteger NTM_netReadSystem(NSString *appId);
static NSArray *NTM_allApps(void);
@interface PSViewController : UIViewController
@end

@interface NTMPrincipalController : PSViewController <UISearchBarDelegate, UIDocumentPickerDelegate, UITableViewDelegate, UITableViewDataSource>
@end

// 激活相关方法声明（category）
@interface NTMPrincipalController (ActivationStuff)
- (void)setupActivationBar;
- (void)showActivationModalIfNeeded;
- (BOOL)NTM_isActivated;
- (void)activationSucceed;
- (void)NTM_applyLock;
- (void)NTM_disableControlsIn:(UIView *)view locked:(BOOL)lock;
- (NSString *)NTM_readUDID;
@end

#pragma mark - 存储: NSUserDefaults suiteName (Tweak 读取同一份)
static NSString *NTM_suite = @"com.ntm.notifymanager";

// ===== 2.3.24 激活缓存公共 JSON（跨 rootless 容器隔离）=====
static NSString *NTM_licPath(void) {
    static NSString *p = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        p = @"/var/jb/var/mobile/Library/NTM_license.json";
        [[NSFileManager defaultManager] createDirectoryAtPath:[p stringByDeletingLastPathComponent]
                                  withIntermediateDirectories:YES attributes:nil error:nil];
    });
    return p;
}
static void NTM_writeLic(NSDictionary *dict) {
    if (!dict) { [NSFileManager.defaultManager removeItemAtPath:NTM_licPath() error:nil]; return; }
    NSError *e = nil;
    NSData *d = [NSJSONSerialization dataWithJSONObject:dict options:0 error:&e];
    if (!e) [d writeToFile:NTM_licPath() atomically:YES];
}
static NSDictionary *NTM_readLic(void) {
    NSData *d = [NSData dataWithContentsOfFile:NTM_licPath()];
    if (!d) return nil;
    NSError *e = nil;
    id j = [NSJSONSerialization JSONObjectWithData:d options:0 error:&e];
    if (e || ![j isKindOfClass:[NSDictionary class]]) return nil;
    return (NSDictionary *)j;
}

static NSString *NTM_key(NSString *appId, NSString *dim) {
    return [NSString stringWithFormat:@"NTM_%@_%@", dim, appId];
}
static NSUserDefaults *NTM_prefs(void) {
    static NSUserDefaults *prefs = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        prefs = [[NSUserDefaults alloc] initWithSuiteName:NTM_suite];
    });
    return prefs;
}
static BOOL NTM_read(NSString *appId, NSString *dim) {
    id v = [NTM_prefs() objectForKey:NTM_key(appId, dim)];
    return v ? [v boolValue] : YES;
}
static BOOL NTM_readWith(NSUserDefaults *prefs, NSString *appId, NSString *dim) {
    id v = [prefs objectForKey:NTM_key(appId, dim)];
    return v ? [v boolValue] : YES;
}
// 增强开关：未设置默认关闭
static BOOL NTM_feat(NSString *appId, NSString *key) {
    id v = [NTM_prefs() objectForKey:NTM_key(appId, key)];
    return v ? [v boolValue] : NO;
}
// 维护"是否有 App 开了后台断网"的全局标记，供 Tweak 快速跳过场景 KVC（省电）。
// 需在每次 bgNet 可能变化后调用。
static void NTM_postConfigChanged(void); // 定义见下
static void NTM_updateAnyBgNet(void) {
    BOOL any = NO;
    for (NSDictionary *app in NTM_allApps()) {
        if (app[@"id"] && NTM_feat(app[@"id"], @"bgNet")) { any = YES; break; }
    }
    [NTM_prefs() setBool:any forKey:@"NTM_anyBgNet"];
    [NTM_prefs() synchronize];
    NTM_postConfigChanged(); // 通知 SpringBoard 重写配置镜像（App 沙盒读不到 suite）
}
static void NTM_postConfigChanged(void) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.ntm.notifymanager.configChanged"),
                                         NULL, NULL, YES);
}
static void NTM_write(NSString *appId, NSString *dim, BOOL val) {
    [NTM_prefs() setBool:val forKey:NTM_key(appId, dim)];
    [NTM_prefs() synchronize];
    NTM_postConfigChanged();
}

#pragma mark - 网络权限存储
// policy: 0=wifi+流量 1=断网 2=打开wifi 3=流量
static NSString *NTM_netKey(NSString *appId) {
    return [NSString stringWithFormat:@"NTM_net_%@", appId];
}
static NSInteger NTM_netReadSystem(NSString *appId) {
    NSDictionary *ap = NTM_cellularPolicies();
    NSDictionary *policy = ap[appId];
    if (![policy isKindOfClass:[NSDictionary class]]) return 0;
    NSString *cell = policy[@"kCTCellularDataUsagePolicy"];
    NSString *wifi = policy[@"kCTWiFiDataUsagePolicy"];
    BOOL cellOn = cell.length && [cell containsString:@"Allow"];
    BOOL wifiOn = wifi.length && [wifi containsString:@"Allow"];
    if (cellOn && wifiOn) return 0;
    if (!cellOn && !wifiOn) return 1;
    if (wifiOn) return 2;
    return 3;
}
static NSInteger NTM_netRead(NSString *appId) {
    id v = [NTM_prefs() objectForKey:NTM_netKey(appId)];
    if (v) return [v integerValue];
    return NTM_netReadSystem(appId);
}
static void NTM_netWrite(NSString *appId, NSInteger policy) {
    [NTM_prefs() setInteger:policy forKey:NTM_netKey(appId)];
    [NTM_prefs() synchronize];
    NTM_postConfigChanged(); // App 进程要靠它刷新「断网」拦截 + 配置镜像（此前漏发）
}
static NSArray *NTM_netOptions(void) {
    return @[
        @{@"title":@"wifi",     @"policy":@2},
        @{@"title":@"流量",     @"policy":@3},
        @{@"title":@"wifi+流量", @"policy":@0},
        @{@"title":@"断网",     @"policy":@1},
    ];
}
static UIColor *NTM_netColor(NSInteger policy) {
    switch (policy) {
        case 1: return [UIColor colorWithRed:0.87 green:0.24 blue:0.24 alpha:1];
        case 2: return [UIColor colorWithRed:0.30 green:0.55 blue:1.0 alpha:1];
        case 3: return [UIColor colorWithRed:0.42 green:0.75 blue:0.50 alpha:1];
        default: return [UIColor colorWithRed:0.32 green:0.68 blue:0.88 alpha:1];
    }
}

#pragma mark - 关键词存储 (NSString JSON 数组 / NSArray)
static NSArray *NTM_kwList(NSString *appId) {
    id v = [NTM_prefs() objectForKey:NTM_key(appId, @"kw")];
    if ([v isKindOfClass:[NSArray class]]) return v;
    if ([v isKindOfClass:[NSString class]] && [(NSString *)v length]) {
        NSData *d = [(NSString *)v dataUsingEncoding:NSUTF8StringEncoding];
        id parsed = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        if ([parsed isKindOfClass:[NSArray class]]) return parsed;
    }
    return @[];
}
static void NTM_kwSave(NSString *appId, NSArray *list) {
    NSMutableArray *clean = [NSMutableArray array];
    for (NSString *s in list) {
        NSString *t = [(s ?: @"") stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.length) [clean addObject:t];
    }
    if (clean.count) {
        NSData *d = [NSJSONSerialization dataWithJSONObject:clean options:0 error:nil];
        [NTM_prefs() setObject:[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] forKey:NTM_key(appId, @"kw")];
    } else {
        [NTM_prefs() removeObjectForKey:NTM_key(appId, @"kw")];
    }
    [NTM_prefs() synchronize];
    NTM_postConfigChanged();
}

#pragma mark - 分组存储
static NSArray *NTM_groupNames(void) {
    NSArray *arr = [NTM_prefs() objectForKey:@"NTM_groupNames"];
    return [arr isKindOfClass:[NSArray class]] ? arr : @[];
}
static void NTM_setGroup(NSString *appId, NSString *name) {
    if (name.length) {
        [NTM_prefs() setObject:name forKey:NTM_key(appId, @"group")];
    } else {
        [NTM_prefs() removeObjectForKey:NTM_key(appId, @"group")];
    }
    [NTM_prefs() synchronize];
    NTM_postConfigChanged();
}
static void NTM_addGroupName(NSString *name) {
    name = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!name.length) return;
    NSMutableArray *arr = [NTM_groupNames() mutableCopy];
    if (![arr containsObject:name]) [arr addObject:name];
    [NTM_prefs() setObject:arr forKey:@"NTM_groupNames"];
    [NTM_prefs() synchronize];
}
static void NTM_removeGroupName(NSString *name) {
    NSMutableArray *arr = [NTM_groupNames() mutableCopy];
    [arr removeObject:name];
    [NTM_prefs() setObject:arr forKey:@"NTM_groupNames"];
    // 该组下所有 App 回到未分组
    for (NSString *k in [NTM_prefs() dictionaryRepresentation].allKeys) {
        if ([k hasPrefix:@"NTM_group_"] && [[NTM_prefs() objectForKey:k] isEqualToString:name]) {
            [NTM_prefs() removeObjectForKey:k];
        }
    }
    [NTM_prefs() synchronize];
    NTM_postConfigChanged();
}

#pragma mark - 同步到系统通知设置 (BBSettingsGateway)
static id NTM_gateway(void) {
    static id gw = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = NSClassFromString(@"BBSettingsGateway");
        if (cls) gw = [[cls alloc] init];
    });
    return gw;
}
static dispatch_queue_t NTM_syncQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("com.ntm.sync", DISPATCH_QUEUE_SERIAL); });
    return q;
}
static void NTM_syncSystem(NSString *appId) {
    if (!appId.length) return;
    @try {
        id gateway = NTM_gateway();
        if (!gateway) return;
        id info = [gateway performSelector:@selector(sectionInfoForSectionID:) withObject:appId];
        if (!info) return;
        BOOL en = NTM_read(appId, @"en");
        BOOL lock = NTM_read(appId, @"lock");
        BOOL nc = NTM_read(appId, @"nc");
        BOOL banner = NTM_read(appId, @"banner");
        BOOL anyVisible = lock || nc || banner;
        BOOL sound = en && anyVisible && NTM_read(appId, @"sound");
        BOOL badge = en && anyVisible && NTM_read(appId, @"badge");
        [info setValue:@(en) forKey:@"allowsNotifications"];
        [info setValue:@(lock) forKey:@"showsInLockScreen"];
        [info setValue:@(nc) forKey:@"showsInNotificationCenter"];
        [info setValue:@(banner ? 1 : 0) forKey:@"alertType"];
        NSUInteger push = 0;
        if (sound) push |= 18;
        if (badge) push |= 9;
        if (banner) push |= 36;
        [info setValue:@(push) forKey:@"pushSettings"];
        SEL setSel = NSSelectorFromString(@"setSectionInfo:forSectionID:");
        if ([gateway respondsToSelector:setSel]) {
            [gateway performSelector:setSel withObject:info withObject:appId];
        }
    } @catch(NSException *e) {
    }
}
static void NTM_syncSystemAsync(NSString *appId) {
    if (!appId.length) return;
    dispatch_async(NTM_syncQueue(), ^{ NTM_syncSystem(appId); });
}

#pragma mark - 同步到系统蜂窝网络设置
static NSDictionary *NTM_cellularPolicies(void) {
    static NSDictionary *dict = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *root = [NSDictionary dictionaryWithContentsOfFile:
            @"/var/mobile/Library/Preferences/com.apple.cellularplan.plist"];
        id ap = root[@"AppPolicy"];
        if ([ap isKindOfClass:[NSDictionary class]]) dict = ap;
    });
    return dict;
}
// iOS 14+ 起 PSAppDataUsagePolicyCache 在 SettingsCellular.framework，iOS 13- 在 Preferences.framework。
// 原来只 dlopen Preferences.framework，导致新系统上找不到该类、写入被静默跳过 → 设置里看不到「关闭」。
static void NTM_loadPolicyFramework(void) {
    static BOOL loaded = NO;
    if (loaded) return;
    if (NSClassFromString(@"PSAppDataUsagePolicyCache")) { loaded = YES; return; }
    dlopen("/System/Library/PrivateFrameworks/SettingsCellular.framework/SettingsCellular", RTLD_NOW);
    if (NSClassFromString(@"PSAppDataUsagePolicyCache")) { loaded = YES; return; }
    dlopen("/System/Library/PrivateFrameworks/Preferences.framework/Preferences", RTLD_NOW);
    if (NSClassFromString(@"PSAppDataUsagePolicyCache")) loaded = YES;
}

// 按系统「设置 → 蜂窝网络 → App → 允许App使用数据」的真实写入路径落盘（已用 Frida 抓系统 UI 验证）：
//   1. cache = PSAppDataUsagePolicyCache.sharedInstance
//   2. pol   = [cache policiesFor:appId]              // CTDataUsagePolicies
//   3. [pol setCellular:0/1] [pol setWifi:0/1]        // 1=允许 0=禁止
//   4. [cache setPolicies:pol completion:^{}]
// 原实现调用的 setUsagePoliciesForBundle:cellular:wifi: 在 iOS 15/16/17 上根本不存在，
// CoreTelephony 的 _CTServerConnectionSetCellularUsagePolicy 也没有导出，写入一直是空操作，
// 所以系统策略从未改变 → 连着 WiFi 时 App 照样有网。此处改为真实路径。
static void NTM_syncCellular(NSString *appId, NSInteger policy) {
    if (!appId.length) return;
    // policy: 0=wifi+流量 1=断网 2=只wifi 3=只流量；系统侧 1=允许 0=禁止
    long long cell = (policy == 0 || policy == 3) ? 1 : 0;
    long long wifi = (policy == 0 || policy == 2) ? 1 : 0;
    NTM_loadPolicyFramework();
    @try {
        Class cls = NSClassFromString(@"PSAppDataUsagePolicyCache");
        if (!cls) return;
        id cache = ((id (*)(id, SEL))objc_msgSend)(cls, NSSelectorFromString(@"sharedInstance"));
        if (!cache) return;

        id pol = nil;
        SEL selPoliciesFor = NSSelectorFromString(@"policiesFor:");
        if ([cache respondsToSelector:selPoliciesFor]) {
            pol = ((id (*)(id, SEL, id))objc_msgSend)(cache, selPoliciesFor, appId);
        }
        if (pol) {
            SEL sCell = NSSelectorFromString(@"setCellular:");
            SEL sWifi = NSSelectorFromString(@"setWifi:");
            if ([pol respondsToSelector:sCell])
                ((void (*)(id, SEL, long long))objc_msgSend)(pol, sCell, cell);
            if ([pol respondsToSelector:sWifi])
                ((void (*)(id, SEL, long long))objc_msgSend)(pol, sWifi, wifi);
        } else {
            Class polCls = NSClassFromString(@"CTDataUsagePolicies");
            SEL initSel = NSSelectorFromString(@"init:withCellularPolicy:andWifiPolicy:");
            if (polCls && [polCls instancesRespondToSelector:initSel]) {
                id obj = ((id (*)(id, SEL))objc_msgSend)((id)polCls, NSSelectorFromString(@"alloc"));
                pol = ((id (*)(id, SEL, id, long long, long long))objc_msgSend)(obj, initSel, appId, cell, wifi);
            }
        }
        if (!pol) return;

        SEL setPol = NSSelectorFromString(@"setPolicies:completion:");
        if ([cache respondsToSelector:setPol]) {
            void (^done)(void) = ^{};
            ((void (*)(id, SEL, id, id))objc_msgSend)(cache, setPol, pol, done);
        }
    } @catch(NSException *e) {
    }
}
static void NTM_syncCellularAsync(NSString *appId, NSInteger policy) {
    if (!appId.length) return;
    dispatch_async(NTM_syncQueue(), ^{ NTM_syncCellular(appId, policy); });
}

#pragma mark - 维度定义
static NSArray *NTM_dims(void) {
    return @[
        @{@"key":@"lock",   @"title":@"锁定屏幕"},
        @{@"key":@"nc",     @"title":@"通知中心"},
        @{@"key":@"banner", @"title":@"横幅"},
        @{@"key":@"sound",  @"title":@"声音"},
        @{@"key":@"badge",  @"title":@"标记"},
    ];
}

#pragma mark - 系统通知 section
static NSArray *NTM_systemSections(void) {
    static NSArray *arr = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *out = [NSMutableArray array];
        @try {
            id gateway = NTM_gateway();
            if (gateway) {
                id sections = nil;
                SEL sels[] = {NSSelectorFromString(@"sectionInfoList"),
                              NSSelectorFromString(@"allSectionInfo"),
                              NSSelectorFromString(@"sectionInfos")};
                for (int i = 0; i < 3 && !sections; i++) {
                    if ([gateway respondsToSelector:sels[i]]) sections = [gateway performSelector:sels[i]];
                }
                NSArray *secList = nil;
                if ([sections isKindOfClass:[NSArray class]]) secList = sections;
                else if ([sections isKindOfClass:[NSDictionary class]]) secList = [sections allValues];
                for (id info in secList) {
                    NSString *sid = nil;
                    @try { sid = [info performSelector:@selector(sectionID)]; } @catch(NSException *e) {}
                    if (!sid.length) { @try { sid = [info performSelector:@selector(sectionIdentifier)]; } @catch(NSException *e) {} }
                    if (!sid.length) continue;
                    NSString *name = nil;
                    @try { name = [info performSelector:@selector(sectionName)]; } @catch(NSException *e) {}
                    if (!name.length) { @try { name = [info performSelector:@selector(displayName)]; } @catch(NSException *e) {} }
                    if (!name.length) name = sid;
                    [out addObject:@{@"id":sid, @"name":name}];
                }
            }
        } @catch(NSException *e) {}
        arr = [out copy];
    });
    return arr;
}
static NSSet *NTM_notifSet(void) {
    static NSMutableSet *set = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSMutableSet set];
        for (NSDictionary *sec in NTM_systemSections()) [set addObject:sec[@"id"]];
    });
    return set;
}
static BOOL NTM_hasNotifications(NSString *appId) {
    NSSet *s = NTM_notifSet();
    if (!s.count) return YES;
    return [s containsObject:appId];
}

#pragma mark - 枚举 App (LSApplicationWorkspace)
static NSString *NTM_catOfProxy(id proxy) {
    NSString *type = ((id(*)(id,SEL))objc_msgSend)(proxy, sel_registerName("applicationType")) ?: @"";
    NSString *bid  = ((id(*)(id,SEL))objc_msgSend)(proxy, sel_registerName("applicationIdentifier")) ?: @"";
    if ([type isEqualToString:@"System"]) {
        return ([bid hasPrefix:@"com.apple."]) ? @"系统应用" : @"巨魔应用";
    }
    NSString *teamID = ((id(*)(id,SEL))objc_msgSend)(proxy, sel_registerName("teamID")) ?: @"";
    BOOL appleSign = (teamID.length && ![teamID isEqualToString:@"adhoc"] && ![teamID isEqualToString:@"AdHoc"]);
    return appleSign ? @"用户应用" : @"巨魔应用";
}
static UIImage *NTM_iconFor(NSString *bid) {
    if (!bid.length) return nil;
    @try {
        id (*f)(id,SEL,id,long long,double) = (id(*)(id,SEL,id,long long,double))objc_msgSend;
        id icon = f((id)UIImage.class, sel_registerName("_applicationIconImageForBundleIdentifier:format:scale:"), bid, 0, 2.0);
        if (icon && [icon isKindOfClass:UIImage.class]) return (UIImage *)icon;
    } @catch(NSException *e) {}
    return nil;
}
static NSArray *NTM_allApps(void) {
    NSMutableArray *out = [NSMutableArray array];
    Class wk = objc_getClass("LSApplicationWorkspace");
    if (!wk) {
        dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_NOW);
        wk = objc_getClass("LSApplicationWorkspace");
    }
    if (!wk) return out;
    id ws = ((id(*)(id,SEL))objc_msgSend)((id)wk, sel_registerName("defaultWorkspace"));
    if (!ws) return out;
    NSArray *proxies = ((id(*)(id,SEL))objc_msgSend)(ws, sel_registerName("allApplications"));
    NSMutableSet *installed = [NSMutableSet set];
    for (id proxy in proxies) {
        NSString *bid = ((id(*)(id,SEL))objc_msgSend)(proxy, sel_registerName("applicationIdentifier"));
        if (bid.length) [installed addObject:bid];
    }
    for (id proxy in proxies) {
        NSString *bid  = ((id(*)(id,SEL))objc_msgSend)(proxy, sel_registerName("applicationIdentifier"));
        NSURL *url     = ((id(*)(id,SEL))objc_msgSend)(proxy, sel_registerName("bundleURL"));
        NSString *name = ((id(*)(id,SEL))objc_msgSend)(proxy, sel_registerName("localizedName"));
        NSString *path = [(NSURL *)url path] ?: @"";
        if (!bid.length || !path.length) continue;
        NSString *cat = NTM_catOfProxy(proxy);
        if ([cat isEqualToString:@"系统应用"]) {
            if (![path hasPrefix:@"/Applications/"]) continue;
            if (!NTM_hasNotifications(bid)) continue;
        }
        [out addObject:@{ @"id":bid, @"name":(name.length?name:bid), @"cat":cat, @"icon":[NSNull null] }];
    }
    NSMutableSet *seen = [NSMutableSet set];
    for (NSDictionary *app in out) [seen addObject:app[@"id"]];
    for (NSDictionary *sec in NTM_systemSections()) {
        NSString *sid = sec[@"id"];
        if ([seen containsObject:sid]) continue;
        if (![installed containsObject:sid]) continue;
        if (![sid hasPrefix:@"com.apple."]) continue;
        [seen addObject:sid];
        [out addObject:@{@"id":sid, @"name":sec[@"name"], @"cat":@"系统应用", @"icon":[NSNull null]}];
    }
    NSArray *order = @[@"用户应用", @"巨魔应用", @"系统应用"];
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b){
        NSInteger ia = [order indexOfObject:a[@"cat"]];
        NSInteger ib = [order indexOfObject:b[@"cat"]];
        if (ia != ib) return ia<ib ? NSOrderedAscending : NSOrderedDescending;
        return [a[@"name"] compare:b[@"name"] options:NSCaseInsensitiveSearch];
    }];
    return out;
}
// App id -> 显示名
static NSDictionary *NTM_nameMap(void) {
    static NSDictionary *map = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        for (NSDictionary *app in NTM_allApps()) if (app[@"name"]) d[app[@"id"]] = app[@"name"];
        map = [d copy];
    });
    return map;
}
// 显示名（可复用的解析，appId可能不在已装列表）
static NSString *NTM_dispName(NSString *appId) {
    NSString *n = NTM_nameMap()[appId];
    return n.length ? n : appId;
}

#pragma mark - 状态 tag 构造
// 状态药丸（纯展示，不做交互）
static UIButton *NTM_tag(NSString *text, UIColor *color) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:text forState:UIControlStateNormal];
    [b setTitleColor:color forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    b.backgroundColor = [color colorWithAlphaComponent:0.14];
    b.layer.cornerRadius = 12;
    b.clipsToBounds = YES;
    b.userInteractionEnabled = NO;
    b.contentEdgeInsets = UIEdgeInsetsMake(4, 10, 4, 10);
    return b;
}

// 可点击的动作药丸（关键词过滤 / 分组）
static UIButton *NTM_actionTag(NSString *text, UIColor *color) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:text forState:UIControlStateNormal];
    [b setTitleColor:color forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    b.backgroundColor = [color colorWithAlphaComponent:0.15];
    b.layer.cornerRadius = 12;
    b.clipsToBounds = YES;
    b.contentEdgeInsets = UIEdgeInsetsMake(4, 10, 4, 10);
    return b;
}

#pragma mark - App 卡片视图
@interface NTMAppCardView : UIView
@property (nonatomic, strong) NSString *appId;
@property (nonatomic, strong) UISwitch *masterSwitch;
@property (nonatomic, strong) NSMutableArray *dimSwitches;
@property (nonatomic, strong) NSMutableArray *netButtons;
@property (nonatomic, strong) UISwitch *noBadgeSwitch;
@property (nonatomic, strong) UISwitch *noPreviewSwitch;
@property (nonatomic, strong) UISwitch *bgNetSwitch;
@property (nonatomic, strong) UIStackView *statusRow;
@property (nonatomic, copy) void (^onDimChange)(NSString *appId, NSString *dim, BOOL val);
@property (nonatomic, copy) void (^onMasterChange)(NSString *appId, BOOL val);
@property (nonatomic, copy) void (^onNetChange)(NSString *appId, NSInteger policy);
@property (nonatomic, copy) void (^onReset)(NSString *appId);
@property (nonatomic, copy) void (^onFeatChange)(NSString *appId, NSString *key, BOOL val);
@property (nonatomic, copy) void (^onKeywordEdit)(NSString *appId);
@property (nonatomic, copy) void (^onGroupPick)(NSString *appId);
- (instancetype)initWithApp:(NSDictionary *)app;
- (void)reloadFromPrefs;
@end

@implementation NTMAppCardView

- (instancetype)initWithApp:(NSDictionary *)app {
    self = [super init];
    if (self) {
        _appId = app[@"id"];
        _dimSwitches = [NSMutableArray array];
        _netButtons = [NSMutableArray array];
        self.backgroundColor = [UIColor whiteColor];
        self.layer.cornerRadius = 16;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.06;
        self.layer.shadowRadius = 8;
        self.layer.shadowOffset = CGSizeMake(0, 2);
        [self buildUI:app];
    }
    return self;
}

// 构造一个 "标签+开关" 的竖向单元（行内均分宽度，开关列自动对齐）
- (UIView *)swCell:(NSString *)title sw:(UISwitch *)sw {
    UILabel *lbl = [[UILabel alloc] init];
    lbl.text = title;
    lbl.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
    lbl.textColor = [UIColor colorWithWhite:0.32 alpha:1];
    lbl.textAlignment = NSTextAlignmentCenter;
    lbl.numberOfLines = 2;
    lbl.adjustsFontSizeToFitWidth = YES;
    lbl.minimumScaleFactor = 0.6;
    sw.transform = CGAffineTransformMakeScale(0.56, 0.56);
    UIStackView *item = [[UIStackView alloc] initWithArrangedSubviews:@[lbl, sw]];
    item.axis = UILayoutConstraintAxisVertical;
    item.alignment = UIStackViewAlignmentCenter;
    item.spacing = 2;
    return item;
}

- (void)buildUI:(NSDictionary *)app {
    NSArray *dims = NTM_dims();

    // 头部行：图标 + 名称 + 重置 + 总开关
    UIImageView *iconView = [[UIImageView alloc] init];
    iconView.contentMode = UIViewContentModeScaleAspectFill;
    iconView.layer.cornerRadius = 8;
    iconView.clipsToBounds = YES;
    iconView.backgroundColor = [UIColor colorWithRed:0.45 green:0.62 blue:0.98 alpha:1];
    [iconView.widthAnchor constraintEqualToConstant:32].active = YES;
    [iconView.heightAnchor constraintEqualToConstant:32].active = YES;
    NSString *bid = _appId;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        UIImage *icon = NTM_iconFor(bid);
        if (!icon) return;
        dispatch_async(dispatch_get_main_queue(), ^{ iconView.image = icon; });
    });

    UILabel *nameLabel = [[UILabel alloc] init];
    nameLabel.text = app[@"name"];
    nameLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    nameLabel.textColor = [UIColor colorWithWhite:0.13 alpha:1];
    [nameLabel setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [nameLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

    UIButton *resetBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [resetBtn setTitle:@"重置" forState:UIControlStateNormal];
    [resetBtn setTitleColor:[UIColor colorWithRed:0.87 green:0.24 blue:0.24 alpha:1] forState:UIControlStateNormal];
    resetBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    [resetBtn addTarget:self action:@selector(resetTapped) forControlEvents:UIControlEventTouchUpInside];

    UILabel *masterLabel = [[UILabel alloc] init];
    masterLabel.text = @"总开关";
    masterLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    masterLabel.textColor = [UIColor colorWithWhite:0.35 alpha:1];

    UISwitch *master = [[UISwitch alloc] init];
    [master addTarget:self action:@selector(masterChanged:) forControlEvents:UIControlEventValueChanged];
    _masterSwitch = master;

    UIStackView *header = [[UIStackView alloc] initWithArrangedSubviews:@[iconView, nameLabel, resetBtn, masterLabel, master]];
    header.axis = UILayoutConstraintAxisHorizontal;
    header.alignment = UIStackViewAlignmentCenter;
    header.spacing = 10;

    // 状态标签行（纵向容器，内分两行铺标签，避免一行塞不下溢出）
    _statusRow = [[UIStackView alloc] init];
    _statusRow.axis = UILayoutConstraintAxisVertical;
    _statusRow.alignment = UIStackViewAlignmentLeading;
    _statusRow.spacing = 4;

    // 子开关行：5 个维度横排
    NSMutableArray *dimItems = [NSMutableArray array];
    for (NSDictionary *d in dims) {
        UISwitch *sw = [[UISwitch alloc] init];
        [sw addTarget:self action:@selector(dimChanged:) forControlEvents:UIControlEventValueChanged];
        [_dimSwitches addObject:sw];
        [dimItems addObject:[self swCell:d[@"title"] sw:sw]];
    }
    // 增强开关，与维度开关挤进同一行（8 个列，标签自动两行换行）
    _noBadgeSwitch = [[UISwitch alloc] init];
    [_noBadgeSwitch addTarget:self action:@selector(featChanged:) forControlEvents:UIControlEventValueChanged];
    _noPreviewSwitch = [[UISwitch alloc] init];
    [_noPreviewSwitch addTarget:self action:@selector(featChanged:) forControlEvents:UIControlEventValueChanged];
    _bgNetSwitch = [[UISwitch alloc] init];
    [_bgNetSwitch addTarget:self action:@selector(featChanged:) forControlEvents:UIControlEventValueChanged];
    [dimItems addObject:[self swCell:@"仅隐藏角标" sw:_noBadgeSwitch]];
    [dimItems addObject:[self swCell:@"隐藏预览" sw:_noPreviewSwitch]];
    [dimItems addObject:[self swCell:@"后台断网" sw:_bgNetSwitch]];
    UIStackView *swRow = [[UIStackView alloc] initWithArrangedSubviews:dimItems];
    swRow.axis = UILayoutConstraintAxisHorizontal;
    swRow.distribution = UIStackViewDistributionFillEqually;
    swRow.alignment = UIStackViewAlignmentCenter;
    swRow.spacing = 2;

    NSMutableArray *rows = [NSMutableArray arrayWithArray:@[header, _statusRow, swRow]];
    [rows addObject:[self buildNetRow]];
    UIStackView *v = [[UIStackView alloc] initWithArrangedSubviews:rows];
    v.axis = UILayoutConstraintAxisVertical;
    v.spacing = 6;
    v.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:v];
    [NSLayoutConstraint activateConstraints:@[
        [v.topAnchor constraintEqualToAnchor:self.topAnchor constant:8],
        [v.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:14],
        [v.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-14],
        [v.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-8],
    ]];

    [self reloadStatus];
}

- (UIView *)buildNetRow {
    UILabel *netLabel = [[UILabel alloc] init];
    netLabel.text = @"网络";
    netLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    netLabel.textColor = [UIColor colorWithWhite:0.33 alpha:1];
    [netLabel.widthAnchor constraintEqualToConstant:30].active = YES;

    NSMutableArray *btns = [NSMutableArray array];
    for (NSDictionary *opt in NTM_netOptions()) {
        UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
        [btn setTitle:opt[@"title"] forState:UIControlStateNormal];
        btn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        btn.layer.cornerRadius = 9;
        btn.tag = [opt[@"policy"] integerValue];
        [btn addTarget:self action:@selector(netTapped:) forControlEvents:UIControlEventTouchUpInside];
        [btn.heightAnchor constraintEqualToConstant:30].active = YES;
        [btns addObject:btn];
        [_netButtons addObject:btn];
    }
    UIStackView *netRow = [[UIStackView alloc] initWithArrangedSubviews:btns];
    netRow.axis = UILayoutConstraintAxisHorizontal;
    netRow.distribution = UIStackViewDistributionFillEqually;
    netRow.alignment = UIStackViewAlignmentCenter;
    netRow.spacing = 6;

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[netLabel, netRow]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 8;
    return row;
}

- (void)reloadStatus {
    for (UIView *v in _statusRow.arrangedSubviews) {
        [_statusRow removeArrangedSubview:v];
        [v removeFromSuperview];
    }

    NSMutableArray *pills = [NSMutableArray array];

    // 通知状态
    BOOL en = NTM_read(_appId, @"en");
    if (!en) {
        [pills addObject:NTM_tag(@"通知关闭", [UIColor colorWithRed:0.87 green:0.24 blue:0.24 alpha:1])];
    } else {
        BOOL allOn = YES;
        for (NSDictionary *d in NTM_dims()) if (!NTM_read(_appId, d[@"key"])) { allOn = NO; break; }
        [pills addObject:NTM_tag(allOn ? @"通知全开" : @"部分开启",
                                 allOn ? [UIColor colorWithRed:0.30 green:0.55 blue:1.0 alpha:1]
                                       : [UIColor colorWithRed:0.95 green:0.60 blue:0.15 alpha:1])];
    }

    // 网络状态
    NSInteger net = NTM_netRead(_appId);
    BOOL netOff = (net == 1);
    [pills addObject:NTM_tag(netOff ? @"断网" : @"正常联网",
                             netOff ? [UIColor colorWithRed:0.87 green:0.24 blue:0.24 alpha:1]
                                    : [UIColor colorWithRed:0.42 green:0.75 blue:0.50 alpha:1])];

    // 关键词过滤（动作）
    NSArray *kws = NTM_kwList(_appId);
    NSString *kwTitle = kws.count ? [NSString stringWithFormat:@"关键词 %lu", (unsigned long)kws.count] : @"关键词过滤";
    UIButton *kwPill = NTM_actionTag(kwTitle, [UIColor colorWithRed:0.87 green:0.35 blue:0.55 alpha:1]);
    [kwPill addTarget:self action:@selector(keywordTapped) forControlEvents:UIControlEventTouchUpInside];
    [pills addObject:kwPill];

    // 分组（动作：已分组显示组名，未分组显示入口）
    NSString *grp = [NTM_prefs() objectForKey:NTM_key(_appId, @"group")];
    UIButton *grpPill = NTM_actionTag(grp.length ? grp : @"分组",
                                      [UIColor colorWithRed:0.55 green:0.40 blue:0.90 alpha:1]);
    [grpPill addTarget:self action:@selector(groupTapped) forControlEvents:UIControlEventTouchUpInside];
    [pills addObject:grpPill];

    // 按可用宽度自动换行铺排，避免任何一行被挤掉显示不全
    CGFloat avail = self.bounds.size.width - 28; // v 的左右内边距 14+14
    if (avail < 120) avail = [UIScreen mainScreen].bounds.size.width - 60; // 布局前兜底：卡片宽-内边距
    NSMutableArray *cur = [NSMutableArray array];
    CGFloat usedX = 0;
    for (UIView *p in pills) {
        CGFloat w = ceil([p intrinsicContentSize].width);
        if (cur.count && (usedX + w > avail)) {
            [self appendStatusRow:cur];
            cur = [NSMutableArray array];
            usedX = 0;
        }
        [cur addObject:p];
        usedX += w + 6;
    }
    if (cur.count) [self appendStatusRow:cur];
}

// 把一组药丸铺成一行，加入状态纵向容器
- (void)appendStatusRow:(NSArray *)views {
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:views];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 6;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [_statusRow addArrangedSubview:row];
}

- (void)netTapped:(UIButton *)sender {
    NSInteger policy = sender.tag;
    NTM_netWrite(_appId, policy);
    [self updateNetButtons];
    [self reloadStatus];
    NTM_syncCellularAsync(_appId, policy);
    if (_onNetChange) _onNetChange(_appId, policy);
}

- (void)updateNetButtons {
    NSInteger policy = NTM_netRead(_appId);
    for (UIButton *btn in _netButtons) {
        BOOL selected = (btn.tag == policy);
        if (selected) {
            btn.backgroundColor = [NTM_netColor(policy) colorWithAlphaComponent:0.18];
            [btn setTitleColor:NTM_netColor(policy) forState:UIControlStateNormal];
        } else {
            btn.backgroundColor = [UIColor colorWithWhite:0.93 alpha:1];
            [btn setTitleColor:[UIColor colorWithWhite:0.42 alpha:1] forState:UIControlStateNormal];
        }
    }
}

- (void)masterChanged:(UISwitch *)sender {
    NSUserDefaults *prefs = NTM_prefs();
    [prefs setBool:sender.on forKey:NTM_key(_appId, @"en")];
    for (NSDictionary *d in NTM_dims()) [prefs setBool:sender.on forKey:NTM_key(_appId, d[@"key"])];
    [prefs synchronize];
    NTM_postConfigChanged();
    [self reloadFromPrefs];
    NTM_syncSystemAsync(_appId);
    if (_onMasterChange) _onMasterChange(_appId, sender.on);
}

- (void)dimChanged:(UISwitch *)sender {
    NSUInteger idx = [_dimSwitches indexOfObject:sender];
    if (idx == NSNotFound || idx >= NTM_dims().count) return;
    NSDictionary *d = NTM_dims()[idx];
    NTM_write(_appId, d[@"key"], sender.on);
    [self reloadFromPrefs];
    NTM_syncSystemAsync(_appId);
    if (_onDimChange) _onDimChange(_appId, d[@"key"], sender.on);
}

// 增强功能开关
- (void)featChanged:(UISwitch *)sender {
    NSString *key = nil;
    if (sender == _noBadgeSwitch) key = @"noBadge";
    else if (sender == _noPreviewSwitch) key = @"noPreview";
    else if (sender == _bgNetSwitch) key = @"bgNet";
    if (!key) return;
    [NTM_prefs() setBool:sender.on forKey:NTM_key(_appId, key)];
    [NTM_prefs() synchronize];
    if ([key isEqualToString:@"bgNet"]) NTM_updateAnyBgNet();
    NTM_postConfigChanged();
    [self reloadFromPrefs];
    if (_onFeatChange) _onFeatChange(_appId, key, sender.on);
}

- (void)keywordTapped {
    if (_onKeywordEdit) _onKeywordEdit(_appId);
}
- (void)groupTapped {
    if (_onGroupPick) _onGroupPick(_appId);
}

- (void)resetTapped {
    NSUserDefaults *prefs = NTM_prefs();
    [prefs setBool:YES forKey:NTM_key(_appId, @"en")];
    for (NSDictionary *d in NTM_dims()) [prefs setBool:YES forKey:NTM_key(_appId, d[@"key"])];
    [prefs setBool:NO forKey:NTM_key(_appId, @"noBadge")];
    [prefs setBool:NO forKey:NTM_key(_appId, @"noPreview")];
    [prefs setBool:NO forKey:NTM_key(_appId, @"bgNet")];
    [prefs removeObjectForKey:NTM_key(_appId, @"kw")];
    [prefs synchronize];
    NTM_updateAnyBgNet();
    NTM_postConfigChanged();
    [self reloadFromPrefs];
    NTM_syncSystemAsync(_appId);
    if (_onReset) _onReset(_appId);
}

- (void)reloadFromPrefs {
    BOOL en = NTM_read(_appId, @"en");
    _masterSwitch.on = en;
    NSArray *dims = NTM_dims();
    BOOL anyVisible = NTM_read(_appId, @"lock") || NTM_read(_appId, @"nc") || NTM_read(_appId, @"banner");
    BOOL soundBadgeEnabled = en && anyVisible;
    for (NSUInteger i = 0; i < dims.count && i < _dimSwitches.count; i++) {
        UISwitch *sw = _dimSwitches[i];
        sw.on = NTM_read(_appId, dims[i][@"key"]);
        if (i == 3 || i == 4) sw.enabled = soundBadgeEnabled;
    }
    _noBadgeSwitch.on = NTM_feat(_appId, @"noBadge");
    _noPreviewSwitch.on = NTM_feat(_appId, @"noPreview");
    _bgNetSwitch.on = NTM_feat(_appId, @"bgNet");
    [self updateNetButtons];
    [self reloadStatus];
}

@end

#pragma mark - 控制器
@implementation NTMPrincipalController {
    UISegmentedControl *_catSeg;
    UISegmentedControl *_filterSeg;
    UISearchBar *_searchBar;
    UILabel *_statLabel;
    UITableView *_tableView;
    UIActivityIndicatorView *_spinner;
    NSArray *_allApps;
    NSArray *_curApps;
    NSString *_curCat;
    NSString *_searchText;
    NSInteger _filter; // 0全部 1已开启 2已关闭 3断网
    NSMutableDictionary *_snapshot;
    UIStackView *_topRow;   // 顶部一行：全部开启/关闭/自定义/模式快照/应用分组
    UIButton *_multiAllBtn;
    UIButton *_selEntryBtn; // 分类栏右侧"全选"入口
    UIStackView *_headCol;  // 顶部行 + 多选批量栏 的纵向容器
    UIStackView *_editCol;  // 多选批量操作三行容器
    UIStackView *_editRow1; // 取消/全选/通知/声音
    UIStackView *_editRow2; // 后台断网/子项全开全关
    UIStackView *_editRow3; // 网络策略
    BOOL _editing;          // 是否多选批量模式
    NSMutableSet *_selected; // 多选模式下选中的 appId
    UISwitch *_autoAuthSwitch; // 全局：自动授权通知权限
    BOOL _ntmLocked;          // 2.3.24 卡密未激活 = YES
}

- (void)setRootController:(id)rootController {}
- (void)setParentController:(id)parentController {}
- (void)setSpecifier:(id)specifier {}
- (void)setPreferenceLoader:(id)preferenceLoader {}
- (void)setParentController:(id)parentController specifier:(id)specifier {}

static UIButton *NTM_pillButton(NSString *title, UIColor *bg, UIColor *fg) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:fg forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    b.backgroundColor = bg;
    b.layer.cornerRadius = 14;
    return b;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"通知管理";
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    self.view.backgroundColor = [UIColor colorWithRed:0.95 green:0.96 blue:0.98 alpha:1];
    _curCat = @"用户应用";
    _searchText = @"";
    _filter = 0;
    _snapshot = [NSMutableDictionary dictionary];
    _selected = [NSMutableSet set];
    _editing = NO;

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"反馈"
                                                                             style:UIBarButtonItemStylePlain
                                                                            target:self action:@selector(feedback)];
    [self buildUI];
    [self setupActivationBar];  // 注册 Darwin 通知

    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [_spinner startAnimating];
    [self.view addSubview:_spinner];
    [NSLayoutConstraint activateConstraints:@[
        [_spinner.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_spinner.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
    ]];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray *apps = NTM_allApps();
        dispatch_async(dispatch_get_main_queue(), ^{
            _allApps = apps;
            NTM_updateAnyBgNet(); // 初始化"是否有后台断网"全局标记
            [self reloadList];
        });
    });
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self showActivationModalIfNeeded];
}

- (void)autoAuthChanged {
    if (_ntmLocked) { [self toast:@"请先激活卡密"]; return; }
    [NTM_prefs() setBool:_autoAuthSwitch.on forKey:@"NTM_autoAuth"];
    [NTM_prefs() synchronize];
    NTM_postConfigChanged();
    [self toast:_autoAuthSwitch.on ? @"已开启：打开 App 不再弹通知授权框" : @"已关闭自动授权"];
}

- (void)buildUI {
    _catSeg = [[UISegmentedControl alloc] initWithItems:@[@"用户应用", @"巨魔应用", @"系统应用"]];
    _catSeg.selectedSegmentIndex = 0;
    [_catSeg addTarget:self action:@selector(catChanged) forControlEvents:UIControlEventValueChanged];

    _selEntryBtn = NTM_pillButton(@"全选",
        [UIColor colorWithRed:0.45 green:0.62 blue:0.98 alpha:0.16],
        [UIColor colorWithRed:0.16 green:0.38 blue:0.78 alpha:1]);
    _selEntryBtn.titleLabel.font = [UIFont systemFontOfSize:14];
    [_selEntryBtn addTarget:self action:@selector(selEntryTapped) forControlEvents:UIControlEventTouchUpInside];

    _filterSeg = [[UISegmentedControl alloc] initWithItems:@[@"全部", @"已开启", @"已关闭", @"断网"]];
    _filterSeg.selectedSegmentIndex = 0;
    _filterSeg.tintColor = [UIColor colorWithRed:0.45 green:0.62 blue:0.98 alpha:1];
    [_filterSeg addTarget:self action:@selector(filterChanged) forControlEvents:UIControlEventValueChanged];

    UIButton *allOnBtn = NTM_pillButton(@"全部开启",
        [UIColor colorWithRed:0.45 green:0.78 blue:0.54 alpha:0.18],
        [UIColor colorWithRed:0.13 green:0.55 blue:0.24 alpha:1]);
    [allOnBtn addTarget:self action:@selector(allOnTapped) forControlEvents:UIControlEventTouchUpInside];
    UIButton *allOffBtn = NTM_pillButton(@"全部关闭",
        [UIColor colorWithRed:0.87 green:0.24 blue:0.24 alpha:0.15],
        [UIColor colorWithRed:0.72 green:0.17 blue:0.17 alpha:1]);
    [allOffBtn addTarget:self action:@selector(allOffTapped) forControlEvents:UIControlEventTouchUpInside];
    UIButton *customBtn = NTM_pillButton(@"自定义",
        [UIColor colorWithRed:0.55 green:0.58 blue:0.65 alpha:0.18],
        [UIColor colorWithWhite:0.35 alpha:1]);
    [customBtn addTarget:self action:@selector(customTapped) forControlEvents:UIControlEventTouchUpInside];

    // 多选模式：三行批量操作（选择/通知声音 / 增强子项 / 网络）
    UIButton *cancelBtn = NTM_pillButton(@"取消",
        [UIColor colorWithRed:0.55 green:0.58 blue:0.65 alpha:0.18],
        [UIColor colorWithWhite:0.35 alpha:1]);
    [cancelBtn addTarget:self action:@selector(multiTapped) forControlEvents:UIControlEventTouchUpInside];
    _multiAllBtn = NTM_pillButton(@"全选",
        [UIColor colorWithRed:0.45 green:0.62 blue:0.98 alpha:0.16],
        [UIColor colorWithRed:0.16 green:0.38 blue:0.78 alpha:1]);
    [_multiAllBtn addTarget:self action:@selector(multiSelectAllTapped) forControlEvents:UIControlEventTouchUpInside];

    UIButton *onNotifBtn = NTM_pillButton(@"开通知",
        [UIColor colorWithRed:0.45 green:0.78 blue:0.54 alpha:0.18],
        [UIColor colorWithRed:0.13 green:0.55 blue:0.24 alpha:1]);
    onNotifBtn.tag = 1;
    [onNotifBtn addTarget:self action:@selector(batchMasterTapped:) forControlEvents:UIControlEventTouchUpInside];
    UIButton *offNotifBtn = NTM_pillButton(@"关通知",
        [UIColor colorWithRed:0.87 green:0.24 blue:0.24 alpha:0.15],
        [UIColor colorWithRed:0.72 green:0.17 blue:0.17 alpha:1]);
    offNotifBtn.tag = 0;
    [offNotifBtn addTarget:self action:@selector(batchMasterTapped:) forControlEvents:UIControlEventTouchUpInside];
    UIButton *onSoundBtn = NTM_pillButton(@"开声音",
        [UIColor colorWithRed:0.45 green:0.78 blue:0.54 alpha:0.18],
        [UIColor colorWithRed:0.13 green:0.55 blue:0.24 alpha:1]);
    onSoundBtn.tag = 1;
    [onSoundBtn addTarget:self action:@selector(batchSoundTapped:) forControlEvents:UIControlEventTouchUpInside];
    UIButton *offSoundBtn = NTM_pillButton(@"关声音",
        [UIColor colorWithRed:0.87 green:0.24 blue:0.24 alpha:0.15],
        [UIColor colorWithRed:0.72 green:0.17 blue:0.17 alpha:1]);
    offSoundBtn.tag = 0;
    [offSoundBtn addTarget:self action:@selector(batchSoundTapped:) forControlEvents:UIControlEventTouchUpInside];

    NSMutableArray *row1 = [NSMutableArray arrayWithObjects:cancelBtn, _multiAllBtn, onNotifBtn, offNotifBtn, onSoundBtn, offSoundBtn, nil];
    _editRow1 = [[UIStackView alloc] initWithArrangedSubviews:row1];
    _editRow1.axis = UILayoutConstraintAxisHorizontal;
    _editRow1.distribution = UIStackViewDistributionFillEqually;
    _editRow1.spacing = 5;

    UIButton *onBgBtn = NTM_pillButton(@"开后台断网",
        [UIColor colorWithRed:0.45 green:0.78 blue:0.54 alpha:0.18],
        [UIColor colorWithRed:0.13 green:0.55 blue:0.24 alpha:1]);
    onBgBtn.tag = 1;
    [onBgBtn addTarget:self action:@selector(batchBgNetTapped:) forControlEvents:UIControlEventTouchUpInside];
    UIButton *offBgBtn = NTM_pillButton(@"关后台断网",
        [UIColor colorWithRed:0.87 green:0.24 blue:0.24 alpha:0.15],
        [UIColor colorWithRed:0.72 green:0.17 blue:0.17 alpha:1]);
    offBgBtn.tag = 0;
    [offBgBtn addTarget:self action:@selector(batchBgNetTapped:) forControlEvents:UIControlEventTouchUpInside];
    UIButton *subOnBtn = NTM_pillButton(@"子项全开",
        [UIColor colorWithRed:0.55 green:0.58 blue:0.65 alpha:0.18],
        [UIColor colorWithRed:0.30 green:0.35 blue:0.42 alpha:1]);
    subOnBtn.tag = 1;
    [subOnBtn addTarget:self action:@selector(batchSubTapped:) forControlEvents:UIControlEventTouchUpInside];
    UIButton *subOffBtn = NTM_pillButton(@"子项全关",
        [UIColor colorWithRed:0.55 green:0.58 blue:0.65 alpha:0.18],
        [UIColor colorWithRed:0.55 green:0.26 blue:0.26 alpha:1]);
    subOffBtn.tag = 0;
    [subOffBtn addTarget:self action:@selector(batchSubTapped:) forControlEvents:UIControlEventTouchUpInside];

    _editRow2 = [[UIStackView alloc] initWithArrangedSubviews:@[onBgBtn, offBgBtn, subOnBtn, subOffBtn]];
    _editRow2.axis = UILayoutConstraintAxisHorizontal;
    _editRow2.distribution = UIStackViewDistributionFillEqually;
    _editRow2.spacing = 5;

    NSMutableArray *netBtns = [NSMutableArray array];
    for (NSDictionary *opt in NTM_netOptions()) {
        UIButton *nb = NTM_pillButton(opt[@"title"],
            [NTM_netColor([opt[@"policy"] integerValue]) colorWithAlphaComponent:0.15],
            NTM_netColor([opt[@"policy"] integerValue]));
        nb.tag = [opt[@"policy"] integerValue];
        nb.titleLabel.numberOfLines = 2;
        nb.titleLabel.textAlignment = NSTextAlignmentCenter;
        if ([opt[@"policy"] integerValue] == 0) [nb setTitle:@"wifi\n+流量" forState:UIControlStateNormal];
        [nb addTarget:self action:@selector(editNetTapped:) forControlEvents:UIControlEventTouchUpInside];
        [netBtns addObject:nb];
    }
    _editRow3 = [[UIStackView alloc] initWithArrangedSubviews:netBtns];
    _editRow3.axis = UILayoutConstraintAxisHorizontal;
    _editRow3.distribution = UIStackViewDistributionFillEqually;
    _editRow3.spacing = 5;

    for (UIStackView *row in @[_editRow1, _editRow2, _editRow3]) {
        row.translatesAutoresizingMaskIntoConstraints = NO;
        [row.heightAnchor constraintEqualToConstant:40].active = YES;
    }
    // 多选批量操作三行打包成一个纵向栈，靠 hidden 自动折叠/展开（避免手写高度冲突）
    _editCol = [[UIStackView alloc] initWithArrangedSubviews:@[_editRow1, _editRow2, _editRow3]];
    _editCol.axis = UILayoutConstraintAxisVertical;
    _editCol.spacing = 6;
    _editCol.hidden = YES;
    _editCol.clipsToBounds = YES;

    UIButton *snapBtn = NTM_pillButton(@"模式快照",
        [UIColor colorWithRed:0.55 green:0.40 blue:0.90 alpha:0.15],
        [UIColor colorWithRed:0.45 green:0.30 blue:0.85 alpha:1]);
    [snapBtn addTarget:self action:@selector(snapshotTapped) forControlEvents:UIControlEventTouchUpInside];
    UIButton *grpBtn = NTM_pillButton(@"应用分组",
        [UIColor colorWithRed:0.30 green:0.66 blue:0.95 alpha:0.15],
        [UIColor colorWithRed:0.15 green:0.45 blue:0.78 alpha:1]);
    [grpBtn addTarget:self action:@selector(groupManagerTapped) forControlEvents:UIControlEventTouchUpInside];

    // 顶部一行：全部开启/关闭 + 自定义 + 模式快照 + 应用分组（多选入口统一用分类栏右侧"全选"）
    _topRow = [[UIStackView alloc] initWithArrangedSubviews:@[allOnBtn, allOffBtn, customBtn, snapBtn, grpBtn]];
    _topRow.axis = UILayoutConstraintAxisHorizontal;
    _topRow.distribution = UIStackViewDistributionFillEqually;
    _topRow.spacing = 5;
    for (UIView *tb in _topRow.arrangedSubviews) {
        ((UIButton *)tb).titleLabel.numberOfLines = 2;
        ((UIButton *)tb).titleLabel.textAlignment = NSTextAlignmentCenter;
        ((UIButton *)tb).titleLabel.lineBreakMode = NSLineBreakByWordWrapping;
        ((UIButton *)tb).titleLabel.adjustsFontSizeToFitWidth = NO;
    }
    [_topRow.heightAnchor constraintEqualToConstant:44].active = YES;

    _searchBar = [[UISearchBar alloc] init];
    _searchBar.placeholder = @"搜索应用名称";
    _searchBar.delegate = self;
    _searchBar.searchBarStyle = UISearchBarStyleMinimal;
    _searchBar.backgroundImage = [UIImage new];

    _statLabel = [[UILabel alloc] init];
    _statLabel.font = [UIFont systemFontOfSize:12];
    _statLabel.textColor = [UIColor colorWithWhite:0.4 alpha:1];

    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _tableView.delegate = self;
    _tableView.dataSource = self;
    _tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    _tableView.backgroundColor = [UIColor clearColor];
    _tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    _tableView.rowHeight = _editing ? 64 : 200;
    _tableView.contentInset = UIEdgeInsetsMake(4, 0, 4, 0);

    UIButton *exportBtn = NTM_pillButton(@"导出配置",
        [UIColor colorWithRed:0.35 green:0.56 blue:1.0 alpha:0.15],
        [UIColor colorWithRed:0.17 green:0.35 blue:0.72 alpha:1]);
    [exportBtn addTarget:self action:@selector(exportConfig) forControlEvents:UIControlEventTouchUpInside];
    UIButton *importBtn = NTM_pillButton(@"导入配置",
        [UIColor colorWithRed:0.45 green:0.78 blue:0.54 alpha:0.18],
        [UIColor colorWithRed:0.13 green:0.55 blue:0.24 alpha:1]);
    [importBtn addTarget:self action:@selector(importConfig) forControlEvents:UIControlEventTouchUpInside];

    // 全局：自动授权通知权限（抹除手机设置后，按本插件配置静默授权，App 打开不再弹"想给你发送通知"）
    _autoAuthSwitch = [[UISwitch alloc] init];
    [_autoAuthSwitch addTarget:self action:@selector(autoAuthChanged) forControlEvents:UIControlEventValueChanged];
    _autoAuthSwitch.on = ({ id _v = [NTM_prefs() objectForKey:@"NTM_autoAuth"]; _v ? [_v boolValue] : YES; }); // 默认开启
    UILabel *aaLabel = [[UILabel alloc] init];
    aaLabel.text = @"自动授权通知（抹除后免弹窗）";
    aaLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    aaLabel.textColor = [UIColor colorWithWhite:0.2 alpha:1];
    aaLabel.numberOfLines = 2;
    UIStackView *aaRow = [[UIStackView alloc] initWithArrangedSubviews:@[aaLabel, _autoAuthSwitch]];
    aaRow.axis = UILayoutConstraintAxisHorizontal;
    aaRow.alignment = UIStackViewAlignmentCenter;
    aaRow.spacing = 10;
    aaRow.layoutMargins = UIEdgeInsetsMake(10, 14, 10, 14);
    aaRow.layoutMarginsRelativeArrangement = YES;
    aaRow.backgroundColor = [UIColor whiteColor];
    aaRow.layer.cornerRadius = 14;
    [aaRow.heightAnchor constraintEqualToConstant:52].active = YES;

    // 顶部行 + 多选批量栏 做成纵向栈，停用/启用时靠 hidden 自动折叠展开
    _headCol = [[UIStackView alloc] initWithArrangedSubviews:@[aaRow, _topRow, _editCol]];
    _headCol.axis = UILayoutConstraintAxisVertical;
    _headCol.spacing = 6;

    for (UIView *v in @[_tableView, _headCol, _statLabel, _searchBar, _filterSeg, _catSeg, _selEntryBtn, exportBtn, importBtn]) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [self.view addSubview:v];
    }
    for (UIView *sv in @[_editRow1, _editRow2, _editRow3]) {
        for (UIView *tb in ((UIStackView *)sv).arrangedSubviews) {
            ((UIButton *)tb).titleLabel.numberOfLines = 2;
            ((UIButton *)tb).titleLabel.textAlignment = NSTextAlignmentCenter;
            ((UIButton *)tb).titleLabel.lineBreakMode = NSLineBreakByWordWrapping;
        }
    }
    [self.view bringSubviewToFront:_headCol];

    [NSLayoutConstraint activateConstraints:@[
        [_headCol.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12],
        [_headCol.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [_headCol.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],

        [_statLabel.topAnchor constraintEqualToAnchor:_headCol.bottomAnchor constant:8],
        [_statLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [_statLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],

        [_searchBar.topAnchor constraintEqualToAnchor:_statLabel.bottomAnchor constant:2],
        [_searchBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [_searchBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],

        [_filterSeg.topAnchor constraintEqualToAnchor:_searchBar.bottomAnchor constant:2],
        [_filterSeg.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [_filterSeg.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],

        [_catSeg.topAnchor constraintEqualToAnchor:_filterSeg.bottomAnchor constant:6],
        [_catSeg.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [_catSeg.trailingAnchor constraintEqualToAnchor:_selEntryBtn.leadingAnchor constant:-8],

        [_selEntryBtn.centerYAnchor constraintEqualToAnchor:_catSeg.centerYAnchor],
        [_selEntryBtn.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [_selEntryBtn.widthAnchor constraintEqualToConstant:64],
        [_selEntryBtn.heightAnchor constraintEqualToConstant:34],

        [exportBtn.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [exportBtn.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-6],
        [exportBtn.heightAnchor constraintEqualToConstant:44],
        [importBtn.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [importBtn.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-6],
        [importBtn.heightAnchor constraintEqualToConstant:44],
        [exportBtn.trailingAnchor constraintEqualToAnchor:importBtn.leadingAnchor constant:-12],
        [exportBtn.widthAnchor constraintEqualToAnchor:importBtn.widthAnchor],

        [_tableView.topAnchor constraintEqualToAnchor:_catSeg.bottomAnchor constant:12],
        [_tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_tableView.bottomAnchor constraintEqualToAnchor:exportBtn.topAnchor constant:-10],
    ]];
}

- (void)hideSpinner {
    [_spinner stopAnimating];
    [_spinner removeFromSuperview];
    _spinner = nil;
}

#pragma mark - UITableViewDataSource
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return _curApps.count; }
- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath { return _editing ? 52 : 200; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (_editing) return [self multiCellFor:indexPath];
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"card"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"card"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.backgroundColor = [UIColor clearColor];
    }
    for (UIView *v in cell.contentView.subviews) [v removeFromSuperview];

    NSDictionary *app = _curApps[indexPath.row];
    NTMAppCardView *card = [[NTMAppCardView alloc] initWithApp:app];
    [card reloadFromPrefs];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:card];
    [NSLayoutConstraint activateConstraints:@[
        [card.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:6],
        [card.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [card.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
        [card.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-6],
    ]];
    __weak typeof(self) ws = self;
    card.onDimChange = ^(NSString *aid, NSString *dim, BOOL val) { [ws refreshStat]; };
    card.onMasterChange = ^(NSString *aid, BOOL val) { [ws refreshStat]; };
    card.onNetChange = ^(NSString *aid, NSInteger policy) { [ws refreshStat]; };
    card.onReset = ^(NSString *aid) { [ws refreshStat]; };
    card.onFeatChange = ^(NSString *aid, NSString *key, BOOL val) { [ws refreshStat]; };
    card.onKeywordEdit = ^(NSString *aid) { [ws editKeyword:aid]; };
    card.onGroupPick = ^(NSString *aid) { [ws pickGroup:aid]; };
    return cell;
}

#pragma mark - 多选批量模式
- (void)multiTapped {
    _editing = !_editing;
    if (_editing) [_selected removeAllObjects];
    [self updateMultiUIBar];
    [self updateSelAllTitle];
    [_tableView reloadData];
}
- (void)selEntryTapped {
    // 分类栏"全选"：进入多选并全选当前分类
    _editing = YES;
    [_selected removeAllObjects];
    for (NSDictionary *app in _curApps) [_selected addObject:app[@"id"]];
    [self updateMultiUIBar];
    [self updateSelAllTitle];
    [_tableView reloadData];
}
- (void)updateMultiUIBar {
    // UIStackView 对 arranged 子视图设置 hidden 会自动折叠/展开，无需手调高度
    _topRow.hidden = _editing;
    _editCol.hidden = !_editing;
    _tableView.rowHeight = _editing ? 64 : 200;
    if (_editing) [_tableView setEditing:NO animated:NO];
    [self.view setNeedsUpdateConstraints];
    [UIView animateWithDuration:0.2 animations:^{ [self.view layoutIfNeeded]; }];
}
- (void)multiSelectAllTapped {
    if (_curApps.count && _selected.count == _curApps.count) {
        [_selected removeAllObjects];
    } else {
        for (NSDictionary *app in _curApps) [_selected addObject:app[@"id"]];
    }
    [self updateSelAllTitle];
    [_tableView reloadData];
}
- (void)updateSelAllTitle {
    BOOL all = _curApps.count > 0 && _selected.count == _curApps.count;
    [_multiAllBtn setTitle:all ? @"清空" : @"全选" forState:UIControlStateNormal];
}
- (void)batchMasterTapped:(UIButton *)sender {
    BOOL v = sender.tag == 1;
    NSArray *ids = _selected.allObjects;
    if (!ids.count) return;
    NSUserDefaults *prefs = NTM_prefs();
    for (NSString *aid in ids) {
        [prefs setBool:v forKey:NTM_key(aid, @"en")];
        for (NSDictionary *d in NTM_dims()) [prefs setBool:v forKey:NTM_key(aid, d[@"key"])];
    }
    [self batchCommit:ids postSync:YES bgNet:NO];
}
- (void)batchSoundTapped:(UIButton *)sender {
    BOOL v = sender.tag == 1;
    NSArray *ids = _selected.allObjects;
    if (!ids.count) return;
    NSUserDefaults *prefs = NTM_prefs();
    for (NSString *aid in ids) [prefs setBool:v forKey:NTM_key(aid, @"sound")];
    [self batchCommit:ids postSync:YES bgNet:NO];
}
- (void)batchBgNetTapped:(UIButton *)sender {
    BOOL v = sender.tag == 1;
    NSArray *ids = _selected.allObjects;
    if (!ids.count) return;
    NSUserDefaults *prefs = NTM_prefs();
    for (NSString *aid in ids) [prefs setBool:v forKey:NTM_key(aid, @"bgNet")];
    [self batchCommit:ids postSync:NO bgNet:YES];
}
- (void)batchSubTapped:(UIButton *)sender {
    BOOL v = sender.tag == 1;
    NSArray *ids = _selected.allObjects;
    if (!ids.count) return;
    NSUserDefaults *prefs = NTM_prefs();
    for (NSString *aid in ids) {
        for (NSDictionary *d in NTM_dims()) [prefs setBool:v forKey:NTM_key(aid, d[@"key"])];
        [prefs setBool:v forKey:NTM_key(aid, @"noBadge")];
        [prefs setBool:v forKey:NTM_key(aid, @"noPreview")];
    }
    [self batchCommit:ids postSync:YES bgNet:NO];
}
- (void)batchCommit:(NSArray *)ids postSync:(BOOL)postSync bgNet:(BOOL)bgNet {
    if (!ids.count) return;
    NSUserDefaults *prefs = NTM_prefs();
    NSArray *copy = [ids copy];
    dispatch_async(NTM_syncQueue(), ^{
        [prefs synchronize];
        NTM_postConfigChanged();
        if (postSync) for (NSString *aid in copy) NTM_syncSystem(aid);
    });
    if (bgNet) NTM_updateAnyBgNet();
    [_tableView reloadData];
    [self refreshStat];
}
- (void)editNetTapped:(UIButton *)sender {
    NSInteger policy = sender.tag;
    NSArray *ids = _selected.allObjects;
    if (!ids.count) return;
    NSUserDefaults *prefs = NTM_prefs();
    for (NSString *aid in ids) {
        [prefs setInteger:policy forKey:NTM_netKey(aid)];
    }
    NSArray *copy = [ids copy];
    dispatch_async(NTM_syncQueue(), ^{
        [prefs synchronize];
        NTM_postConfigChanged();
        for (NSString *aid in copy) NTM_syncCellular(aid, policy);
    });
    [_tableView reloadData];
    [self refreshStat];
}
- (UITableViewCell *)multiCellFor:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [_tableView dequeueReusableCellWithIdentifier:@"mcell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"mcell"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.backgroundColor = [UIColor clearColor];
    }
    for (UIView *v in cell.contentView.subviews) [v removeFromSuperview];
    NSDictionary *app = _curApps[indexPath.row];
    NSString *aid = app[@"id"];
    BOOL sel = [_selected containsObject:aid];
    NSInteger net = NTM_netRead(aid);
    NSString *netTitle = @[@"wifi+流量", @"断网", @"wifi", @"流量"][net % 4];

    UIButton *box = [UIButton buttonWithType:UIButtonTypeSystem];
    box.userInteractionEnabled = NO;
    box.layer.cornerRadius = 12;
    box.clipsToBounds = YES;
    box.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    if (sel) {
        box.backgroundColor = [UIColor colorWithRed:0.22 green:0.52 blue:0.96 alpha:1];
        [box setTitle:@"✓" forState:UIControlStateNormal];
        [box setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    } else {
        box.backgroundColor = [UIColor whiteColor];
        box.layer.borderWidth = 2;
        box.layer.borderColor = [UIColor colorWithWhite:0.75 alpha:1].CGColor;
        [box setTitle:@"" forState:UIControlStateNormal];
    }
    [box.widthAnchor constraintEqualToConstant:24].active = YES;
    [box.heightAnchor constraintEqualToConstant:24].active = YES;

    UIImageView *icon = [[UIImageView alloc] init];
    icon.contentMode = UIViewContentModeScaleAspectFill;
    icon.layer.cornerRadius = 6;
    icon.clipsToBounds = YES;
    icon.backgroundColor = [UIColor colorWithRed:0.45 green:0.62 blue:0.98 alpha:1];
    [icon.widthAnchor constraintEqualToConstant:24].active = YES;
    [icon.heightAnchor constraintEqualToConstant:24].active = YES;
    UIImage *ic = NTM_iconFor(aid);
    if (ic) icon.image = ic;

    UILabel *name = [[UILabel alloc] init];
    name.text = app[@"name"];
    name.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    name.textColor = [UIColor colorWithWhite:0.13 alpha:1];
    [name setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];

    UIButton *tag = NTM_tag(net == 1 ? @"已断网" : netTitle, [NTM_netColor(net) colorWithAlphaComponent:0.9]);
    tag.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];

    UIStackView *topRow = [[UIStackView alloc] initWithArrangedSubviews:@[box, icon, name, tag]];
    topRow.axis = UILayoutConstraintAxisHorizontal;
    topRow.alignment = UIStackViewAlignmentCenter;
    topRow.spacing = 12;

    UIColor *g = [UIColor colorWithRed:0.20 green:0.66 blue:0.35 alpha:1];
    UIColor *r = [UIColor colorWithRed:0.80 green:0.24 blue:0.24 alpha:1];
    UIColor *o = [UIColor colorWithRed:0.93 green:0.55 blue:0.12 alpha:1];
    UIColor *gr = [UIColor colorWithWhite:0.5 alpha:1];
    UIColor *bl = [UIColor colorWithRed:0.15 green:0.45 blue:0.78 alpha:1];
    UIButton *(^chip)(NSString *, UIColor *) = ^UIButton *(NSString *t, UIColor *c) {
        UIButton *b = NTM_tag(t, c);
        b.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
        [b.heightAnchor constraintEqualToConstant:24].active = YES;
        return b;
    };

    BOOL en = NTM_read(aid, @"en");
    BOOL sound = NTM_read(aid, @"sound");
    BOOL bg = NTM_feat(aid, @"bgNet");
    BOOL subAllOn = YES, subAllOff = YES;
    for (NSDictionary *d in NTM_dims()) {
        BOOL v = NTM_read(aid, d[@"key"]);
        if (v) subAllOff = NO; else subAllOn = NO;
    }
    for (NSString *fk in @[@"noBadge", @"noPreview"]) {
        BOOL v = NTM_feat(aid, fk);
        if (v) subAllOff = NO; else subAllOn = NO;
    }
    UIButton *notiChip = chip(en ? @"通知开" : @"通知关", en ? g : r);
    UIButton *soundChip = chip(sound ? @"声音开" : @"声音关", sound ? g : gr);
    UIButton *bgChip = chip(bg ? @"后台开" : @"后台关", bg ? bl : gr);
    UIButton *subChip = chip(subAllOn ? @"子项全开" : (subAllOff ? @"子项全关" : @"子项部分"),
                             subAllOn ? g : (subAllOff ? gr : o));

    UIStackView *subRow = [[UIStackView alloc] initWithArrangedSubviews:@[notiChip, soundChip, bgChip, subChip]];
    subRow.axis = UILayoutConstraintAxisHorizontal;
    subRow.alignment = UIStackViewAlignmentLeading;
    subRow.spacing = 8;

    UIStackView *col = [[UIStackView alloc] initWithArrangedSubviews:@[topRow, subRow]];
    col.axis = UILayoutConstraintAxisVertical;
    col.alignment = UIStackViewAlignmentFill;
    col.spacing = 6;
    col.translatesAutoresizingMaskIntoConstraints = NO;

    UIView *card = [[UIView alloc] init];
    card.backgroundColor = sel ? [UIColor colorWithRed:0.45 green:0.62 blue:0.98 alpha:0.12]
                              : [UIColor whiteColor];
    card.layer.cornerRadius = 14;
    card.layer.shadowColor = [UIColor blackColor].CGColor;
    card.layer.shadowOpacity = 0.04;
    card.layer.shadowRadius = 6;
    card.layer.shadowOffset = CGSizeMake(0, 1);
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:col];
    [cell.contentView addSubview:card];
    [NSLayoutConstraint activateConstraints:@[
        [card.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:3],
        [card.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [card.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
        [card.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-3],
        [col.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:12],
        [col.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-12],
        [col.centerYAnchor constraintEqualToAnchor:card.centerYAnchor],
    ]];
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    if (!_editing) return;
    NSString *aid = _curApps[indexPath.row][@"id"];
    if ([_selected containsObject:aid]) [_selected removeObject:aid];
    else [_selected addObject:aid];
    [self updateSelAllTitle];
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
}

#pragma mark - 列表
- (void)reloadList {
    NSMutableArray *filtered = [NSMutableArray array];
    for (NSDictionary *app in _allApps) {
        if (_searchText.length) {
            NSString *name = app[@"name"];
            NSString *bid = app[@"id"];
            if (![name localizedCaseInsensitiveContainsString:_searchText] &&
                ![bid localizedCaseInsensitiveContainsString:_searchText]) continue;
        } else {
            if (![app[@"cat"] isEqualToString:_curCat]) continue;
        }
        if (_filter == 1) { if (!NTM_read(app[@"id"], @"en")) continue; }
        else if (_filter == 2) { if (NTM_read(app[@"id"], @"en")) continue; }
        else if (_filter == 3) { if (NTM_netRead(app[@"id"]) != 1) continue; }
        [filtered addObject:app];
    }
    _curApps = filtered;

    if (!filtered.count) {
        UILabel *empty = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 260, 80)];
        empty.text = @"暂无应用";
        empty.font = [UIFont systemFontOfSize:14];
        empty.textColor = [UIColor colorWithWhite:0.55 alpha:1];
        empty.textAlignment = NSTextAlignmentCenter;
        _tableView.backgroundView = empty;
    } else {
        _tableView.backgroundView = nil;
    }
    [_tableView reloadData];
    [self refreshStat];
    [self hideSpinner];
}

- (void)refreshAllCards {
    for (UITableViewCell *cell in _tableView.visibleCells) {
        for (UIView *v in cell.contentView.subviews) {
            if ([v isKindOfClass:[NTMAppCardView class]]) [(NTMAppCardView *)v reloadFromPrefs];
        }
    }
}

- (void)refreshStat {
    NSUserDefaults *prefs = NTM_prefs();
    NSInteger total = 0, on = 0;
    for (NSDictionary *app in _curApps) {
        NSString *aid = app[@"id"];
        if (NTM_readWith(prefs, aid, @"en")) on++;
        total++;
    }
    NSString *scope = _searchText.length ? [NSString stringWithFormat:@"搜索：%@", _searchText]
                     : (_filter ? [NSString stringWithFormat:@"%@ / %@", _curCat, @[@"", @"已开启", @"已关闭", @"断网"][_filter]]
                                : _curCat);
    _statLabel.text = [NSString stringWithFormat:@"%@    已开启 %ld / %ld 个应用", scope, (long)on, (long)total];
}

#pragma mark - 交互
- (void)catChanged {
    NSArray *cats = @[@"用户应用", @"巨魔应用", @"系统应用"];
    _curCat = cats[_catSeg.selectedSegmentIndex];
    [self reloadList];
}
- (void)filterChanged { _filter = _filterSeg.selectedSegmentIndex; [self reloadList]; }

- (void)allOnTapped { [self saveSnapshot]; [self batchWrite:YES]; [self refreshAllCards]; [self refreshStat]; }
- (void)allOffTapped { [self saveSnapshot]; [self batchWrite:NO]; [self refreshAllCards]; [self refreshStat]; }
- (void)customTapped { [self restoreSnapshot]; [self refreshAllCards]; [self refreshStat]; }

- (void)batchWrite:(BOOL)val {
    NSUserDefaults *prefs = NTM_prefs();
    NSMutableArray *ids = [NSMutableArray array];
    NSInteger netPolicy = val ? 0 : 1;
    for (NSDictionary *app in _curApps) {
        NSString *aid = app[@"id"];
        [ids addObject:aid];
        [prefs setBool:val forKey:NTM_key(aid, @"en")];
        for (NSDictionary *d in NTM_dims()) [prefs setBool:val forKey:NTM_key(aid, d[@"key"])];
        [prefs setInteger:netPolicy forKey:NTM_netKey(aid)];
        if (!val) {
            [prefs setBool:NO forKey:NTM_key(aid, @"bgNet")]; // 全部关闭时顺带关后台断网
        }
    }
    if (!val) NTM_updateAnyBgNet(); // 全部关闭时 bgNet 一并关闭，更新全局标记
    NSArray *idsCopy = [ids copy];
    dispatch_async(NTM_syncQueue(), ^{
        [prefs synchronize];
        NTM_postConfigChanged();
        for (NSString *aid in idsCopy) NTM_syncSystem(aid);
        for (NSString *aid in idsCopy) NTM_syncCellular(aid, netPolicy);
    });
}

- (void)saveSnapshot {
    [_snapshot removeAllObjects];
    NSUserDefaults *prefs = NTM_prefs();
    for (NSDictionary *app in _curApps) {
        NSString *aid = app[@"id"];
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"en"] = @(NTM_readWith(prefs, aid, @"en"));
        for (NSDictionary *dim in NTM_dims()) d[dim[@"key"]] = @(NTM_readWith(prefs, aid, dim[@"key"]));
        d[@"net"] = @(NTM_netRead(aid));
        _snapshot[aid] = d;
    }
}
- (void)restoreSnapshot {
    NSUserDefaults *prefs = NTM_prefs();
    for (NSString *aid in _snapshot) {
        NSDictionary *d = _snapshot[aid];
        id en = d[@"en"];
        if (en) [prefs setBool:[en boolValue] forKey:NTM_key(aid, @"en")];
        for (NSDictionary *dim in NTM_dims()) {
            id v = d[dim[@"key"]];
            if (v) [prefs setBool:[v boolValue] forKey:NTM_key(aid, dim[@"key"])];
        }
        id net = d[@"net"];
        if (net) { [prefs setInteger:[net integerValue] forKey:NTM_netKey(aid)]; NTM_syncCellularAsync(aid, [net integerValue]); }
        NTM_syncSystemAsync(aid);
    }
    dispatch_async(NTM_syncQueue(), ^{ [prefs synchronize]; NTM_postConfigChanged(); });
}

#pragma mark - Alert/Sheet 弹出（统一设置 popover 来源，避免 iPad 崩溃）
- (void)showAlertController:(UIAlertController *)ac {
    ac.popoverPresentationController.sourceView = self.view;
    ac.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width/2, self.view.bounds.size.height-40, 1, 1);
    [self presentViewController:ac animated:YES completion:nil];
}

#pragma mark - 模式快照（持久化，一键回滚）
- (void)snapshotTapped {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"模式快照"
                                                                message:@"保存当前全部App的通知+网络配置，可随时一键回滚"
                                                         preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"保存当前配置为快照" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
        [self snapshotSave];
    }]];
    BOOL has = [[NTM_prefs() objectForKey:@"NTM_snapshot"] isKindOfClass:[NSDictionary class]];
    if (has) {
        [ac addAction:[UIAlertAction actionWithTitle:@"恢复已保存的快照" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
            [self snapshotRestore];
        }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"删除已保存的快照" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a){
            [NTM_prefs() removeObjectForKey:@"NTM_snapshot"];
            [NTM_prefs() synchronize];
            [self toast:@"已删除快照"];
        }]];
    } else {
        [ac addAction:[UIAlertAction actionWithTitle:@"恢复已保存的快照" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
            [self toast:@"还没有保存过快照"];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self showAlertController:ac];
}
- (void)snapshotSave {
    NSMutableDictionary *snap = [NSMutableDictionary dictionary];
    for (NSDictionary *app in _allApps) {
        NSString *aid = app[@"id"];
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"en"] = @(NTM_read(aid, @"en"));
        NSMutableDictionary *dims = [NSMutableDictionary dictionary];
        for (NSDictionary *dim in NTM_dims()) dims[dim[@"key"]] = @(NTM_read(aid, dim[@"key"]));
        d[@"dims"] = dims;
        d[@"net"] = @(NTM_netRead(aid));
        d[@"noBadge"] = @(NTM_feat(aid, @"noBadge"));
        d[@"noPreview"] = @(NTM_feat(aid, @"noPreview"));
        d[@"bgNet"] = @(NTM_feat(aid, @"bgNet"));
        d[@"kw"] = NTM_kwList(aid);
        NSString *grp = [NTM_prefs() objectForKey:NTM_key(aid, @"group")];
        if (grp.length) d[@"group"] = grp;
        snap[aid] = d;
    }
    [NTM_prefs() setObject:snap forKey:@"NTM_snapshot"];
    [NTM_prefs() synchronize];
    [self toast:[NSString stringWithFormat:@"已保存 %lu 个应用为快照", (unsigned long)snap.count]];
}
- (void)snapshotRestore {
    id snap = [NTM_prefs() objectForKey:@"NTM_snapshot"];
    if (![snap isKindOfClass:[NSDictionary class]]) return;
    NSUserDefaults *prefs = NTM_prefs();
    NSMutableArray *ids = [NSMutableArray array];
    for (NSString *aid in snap) {
        NSDictionary *d = snap[aid];
        [ids addObject:aid];
        id en = d[@"en"]; if (en) [prefs setBool:[en boolValue] forKey:NTM_key(aid, @"en")];
        NSDictionary *dims = d[@"dims"];
        if ([dims isKindOfClass:[NSDictionary class]]) for (NSString *k in dims) [prefs setBool:[dims[k] boolValue] forKey:NTM_key(aid, k)];
        id net = d[@"net"];
        if (net) [prefs setInteger:[net integerValue] forKey:NTM_netKey(aid)];
        if (d[@"noBadge"]) [prefs setBool:[d[@"noBadge"] boolValue] forKey:NTM_key(aid, @"noBadge")];
        if (d[@"noPreview"]) [prefs setBool:[d[@"noPreview"] boolValue] forKey:NTM_key(aid, @"noPreview")];
        if (d[@"bgNet"]) [prefs setBool:[d[@"bgNet"] boolValue] forKey:NTM_key(aid, @"bgNet")];
        NSArray *kw = d[@"kw"];
        if (kw) { [prefs removeObjectForKey:NTM_key(aid, @"kw")]; if ([kw isKindOfClass:[NSArray class]] && kw.count) NTM_kwSave(aid, kw); }
        if (d[@"group"]) [prefs setObject:d[@"group"] forKey:NTM_key(aid, @"group")];
    }
    NTM_updateAnyBgNet();
    NSArray *idsCopy = [ids copy];
    dispatch_async(NTM_syncQueue(), ^{
        [prefs synchronize]; NTM_postConfigChanged();
        for (NSString *aid in idsCopy) { NTM_syncSystem(aid); NTM_syncCellular(aid, NTM_netRead(aid)); }
    });
    [self refreshAllCards];
    [self refreshStat];
    [self toast:[NSString stringWithFormat:@"已恢复 %lu 个应用", (unsigned long)ids.count]];
}

#pragma mark - 应用分组
- (void)groupManagerTapped {
    NSArray *names = NTM_groupNames();
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"应用分组"
                                                                message:names.count ? @"选中的整组可批量操作" : @"还没有分组，先新建一个"
                                                         preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *name in names) {
        [ac addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@ 分组", name]
                                               style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ [self groupOps:name]; }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"新建分组" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ [self promptNewGroup]; }]];
    if (names.count)
        [ac addAction:[UIAlertAction actionWithTitle:@"管理分组（删除）" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a){ [self manageGroups]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self showAlertController:ac];
}
- (void)promptNewGroup {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"新建分组" message:@"输入分组名称（如：社交、游戏、短视频）" preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf){ tf.placeholder = @"分组名称"; }];
    [ac addAction:[UIAlertAction actionWithTitle:@"创建" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
        NTM_addGroupName(ac.textFields.firstObject.text);
        [self toast:@"已创建分组"];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self showAlertController:ac];
}
- (void)manageGroups {
    NSArray *names = NTM_groupNames();
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"管理分组" message:@"点击删除分组" preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSString *name in names) {
        [ac addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"删除 %@", name] style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a){
            NTM_removeGroupName(name);
            [self refreshAllCards];
            [self toast:[NSString stringWithFormat:@"已删除分组 %@", name]];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self showAlertController:ac];
}
- (NSArray *)appIdsOfGroup:(NSString *)name {
    NSMutableArray *ids = [NSMutableArray array];
    for (NSDictionary *app in _allApps) {
        NSString *g = [NTM_prefs() objectForKey:NTM_key(app[@"id"], @"group")];
        if ([g isEqualToString:name]) [ids addObject:app[@"id"]];
    }
    return ids;
}
- (void)groupOps:(NSString *)name {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"%@ 分组", name] message:@"整组批量操作" preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"整组全部开启" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ [self groupBatch:name en:YES]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"整组全部关闭" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ [self groupBatch:name en:NO]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"整组断网" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ [self groupNetOff:name]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self showAlertController:ac];
}
- (void)groupBatch:(NSString *)name en:(BOOL)en {
    NSUserDefaults *prefs = NTM_prefs();
    NSArray *ids = [self appIdsOfGroup:name];
    for (NSString *aid in ids) {
        [prefs setBool:en forKey:NTM_key(aid, @"en")];
        for (NSDictionary *d in NTM_dims()) [prefs setBool:en forKey:NTM_key(aid, d[@"key"])];
        [prefs setInteger:(en ? 0 : 1) forKey:NTM_netKey(aid)];
    }
    NSArray *copy = [ids copy];
    dispatch_async(NTM_syncQueue(), ^{ [prefs synchronize]; NTM_postConfigChanged();
        for (NSString *aid in copy) { NTM_syncSystem(aid); NTM_syncCellular(aid, en?0:1); } });
    [self refreshAllCards]; [self refreshStat];
    [self toast:[NSString stringWithFormat:@"%@：已%@ %lu 个应用", name, en?@"开启":@"关闭", (unsigned long)ids.count]];
}
- (void)groupNetOff:(NSString *)name {
    NSUserDefaults *prefs = NTM_prefs();
    NSArray *ids = [self appIdsOfGroup:name];
    for (NSString *aid in ids) [prefs setInteger:1 forKey:NTM_netKey(aid)];
    NSArray *copy = [ids copy];
    dispatch_async(NTM_syncQueue(), ^{ [prefs synchronize]; NTM_postConfigChanged();
        for (NSString *aid in copy) NTM_syncCellular(aid, 1); });
    [self refreshAllCards]; [self refreshStat];
    [self toast:[NSString stringWithFormat:@"%@：已断网 %lu 个应用", name, (unsigned long)ids.count]];
}
- (void)pickGroup:(NSString *)aid {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:NTM_dispName(aid) message:@"选择分组" preferredStyle:UIAlertControllerStyleActionSheet];
    [ac addAction:[UIAlertAction actionWithTitle:@"未分组" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
        NTM_setGroup(aid, @""); [self refreshAllCards];
    }]];
    for (NSString *name in NTM_groupNames()) {
        [ac addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
            NTM_setGroup(aid, name); [self refreshAllCards];
        }]];
    }
    [ac addAction:[UIAlertAction actionWithTitle:@"新建分组" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){ [self promptNewGroup]; }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self showAlertController:ac];
}

#pragma mark - 关键词过滤
- (void)editKeyword:(NSString *)aid {
    NSArray *list = NTM_kwList(aid);
    NSString *text = [list componentsJoinedByString:@","];
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"关键词过滤" message:@"输入关键词，用逗号或分号分隔；命中即拦截该条通知" preferredStyle:UIAlertControllerStyleAlert];
    [ac addTextFieldWithConfigurationHandler:^(UITextField *tf){ tf.text = text; tf.placeholder = @"如：广告,优惠券,营销"; }];
    [ac addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
        NSString *v = ac.textFields.firstObject.text ?: @"";
        NSMutableArray *kws = [NSMutableArray array];
        for (NSString *part in [v componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@",，;；"]]) {
            NSString *t = [part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (t.length) [kws addObject:t];
        }
        NTM_kwSave(aid, kws);
        [self refreshAllCards];
        [self toast:kws.count ? [NSString stringWithFormat:@"已设置 %lu 个关键词", (unsigned long)kws.count] : @"已清除关键词"];
    }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self showAlertController:ac];
}

#pragma mark - 反馈
- (void)feedback {
    NSString *subject = [@"通知管理插件反馈" stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"mailto:wacljcr@qq.com?subject=%@", subject]];
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

#pragma mark - 导入/导出
- (NSString *)configPath {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/NotifyManagerConfig.json"];
}
- (void)exportConfig {
    NSMutableArray *arr = [NSMutableArray array];
    for (NSDictionary *app in _allApps) {
        NSString *aid = app[@"id"];
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"appId"] = aid;
        d[@"name"] = app[@"name"];
        d[@"en"] = @(NTM_read(aid, @"en"));
        NSMutableDictionary *dims = [NSMutableDictionary dictionary];
        for (NSDictionary *dim in NTM_dims()) dims[dim[@"key"]] = @(NTM_read(aid, dim[@"key"]));
        d[@"dims"] = dims;
        d[@"net"] = @(NTM_netRead(aid));
        d[@"noBadge"] = @(NTM_feat(aid, @"noBadge"));
        d[@"noPreview"] = @(NTM_feat(aid, @"noPreview"));
        d[@"bgNet"] = @(NTM_feat(aid, @"bgNet"));
        d[@"kw"] = NTM_kwList(aid);
        NSString *grp = [NTM_prefs() objectForKey:NTM_key(aid, @"group")];
        if (grp.length) d[@"group"] = grp;
        [arr addObject:d];
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:arr options:NSJSONWritingPrettyPrinted error:nil];
    if (!data) { [self toast:@"导出失败"]; return; }
    NSString *path = [self configPath];
    if (![data writeToFile:path atomically:YES]) { [self toast:@"导出失败，无写入权限"]; return; }
    [self toast:[NSString stringWithFormat:@"已导出 %lu 个应用", (unsigned long)arr.count]];
    NSURL *url = [NSURL fileURLWithPath:path];
    UIActivityViewController *avc = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    avc.popoverPresentationController.sourceView = self.view;
    avc.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width/2, self.view.bounds.size.height/2, 1, 1);
    [self presentViewController:avc animated:YES completion:nil];
}
- (void)importConfig {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initWithDocumentTypes:@[@"public.json", @"public.data"] inMode:UIDocumentPickerModeImport];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (!data) { [self toast:@"读取文件失败"]; return; }
    NSArray *arr = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![arr isKindOfClass:[NSArray class]]) { [self toast:@"配置格式错误"]; return; }
    NSInteger count = 0;
    NSUserDefaults *prefs = NTM_prefs();
    for (NSDictionary *d in arr) {
        NSString *aid = d[@"appId"];
        if (!aid.length) continue;
        id en = d[@"en"];
        if (en) [prefs setBool:[en boolValue] forKey:NTM_key(aid, @"en")];
        NSDictionary *dims = d[@"dims"];
        if ([dims isKindOfClass:[NSDictionary class]]) for (NSString *k in dims) [prefs setBool:[dims[k] boolValue] forKey:NTM_key(aid, k)];
        id net = d[@"net"];
        if (net) { [prefs setInteger:[net integerValue] forKey:NTM_netKey(aid)]; NTM_syncCellularAsync(aid, [net integerValue]); }
        if (d[@"noBadge"]) [prefs setBool:[d[@"noBadge"] boolValue] forKey:NTM_key(aid, @"noBadge")];
        if (d[@"noPreview"]) [prefs setBool:[d[@"noPreview"] boolValue] forKey:NTM_key(aid, @"noPreview")];
        if (d[@"bgNet"]) [prefs setBool:[d[@"bgNet"] boolValue] forKey:NTM_key(aid, @"bgNet")];
        NSArray *kw = d[@"kw"];
        if ([kw isKindOfClass:[NSArray class]]) { [prefs removeObjectForKey:NTM_key(aid, @"kw")]; if (kw.count) NTM_kwSave(aid, kw); }
        NSString *grp = d[@"group"];
        if (grp.length) [prefs setObject:grp forKey:NTM_key(aid, @"group")];
        NTM_syncSystemAsync(aid);
        count++;
    }
    NTM_updateAnyBgNet();
    dispatch_async(NTM_syncQueue(), ^{ [prefs synchronize]; NTM_postConfigChanged(); });
    [self refreshAllCards];
    [self refreshStat];
    [self toast:[NSString stringWithFormat:@"已导入 %ld 个应用", (long)count]];
}

#pragma mark - 搜索（防抖 0.3s）
- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    _searchText = searchText ?: @"";
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(applySearch) object:nil];
    [self performSelector:@selector(applySearch) withObject:nil afterDelay:0.3];
}
- (void)applySearch { [self reloadList]; }
- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(applySearch) object:nil];
    [self applySearch];
}

#pragma mark - Toast
- (void)toast:(NSString *)msg {
    UILabel *l = [[UILabel alloc] init];
    l.text = msg;
    l.font = [UIFont systemFontOfSize:13];
    l.textColor = [UIColor whiteColor];
    l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.78];
    l.layer.cornerRadius = 10;
    l.clipsToBounds = YES;
    l.textAlignment = NSTextAlignmentCenter;
    l.numberOfLines = 0;
    l.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:l];
    [NSLayoutConstraint activateConstraints:@[
        [l.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [l.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [l.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:30],
        [l.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-30],
    ]];
    l.alpha = 0;
    [UIView animateWithDuration:0.2 animations:^{ l.alpha = 1; }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.3 animations:^{ l.alpha = 0; } completion:^(BOOL f){ [l removeFromSuperview]; }];
    });
}

@end   // ← 关掉原来的 NTMPrincipalController

#pragma mark - 卡密激活 (2.3.24)

// === NTMActivationVC —— 全屏遮罩，挡住所有功能按钮 ===
@interface NTMActivationVC : UIViewController <UITextFieldDelegate> {
    UITextField *_keyField;
    UIActivityIndicatorView *_spinner;
    UILabel *_udidLabel;
    UIButton *_copyBtn;
}
@end

@implementation NTMActivationVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
    self.modalPresentationStyle = UIModalPresentationOverFullScreen;
    self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    
    CGFloat w = self.view.bounds.size.width;
    
    UIBlurEffect *be = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
    UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:be];
    blur.frame = self.view.bounds;
    blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:blur];
    
    UIView *card = [[UIView alloc] init];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.backgroundColor = [UIColor whiteColor];
    card.layer.cornerRadius = 18;
    card.layer.shadowColor = [UIColor blackColor].CGColor;
    card.layer.shadowOpacity = 0.3;
    card.layer.shadowRadius = 20;
    card.layer.shadowOffset = CGSizeZero;
    [self.view addSubview:card];
    
    UILabel *icon = [[UILabel alloc] init];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.text = @"🔑";
    icon.font = [UIFont systemFontOfSize:56];
    icon.textAlignment = NSTextAlignmentCenter;
    [card addSubview:icon];
    
    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"通知管理 · 卡密激活";
    title.font = [UIFont boldSystemFontOfSize:20];
    title.textColor = [UIColor blackColor];
    title.textAlignment = NSTextAlignmentCenter;
    [card addSubview:title];
    
    UILabel *sub = [[UILabel alloc] init];
    sub.translatesAutoresizingMaskIntoConstraints = NO;
    sub.text = @"输入卡密解锁插件全部功能\n未激活时插件不生效";
    sub.font = [UIFont systemFontOfSize:13];
    sub.textColor = [UIColor colorWithRed:0.45 green:0.45 blue:0.50 alpha:1];
    sub.textAlignment = NSTextAlignmentCenter;
    sub.numberOfLines = 0;
    [card addSubview:sub];
    
    // UDID
    UIView *udidBox = [[UIView alloc] init];
    udidBox.translatesAutoresizingMaskIntoConstraints = NO;
    udidBox.backgroundColor = [UIColor colorWithRed:0.96 green:0.97 blue:0.98 alpha:1];
    udidBox.layer.cornerRadius = 10;
    [card addSubview:udidBox];
    
    UILabel *udidTitle = [[UILabel alloc] init];
    udidTitle.translatesAutoresizingMaskIntoConstraints = NO;
    udidTitle.text = @"📱 你的设备 UDID";
    udidTitle.font = [UIFont boldSystemFontOfSize:12];
    udidTitle.textColor = [UIColor colorWithRed:0.30 green:0.30 blue:0.35 alpha:1];
    [udidBox addSubview:udidTitle];
    
    // 读 UDID：多种 fallback
    NSString *udidStr = @"";
    void *mg = dlopen("/System/Library/PrivateFrameworks/MobileGestalt.framework/MobileGestalt", RTLD_NOW);
    if (mg) {
        NSString *(*copyAns)(NSString *, NSDictionary *) = dlsym(mg, "MGCopyAnswer");
        if (copyAns) {
            udidStr = copyAns(@"UniqueDeviceID", nil) ?: @"";
            if (udidStr.length < 20) {
                NSString *idfv = copyAns(@"IdentifierForVendor", nil) ?: @"";
                if (idfv.length > udidStr.length) udidStr = idfv;
            }
            if (udidStr.length < 20) {
                NSString *serial = copyAns(@"SerialNumber", nil) ?: @"";
                if (serial.length > udidStr.length) udidStr = serial;
            }
        }
        dlclose(mg);
    }
    if (udidStr.length < 10) {
        udidStr = [UIDevice currentDevice].identifierForVendor.UUIDString ?: @"";
    }
    _udidLabel = [[UILabel alloc] init];
    _udidLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _udidLabel.text = udidStr.length > 0 ? udidStr : @"（读不到）";
    _udidLabel.font = [UIFont fontWithName:@"Menlo" size:11];
    _udidLabel.textColor = [UIColor colorWithRed:0.20 green:0.20 blue:0.25 alpha:1];
    _udidLabel.numberOfLines = 2;
    _udidLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [udidBox addSubview:_udidLabel];
    
    _copyBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    _copyBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [_copyBtn setTitle:@"复制" forState:UIControlStateNormal];
    _copyBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    [_copyBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _copyBtn.backgroundColor = [UIColor colorWithRed:0.20 green:0.55 blue:0.95 alpha:1];
    _copyBtn.layer.cornerRadius = 8;
    [_copyBtn addTarget:self action:@selector(copyUdid) forControlEvents:UIControlEventTouchUpInside];
    [udidBox addSubview:_copyBtn];
    
    UILabel *hint = [[UILabel alloc] init];
    hint.translatesAutoresizingMaskIntoConstraints = NO;
    hint.text = @"把 UDID 发给卖家，获取你的专属卡密";
    hint.font = [UIFont systemFontOfSize:11];
    hint.textColor = [UIColor colorWithRed:0.55 green:0.55 blue:0.60 alpha:1];
    hint.textAlignment = NSTextAlignmentCenter;
    [udidBox addSubview:hint];
    
    // 输入框
    UIView *inputBox = [[UIView alloc] init];
    inputBox.translatesAutoresizingMaskIntoConstraints = NO;
    inputBox.backgroundColor = [UIColor colorWithRed:0.96 green:0.97 blue:0.98 alpha:1];
    inputBox.layer.cornerRadius = 10;
    [card addSubview:inputBox];
    
    _keyField = [[UITextField alloc] init];
    _keyField.translatesAutoresizingMaskIntoConstraints = NO;
    _keyField.placeholder = @"粘贴或输入卡密 (XXXX-XXXX-XXXX)";
    _keyField.font = [UIFont fontWithName:@"Menlo" size:14];
    _keyField.returnKeyType = UIReturnKeyDone;
    _keyField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _keyField.autocorrectionType = UITextAutocorrectionTypeNo;
    _keyField.delegate = self;
    [inputBox addSubview:_keyField];
    
    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [inputBox addSubview:_spinner];
    
    UIButton *activateBtn = [UIButton buttonWithType:UIButtonTypeCustom];
    activateBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [activateBtn setTitle:@"✅ 验证并激活" forState:UIControlStateNormal];
    activateBtn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
    [activateBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    activateBtn.backgroundColor = [UIColor colorWithRed:0.20 green:0.65 blue:0.35 alpha:1];
    activateBtn.layer.cornerRadius = 12;
    [activateBtn addTarget:self action:@selector(doActivate) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:activateBtn];
    
    UIButton *clearBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    clearBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [clearBtn setTitle:@"清除已保存卡密" forState:UIControlStateNormal];
    clearBtn.titleLabel.font = [UIFont systemFontOfSize:12];
    [clearBtn setTitleColor:[UIColor colorWithRed:0.70 green:0.30 blue:0.20 alpha:1] forState:UIControlStateNormal];
    [clearBtn addTarget:self action:@selector(doClear) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:clearBtn];
    
    [NSLayoutConstraint activateConstraints:@[
        [card.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:-20],
        [card.widthAnchor constraintEqualToAnchor:self.view.widthAnchor constant:-40],
        
        [icon.topAnchor constraintEqualToAnchor:card.topAnchor constant:20],
        [icon.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        
        [title.topAnchor constraintEqualToAnchor:icon.bottomAnchor constant:4],
        [title.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [title.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],
        
        [sub.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:4],
        [sub.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [sub.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],
        
        [udidBox.topAnchor constraintEqualToAnchor:sub.bottomAnchor constant:16],
        [udidBox.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [udidBox.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],
        [udidBox.heightAnchor constraintGreaterThanOrEqualToConstant:80],
        
        [udidTitle.topAnchor constraintEqualToAnchor:udidBox.topAnchor constant:10],
        [udidTitle.leadingAnchor constraintEqualToAnchor:udidBox.leadingAnchor constant:12],
        [udidTitle.trailingAnchor constraintEqualToAnchor:_copyBtn.leadingAnchor constant:-8],
        
        [_udidLabel.topAnchor constraintEqualToAnchor:udidTitle.bottomAnchor constant:2],
        [_udidLabel.leadingAnchor constraintEqualToAnchor:udidBox.leadingAnchor constant:12],
        [_udidLabel.trailingAnchor constraintEqualToAnchor:_copyBtn.leadingAnchor constant:-8],
        
        [_copyBtn.centerYAnchor constraintEqualToAnchor:udidBox.centerYAnchor],
        [_copyBtn.trailingAnchor constraintEqualToAnchor:udidBox.trailingAnchor constant:-12],
        [_copyBtn.widthAnchor constraintEqualToConstant:56],
        [_copyBtn.heightAnchor constraintEqualToConstant:32],
        
        [hint.topAnchor constraintEqualToAnchor:_udidLabel.bottomAnchor constant:2],
        [hint.leadingAnchor constraintEqualToAnchor:udidBox.leadingAnchor constant:12],
        [hint.trailingAnchor constraintEqualToAnchor:udidBox.trailingAnchor constant:-12],
        
        [inputBox.topAnchor constraintEqualToAnchor:udidBox.bottomAnchor constant:14],
        [inputBox.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [inputBox.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],
        [inputBox.heightAnchor constraintEqualToConstant:48],
        
        [_keyField.leadingAnchor constraintEqualToAnchor:inputBox.leadingAnchor constant:12],
        [_keyField.trailingAnchor constraintEqualToAnchor:_spinner.leadingAnchor constant:-6],
        [_keyField.centerYAnchor constraintEqualToAnchor:inputBox.centerYAnchor],
        [_keyField.heightAnchor constraintEqualToConstant:40],
        
        [_spinner.trailingAnchor constraintEqualToAnchor:inputBox.trailingAnchor constant:-12],
        [_spinner.centerYAnchor constraintEqualToAnchor:inputBox.centerYAnchor],
        
        [activateBtn.topAnchor constraintEqualToAnchor:inputBox.bottomAnchor constant:14],
        [activateBtn.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
        [activateBtn.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],
        [activateBtn.heightAnchor constraintEqualToConstant:48],
        
        [clearBtn.topAnchor constraintEqualToAnchor:activateBtn.bottomAnchor constant:6],
        [clearBtn.centerXAnchor constraintEqualToAnchor:card.centerXAnchor],
        [clearBtn.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14],
    ]];
}

- (void)copyUdid {
    _copyBtn.backgroundColor = [UIColor colorWithRed:0.15 green:0.80 blue:0.40 alpha:1];
    [_copyBtn setTitle:@"已复制" forState:UIControlStateNormal];
    [UIPasteboard generalPasteboard].string = _udidLabel.text ?: @"";
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1500*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        self->_copyBtn.backgroundColor = [UIColor colorWithRed:0.20 green:0.55 blue:0.95 alpha:1];
        [self->_copyBtn setTitle:@"复制" forState:UIControlStateNormal];
    });
}

- (void)doActivate {
    NSString *newKey = [_keyField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (newKey.length == 0) return;
    
    // 读 UDID fallback（和 viewDidLoad 里的逻辑一致）
    NSString *udidStr = @"";
    void *mg = dlopen("/System/Library/PrivateFrameworks/MobileGestalt.framework/MobileGestalt", RTLD_NOW);
    if (mg) {
        NSString *(*copyAns)(NSString *, NSDictionary *) = dlsym(mg, "MGCopyAnswer");
        if (copyAns) {
            udidStr = copyAns(@"UniqueDeviceID", nil) ?: @"";
            if (udidStr.length < 20) {
                NSString *idfv = copyAns(@"IdentifierForVendor", nil) ?: @"";
                if (idfv.length > udidStr.length) udidStr = idfv;
            }
            if (udidStr.length < 20) {
                NSString *serial = copyAns(@"SerialNumber", nil) ?: @"";
                if (serial.length > udidStr.length) udidStr = serial;
            }
        }
        dlclose(mg);
    }
    if (udidStr.length < 10) {
        udidStr = [UIDevice currentDevice].identifierForVendor.UUIDString ?: @"";
    }
    
    [_spinner startAnimating];
    _keyField.enabled = NO;
    
    // 正确 API（license-system/server）: POST verify.php  action=activate&card_key=X&device_id=X&tweak_id=X
    NSString *body = [NSString stringWithFormat:
        @"action=activate&card_key=%@&device_id=%@&tweak_id=com.ntm.notifymanager",
        [newKey   stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]],
        [udidStr  stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"http://101.200.189.251/verify.php"]];
    req.HTTPMethod = @"POST";
    req.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];
    [req setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    req.timeoutInterval = 10;
    
    NSURLResponse *resp = nil; NSError *err = nil;
    NSData *data = [NSURLConnection sendSynchronousRequest:req returningResponse:&resp error:&err];
    
    [_spinner stopAnimating];
    _keyField.enabled = YES;
    
    if (err || !data) {
        [self flashError:[NSString stringWithFormat:@"网络错误：%@", err.localizedDescription ?: @"无响应"]];
        return;
    }
    
    NSError *je = nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&je];
    if (je || ![json isKindOfClass:[NSDictionary class]]) {
        NSString *raw = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
        [self flashError:[NSString stringWithFormat:@"服务器返回异常：%@", raw.length > 50 ? [raw substringToIndex:50] : raw]];
        return;
    }
    
    BOOL authorized = [json[@"authorized"] boolValue];
    NSString *message = json[@"message"] ?: @"";
    
    if (!authorized) {
        NSString *msg = [NSString stringWithFormat:@"❌ %@", message.length ? message : @"激活失败"];
        [self flashError:msg];
        return;
    }
    
    // OK! 从服务器拿 expiry（Unix 时间戳），存公共 JSON（跨 rootless 容器）
    NSNumber *expiryNum = json[@"expiry"];
    NSTimeInterval expTs = 0;
    if (expiryNum && [expiryNum longLongValue] > 0) {
        expTs = [expiryNum doubleValue] + 7*86400; // +7 天宽限期
    } else {
        expTs = [[NSDate date] timeIntervalSince1970] + 365*86400;
    }
    NTM_writeLic(@{
        @"activation_key": newKey,
        @"verify_expires": @(expTs),
        @"verify_udid": udidStr ?: @"",
    });
    // 同时也写一份到旧 suite（兼容旧版本）
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:@"com.ntm.notifymanager"];
    [d setObject:newKey forKey:@"NTM_activation_key"];
    [d setObject:udidStr forKey:@"NTM_verify_udid"];
    [d setObject:[NSDate dateWithTimeIntervalSince1970:expTs] forKey:@"NTM_verify_expires"];
    [d synchronize];
    
    CFNotificationCenterPostNotification(CFNotificationCenterGetLocalCenter(),
        (CFNotificationName)@"com.ntm.notifymanager.activationChanged", NULL, NULL, YES);
    
    [self dismissViewControllerAnimated:YES completion:^{
        UIViewController *parent = self.presentingViewController;
        if ([parent respondsToSelector:@selector(activationSucceed)]) {
            [parent performSelector:@selector(activationSucceed)];
        }
    }];
}

- (void)doClear {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"清除卡密"
        message:@"确定清除已保存的卡密？清除后插件将被锁定"
        preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [ac addAction:[UIAlertAction actionWithTitle:@"清除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        NTM_writeLic(nil); // 删公共 JSON
        NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:@"com.ntm.notifymanager"];
        [d removeObjectForKey:@"NTM_activation_key"];
        [d removeObjectForKey:@"NTM_verify_expires"];
        [d removeObjectForKey:@"NTM_verify_udid"];
        [d synchronize];
        self->_keyField.text = @"";
        [self flashError:@"已清除卡密"];
    }]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (void)flashError:(NSString *)msg {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"提示"
        message:msg preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:ac animated:YES completion:nil];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [textField resignFirstResponder];
    [self doActivate];
    return YES;
}

@end

@implementation NTMPrincipalController (ActivationStuff)
- (void)setupActivationBar {
    CFNotificationCenterAddObserver(CFNotificationCenterGetLocalCenter(), NULL,
        &NTMNotifyCallback, (CFNotificationName)@"com.ntm.notifymanager.activationChanged", NULL, CFNotificationSuspensionBehaviorDrop);
}

// 秒级查服务器（NotifyManager.m 专用，和 Tweak.m 逻辑一致）
static BOOL NTM_verifyNow(void) {
    // 读 UDID
    NSString *udid = nil;
    void *mg = dlopen("/System/Library/PrivateFrameworks/MobileGestalt.framework/MobileGestalt", RTLD_NOW);
    if (mg) {
        NSString *(*copyAnswer)(NSString *, NSDictionary *) = dlsym(mg, "MGCopyAnswer");
        if (copyAnswer) udid = copyAnswer(@"UniqueDeviceID", nil);
        dlclose(mg);
    }
    if (!udid.length) return NO;
    
    // 同步请求
    NSString *body = [NSString stringWithFormat:
        @"action=verify&device_id=%@&tweak_id=com.ntm.notifymanager", udid];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"http://101.200.189.251/verify.php"]];
    req.HTTPMethod = @"POST";
    req.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];
    [req setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    req.timeoutInterval = 3;
    
    NSURLResponse *resp = nil; NSError *err = nil;
    NSData *data = [NSURLConnection sendSynchronousRequest:req returningResponse:&resp error:&err];
    
    if (err || !data) {
        // 服务器挂了 → 读公共 JSON 兜底
        NSDictionary *lic = NTM_readLic();
        if (!lic) return NO;
        NSNumber *expNum = lic[@"verify_expires"];
        if (!expNum || [expNum doubleValue] < [[NSDate date] timeIntervalSince1970]) return NO;
        return YES;
    }
    
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    BOOL ok = [json isKindOfClass:[NSDictionary class]] && [json[@"authorized"] boolValue];
    
    if (!ok) {
        NTM_writeLic(nil);  // 删公共 JSON
        NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:@"com.ntm.notifymanager"];
        [d removeObjectForKey:@"NTM_activation_key"];
        [d removeObjectForKey:@"NTM_verify_expires"];
        [d removeObjectForKey:@"NTM_verify_udid"];
        [d synchronize];
    }
    return ok;
}

- (BOOL)NTM_isActivated {
    // 每次都秒级同步服务器（CallAssist 风格）
    return NTM_verifyNow();
}

- (void)showActivationModalIfNeeded {
    if ([self NTM_isActivated]) {
        _ntmLocked = NO;
        [self NTM_applyLock];
        return;
    }
    _ntmLocked = YES;
    [self NTM_applyLock];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 400*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if ([self NTM_isActivated]) return;
        NTMActivationVC *vc = [[NTMActivationVC alloc] init];
        [self presentViewController:vc animated:YES completion:nil];
    });
}

- (void)activationSucceed {
    [self toast:@"✅ 验证通过！插件已解锁"];
    _ntmLocked = NO;
    [self NTM_applyLock];
    [self reloadList];
}

- (NSString *)NTM_readUDID {
    NSString *udid = @"";
    void *mg = dlopen("/System/Library/PrivateFrameworks/MobileGestalt.framework/MobileGestalt", RTLD_NOW);
    if (mg) {
        NSString *(*copyAns)(NSString *, NSDictionary *) = dlsym(mg, "MGCopyAnswer");
        if (copyAns) {
            udid = copyAns(@"UniqueDeviceID", nil) ?: @"";
            if (udid.length < 20) {
                NSString *idfv = copyAns(@"IdentifierForVendor", nil) ?: @"";
                if (idfv.length > udid.length) udid = idfv;
            }
            if (udid.length < 20) {
                NSString *serial = copyAns(@"SerialNumber", nil) ?: @"";
                if (serial.length > udid.length) udid = serial;
            }
        }
        dlclose(mg);
    }
    if (udid.length < 10) {
        udid = [UIDevice currentDevice].identifierForVendor.UUIDString ?: @"";
    }
    return udid ?: @"";
}

- (void)NTM_applyLock {
    BOOL lock = _ntmLocked;
    self.navigationItem.rightBarButtonItem.enabled = !lock;
    _catSeg.enabled = !lock;
    _filterSeg.enabled = !lock;
    _searchBar.userInteractionEnabled = !lock;
    _selEntryBtn.enabled = !lock;
    _autoAuthSwitch.enabled = !lock;
    _tableView.userInteractionEnabled = !lock;
    if (_topRow)  [self NTM_disableControlsIn:_topRow  locked:lock];
    if (_editCol) [self NTM_disableControlsIn:_editCol locked:lock];
    if (_headCol) [self NTM_disableControlsIn:_headCol locked:lock];
}

- (void)NTM_disableControlsIn:(UIView *)view locked:(BOOL)lock {
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:[UIControl class]]) {
            ((UIControl *)sub).enabled = !lock;
        }
        [self NTM_disableControlsIn:sub locked:lock];
    }
}

void NTMNotifyCallback(CFNotificationCenterRef center, void *observer, CFNotificationName name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *w = [UIApplication sharedApplication].keyWindow;
        UIViewController *vc = w.rootViewController;
        if ([vc isKindOfClass:[UINavigationController class]]) vc = ((UINavigationController *)vc).visibleViewController;
        if ([vc respondsToSelector:@selector(refreshActivationBar)]) {
            [vc performSelector:@selector(refreshActivationBar)];
        }
        if ([(__bridge NSString *)name isEqualToString:@"com.ntm.notifymanager.needRestart"]) {
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"✅ 卡密已激活"
                message:@"重启设备后插件完全生效\n（设置 → 通知管理 → 关闭再开启也可）"
                preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [vc presentViewController:a animated:YES completion:nil];
        }
    });
}

@end