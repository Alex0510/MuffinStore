// MFSRootViewController.m
#import "MFSRootViewController.h"
#import "CoreServices.h"
#import <objc/runtime.h>
#import <Security/Security.h>
#import <sys/sysctl.h>
#import <spawn.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <os/log.h>
#import <sqlite3.h>

// ============================================
// Tweak 任务文件路径
// ============================================
#define TASK_FILE_PATH @"/var/mobile/Documents/muffinstore_task.plist"

// ============================================
// 日志函数
// ============================================
void CleanLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"🧹 [MuffinStore Clean] %@", message);
}

// ============================================
// 清理统计信息类
// ============================================
@interface CleaningStats : NSObject
@property (nonatomic, assign) NSUInteger filesDeleted;
@property (nonatomic, assign) long long bytesFreed;
@property (nonatomic, strong) NSDate *lastCleaningDate;
@property (nonatomic, assign) NSTimeInterval cleaningDuration;
@property (nonatomic, strong) NSMutableString *logOutput;
@property (nonatomic, assign) NSUInteger keychainItemsDeleted;
@end

@implementation CleaningStats
- (instancetype)init {
    self = [super init];
    if (self) {
        self.filesDeleted = 0;
        self.bytesFreed = 0;
        self.keychainItemsDeleted = 0;
        self.lastCleaningDate = [NSDate date];
        self.cleaningDuration = 0.0;
        self.logOutput = [NSMutableString string];
    }
    return self;
}

- (void)appendLog:(NSString *)log {
    [self.logOutput appendFormat:@"%@\n", log];
    CleanLog(@"%@", log);
}
@end

// ============================================
// SKUI 相关类 (使用运行时动态调用，避免链接错误)
// ============================================

// 添加 LSApplicationWorkspace 的额外方法声明
@interface LSApplicationWorkspace (Private)
- (BOOL)killApplicationWithBundleIdentifier:(NSString *)bundleIdentifier;
- (NSArray *)allApplications;
- (NSArray *)allInstalledApplications;
@end

static NSCache *iconCache = nil;
static NSCache *groupPathCache = nil;

@interface MFSRootViewController () <UISearchBarDelegate>
@property (nonatomic, strong) UISearchBar *searchBar;
@property (nonatomic, strong) UISegmentedControl *segmentControl;
@property (nonatomic, strong) NSArray<PSSpecifier *> *allAppSpecifiers;
@property (nonatomic, strong) NSArray<PSSpecifier *> *userAppSpecifiers;
@property (nonatomic, strong) NSArray<PSSpecifier *> *trollAppSpecifiers;
@property (nonatomic, assign) BOOL isSearching;
@property (nonatomic, copy) NSString *searchKeyword;
// 进度指示器属性
@property (nonatomic, strong) UIView *progressOverlay;
@property (nonatomic, strong) UIProgressView *progressView;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UITextView *logTextView;
@end

@implementation MFSRootViewController

+ (void)initialize {
    if (self == [MFSRootViewController class]) {
        iconCache = [[NSCache alloc] init];
        groupPathCache = [[NSCache alloc] init];
    }
}

- (void)loadView {
    [super loadView];
    
    CleanLog(@"MFSRootViewController 加载完成");
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadSpecifiers) name:UIApplicationWillEnterForegroundNotification object:nil];
    
    UIBarButtonItem *refreshButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(refreshAppList)];
    self.navigationItem.rightBarButtonItem = refreshButton;
    
    UIBarButtonItem *idDownloadButton = [[UIBarButtonItem alloc] initWithTitle:@"ID下载" style:UIBarButtonItemStylePlain target:self action:@selector(promptForAppIdDownload)];
    self.navigationItem.leftBarButtonItem = idDownloadButton;
    
    self.segmentControl = [[UISegmentedControl alloc] initWithItems:@[@"全部", @"用户应用", @"巨魔/ESign应用"]];
    self.segmentControl.selectedSegmentIndex = 0;
    [self.segmentControl addTarget:self action:@selector(segmentChanged:) forControlEvents:UIControlEventValueChanged];
    self.navigationItem.titleView = self.segmentControl;
    
    self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 44)];
    self.searchBar.delegate = self;
    self.searchBar.placeholder = @"搜索应用名称或 Bundle ID";
    self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    self.searchBar.showsCancelButton = YES;
    self.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.table.tableHeaderView = self.searchBar;
    
    self.searchKeyword = @"";
}

- (void)refreshAppList {
    CleanLog(@"刷新应用列表");
    _specifiers = nil;
    self.allAppSpecifiers = nil;
    self.userAppSpecifiers = nil;
    self.trollAppSpecifiers = nil;
    self.isSearching = NO;
    self.searchBar.text = @"";
    self.searchKeyword = @"";
    [iconCache removeAllObjects];
    [groupPathCache removeAllObjects];
    [self reloadSpecifiers];
}

- (void)segmentChanged:(UISegmentedControl *)sender {
    self.isSearching = (self.searchKeyword.length > 0);
    [self reloadSpecifiers];
}

#pragma mark - 搜索栏代理
- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    self.searchKeyword = searchText ?: @"";
    self.isSearching = (self.searchKeyword.length > 0);
    [self reloadSpecifiers];
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {
    searchBar.text = @"";
    self.searchKeyword = @"";
    self.isSearching = NO;
    [self reloadSpecifiers];
    [searchBar resignFirstResponder];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}

#pragma mark - 判断是否为巨魔安装应用
- (BOOL)isSideStoreAppAtPath:(NSString *)bundlePath {
    NSFileManager *fm = [NSFileManager defaultManager];
    
    NSArray *markerFiles = @[
        @"_TrollStore", @"_ESignStore", @"_SignStore",
        @"_SideStore", @"_AltStore", @"_AppSync",
        @".TrollStore", @".ESignStore", @"TrollStore",
        @"_TrollStoreHelper", @"_TrollStoreApp"
    ];
    
    for (NSString *marker in markerFiles) {
        NSString *filePath = [bundlePath stringByAppendingPathComponent:marker];
        if ([fm fileExistsAtPath:filePath]) {
            return YES;
        }
    }
    
    NSString *parentPath = [bundlePath stringByDeletingLastPathComponent];
    for (NSString *marker in markerFiles) {
        NSString *filePath = [parentPath stringByAppendingPathComponent:marker];
        if ([fm fileExistsAtPath:filePath]) {
            return YES;
        }
    }
    
    NSArray *bundleContents = [fm contentsOfDirectoryAtPath:bundlePath error:nil];
    for (NSString *file in bundleContents) {
        if ([file hasPrefix:@"_"] && ([file containsString:@"Store"] || [file containsString:@"store"])) {
            return YES;
        }
        if ([file containsString:@"Troll"] || [file containsString:@"ESign"] || 
            [file containsString:@"SideStore"] || [file containsString:@"AltStore"]) {
            return YES;
        }
    }
    
    return NO;
}

