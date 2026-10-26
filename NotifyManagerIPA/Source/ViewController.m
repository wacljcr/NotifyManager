#import "ViewController.h"
#import "AppCardView.h"
#import "StorageManager.h"
#import <objc/message.h>
#import <dlfcn.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface ViewController ()
@property (nonatomic, strong) UISegmentedControl *catSeg;
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UILabel *statLabel;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) NSArray *allApps;
@property (nonatomic, strong) NSArray *curApps;
@property (nonatomic, copy) NSString *curCat;
@property (nonatomic, copy) NSString *searchText;
@property (nonatomic, strong) NSDictionary *snapshot;
@end

@implementation ViewController

static NSArray *kCategories(void) {
    return @[@"用户应用", @"巨魔应用", @"系统应用"];
}

#pragma mark - Lifecycle

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"通知管理";
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleLight;
    self.navigationController.navigationBar.prefersLargeTitles = YES;
    self.navigationController.navigationBar.tintColor = [UIColor colorWithRed:0.25 green:0.48 blue:0.85 alpha:1];

    // 渐变背景
    CAGradientLayer *gradient = [CAGradientLayer layer];
    gradient.frame = self.view.bounds;
    gradient.colors = @[
        (id)[UIColor colorWithRed:0.95 green:0.96 blue:0.98 alpha:1].CGColor,
        (id)[UIColor colorWithRed:0.92 green:0.94 blue:0.97 alpha:1].CGColor,
    ];
    gradient.name = @"NTM_background_gradient";
    [self.view.layer insertSublayer:gradient atIndex:0];

    _curCat = @"用户应用";
    _searchText = @"";

    [self buildUI];

    // 异步加载应用列表
    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [_spinner startAnimating];
    [self.view addSubview:_spinner];
    [NSLayoutConstraint activateConstraints:@[
        [_spinner.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [_spinner.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
    ]];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray *apps = [self enumerateApps];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.allApps = apps;
            [self reloadList];
        });
    });
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    for (CALayer *layer in self.view.layer.sublayers) {
        if ([layer isKindOfClass:[CAGradientLayer class]] &&
            [layer.name isEqualToString:@"NTM_background_gradient"]) {
            layer.frame = self.view.bounds;
            break;
        }
    }
}

#pragma mark - Build UI