#pragma mark - 应用列表生成
- (NSArray<PSSpecifier *> *)generateAppSpecifiers {
    NSMutableArray *appSpecifiers = [NSMutableArray new];
    NSFileManager *fm = [NSFileManager defaultManager];
    
    NSArray *bundleDirs = @[
        @"/var/containers/Bundle/Application",
        @"/private/var/containers/Bundle/Application",
        @"/var/mobile/Containers/Bundle/Application"
    ];
    
    NSMutableArray *allAppDirs = [NSMutableArray array];
    for (NSString *bundleDir in bundleDirs) {
        NSArray *appDirs = [fm contentsOfDirectoryAtPath:bundleDir error:nil];
        if (appDirs && appDirs.count > 0) {
            [allAppDirs addObjectsFromArray:appDirs];
        }
    }
    
    allAppDirs = [NSMutableArray arrayWithArray:[[NSSet setWithArray:allAppDirs] allObjects]];
    
    for (NSString *uuidDir in allAppDirs) {
        @autoreleasepool {
            NSString *appPath = nil;
            for (NSString *bundleDir in bundleDirs) {
                NSString *testPath = [bundleDir stringByAppendingPathComponent:uuidDir];
                if ([fm fileExistsAtPath:testPath]) {
                    appPath = testPath;
                    break;
                }
            }
            if (!appPath) continue;
            
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:appPath isDirectory:&isDir] || !isDir) continue;
            
            NSArray *contents = [fm contentsOfDirectoryAtPath:appPath error:nil];
            for (NSString *item in contents) {
                if ([item hasSuffix:@".app"]) {
                    NSString *bundlePath = [appPath stringByAppendingPathComponent:item];
                    
                    NSString *infoPath = [bundlePath stringByAppendingPathComponent:@"Info.plist"];
                    NSDictionary *infoPlist = [NSDictionary dictionaryWithContentsOfFile:infoPath];
                    if (!infoPlist) continue;
                    
                    NSString *bundleId = infoPlist[@"CFBundleIdentifier"];
                    if (!bundleId) continue;
                    if ([bundleId hasPrefix:@"com.apple."]) continue;
                    
                    NSString *displayName = infoPlist[@"CFBundleDisplayName"];
                    NSString *bundleName = infoPlist[@"CFBundleName"];
                    NSString *appName = displayName ?: (bundleName ?: bundleId);
                    appName = [appName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                    if (appName.length == 0) appName = bundleId;
                    
                    NSString *shortVersion = infoPlist[@"CFBundleShortVersionString"];
                    NSString *bundleVersion = infoPlist[@"CFBundleVersion"];
                    NSString *version = shortVersion ?: (bundleVersion ?: @"N/A");
                    
                    BOOL isSideApp = [self isSideStoreAppAtPath:bundlePath];
                    
                    NSMutableDictionary *appInfo = [NSMutableDictionary dictionary];
                    appInfo[@"bundleIdentifier"] = bundleId;
                    appInfo[@"localizedName"] = appName;
                    appInfo[@"version"] = version;
                    appInfo[@"bundlePath"] = bundlePath;
                    appInfo[@"containerPath"] = appPath;
                    appInfo[@"bundleURL"] = [NSURL fileURLWithPath:bundlePath];
                    appInfo[@"isSideApp"] = @(isSideApp);
                    
                    PSSpecifier* appSpecifier = [PSSpecifier preferenceSpecifierNamed:appName target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
                    [appSpecifier setProperty:[NSURL fileURLWithPath:bundlePath] forKey:@"bundleURL"];
                    [appSpecifier setProperty:@YES forKey:@"enabled"];
                    appSpecifier.buttonAction = @selector(downloadAppShortcut:);
                    [appSpecifier setProperty:appInfo forKey:@"appInfo"];
                    [appSpecifiers addObject:appSpecifier];
                    
                    break;
                }
            }
        }
    }
    
    [appSpecifiers sortUsingComparator:^NSComparisonResult(PSSpecifier* a, PSSpecifier* b) {
        return [a.name compare:b.name];
    }];
    
    CleanLog(@"生成应用列表完成，共 %lu 个应用", (unsigned long)appSpecifiers.count);
    return [appSpecifiers copy];
}

#pragma mark - 生成分类数组
- (void)buildCategorizedSpecifiers {
    if (self.allAppSpecifiers) return;
    
    NSArray *all = [self generateAppSpecifiers];
    NSMutableArray *user = [NSMutableArray array];
    NSMutableArray *side = [NSMutableArray array];
    
    for (PSSpecifier *spec in all) {
        NSDictionary *appInfo = [spec propertyForKey:@"appInfo"];
        BOOL isSideApp = [appInfo[@"isSideApp"] boolValue];
        if (isSideApp) {
            [side addObject:spec];
        } else {
            [user addObject:spec];
        }
    }
    
    self.allAppSpecifiers = all;
    self.userAppSpecifiers = user;
    self.trollAppSpecifiers = side;
}

#pragma mark - 获取当前显示的应用列表
- (NSArray *)getCurrentDisplaySpecifiers {
    [self buildCategorizedSpecifiers];
    
    NSArray *sourceSpecifiers = nil;
    NSInteger idx = self.segmentControl.selectedSegmentIndex;
    if (idx == 0) {
        sourceSpecifiers = self.allAppSpecifiers;
    } else if (idx == 1) {
        sourceSpecifiers = self.userAppSpecifiers;
    } else {
        sourceSpecifiers = self.trollAppSpecifiers;
    }
    
    if (!sourceSpecifiers) return @[];
    
    if (self.searchKeyword.length > 0) {
        NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(PSSpecifier *spec, NSDictionary *bindings) {
            NSDictionary *appInfo = [spec propertyForKey:@"appInfo"];
            if (!appInfo) return NO;
            NSString *appName = appInfo[@"localizedName"];
            NSString *bundleId = appInfo[@"bundleIdentifier"];
            if (!appName) appName = @"";
            if (!bundleId) bundleId = @"";
            BOOL nameMatch = [appName rangeOfString:self.searchKeyword options:NSCaseInsensitiveSearch|NSDiacriticInsensitiveSearch].location != NSNotFound;
            BOOL idMatch = [bundleId rangeOfString:self.searchKeyword options:NSCaseInsensitiveSearch].location != NSNotFound;
            return nameMatch || idMatch;
        }];
        return [sourceSpecifiers filteredArrayUsingPredicate:predicate];
    }
    
    return sourceSpecifiers;
}

#pragma mark - 构建 specifiers
- (NSMutableArray*)specifiers {
    if(!_specifiers) {
        _specifiers = [NSMutableArray new];
        
        PSSpecifier* downloadGroupSpecifier = [PSSpecifier emptyGroupSpecifier];
        downloadGroupSpecifier.name = @"下载";
        [_specifiers addObject:downloadGroupSpecifier];
        
        PSSpecifier* downloadSpecifier = [PSSpecifier preferenceSpecifierNamed:@"下载" target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
        downloadSpecifier.identifier = @"download";
        [downloadSpecifier setProperty:@YES forKey:@"enabled"];
        downloadSpecifier.buttonAction = @selector(downloadApp);
        [_specifiers addObject:downloadSpecifier];
        
        NSString* aboutText = [self getAboutText];
        [downloadGroupSpecifier setProperty:aboutText forKey:@"footerText"];
        
        PSSpecifier* installedGroupSpecifier = [PSSpecifier emptyGroupSpecifier];
        installedGroupSpecifier.name = @"已安装应用";
        [_specifiers addObject:installedGroupSpecifier];
        
        NSArray *displaySpecifiers = [self getCurrentDisplaySpecifiers];
        if (displaySpecifiers.count > 0) {
            [_specifiers addObjectsFromArray:displaySpecifiers];
        } else {
            PSSpecifier* emptySpecifier = [PSSpecifier preferenceSpecifierNamed:@"正在扫描应用..." target:nil set:nil get:nil detail:nil cell:PSStaticTextCell edit:nil];
            [emptySpecifier setProperty:@YES forKey:@"enabled"];
            [_specifiers addObject:emptySpecifier];
        }
    }
    self.navigationItem.title = @"MuffinStore";
    return _specifiers;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    PSSpecifier *specifier = [self specifierAtIndexPath:indexPath];
    NSDictionary *appInfo = [specifier propertyForKey:@"appInfo"];
    
    if (appInfo && specifier.identifier != nil && ![specifier.identifier isEqualToString:@"download"]) {
        cell.textLabel.text = appInfo[@"localizedName"];
        NSString *version = appInfo[@"version"];
        NSString *bundleId = appInfo[@"bundleIdentifier"];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"v%@ • %@", version, bundleId];
        cell.detailTextLabel.textColor = [UIColor grayColor];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
        
        UIImage *icon = [iconCache objectForKey:bundleId];
        if (!icon) {
            icon = [self loadIconForAppAtPath:appInfo[@"bundlePath"]];
            if (icon) {
                [iconCache setObject:icon forKey:bundleId];
            } else {
                icon = [UIImage imageNamed:@"AppIconPlaceholder"];
            }
        }
        cell.imageView.image = icon;
        cell.imageView.layer.cornerRadius = 8;
        cell.imageView.clipsToBounds = YES;
        
        UIButton *infoButton = [UIButton buttonWithType:UIButtonTypeDetailDisclosure];
        [infoButton addTarget:self action:@selector(showAppDetails:) forControlEvents:UIControlEventTouchUpInside];
        objc_setAssociatedObject(infoButton, "appInfo", appInfo, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        cell.accessoryView = infoButton;
        cell.selectionStyle = UITableViewCellSelectionStyleBlue;
        
        [self addLongPressGestureForCell:cell appInfo:appInfo specifier:specifier];
    } else {
        cell.accessoryView = nil;
        cell.detailTextLabel.text = nil;
        cell.imageView.image = nil;
    }
    return cell;
}

- (void)addLongPressGestureForCell:(UITableViewCell *)cell appInfo:(NSDictionary *)appInfo specifier:(PSSpecifier *)specifier {
    UILongPressGestureRecognizer *existingGesture = objc_getAssociatedObject(cell, "longPressGesture");
    if (existingGesture) {
        [cell removeGestureRecognizer:existingGesture];
    }
    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    longPress.minimumPressDuration = 0.6;
    [cell addGestureRecognizer:longPress];
    objc_setAssociatedObject(cell, "longPressGesture", longPress, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, "appInfo", appInfo, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, "specifier", specifier, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    UITableViewCell *cell = (UITableViewCell *)gesture.view;
    NSDictionary *appInfo = objc_getAssociatedObject(cell, "appInfo");
    if (!appInfo) return;
    
    NSString *bundleId = appInfo[@"bundleIdentifier"];
    NSString *bundlePath = appInfo[@"bundlePath"];
    
    UIAlertController *actionSheet = [UIAlertController alertControllerWithTitle:appInfo[@"localizedName"] message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    
    UIAlertAction *launchAction = [UIAlertAction actionWithTitle:@"启动" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self launchAppWithBundleId:bundleId];
    }];
    UIAlertAction *appDirAction = [UIAlertAction actionWithTitle:@"应用目录" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        if (bundlePath && [[NSFileManager defaultManager] fileExistsAtPath:bundlePath]) {
            [self openInFilza:[NSURL fileURLWithPath:bundlePath]];
        } else {
            [self showAlert:@"错误" message:[NSString stringWithFormat:@"应用目录不存在:\n%@", bundlePath]];
        }
    }];
    UIAlertAction *dataAction = [UIAlertAction actionWithTitle:@"数据目录" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *dataPath = [self findDataContainerPathForBundleId:bundleId];
        if (dataPath && [[NSFileManager defaultManager] fileExistsAtPath:dataPath]) {
            [self openInFilza:[NSURL fileURLWithPath:dataPath]];
        } else {
            [self showAlert:@"错误" message:@"无法找到数据目录，请确保应用已运行过"];
        }
    }];
    
    NSString *groupPath = [self findFirstAppGroupPathForBundleId:bundleId];
    BOOL hasAppGroup = (groupPath != nil);
    
    [actionSheet addAction:launchAction];
    [actionSheet addAction:appDirAction];
    [actionSheet addAction:dataAction];
    
    if (hasAppGroup) {
        UIAlertAction *appGroupAction = [UIAlertAction actionWithTitle:@"应用组目录" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self openInFilza:[NSURL fileURLWithPath:groupPath]];
        }];
        [actionSheet addAction:appGroupAction];
    }
    
    // 使用 Tweak 方案清理
    UIAlertAction *clearDataAction = [UIAlertAction actionWithTitle:@"完全清理 (Tweak)" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [self cleanTargetAppViaTweak:bundleId appName:appInfo[@"localizedName"]];
    }];
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];
    
    [actionSheet addAction:clearDataAction];
    [actionSheet addAction:cancelAction];
    
    if ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        actionSheet.popoverPresentationController.sourceView = cell;
        actionSheet.popoverPresentationController.sourceRect = cell.bounds;
    }
    [self presentViewController:actionSheet animated:YES completion:nil];
}

#pragma mark - Tweak 清理方法
- (void)cleanTargetAppViaTweak:(NSString *)bundleId appName:(NSString *)appName {
    [self showProgressIndicator];
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // 1. 写入任务文件
        NSDictionary *task = @{
            @"bundleId": bundleId,
            @"appName": appName ?: @"",
            @"timestamp": @([[NSDate date] timeIntervalSince1970])
        };
        
        [task writeToFile:TASK_FILE_PATH atomically:YES];
        
        // 2. 修改任务文件权限
        [self executeShellCommandNoOutput:[NSString stringWithFormat:@"chmod 666 %@", TASK_FILE_PATH]];
        
        // 3. 杀死目标应用
        [self forceKillAppCompletely:bundleId];
        
        // 4. 更新进度
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateProgress:0.5 withStatus:@"正在通过 Tweak 清理..."];
        });
        
        // 5. 打开目标应用，Tweak 会自动执行清理
        LSApplicationWorkspace *workspace = [LSApplicationWorkspace defaultWorkspace];
        [workspace openApplicationWithBundleID:bundleId];
        
        // 6. 等待清理完成
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self hideProgressIndicator];
            [self showAlert:@"✅ 清理完成" message:[NSString stringWithFormat:@"%@ 的数据已被清理，重新打开后即为新机状态", appName]];
        });
    });
}