- (void)buildUI {
    _catSeg = [[UISegmentedControl alloc] initWithItems:kCategories()];
    _catSeg.selectedSegmentIndex = 0;
    [_catSeg addTarget:self action:@selector(catChanged) forControlEvents:UIControlEventValueChanged];

    UIButton *allOnBtn = [self pillButton:@"全部开启"
                                     bg:[UIColor colorWithRed:0.45 green:0.78 blue:0.54 alpha:0.18]
                                     fg:[UIColor colorWithRed:0.13 green:0.55 blue:0.24 alpha:1]];
    [allOnBtn addTarget:self action:@selector(allOnTapped) forControlEvents:UIControlEventTouchUpInside];

    UIButton *allOffBtn = [self pillButton:@"全部关闭"
                                       bg:[UIColor colorWithRed:0.87 green:0.24 blue:0.24 alpha:0.15]
                                       fg:[UIColor colorWithRed:0.72 green:0.17 blue:0.17 alpha:1]];
    [allOffBtn addTarget:self action:@selector(allOffTapped) forControlEvents:UIControlEventTouchUpInside];

    UIButton *customBtn = [self pillButton:@"自定义"
                                       bg:[UIColor colorWithRed:0.55 green:0.58 blue:0.65 alpha:0.18]
                                       fg:[UIColor colorWithWhite:0.35 alpha:1]];
    [customBtn addTarget:self action:@selector(customTapped) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *batchRow = [[UIStackView alloc] initWithArrangedSubviews:@[allOnBtn, allOffBtn, customBtn]];
    batchRow.axis = UILayoutConstraintAxisHorizontal;
    batchRow.distribution = UIStackViewDistributionFillEqually;
    batchRow.spacing = 10;

    _searchBar = [[UISearchBar alloc] init];
    _searchBar.placeholder = @"搜索应用名称或 Bundle ID";
    _searchBar.delegate = self;
    _searchBar.searchBarStyle = UISearchBarStyleMinimal;
    _searchBar.backgroundImage = [UIImage new];

    _statLabel = [[UILabel alloc] init];
    _statLabel.font = [UIFont systemFontOfSize:12];
    _statLabel.textColor = [UIColor colorWithWhite:0.40 alpha:1];

    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _tableView.delegate = self;
    _tableView.dataSource = self;
    _tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    _tableView.backgroundColor = [UIColor clearColor];
    _tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    _tableView.contentInset = UIEdgeInsetsMake(4, 0, 80, 0);

    UIButton *exportBtn = [self pillButton:@"导出配置"
                                       bg:[UIColor colorWithRed:0.35 green:0.56 blue:1.0 alpha:0.15]
                                       fg:[UIColor colorWithRed:0.17 green:0.35 blue:0.72 alpha:1]];
    [exportBtn addTarget:self action:@selector(exportConfig) forControlEvents:UIControlEventTouchUpInside];

    UIButton *importBtn = [self pillButton:@"导入配置"
                                       bg:[UIColor colorWithRed:0.45 green:0.78 blue:0.54 alpha:0.18]
                                       fg:[UIColor colorWithRed:0.13 green:0.55 blue:0.24 alpha:1]];
    [importBtn addTarget:self action:@selector(importConfig) forControlEvents:UIControlEventTouchUpInside];

    // 底部按钮容器
    UIView *bottomBar = [[UIView alloc] init];
    bottomBar.backgroundColor = [UIColor colorWithWhite:0.97 alpha:0.95];
    bottomBar.translatesAutoresizingMaskIntoConstraints = NO;
    UIStackView *bottomRow = [[UIStackView alloc] initWithArrangedSubviews:@[exportBtn, importBtn]];
    bottomRow.axis = UILayoutConstraintAxisHorizontal;
    bottomRow.distribution = UIStackViewDistributionFillEqually;
    bottomRow.spacing = 12;
    bottomRow.translatesAutoresizingMaskIntoConstraints = NO;
    [bottomBar addSubview:bottomRow];
    [NSLayoutConstraint activateConstraints:@[
        [bottomRow.topAnchor constraintEqualToAnchor:bottomBar.topAnchor constant:8],
        [bottomRow.leadingAnchor constraintEqualToAnchor:bottomBar.leadingAnchor constant:16],
        [bottomRow.trailingAnchor constraintEqualToAnchor:bottomBar.trailingAnchor constant:-16],
        [bottomRow.bottomAnchor constraintEqualToAnchor:bottomBar.bottomAnchor constant:-16],
    ]];

    for (UIView *v in @[_tableView, batchRow, _statLabel, _searchBar, _catSeg, bottomBar]) {
        v.translatesAutoresizingMaskIntoConstraints = NO;
        [self.view addSubview:v];
    }

    [NSLayoutConstraint activateConstraints:@[
        [batchRow.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12],
        [batchRow.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [batchRow.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [batchRow.heightAnchor constraintEqualToConstant:40],

        [_statLabel.topAnchor constraintEqualToAnchor:batchRow.bottomAnchor constant:8],
        [_statLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20],
        [_statLabel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20],

        [_searchBar.topAnchor constraintEqualToAnchor:_statLabel.bottomAnchor constant:2],
        [_searchBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8],
        [_searchBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8],

        [_catSeg.topAnchor constraintEqualToAnchor:_searchBar.bottomAnchor constant:2],
        [_catSeg.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [_catSeg.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],

        [_tableView.topAnchor constraintEqualToAnchor:_catSeg.bottomAnchor constant:12],
        [_tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_tableView.bottomAnchor constraintEqualToAnchor:bottomBar.topAnchor constant:-4],

        [bottomBar.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [bottomBar.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [bottomBar.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

- (UIButton *)pillButton:(NSString *)title bg:(UIColor *)bg fg:(UIColor *)fg {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    [b setTitleColor:fg forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    b.backgroundColor = bg;
    b.layer.cornerRadius = 14;
    b.clipsToBounds = YES;
    return b;
}

#pragma mark - Enumerate Apps

- (NSString *)categoryOfProxy:(id)proxy {
    NSString *type = ((id (*)(id, SEL))objc_msgSend)(proxy, sel_registerName("applicationType")) ?: @"";
    NSString *bid  = ((id (*)(id, SEL))objc_msgSend)(proxy, sel_registerName("applicationIdentifier")) ?: @"";
    if ([type isEqualToString:@"System"]) {
        return ([bid hasPrefix:@"com.apple."]) ? @"系统应用" : @"巨魔应用";
    }
    NSString *teamID = ((id (*)(id, SEL))objc_msgSend)(proxy, sel_registerName("teamID")) ?: @"";
    BOOL appleSign = (teamID.length && ![teamID isEqualToString:@"adhoc"] && ![teamID isEqualToString:@"AdHoc"]);
    return appleSign ? @"用户应用" : @"巨魔应用";
}

- (NSSet *)_systemAppKeepList {
    // 只保留这些系统应用，其余过滤掉
    // 注：测距仪/放大器的真实 bundle id 为 com.apple.measure / com.apple.Magnifier
    //     （原仓库写的 measurify / magnifier 是错的，会导致这两个 App 被过滤掉、面板里看不到）
    return [NSSet setWithArray:@[
        @"com.apple.mobilenotes",          // 备忘录
        @"com.apple.podcasts",             // 播客
        @"com.apple.measure",              // 测距仪（修正：原 measurify 拼写错误）
        @"com.apple.findmy",               // 查找
        @"com.apple.Maps",                 // 地图
        @"com.apple.Translate",            // 翻译
        @"com.apple.Magnifier",            // 放大器（修正：原 magnifier 大小写错误）
        @"com.apple.mobilephone",          // FaceTime通话
        @"com.apple.stocks",               // 股市
        @"com.apple.calculator",           // 计算器
        @"com.apple.Home",                 // 家庭
        @"com.apple.Health",               // 健康
        @"com.apple.Fitness",              // 健身
        @"com.apple.shortcuts",            // 快捷指令
        @"com.apple.Passbook",             // 钱包
        @"com.apple.mobilecal",            // 日历
        @"com.apple.mobiletimer",          // 时钟
        @"com.apple.tv",                   // 视频
        @"com.apple.tips",                 // 提示
        @"com.apple.reminders",            // 提醒事项
        @"com.apple.weather",              // 天气
        @"com.apple.MobileAddressBook",    // 通讯录
        @"com.apple.iBooks",               // 图书
        @"com.apple.DocumentsApp",         // 文件
        @"com.apple.freeform",             // 无边记
        @"com.apple.Bridge",               // Watch
        @"com.apple.Music",                // 音乐
        @"com.apple.mobilemail",           // 邮件
        @"com.apple.VoiceMemos",           // 语音备忘录

        // -- 新增：用户反馈需要管理的系统应用（断网生效走系统蜂窝策略，面板必须可见才能改回）--
        @"com.apple.mobilesafari",         // Safari浏览器（曾因被过滤、断网后只能在系统蜂窝里救回）
        @"com.apple.MobileSMS",            // 信息
        @"com.apple.facetime",             // FaceTime
        @"com.apple.mobileslideshow",      // 照片
        @"com.apple.compass",              // 指南针
        @"com.apple.camera",               // 相机
        @"com.apple.AppStore",             // App Store
    ]];
}

- (NSArray *)enumerateApps {
    NSMutableArray *out = [NSMutableArray array];
    Class wk = objc_getClass("LSApplicationWorkspace");
    if (!wk) {
        dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices", RTLD_NOW);
        wk = objc_getClass("LSApplicationWorkspace");
    }
    if (!wk) return out;

    id ws = ((id (*)(id, SEL))objc_msgSend)((id)wk, sel_registerName("defaultWorkspace"));
    if (!ws) return out;

    NSSet *sysKeep = [self _systemAppKeepList];
    NSArray *proxies = ((id (*)(id, SEL))objc_msgSend)(ws, sel_registerName("allApplications"));
    for (id proxy in proxies) {
        NSString *bid  = ((id (*)(id, SEL))objc_msgSend)(proxy, sel_registerName("applicationIdentifier"));
        NSURL *url     = ((id (*)(id, SEL))objc_msgSend)(proxy, sel_registerName("bundleURL"));
        NSString *name = ((id (*)(id, SEL))objc_msgSend)(proxy, sel_registerName("localizedName"));
        NSString *path = [(NSURL *)url path] ?: @"";
        if (!bid.length || !path.length) continue;
        NSString *cat = [self categoryOfProxy:proxy];
        if ([cat isEqualToString:@"系统应用"]) {
            if (![path hasPrefix:@"/Applications/"]) continue;
            if (![sysKeep containsObject:bid]) continue;
        }
        [out addObject:@{ @"id": bid, @"name": (name.length ? name : bid), @"cat": cat }];
    }

    NSArray *order = @[@"用户应用", @"巨魔应用", @"系统应用"];
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSInteger ia = [order indexOfObject:a[@"cat"]];
        NSInteger ib = [order indexOfObject:b[@"cat"]];
        if (ia != ib) return ia < ib ? NSOrderedAscending : NSOrderedDescending;
        return [a[@"name"] compare:b[@"name"] options:NSCaseInsensitiveSearch];
    }];
    return out;
}

#pragma mark - UITableView

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _curApps.count;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 184;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"card"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"card"];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.backgroundColor = [UIColor clearColor];
    }
    for (UIView *v in cell.contentView.subviews) [v removeFromSuperview];

    NSDictionary *app = _curApps[indexPath.row];
    AppCardView *card = [[AppCardView alloc] initWithApp:app];
    [card reloadFromPrefs];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    __weak typeof(self) ws = self;
    card.onValueChanged = ^(NSString *aid) { [ws refreshStat]; };
    [cell.contentView addSubview:card];
    [NSLayoutConstraint activateConstraints:@[
        [card.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:6],
        [card.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [card.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
        [card.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-6],
    ]];
    return cell;
}

#pragma mark - List logic

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
        [filtered addObject:app];
    }
    _curApps = filtered;

    if (!filtered.count) {
        UILabel *empty = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 260, 80)];
        empty.text = @"该分类暂无应用";
        empty.font = [UIFont systemFontOfSize:14];
        empty.textColor = [UIColor colorWithWhite:0.55 alpha:1];
        empty.textAlignment = NSTextAlignmentCenter;
        _tableView.backgroundView = empty;
    } else {
        _tableView.backgroundView = nil;
    }

    [_tableView reloadData];
    [self refreshStat];
    [_spinner stopAnimating];
    [_spinner removeFromSuperview];
    _spinner = nil;
}

- (void)refreshAllCards {
    for (UITableViewCell *cell in _tableView.visibleCells) {
        for (UIView *v in cell.contentView.subviews) {
            if ([v isKindOfClass:[AppCardView class]]) {
                [(AppCardView *)v reloadFromPrefs];
            }
        }
    }
}

- (void)refreshStat {
    StorageManager *mgr = [StorageManager shared];
    NSInteger total = 0, on = 0;
    for (NSDictionary *app in _curApps) {
        if ([mgr readMasterForApp:app[@"id"]]) on++;
        total++;
    }
    NSString *scope = _searchText.length ? [NSString stringWithFormat:@"搜索：%@", _searchText] : _curCat;
    _statLabel.text = [NSString stringWithFormat:@"%@    已开启 %ld / %ld 个应用", scope, (long)on, (long)total];
}

#pragma mark - Actions

- (void)catChanged {
    _curCat = kCategories()[_catSeg.selectedSegmentIndex];
    [self reloadList];
}

- (void)allOnTapped {
    [self saveSnapshot];
    StorageManager *mgr = [StorageManager shared];
    NSMutableArray *ids = [NSMutableArray array];
    for (NSDictionary *app in _curApps) [ids addObject:app[@"id"]];
    [mgr batchWrite:YES forApps:ids netPolicy:0];
    [self refreshAllCards];
    [self refreshStat];
}

- (void)allOffTapped {
    [self saveSnapshot];
    StorageManager *mgr = [StorageManager shared];
    NSMutableArray *ids = [NSMutableArray array];
    for (NSDictionary *app in _curApps) [ids addObject:app[@"id"]];
    [mgr batchWrite:NO forApps:ids netPolicy:1];
    [self refreshAllCards];
    [self refreshStat];
}

- (void)customTapped {
    if (!_snapshot.count) return;
    [[StorageManager shared] restoreSnapshot:_snapshot];
    [self refreshAllCards];
    [self refreshStat];
}

- (void)saveSnapshot {
    _snapshot = [[StorageManager shared] snapshotForApps:_curApps];
}

#pragma mark - Import / Export

- (void)exportConfig {
    NSArray *config = [[StorageManager shared] exportConfigForAllApps:_allApps];
    NSData *data = [NSJSONSerialization dataWithJSONObject:config options:NSJSONWritingPrettyPrinted error:nil];
    if (!data) return;

    NSString *path = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
                      stringByAppendingPathComponent:@"NotifyManagerConfig.json"];
    if (![data writeToFile:path atomically:YES]) return;

    NSURL *url = [NSURL fileURLWithPath:path];
    UIActivityViewController *avc = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    avc.popoverPresentationController.sourceView = self.view;
    avc.popoverPresentationController.sourceRect = CGRectMake(self.view.bounds.size.width/2, self.view.bounds.size.height, 1, 1);
    [self presentViewController:avc animated:YES completion:nil];
}

- (void)importConfig {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[[UTType typeWithIdentifier:@"public.json"]] asCopy:NO];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (!data) return;
    NSArray *arr = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![arr isKindOfClass:[NSArray class]]) return;
    [[StorageManager shared] importConfig:arr];
    [self refreshAllCards];
    [self refreshStat];
}

#pragma mark - Search

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    _searchText = searchText ?: @"";
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(applySearch) object:nil];
    [self performSelector:@selector(applySearch) withObject:nil afterDelay:0.3];
}

- (void)applySearch {
    [self reloadList];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(applySearch) object:nil];
    [self applySearch];
}

@end