#pragma mark - 查找路径方法
- (NSString *)findDataContainerPathForBundleId:(NSString *)bundleId {
    NSFileManager *fm = [NSFileManager defaultManager];
    
    NSArray *dataRoots = @[
        @"/var/mobile/Containers/Data/Application",
        @"/private/var/mobile/Containers/Data/Application"
    ];
    
    for (NSString *dataRoot in dataRoots) {
        if (![fm fileExistsAtPath:dataRoot]) continue;
        
        NSArray *subDirs = [fm contentsOfDirectoryAtPath:dataRoot error:nil];
        for (NSString *dir in subDirs) {
            NSString *appDir = [dataRoot stringByAppendingPathComponent:dir];
            NSString *metadataPlist = [appDir stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
            
            if ([fm fileExistsAtPath:metadataPlist]) {
                NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:metadataPlist];
                NSString *mcBundleId = metadata[@"MCMMetadataIdentifier"];
                if ([mcBundleId isEqualToString:bundleId]) {
                    return appDir;
                }
            }
        }
    }
    
    id appProxy = [LSApplicationProxy applicationProxyForIdentifier:bundleId];
    if (appProxy) {
        NSURL *dataURL = [appProxy valueForKey:@"dataContainerURL"];
        if (dataURL && [fm fileExistsAtPath:dataURL.path]) {
            return dataURL.path;
        }
    }
    
    return nil;
}

- (NSString *)findFirstAppGroupPathForBundleId:(NSString *)bundleId {
    NSString *cachedPath = [groupPathCache objectForKey:bundleId];
    if (cachedPath && [[NSFileManager defaultManager] fileExistsAtPath:cachedPath]) {
        return cachedPath;
    }
    
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *appGroupRoots = @[
        @"/var/mobile/Containers/Shared/AppGroup",
        @"/private/var/mobile/Containers/Shared/AppGroup"
    ];
    
    for (NSString *appGroupRoot in appGroupRoots) {
        if (![fm fileExistsAtPath:appGroupRoot]) continue;
        
        NSArray *subDirs = [fm contentsOfDirectoryAtPath:appGroupRoot error:nil];
        for (NSString *dir in subDirs) {
            NSString *groupDir = [appGroupRoot stringByAppendingPathComponent:dir];
            NSString *metadataPath = [groupDir stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
            
            if ([fm fileExistsAtPath:metadataPath]) {
                NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:metadataPath];
                NSString *identifier = metadata[@"MCMMetadataIdentifier"];
                
                if (identifier && [identifier containsString:bundleId]) {
                    [groupPathCache setObject:groupDir forKey:bundleId];
                    return groupDir;
                }
            }
            
            if ([dir containsString:bundleId]) {
                [groupPathCache setObject:groupDir forKey:bundleId];
                return groupDir;
            }
        }
    }
    
    id appProxy = [LSApplicationProxy applicationProxyForIdentifier:bundleId];
    if (appProxy) {
        @try {
            NSArray *groupURLs = [appProxy valueForKey:@"groupContainerURLs"];
            if ([groupURLs isKindOfClass:[NSArray class]] && groupURLs.count > 0) {
                for (NSURL *url in groupURLs) {
                    if ([url isKindOfClass:[NSURL class]] && [fm fileExistsAtPath:url.path]) {
                        [groupPathCache setObject:url.path forKey:bundleId];
                        return url.path;
                    }
                }
            }
        } @catch (NSException *e) {}
    }
    
    return nil;
}

#pragma mark - 辅助功能
- (void)launchAppWithBundleId:(NSString *)bundleId {
    LSApplicationWorkspace *workspace = [LSApplicationWorkspace defaultWorkspace];
    BOOL success = [workspace openApplicationWithBundleID:bundleId];
    if (!success) {
        [self showAlert:@"错误" message:@"无法启动该应用"];
    }
}

- (void)openInFilza:(NSURL *)url {
    if (!url) {
        [self showAlert:@"错误" message:@"无效的 URL"];
        return;
    }
    
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:url.path]) {
        [self showAlert:@"错误" message:[NSString stringWithFormat:@"路径不存在:\n%@", url.path]];
        return;
    }
    
    NSURL *filzaBaseURL = [NSURL URLWithString:@"filza://view"];
    if (![[UIApplication sharedApplication] canOpenURL:filzaBaseURL]) {
        [self showAlert:@"错误" message:@"未安装 Filza 文件管理器"];
        return;
    }
    
    NSURL *finalURL = nil;
    if (@available(iOS 16.0, *)) {
        finalURL = [filzaBaseURL URLByAppendingPathComponent:url.path];
    } else {
        NSString *encodedPath = [url.path stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
        if (encodedPath) {
            finalURL = [NSURL URLWithString:[NSString stringWithFormat:@"filza://view%@", encodedPath]];
        }
    }
    
    if (!finalURL) {
        NSArray *fallbackSchemes = @[@"filza://open?path=", @"filza://"];
        for (NSString *scheme in fallbackSchemes) {
            NSString *fullString = [scheme stringByAppendingString:[url.path stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]] ?: url.path];
            NSURL *fallback = [NSURL URLWithString:fullString];
            if (fallback && [[UIApplication sharedApplication] canOpenURL:fallback]) {
                finalURL = fallback;
                break;
            }
        }
    }
    
    if (finalURL && [[UIApplication sharedApplication] canOpenURL:finalURL]) {
        [[UIApplication sharedApplication] openURL:finalURL options:@{} completionHandler:^(BOOL success) {
            if (!success) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self showFilzaFallbackAlertWithPath:url.path];
                });
            }
        }];
    } else {
        [self showFilzaFallbackAlertWithPath:url.path];
    }
}

- (void)showFilzaFallbackAlertWithPath:(NSString *)path {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"无法自动跳转"
                                                                   message:[NSString stringWithFormat:@"路径:\n%@\n\n已复制到剪贴板，请手动粘贴到 Filza 中打开。", path]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"复制路径" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [[UIPasteboard generalPasteboard] setString:path];
        [self showAlert:@"提示" message:@"路径已复制到剪贴板"];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 进度指示器
- (void)showProgressIndicator {
    if (self.progressOverlay) {
        [self hideProgressIndicator];
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        self.progressOverlay = [[UIView alloc] initWithFrame:[UIScreen mainScreen].bounds];
        self.progressOverlay.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.7];
        self.progressOverlay.alpha = 0.0;
        
        UIView *containerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 240)];
        containerView.center = self.progressOverlay.center;
        containerView.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.95];
        containerView.layer.cornerRadius = 15;
        containerView.layer.masksToBounds = YES;
        
        UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 15, 280, 25)];
        titleLabel.text = @"正在清理数据...";
        titleLabel.textColor = [UIColor whiteColor];
        titleLabel.font = [UIFont boldSystemFontOfSize:16];
        titleLabel.textAlignment = NSTextAlignmentCenter;
        
        self.progressView = [[UIProgressView alloc] initWithFrame:CGRectMake(20, 50, 280, 4)];
        if (@available(iOS 13.0, *)) {
            self.progressView.progressTintColor = [UIColor systemBlueColor];
        } else {
            self.progressView.progressTintColor = [UIColor blueColor];
        }
        self.progressView.trackTintColor = [UIColor colorWithWhite:0.3 alpha:1.0];
        self.progressView.progress = 0.0;
        
        self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 65, 280, 25)];
        self.statusLabel.text = @"正在初始化...";
        self.statusLabel.textColor = [UIColor lightGrayColor];
        self.statusLabel.font = [UIFont systemFontOfSize:14];
        self.statusLabel.textAlignment = NSTextAlignmentCenter;
        
        self.logTextView = [[UITextView alloc] initWithFrame:CGRectMake(10, 100, 300, 120)];
        self.logTextView.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.8];
        self.logTextView.textColor = [UIColor greenColor];
        self.logTextView.font = [UIFont fontWithName:@"Menlo" size:10] ?: [UIFont systemFontOfSize:10];
        self.logTextView.editable = NO;
        self.logTextView.layer.cornerRadius = 5;
        self.logTextView.text = @"";
        
        [containerView addSubview:titleLabel];
        [containerView addSubview:self.progressView];
        [containerView addSubview:self.statusLabel];
        [containerView addSubview:self.logTextView];
        [self.progressOverlay addSubview:containerView];
        
        UIWindow *keyWindow = nil;
        if (@available(iOS 13.0, *)) {
            NSSet *connectedScenes = [UIApplication sharedApplication].connectedScenes;
            for (UIWindowScene *scene in connectedScenes) {
                if (scene.activationState == UISceneActivationStateForegroundActive) {
                    for (UIWindow *window in scene.windows) {
                        if (window.isKeyWindow) {
                            keyWindow = window;
                            break;
                        }
                    }
                }
            }
        }
        if (!keyWindow) {
            keyWindow = [UIApplication sharedApplication].windows.firstObject;
        }
        
        if (keyWindow) {
            [keyWindow addSubview:self.progressOverlay];
            [keyWindow bringSubviewToFront:self.progressOverlay];
            
            [UIView animateWithDuration:0.3 animations:^{
                self.progressOverlay.alpha = 1.0;
            }];
        }
    });
}

- (void)updateProgress:(float)progress withStatus:(NSString *)status {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.progressView) {
            [UIView animateWithDuration:0.2 animations:^{
                self.progressView.progress = progress;
            }];
        }
        if (self.statusLabel && status) {
            self.statusLabel.text = status;
        }
        if (self.logTextView) {
            NSString *timestamp = [self getCurrentTimestamp];
            NSString *newLog = [NSString stringWithFormat:@"[%@] %@\n", timestamp, status];
            self.logTextView.text = [self.logTextView.text stringByAppendingString:newLog];
            
            if (self.logTextView.text.length > 0) {
                NSRange bottom = NSMakeRange(self.logTextView.text.length - 1, 1);
                [self.logTextView scrollRangeToVisible:bottom];
            }
        }
    });
}

- (NSString *)getCurrentTimestamp {
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"HH:mm:ss.SSS";
    return [formatter stringFromDate:[NSDate date]];
}

- (void)hideProgressIndicator {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.progressOverlay) {
            [UIView animateWithDuration:0.3 animations:^{
                self.progressOverlay.alpha = 0.0;
            } completion:^(BOOL finished) {
                [self.progressOverlay removeFromSuperview];
                self.progressOverlay = nil;
                self.progressView = nil;
                self.statusLabel = nil;
                self.logTextView = nil;
            }];
        }
    });
}

#pragma mark - 进程管理
- (void)killAppWithBundleId:(NSString *)bundleId {
    LSApplicationWorkspace *workspace = [LSApplicationWorkspace defaultWorkspace];
    if ([workspace respondsToSelector:@selector(killApplicationWithBundleIdentifier:)]) {
        [workspace performSelector:@selector(killApplicationWithBundleIdentifier:) withObject:bundleId];
    }
}

- (void)forceKillAppWithBundleId:(NSString *)bundleId {
    NSString *executableName = [self getExecutableNameForBundleId:bundleId];
    
    if (executableName) {
        const char *killCmd = [[NSString stringWithFormat:@"killall -9 \"%@\" 2>/dev/null", executableName] UTF8String];
        pid_t pid;
        posix_spawn(&pid, "/bin/sh", NULL, NULL, (char *[]){"/bin/sh", "-c", (char *)killCmd, NULL}, NULL);
        waitpid(pid, NULL, 0);
    }
    
    const char *pkillCmd = [[NSString stringWithFormat:@"pkill -9 -f \"%@\" 2>/dev/null", bundleId] UTF8String];
    pid_t pid2;
    posix_spawn(&pid2, "/bin/sh", NULL, NULL, (char *[]){"/bin/sh", "-c", (char *)pkillCmd, NULL}, NULL);
    waitpid(pid2, NULL, 0);
}

- (void)killProcessByBundleId:(NSString *)bundleId {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t miblen = 4;
    
    size_t size;
    if (sysctl(mib, miblen, NULL, &size, NULL, 0) < 0) {
        return;
    }
    
    struct kinfo_proc *processes = (struct kinfo_proc *)malloc(size);
    if (sysctl(mib, miblen, processes, &size, NULL, 0) < 0) {
        free(processes);
        return;
    }
    
    int count = (int)(size / sizeof(struct kinfo_proc));
    
    for (int i = 0; i < count; i++) {
        pid_t pid = processes[i].kp_proc.p_pid;
        char *procName = processes[i].kp_proc.p_comm;
        
        NSString *procNameStr = [NSString stringWithUTF8String:procName];
        
        if ([procNameStr containsString:bundleId] || 
            [procNameStr containsString:[bundleId componentsSeparatedByString:@"."].lastObject]) {
            kill(pid, SIGKILL);
        }
    }
    
    free(processes);
}

- (NSString *)getExecutableNameForBundleId:(NSString *)bundleId {
    id appProxy = [LSApplicationProxy applicationProxyForIdentifier:bundleId];
    if (appProxy) {
        NSString *executablePath = [appProxy valueForKey:@"canonicalExecutablePath"];
        if (executablePath) {
            return [executablePath lastPathComponent];
        }
        
        NSURL *bundleURL = [appProxy valueForKey:@"bundleURL"];
        if (bundleURL) {
            NSString *infoPath = [bundleURL.path stringByAppendingPathComponent:@"Info.plist"];
            NSDictionary *infoPlist = [NSDictionary dictionaryWithContentsOfFile:infoPath];
            return infoPlist[@"CFBundleExecutable"];
        }
    }
    return nil;
}

- (void)forceKillAppCompletely:(NSString *)bundleId {
    CleanLog(@"========== 开始强制杀死应用 ==========");
    CleanLog(@"目标 Bundle ID: %@", bundleId);
    
    BOOL isRunning = [self isAppRunning:bundleId];
    CleanLog(@"应用运行状态: %@", isRunning ? @"运行中" : @"未运行");
    
    if (!isRunning) {
        CleanLog(@"应用未运行，跳过杀死进程步骤");
        CleanLog(@"========== 杀死应用完成 ==========");
        return;
    }
    
    [self killAppWithBundleId:bundleId];
    [NSThread sleepForTimeInterval:0.3];
    
    [self killProcessByBundleId:bundleId];
    [NSThread sleepForTimeInterval:0.3];
    
    [self forceKillAppWithBundleId:bundleId];
    [NSThread sleepForTimeInterval:0.5];
    
    isRunning = [self isAppRunning:bundleId];
    if (isRunning) {
        [self sendSIGKILLToAllProcessesWithName:bundleId];
        [NSThread sleepForTimeInterval:0.5];
    }
    
    isRunning = [self isAppRunning:bundleId];
    CleanLog(@"最终运行状态: %@", isRunning ? @"运行中" : @"已终止");
    CleanLog(@"========== 杀死应用完成 ==========");
}

- (void)sendSIGKILLToAllProcessesWithName:(NSString *)name {
    const char *killCmd = [[NSString stringWithFormat:@"ps aux | grep -i '%@' | grep -v grep | awk '{print $2}' | xargs kill -9 2>/dev/null", name] UTF8String];
    pid_t pid;
    posix_spawn(&pid, "/bin/sh", NULL, NULL, (char *[]){"/bin/sh", "-c", (char *)killCmd, NULL}, NULL);
    waitpid(pid, NULL, 0);
}

- (BOOL)isAppRunning:(NSString *)bundleId {
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t miblen = 4;
    
    size_t size;
    if (sysctl(mib, miblen, NULL, &size, NULL, 0) >= 0) {
        struct kinfo_proc *processes = (struct kinfo_proc *)malloc(size);
        if (sysctl(mib, miblen, processes, &size, NULL, 0) >= 0) {
            int count = (int)(size / sizeof(struct kinfo_proc));
            
            for (int i = 0; i < count; i++) {
                char *procName = processes[i].kp_proc.p_comm;
                NSString *procNameStr = [NSString stringWithUTF8String:procName];
                
                if ([procNameStr containsString:bundleId] || 
                    [procNameStr containsString:[bundleId componentsSeparatedByString:@"."].lastObject]) {
                    free(processes);
                    return YES;
                }
            }
        }
        free(processes);
    }
    
    return NO;
}

#pragma mark - 执行 shell 命令
- (NSString *)executeShellCommand:(NSString *)command {
    int pipefd[2];
    if (pipe(pipefd) != 0) {
        return nil;
    }
    
    pid_t pid;
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, pipefd[1], STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&actions, pipefd[0]);
    
    char *argv[] = {"/bin/sh", "-c", (char *)[command UTF8String], NULL};
    int status = posix_spawn(&pid, "/bin/sh", &actions, NULL, argv, NULL);
    posix_spawn_file_actions_destroy(&actions);
    
    if (status != 0) {
        close(pipefd[0]);
        close(pipefd[1]);
        return nil;
    }
    
    close(pipefd[1]);
    
    NSMutableData *data = [NSMutableData data];
    char buffer[4096];
    ssize_t count;
    while ((count = read(pipefd[0], buffer, sizeof(buffer))) > 0) {
        [data appendBytes:buffer length:count];
    }
    close(pipefd[0]);
    
    waitpid(pid, NULL, 0);
    
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

- (int)executeShellCommandNoOutput:(NSString *)command {
    pid_t pid;
    char *argv[] = {"/bin/sh", "-c", (char *)[command UTF8String], NULL};
    int status = posix_spawn(&pid, "/bin/sh", NULL, NULL, argv, NULL);
    if (status != 0) {
        return -1;
    }
    int retStatus;
    waitpid(pid, &retStatus, 0);
    return WEXITSTATUS(retStatus);
}

#pragma mark - 下载功能（使用运行时动态调用，避免链接错误）
- (void)downloadAppWithAppId:(long long)appId versionId:(long long)versionId {
    NSString* adamId = [NSString stringWithFormat:@"%lld", appId];
    NSString* pricingParameters = @"pricingParameter";
    NSString* appExtVrsId = [NSString stringWithFormat:@"%lld", versionId];
    NSString* installed = @"0";
    NSString* offerString = nil;
    if (versionId == 0) {
        offerString = [NSString stringWithFormat:@"productType=C&price=0&salableAdamId=%@&pricingParameters=%@&clientBuyId=1&installed=%@&trolled=1", adamId, pricingParameters, installed];
    } else {
        offerString = [NSString stringWithFormat:@"productType=C&price=0&salableAdamId=%@&pricingParameters=%@&appExtVrsId=%@&clientBuyId=1&installed=%@&trolled=1", adamId, pricingParameters, appExtVrsId, installed];
    }
    
    Class SKUIItemOfferClass = NSClassFromString(@"SKUIItemOffer");
    Class SKUIItemClass = NSClassFromString(@"SKUIItem");
    Class SKUIItemStateCenterClass = NSClassFromString(@"SKUIItemStateCenter");
    Class SKUIClientContextClass = NSClassFromString(@"SKUIClientContext");
    
    if (!SKUIItemOfferClass || !SKUIItemClass || !SKUIItemStateCenterClass || !SKUIClientContextClass) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showAlert:@"错误" message:@"当前系统不支持直接下载，请使用 ID 下载功能"];
        });
        return;
    }
    
    @try {
        NSDictionary* offerDict = @{@"buyParams": offerString};
        NSDictionary* itemDict = @{@"_itemOffer": adamId};
        
        id offer = [[SKUIItemOfferClass alloc] performSelector:@selector(initWithLookupDictionary:) withObject:offerDict];
        id item = [[SKUIItemClass alloc] performSelector:@selector(initWithLookupDictionary:) withObject:itemDict];
        
        [item setValue:offer forKey:@"_itemOffer"];
        [item setValue:@"iosSoftware" forKey:@"_itemKindString"];
        if(versionId != 0) {
            [item setValue:@(versionId) forKey:@"_versionIdentifier"];
        }
        
        id center = [SKUIItemStateCenterClass performSelector:@selector(defaultCenter)];
        NSArray* items = @[item];
        
        SEL newPurchasesSel = NSSelectorFromString(@"_newPurchasesWithItems:");
        SEL performPurchasesSel = NSSelectorFromString(@"_performPurchases:hasBundlePurchase:withClientContext:completionBlock:");
        
        if ([center respondsToSelector:newPurchasesSel] && [center respondsToSelector:performPurchasesSel]) {
            // 使用 performSelector 但忽略警告
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id purchases = [center performSelector:newPurchasesSel withObject:items];
            id context = [SKUIClientContextClass performSelector:@selector(defaultContext)];
            [center performSelector:performPurchasesSel withObject:purchases withObject:@0 withObject:context withObject:^(id arg1){}];
            #pragma clang diagnostic pop
        } else {
            [self showAlert:@"错误" message:@"StoreKit 接口不可用"];
        }
    } @catch (NSException *exception) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showAlert:@"下载错误" message:exception.reason];
        });
    }
}

#pragma mark - 其他功能（保持原有）
- (void)showAppDetails:(UIButton *)sender {
    NSDictionary *appInfo = objc_getAssociatedObject(sender, "appInfo");
    if (!appInfo) return;
    
    NSString *bundlePath = appInfo[@"bundlePath"];
    NSString *containerPath = appInfo[@"containerPath"];
    NSString *bundleId = appInfo[@"bundleIdentifier"];
    NSString *version = appInfo[@"version"];
    
    NSString *metadataPath1 = [containerPath stringByAppendingPathComponent:@"iTunesMetadata.plist"];
    NSString *metadataPath2 = [bundlePath stringByAppendingPathComponent:@"iTunesMetadata.plist"];
    
    NSString *metadataPath = nil;
    if ([[NSFileManager defaultManager] fileExistsAtPath:metadataPath1]) {
        metadataPath = metadataPath1;
    } else if ([[NSFileManager defaultManager] fileExistsAtPath:metadataPath2]) {
        metadataPath = metadataPath2;
    }
    
    NSString *appleID = @"未知";
    NSString *artist = @"未知";
    NSString *purchaseDate = @"未知";
    NSString *appIdStr = @"未知";
    
    if (metadataPath) {
        NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:metadataPath];
        if (metadata) {
            artist = metadata[@"artistName"] ?: @"未知";
            NSDictionary *downloadInfo = metadata[@"com.apple.iTunesStore.downloadInfo"];
            if (downloadInfo && [downloadInfo isKindOfClass:[NSDictionary class]]) {
                NSDictionary *accountInfoDict = downloadInfo[@"accountInfo"];
                if (accountInfoDict && [accountInfoDict isKindOfClass:[NSDictionary class]]) {
                    appleID = accountInfoDict[@"AppleID"] ?: @"未知";
                }
                purchaseDate = downloadInfo[@"purchaseDate"] ?: @"未知";
                if (downloadInfo[@"itemId"]) {
                    appIdStr = [downloadInfo[@"itemId"] stringValue];
                }
            }
            if ([appleID isEqualToString:@"未知"]) appleID = metadata[@"AppleID"] ?: @"未知";
            if ([purchaseDate isEqualToString:@"未知"]) purchaseDate = metadata[@"purchaseDate"] ?: @"未知";
            if ([appIdStr isEqualToString:@"未知"]) {
                if (metadata[@"itemId"]) {
                    appIdStr = [metadata[@"itemId"] stringValue];
                } else if (metadata[@"appleId"]) {
                    appIdStr = [metadata[@"appleId"] stringValue];
                } else if (metadata[@"adamId"]) {
                    appIdStr = [metadata[@"adamId"] stringValue];
                }
            }
        }
    }
    
    NSString *accountInfoStr = [NSString stringWithFormat:@"App ID: %@\nApple ID: %@\n开发者: %@\n购买日期: %@", appIdStr, appleID, artist, purchaseDate];
    NSString *message = [NSString stringWithFormat:@"路径: %@\n\nBundle ID: %@\n版本: %@\n\n%@", bundlePath, bundleId, version, accountInfoStr];
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"应用详情" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (UIImage *)loadIconForAppAtPath:(NSString *)bundlePath {
    NSString *infoPath = [bundlePath stringByAppendingPathComponent:@"Info.plist"];
    NSDictionary *infoPlist = [NSDictionary dictionaryWithContentsOfFile:infoPath];
    if (!infoPlist) return nil;
    
    NSArray *iconFiles = nil;
    NSDictionary *bundleIcons = infoPlist[@"CFBundleIcons"];
    if (bundleIcons) {
        NSDictionary *primaryIcon = bundleIcons[@"CFBundlePrimaryIcon"];
        iconFiles = primaryIcon[@"CFBundleIconFiles"];
    }
    if (!iconFiles.count) {
        iconFiles = infoPlist[@"CFBundleIconFiles"];
    }
    if (!iconFiles.count) {
        NSArray *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:bundlePath error:nil];
        for (NSString *file in contents) {
            if ([file containsString:@"AppIcon"] && [file hasSuffix:@".png"]) {
                iconFiles = @[file];
                break;
            }
        }
    }
    
    if (iconFiles.count) {
        NSString *iconName = [iconFiles lastObject];
        if (![iconName containsString:@".png"]) {
            iconName = [iconName stringByAppendingString:@".png"];
        }
        NSString *iconPath = [bundlePath stringByAppendingPathComponent:iconName];
        UIImage *icon = [UIImage imageWithContentsOfFile:iconPath];
        if (icon) {
            CGSize newSize = CGSizeMake(30, 30);
            UIGraphicsBeginImageContextWithOptions(newSize, NO, 0.0);
            [icon drawInRect:CGRectMake(0, 0, newSize.width, newSize.height)];
            UIImage *scaledIcon = UIGraphicsGetImageFromCurrentImageContext();
            UIGraphicsEndImageContext();
            return scaledIcon;
        }
    }
    return nil;
}

#pragma mark - 左上角按钮
- (void)promptForAppIdDownload {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"输入软件ID" message:@"请输入App的Apple ID (trackId)" preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"例如: 310633997";
        textField.keyboardType = UIKeyboardTypeNumberPad;
    }];
    UIAlertAction *confirmAction = [UIAlertAction actionWithTitle:@"查询版本" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *appIdStr = alert.textFields.firstObject.text;
        if (appIdStr.length > 0) {
            long long appId = [appIdStr longLongValue];
            [self getAllAppVersionIdsAndPrompt:appId];
        } else {
            [self showAlert:@"错误" message:@"软件ID不能为空"];
        }
    }];
    [alert addAction:confirmAction];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)downloadAppShortcut:(PSSpecifier*)specifier {
    NSURL* bundleURL = [specifier propertyForKey:@"bundleURL"];
    NSDictionary* infoPlist = [NSDictionary dictionaryWithContentsOfFile:[bundleURL.path stringByAppendingPathComponent:@"Info.plist"]];
    NSString* bundleId = infoPlist[@"CFBundleIdentifier"];
    
    NSURL* url = [NSURL URLWithString:[NSString stringWithFormat:@"https://itunes.apple.com/lookup?bundleId=%@&limit=1&media=software", bundleId]];
    NSURLRequest* request = [NSURLRequest requestWithURL:url];
    NSURLSessionDataTask* task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
        if(error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showAlert:@"错误" message:error.localizedDescription];
            });
            return;
        }
        NSError* jsonError = nil;
        NSDictionary* json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if(jsonError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showAlert:@"JSON解析错误" message:jsonError.localizedDescription];
            });
            return;
        }
        NSArray* results = json[@"results"];
        if(results.count == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSDictionary *appInfo = [specifier propertyForKey:@"appInfo"];
                NSString *bundlePath = appInfo[@"bundlePath"];
                NSString *containerPath = [bundlePath stringByDeletingLastPathComponent];
                
                NSString *metadataPath1 = [containerPath stringByAppendingPathComponent:@"iTunesMetadata.plist"];
                NSString *metadataPath2 = [bundlePath stringByAppendingPathComponent:@"iTunesMetadata.plist"];
                
                NSString *metadataPath = nil;
                if ([[NSFileManager defaultManager] fileExistsAtPath:metadataPath1]) {
                    metadataPath = metadataPath1;
                } else if ([[NSFileManager defaultManager] fileExistsAtPath:metadataPath2]) {
                    metadataPath = metadataPath2;
                }
                
                long long appId = 0;
                if (metadataPath) {
                    NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:metadataPath];
                    if (metadata) {
                        NSDictionary *downloadInfo = metadata[@"com.apple.iTunesStore.downloadInfo"];
                        if (downloadInfo && downloadInfo[@"itemId"]) {
                            appId = [downloadInfo[@"itemId"] longLongValue];
                        } else if (metadata[@"itemId"]) {
                            appId = [metadata[@"itemId"] longLongValue];
                        } else if (metadata[@"appleId"]) {
                            appId = [metadata[@"appleId"] longLongValue];
                        } else if (metadata[@"adamId"]) {
                            appId = [metadata[@"adamId"] longLongValue];
                        }
                    }
                }
                
                if (appId != 0) {
                    [self getAllAppVersionIdsFromServer:appId];
                } else {
                    [self promptForAppIdAndVersionIdManually];
                }
            });
            return;
        }
        NSDictionary* app = results[0];
        long long trackId = [app[@"trackId"] longLongValue];
        [self getAllAppVersionIdsAndPrompt:trackId];
    }];
    [task resume];
}

- (void)promptForAppIdAndVersionIdManually {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"手动输入" message:@"请输入 App ID (trackId) 和版本 ID (external_identifier)" preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = @"App ID (例如 310633997)";
        textField.keyboardType = UIKeyboardTypeNumberPad;
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = @"版本 ID (留空则下载最新版)";
        textField.keyboardType = UIKeyboardTypeNumberPad;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"下载" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSString *appIdStr = alert.textFields[0].text;
        NSString *versionIdStr = alert.textFields[1].text;
        long long appId = [appIdStr longLongValue];
        long long versionId = [versionIdStr longLongValue];
        if (appId == 0) {
            [self showAlert:@"错误" message:@"App ID 不能为空"];
            return;
        }
        [self downloadAppWithAppId:appId versionId:versionId];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)getAllAppVersionIdsFromServer:(long long)appId {
    NSString* serverURL = @"https://apis.bilin.eu.org/history/";
    NSURL* url = [NSURL URLWithString:[NSString stringWithFormat:@"%@%lld", serverURL, appId]];
    NSURLRequest* request = [NSURLRequest requestWithURL:url];
    NSURLSessionDataTask* task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
        if(error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showAlert:@"错误" message:error.localizedDescription];
            });
            return;
        }
        NSError* jsonError = nil;
        NSDictionary* json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if(jsonError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showAlert:@"JSON解析错误" message:jsonError.debugDescription];
            });
            return;
        }
        NSArray* versionIds = json[@"data"];
        if(versionIds.count == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showAlert:@"错误" message:@"没有获取到版本ID，可能是内部错误"];
            });
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController* versionAlert = [UIAlertController alertControllerWithTitle:@"版本ID" message:@"请选择要下载的应用版本ID" preferredStyle:UIAlertControllerStyleActionSheet];
            for(NSDictionary* versionId in versionIds) {
                UIAlertAction* versionAction = [UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@", versionId[@"bundle_version"]] style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
                    [self downloadAppWithAppId:appId versionId:[versionId[@"external_identifier"] longLongValue]];
                }];
                [versionAlert addAction:versionAction];
            }
            UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];
            [versionAlert addAction:cancelAction];
            if ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad) {
                versionAlert.popoverPresentationController.sourceView = self.view;
                versionAlert.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 0, 0);
            }
            [self presentViewController:versionAlert animated:YES completion:nil];
        });
    }];
    [task resume];
}

- (void)promptForVersionId:(long long)appId {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController* versionAlert = [UIAlertController alertControllerWithTitle:@"版本ID" message:@"请输入要下载的应用版本ID" preferredStyle:UIAlertControllerStyleAlert];
        [versionAlert addTextFieldWithConfigurationHandler:^(UITextField* textField) {
            textField.placeholder = @"版本ID";
        }];
        UIAlertAction* downloadAction = [UIAlertAction actionWithTitle:@"下载" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
            long long versionId = [versionAlert.textFields.firstObject.text longLongValue];
            [self downloadAppWithAppId:appId versionId:versionId];
        }];
        [versionAlert addAction:downloadAction];
        [versionAlert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:versionAlert animated:YES completion:nil];
    });
}

- (void)getAllAppVersionIdsAndPrompt:(long long)appId {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController* promptAlert = [UIAlertController alertControllerWithTitle:@"版本ID" message:@"您想手动输入版本ID还是从服务器获取版本列表？" preferredStyle:UIAlertControllerStyleAlert];
        [promptAlert addAction:[UIAlertAction actionWithTitle:@"手动" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
            [self promptForVersionId:appId];
        }]];
        [promptAlert addAction:[UIAlertAction actionWithTitle:@"服务器" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
            [self getAllAppVersionIdsFromServer:appId];
        }]];
        [promptAlert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:promptAlert animated:YES completion:nil];
    });
}

- (void)downloadAppWithLink:(NSString*)link {
    NSString* targetAppIdParsed = nil;
    if([link containsString:@"id"]) {
        NSArray* components = [link componentsSeparatedByString:@"id"];
        if(components.count < 2) {
            [self showAlert:@"错误" message:@"无效链接"];
            return;
        }
        NSArray* idComponents = [components[1] componentsSeparatedByString:@"?"];
        targetAppIdParsed = idComponents[0];
    } else {
        [self showAlert:@"错误" message:@"无效链接"];
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [self getAllAppVersionIdsAndPrompt:[targetAppIdParsed longLongValue]];
    });
}

- (void)downloadApp {
    UIAlertController* linkAlert = [UIAlertController alertControllerWithTitle:@"应用链接" message:@"请输入要下载的应用链接" preferredStyle:UIAlertControllerStyleAlert];
    [linkAlert addTextFieldWithConfigurationHandler:^(UITextField* textField) {
        textField.placeholder = @"应用链接";
    }];
    [linkAlert addAction:[UIAlertAction actionWithTitle:@"下载" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
        [self downloadAppWithLink:linkAlert.textFields.firstObject.text];
    }]];
    [linkAlert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:linkAlert animated:YES completion:nil];
}

- (NSString*)getAboutText {
    return @"MuffinStore v11.0 (Tweak 清理版)\n作者 Mineek,Mr.Eric\n长按应用选择「完全清理 (Tweak)」\n通过注入 Tweak 彻底清理 Keychain 和沙盒数据\nhttps://github.com/mineek/MuffinStore";
}

- (void)showAlert:(NSString*)title message:(NSString*)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    });
}

@end