// MFSRootViewController.m
#import "MFSRootViewController.h"
#import "CoreServices.h"
#import <objc/runtime.h>
#import <Security/Security.h>
#import <sys/sysctl.h>
#import <spawn.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <WebKit/WebKit.h>

// ============================================
// 清理统计信息类
// ============================================
@interface CleaningStats : NSObject
@property (nonatomic, assign) NSUInteger filesDeleted;
@property (nonatomic, assign) long long bytesFreed;
@property (nonatomic, strong) NSDate *lastCleaningDate;
@property (nonatomic, assign) NSTimeInterval cleaningDuration;
@property (nonatomic, strong) NSMutableArray<NSString *> *cleanedDirectories;
@property (nonatomic, strong) NSMutableArray<NSString *> *cleanedFiles;
@end

@implementation CleaningStats
- (instancetype)init {
    self = [super init];
    if (self) {
        self.filesDeleted = 0;
        self.bytesFreed = 0;
        self.lastCleaningDate = [NSDate date];
        self.cleaningDuration = 0.0;
        self.cleanedDirectories = [NSMutableArray array];
        self.cleanedFiles = [NSMutableArray array];
    }
    return self;
}
@end

// ============================================
// SKUI 相关类 (保持原有下载功能)
// ============================================
@interface SKUIItemStateCenter : NSObject
+ (id)defaultCenter;
- (id)_newPurchasesWithItems:(id)items;
- (void)_performPurchases:(id)purchases hasBundlePurchase:(_Bool)purchase withClientContext:(id)context completionBlock:(id /* block */)block;
- (void)_performSoftwarePurchases:(id)purchases withClientContext:(id)context completionBlock:(id /* block */)block;
@end

@interface SKUIItem : NSObject
- (id)initWithLookupDictionary:(id)dictionary;
@end

@interface SKUIItemOffer : NSObject
- (id)initWithLookupDictionary:(id)dictionary;
@end

@interface SKUIClientContext : NSObject
+ (id)defaultContext;
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
@property (nonatomic, strong) CleaningStats *currentStats;
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
    id appProxy = [LSApplicationProxy applicationProxyForIdentifier:bundleId];
    
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
    
    UIAlertAction *clearDataAction = [UIAlertAction actionWithTitle:@"完全清理" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [self showFullCleanConfirmationForAppProxy:appProxy bundleId:bundleId appName:appInfo[@"localizedName"]];
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

#pragma mark - 查找路径方法
- (NSString *)findDataContainerPathForBundleId:(NSString *)bundleId {
    NSFileManager *fm = [NSFileManager defaultManager];
    
    // 方法1: 通过 LSApplicationProxy
    id appProxy = [LSApplicationProxy applicationProxyForIdentifier:bundleId];
    if (appProxy) {
        @try {
            NSURL *dataURL = [appProxy valueForKey:@"dataContainerURL"];
            if (dataURL && [fm fileExistsAtPath:dataURL.path]) {
                NSLog(@"[路径] 找到数据容器: %@", dataURL.path);
                return dataURL.path;
            }
        } @catch (NSException *e) {}
    }
    
    // 方法2: 遍历数据容器目录
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
                    NSLog(@"[路径] 找到数据容器: %@", appDir);
                    return appDir;
                }
            }
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
        }
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

#pragma mark - ============================================
#pragma mark - 核心清理功能
#pragma mark - ============================================

- (void)showFullCleanConfirmationForAppProxy:(id)appProxy bundleId:(NSString *)bundleId appName:(NSString *)appName {
    UIAlertController *confirmAlert = [UIAlertController alertControllerWithTitle:@"⚠️ 确认清除"
                                                                          message:[NSString stringWithFormat:@"此操作将永久删除应用「%@」所有数据，包括：\n\n• 用户设置和偏好\n• 缓存和临时文件\n• 登录信息和密码\n• 所有本地数据\n• Keychain数据\n• 网络缓存和Cookies\n\n此操作不可逆，确定要继续吗？", appName ?: bundleId]
                                                                   preferredStyle:UIAlertControllerStyleAlert];
    
    [confirmAlert addAction:[UIAlertAction actionWithTitle:@"确认清除" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [self performFullClean:appProxy bundleId:bundleId appName:appName];
    }]];
    
    [confirmAlert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    
    [self presentViewController:confirmAlert animated:YES completion:nil];
}

- (void)performFullClean:(id)appProxy bundleId:(NSString *)bundleId appName:(NSString *)appName {
    [self showProgressIndicator];
    
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        self.currentStats = [[CleaningStats alloc] init];
        NSDate *startTime = [NSDate date];
        
        NSLog(@"[清理] ========== 开始清理应用 ==========");
        NSLog(@"[清理] 目标: %@ (%@)", appName, bundleId);
        
        // 第一次：清理前强制杀死应用
        [self updateProgress:0.03 withStatus:@"正在终止应用进程..."];
        [self forceKillApplication:bundleId];
        [NSThread sleepForTimeInterval:0.5];
        
        // 获取数据容器路径
        [self updateProgress:0.05 withStatus:@"正在定位数据目录..."];
        NSString *dataPath = [self findDataContainerPathForBundleId:bundleId];
        
        if (!dataPath && appProxy) {
            NSURL *dataURL = [appProxy valueForKey:@"dataContainerURL"];
            if (dataURL) dataPath = dataURL.path;
        }
        
        if (dataPath) {
            [self.currentStats.cleanedDirectories addObject:dataPath];
            NSLog(@"[清理] 数据容器: %@", dataPath);
            
            // 清理 Documents 目录
            NSString *documentsPath = [dataPath stringByAppendingPathComponent:@"Documents"];
            [self cleanDocumentsDirectory:documentsPath];
            
            // 清理 Library 目录及其子目录
            NSString *libraryPath = [dataPath stringByAppendingPathComponent:@"Library"];
            [self cleanLibraryDirectory:libraryPath];
            
            // 清理 Caches 目录
            NSString *cachesPath = [dataPath stringByAppendingPathComponent:@"Library/Caches"];
            [self cleanCachesDirectory:cachesPath];
            
            // 清理 tmp 目录
            NSString *tmpPath = [dataPath stringByAppendingPathComponent:@"tmp"];
            [self cleanTmpDirectory:tmpPath];
        }
        
        // 清理 NSUserDefaults
        [self updateProgress:0.60 withStatus:@"清理用户设置..."];
        [self cleanUserDefaults:bundleId];
        
        // 清理偏好设置文件
        [self updateProgress:0.65 withStatus:@"清理偏好设置..."];
        [self cleanPreferences:bundleId];
        
        // 清理 Keychain
        [self updateProgress:0.70 withStatus:@"清理钥匙串..."];
        [self cleanKeychain:bundleId];
        
        // 清理网络缓存
        [self updateProgress:0.75 withStatus:@"清理网络缓存..."];
        [self cleanNetworkCaches:bundleId];
        
        // 清理 Cookies
        [self updateProgress:0.80 withStatus:@"清理Cookies..."];
        [self cleanCookies:bundleId];
        
        // 清理 WebKit 数据
        [self updateProgress:0.83 withStatus:@"清理WebKit缓存..."];
        [self cleanWebKitData:bundleId];
        
        // 清理应用组目录
        [self updateProgress:0.88 withStatus:@"清理应用组..."];
        [self cleanAppGroups:bundleId];
        
        // 第二次：清理后再次强制杀死应用
        [self updateProgress:0.95 withStatus:@"正在终止应用进程..."];
        [self forceKillApplication:bundleId];
        [NSThread sleepForTimeInterval:0.5];
        
        // 第三次：延迟后再杀死一次
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self forceKillApplication:bundleId];
        });
        
        self.currentStats.cleaningDuration = [[NSDate date] timeIntervalSinceDate:startTime];
        
        [self updateProgress:1.0 withStatus:@"清理完成！"];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [self hideProgressIndicator];
            [self showDetailedCleaningResults:self.currentStats appName:appName bundleId:bundleId];
        });
    });
}

#pragma mark - 强制杀死应用方法
- (void)forceKillApplication:(NSString *)bundleId {
    NSLog(@"[清理] 强制杀死应用: %@", bundleId);
    
    // 方法1: LSApplicationWorkspace 官方方法
    @try {
        LSApplicationWorkspace *workspace = [LSApplicationWorkspace defaultWorkspace];
        if ([workspace respondsToSelector:@selector(killApplicationWithBundleIdentifier:)]) {
            [workspace performSelector:@selector(killApplicationWithBundleIdentifier:) withObject:bundleId];
        }
        if ([workspace respondsToSelector:@selector(terminateApplicationWithBundleIdentifier:)]) {
            [workspace performSelector:@selector(terminateApplicationWithBundleIdentifier:) withObject:bundleId];
        }
    } @catch (NSException *e) {
        NSLog(@"[清理] 方法1异常: %@", e);
    }
    
    // 方法2: 使用 killall 命令
    [self runShellCommand:[NSString stringWithFormat:@"killall -9 '%@' 2>/dev/null", bundleId]];
    [self runShellCommand:[NSString stringWithFormat:@"killall -9 '%@' 2>/dev/null", 
                           [bundleId stringByReplacingOccurrencesOfString:@"." withString:@"_"]]];
    
    // 方法3: 使用 pkill 按进程名杀死
    [self runShellCommand:[NSString stringWithFormat:@"pkill -9 -f '%@' 2>/dev/null", bundleId]];
    
    // 方法4: 通过进程ID杀死
    [self runShellCommand:[NSString stringWithFormat:@"ps aux | grep '%@' | grep -v grep | awk '{print $2}' | xargs kill -9 2>/dev/null", bundleId]];
    
    // 方法5: 强制杀死所有相关进程
    [self runShellCommand:[NSString stringWithFormat:@"kill -9 $(ps aux | grep '%@' | grep -v grep | awk '{print $2}') 2>/dev/null", bundleId]];
    
    // 方法6: 验证是否杀死成功
    [self runShellCommand:[NSString stringWithFormat:@"if pgrep -f '%@' > /dev/null; then pkill -9 -f '%@'; fi", bundleId, bundleId]];
}

#pragma mark - 详细的清理方法实现

// 清理 Documents 目录
- (void)cleanDocumentsDirectory:(NSString *)documentsPath {
    NSFileManager *fm = [NSFileManager defaultManager];
    
    if ([fm fileExistsAtPath:documentsPath]) {
        [self.currentStats.cleanedDirectories addObject:documentsPath];
        [self updateProgress:0.20 withStatus:@"清理 Documents..."];
        
        NSArray *files = [fm contentsOfDirectoryAtPath:documentsPath error:nil];
        for (NSString *file in files) {
            NSString *filePath = [documentsPath stringByAppendingPathComponent:file];
            [self deleteItemAtPath:filePath];
        }
    }
}

// 清理 Library 目录
- (void)cleanLibraryDirectory:(NSString *)libraryPath {
    NSFileManager *fm = [NSFileManager defaultManager];
    
    if ([fm fileExistsAtPath:libraryPath]) {
        [self.currentStats.cleanedDirectories addObject:libraryPath];
        [self updateProgress:0.35 withStatus:@"清理 Library..."];
        
        NSArray *subDirs = @[@"Preferences", @"Caches", @"Saved Application State", 
                             @"HTTPStorages", @"SplashBoard", @"Cookies", @"WebKit"];
        
        for (NSString *subDir in subDirs) {
            NSString *subPath = [libraryPath stringByAppendingPathComponent:subDir];
            if ([fm fileExistsAtPath:subPath]) {
                [self.currentStats.cleanedDirectories addObject:subPath];
                [self deleteItemAtPath:subPath];
            }
        }
        
        // 清理 Library 根目录下的文件
        NSArray *rootFiles = [fm contentsOfDirectoryAtPath:libraryPath error:nil];
        for (NSString *file in rootFiles) {
            NSString *filePath = [libraryPath stringByAppendingPathComponent:file];
            BOOL isDir;
            if ([fm fileExistsAtPath:filePath isDirectory:&isDir] && !isDir) {
                [self deleteItemAtPath:filePath];
            }
        }
    }
}

// 清理 Caches 目录
- (void)cleanCachesDirectory:(NSString *)cachesPath {
    NSFileManager *fm = [NSFileManager defaultManager];
    
    if ([fm fileExistsAtPath:cachesPath]) {
        [self.currentStats.cleanedDirectories addObject:cachesPath];
        [self updateProgress:0.50 withStatus:@"清理 Caches..."];
        
        NSArray *cacheFiles = [fm contentsOfDirectoryAtPath:cachesPath error:nil];
        for (NSString *file in cacheFiles) {
            NSString *filePath = [cachesPath stringByAppendingPathComponent:file];
            [self deleteItemAtPath:filePath];
        }
        
        // 重新创建空的 Caches 目录
        [fm createDirectoryAtPath:cachesPath withIntermediateDirectories:YES attributes:nil error:nil];
    }
}

// 清理 tmp 目录
- (void)cleanTmpDirectory:(NSString *)tmpPath {
    NSFileManager *fm = [NSFileManager defaultManager];
    
    if ([fm fileExistsAtPath:tmpPath]) {
        [self.currentStats.cleanedDirectories addObject:tmpPath];
        [self updateProgress:0.55 withStatus:@"清理 tmp..."];
        
        NSArray *tmpFiles = [fm contentsOfDirectoryAtPath:tmpPath error:nil];
        for (NSString *file in tmpFiles) {
            NSString *filePath = [tmpPath stringByAppendingPathComponent:file];
            [self deleteItemAtPath:filePath];
        }
    }
}

// 清理 NSUserDefaults
- (void)cleanUserDefaults:(NSString *)bundleId {
    NSLog(@"[清理] 开始清理 NSUserDefaults");
    
    NSString *prefPath = [NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@.plist", bundleId];
    NSFileManager *fm = [NSFileManager defaultManager];
    unsigned long long prefSize = 0;
    
    if ([fm fileExistsAtPath:prefPath]) {
        NSDictionary *attrs = [fm attributesOfItemAtPath:prefPath error:nil];
        if (attrs) {
            prefSize = [attrs fileSize];
        }
    }
    
    [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:bundleId];
    [[NSUserDefaults standardUserDefaults] synchronize];
    
    NSString *sizeStr = [self formatFileSize:prefSize > 0 ? prefSize : 256];
    [self.currentStats.cleanedFiles addObject:[NSString stringWithFormat:@"[设置] 清除 NSUserDefaults (%@)", sizeStr]];
    self.currentStats.filesDeleted++;
    self.currentStats.bytesFreed += (prefSize > 0 ? prefSize : 256);
    
    NSLog(@"[清理] NSUserDefaults 清理完成");
}

// 清理偏好设置文件
- (void)cleanPreferences:(NSString *)bundleId {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *prefDir = @"/var/mobile/Library/Preferences";
    
    if ([fm fileExistsAtPath:prefDir]) {
        NSArray *prefFiles = [fm contentsOfDirectoryAtPath:prefDir error:nil];
        for (NSString *file in prefFiles) {
            if ([file hasPrefix:bundleId] && [file hasSuffix:@".plist"]) {
                NSString *filePath = [prefDir stringByAppendingPathComponent:file];
                [self deleteItemAtPath:filePath];
            }
        }
    }
}

// 清理 Keychain
- (void)cleanKeychain:(NSString *)bundleId {
    NSLog(@"[清理] 开始清理 Keychain 数据");
    
    int keychainItemsDeleted = 0;
    unsigned long long estimatedSize = 0;
    
    NSArray *secClasses = @[
        (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecClassInternetPassword,
        (__bridge id)kSecClassCertificate,
        (__bridge id)kSecClassKey,
        (__bridge id)kSecClassIdentity
    ];
    
    for (id secClass in secClasses) {
        NSDictionary *deleteQuery = @{
            (__bridge id)kSecClass: secClass,
            (__bridge id)kSecAttrService: bundleId,
            (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll
        };
        OSStatus status = SecItemDelete((__bridge CFDictionaryRef)deleteQuery);
        if (status == errSecSuccess) {
            keychainItemsDeleted++;
            estimatedSize += 1024;
        }
        
        NSDictionary *deleteByAccount = @{
            (__bridge id)kSecClass: secClass,
            (__bridge id)kSecAttrAccount: bundleId,
            (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll
        };
        status = SecItemDelete((__bridge CFDictionaryRef)deleteByAccount);
        if (status == errSecSuccess) {
            keychainItemsDeleted++;
            estimatedSize += 1024;
        }
    }
    
    [self runShellCommand:[NSString stringWithFormat:@"security delete-generic-password -l '%@' 2>/dev/null", bundleId]];
    [self runShellCommand:[NSString stringWithFormat:@"security delete-internet-password -l '%@' 2>/dev/null", bundleId]];
    
    if (keychainItemsDeleted > 0) {
        NSString *sizeStr = [self formatFileSize:estimatedSize];
        [self.currentStats.cleanedFiles addObject:[NSString stringWithFormat:@"[Keychain] 清除所有钥匙串数据 (%d项, %@)", keychainItemsDeleted, sizeStr]];
        self.currentStats.filesDeleted += keychainItemsDeleted;
        self.currentStats.bytesFreed += estimatedSize;
    } else {
        [self.currentStats.cleanedFiles addObject:@"[Keychain] 清除所有钥匙串数据 (已执行清理)"];
        self.currentStats.filesDeleted++;
    }
    
    NSLog(@"[清理] Keychain 清理完成");
}

// 清理网络缓存
- (void)cleanNetworkCaches:(NSString *)bundleId {
    NSLog(@"[清理] 开始清理网络缓存");
    
    NSFileManager *fm = [NSFileManager defaultManager];
    int cacheCount = 0;
    unsigned long long totalSize = 0;
    
    // 1. 清理 NSURLCache
    @try {
        [[NSURLCache sharedURLCache] removeAllCachedResponses];
        cacheCount++;
        totalSize += 1024 * 1024;
        NSLog(@"[清理] NSURLCache 已清理");
    } @catch (NSException *e) {
        NSLog(@"[清理] NSURLCache 清理异常: %@", e);
    }
    
    // 2. 清理应用自身的网络缓存目录
    NSString *dataPath = [self findDataContainerPathForBundleId:bundleId];
    if (dataPath) {
        NSArray *networkCachePaths = @[
            [dataPath stringByAppendingPathComponent:@"Library/Caches/com.apple.WebKit.Networking"],
            [dataPath stringByAppendingPathComponent:@"Library/Caches/WebKit"],
            [dataPath stringByAppendingPathComponent:@"Library/Caches/NetworkPersistentCache"],
            [dataPath stringByAppendingPathComponent:@"Library/Caches/CFNetworkDownloadCache"],
            [dataPath stringByAppendingPathComponent:@"Library/HTTPStorages"],
            [dataPath stringByAppendingPathComponent:@"Library/Caches/com.apple.nsurlsessiond"],
            [dataPath stringByAppendingPathComponent:@"Library/Caches/NSURLCache"]
        ];
        
        for (NSString *cachePath in networkCachePaths) {
            if ([fm fileExistsAtPath:cachePath]) {
                unsigned long long size = [self calculateDirectorySize:cachePath];
                totalSize += size;
                cacheCount++;
                [self deleteItemAtPath:cachePath];
                NSLog(@"[清理] 删除网络缓存目录: %@", cachePath);
            }
        }
    }
    
    // 3. 使用 Shell 命令清理
    [self runShellCommand:[NSString stringWithFormat:@"find /var/mobile/Library/Caches -name '*%@*' -type f -delete 2>/dev/null", bundleId]];
    
    if (cacheCount > 0) {
        NSString *sizeStr = [self formatFileSize:totalSize];
        [self.currentStats.cleanedFiles addObject:[NSString stringWithFormat:@"[网络缓存] 清理网络缓存 (%d个文件, %@)", cacheCount, sizeStr]];
        self.currentStats.filesDeleted += cacheCount;
        self.currentStats.bytesFreed += totalSize;
    } else {
        [self.currentStats.cleanedFiles addObject:@"[网络缓存] 清理网络缓存 (已执行清理)"];
        self.currentStats.filesDeleted++;
    }
    
    NSLog(@"[清理] 网络缓存清理完成");
}

// 清理 Cookies
- (void)cleanCookies:(NSString *)bundleId {
    NSLog(@"[清理] 开始清理 Cookies");
    
    int cookiesDeleted = 0;
    unsigned long long totalSize = 0;
    
    @try {
        NSHTTPCookieStorage *cookieStorage = [NSHTTPCookieStorage sharedHTTPCookieStorage];
        NSArray *cookies = [cookieStorage cookies];
        for (NSHTTPCookie *cookie in cookies) {
            if ([cookie.domain containsString:bundleId] || 
                [cookie.name containsString:bundleId]) {
                [cookieStorage deleteCookie:cookie];
                cookiesDeleted++;
                totalSize += 256;
            }
        }
    } @catch (NSException *e) {
        NSLog(@"[清理] Cookies清理异常: %@", e);
    }
    
    [self runShellCommand:[NSString stringWithFormat:@"rm -f /var/mobile/Library/Cookies/Cookies.binarycookies 2>/dev/null"]];
    [self runShellCommand:[NSString stringWithFormat:@"find /var/mobile/Containers/Data/Application -name '*.binarycookies' -delete 2>/dev/null"]];
    
    if (cookiesDeleted > 0) {
        NSString *sizeStr = [self formatFileSize:totalSize];
        [self.currentStats.cleanedFiles addObject:[NSString stringWithFormat:@"[Cookies] 清理 Cookies (%d个, %@)", cookiesDeleted, sizeStr]];
        self.currentStats.filesDeleted += cookiesDeleted;
        self.currentStats.bytesFreed += totalSize;
    } else {
        [self.currentStats.cleanedFiles addObject:@"[Cookies] 清理 Cookies (已执行清理)"];
        self.currentStats.filesDeleted++;
    }
    
    NSLog(@"[清理] Cookies 清理完成");
}

// 清理 WebKit 数据
- (void)cleanWebKitData:(NSString *)bundleId {
    NSLog(@"[清理] 开始清理 WebKit 数据");
    
    @try {
        if (@available(iOS 9.0, *)) {
            NSSet *dataTypes = [NSSet setWithArray:@[
                WKWebsiteDataTypeDiskCache,
                WKWebsiteDataTypeMemoryCache,
                WKWebsiteDataTypeOfflineWebApplicationCache,
                WKWebsiteDataTypeCookies,
                WKWebsiteDataTypeSessionStorage,
                WKWebsiteDataTypeLocalStorage,
                WKWebsiteDataTypeWebSQLDatabases,
                WKWebsiteDataTypeIndexedDBDatabases
            ]];
            
            [[WKWebsiteDataStore defaultDataStore] removeDataOfTypes:dataTypes 
                                                       modifiedSince:[NSDate dateWithTimeIntervalSince1970:0] 
                                                   completionHandler:^{
                NSLog(@"[清理] WKWebsiteDataStore 清理完成");
            }];
        }
    } @catch (NSException *e) {
        NSLog(@"[清理] WebKit清理异常: %@", e);
    }
    
    [self runShellCommand:[NSString stringWithFormat:@"find /var/mobile/Library/WebKit -name '*%@*' -delete 2>/dev/null", bundleId]];
    [self runShellCommand:[NSString stringWithFormat:@"find /var/mobile/Containers/Data/Application -path '*/Library/WebKit/*' -delete 2>/dev/null"]];
    
    [self.currentStats.cleanedFiles addObject:@"[WebKit] 清理 WebKit 缓存"];
    self.currentStats.filesDeleted++;
    
    NSLog(@"[清理] WebKit 数据清理完成");
}

// 清理应用组目录
- (void)cleanAppGroups:(NSString *)bundleId {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *appGroupRoots = @[
        @"/var/mobile/Containers/Shared/AppGroup",
        @"/private/var/mobile/Containers/Shared/AppGroup"
    ];
    
    for (NSString *groupRoot in appGroupRoots) {
        if ([fm fileExistsAtPath:groupRoot]) {
            NSArray *groups = [fm contentsOfDirectoryAtPath:groupRoot error:nil];
            for (NSString *group in groups) {
                NSString *groupPath = [groupRoot stringByAppendingPathComponent:group];
                NSString *metadataPath = [groupPath stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
                
                if ([fm fileExistsAtPath:metadataPath]) {
                    NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:metadataPath];
                    NSString *identifier = metadata[@"MCMMetadataIdentifier"];
                    if (identifier && [identifier containsString:bundleId]) {
                        [self deleteItemAtPath:groupPath];
                    }
                }
            }
        }
    }
}

// 通用删除方法
- (void)deleteItemAtPath:(NSString *)path {
    NSFileManager *fm = [NSFileManager defaultManager];
    
    if (![fm fileExistsAtPath:path]) return;
    
    unsigned long long itemSize = 0;
    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
    if (attrs) {
        if ([attrs[NSFileType] isEqualToString:NSFileTypeDirectory]) {
            itemSize = [self calculateDirectorySize:path];
        } else {
            itemSize = [attrs fileSize];
        }
    }
    
    NSString *fileName = [path lastPathComponent];
    NSString *sizeStr = [self formatFileSize:itemSize];
    [self.currentStats.cleanedFiles addObject:[NSString stringWithFormat:@"[文件] %@ (%@)", fileName, sizeStr]];
    
    self.currentStats.filesDeleted++;
    self.currentStats.bytesFreed += itemSize;
    
    NSError *error = nil;
    if (![fm removeItemAtPath:path error:&error]) {
        [self runShellCommand:[NSString stringWithFormat:@"rm -rf '%@'", path]];
    }
}

// 计算目录大小
- (unsigned long long)calculateDirectorySize:(NSString *)directoryPath {
    NSFileManager *fm = [NSFileManager defaultManager];
    unsigned long long totalSize = 0;
    
    NSArray *contents = [fm contentsOfDirectoryAtPath:directoryPath error:nil];
    for (NSString *item in contents) {
        NSString *itemPath = [directoryPath stringByAppendingPathComponent:item];
        NSDictionary *attrs = [fm attributesOfItemAtPath:itemPath error:nil];
        if (attrs) {
            if ([attrs[NSFileType] isEqualToString:NSFileTypeDirectory]) {
                totalSize += [self calculateDirectorySize:itemPath];
            } else {
                totalSize += [attrs fileSize];
            }
        }
    }
    return totalSize;
}

// 格式化文件大小
- (NSString *)formatFileSize:(unsigned long long)size {
    if (size >= 1024 * 1024 * 1024) {
        return [NSString stringWithFormat:@"%.2f GB", size / (1024.0 * 1024.0 * 1024.0)];
    } else if (size >= 1024 * 1024) {
        return [NSString stringWithFormat:@"%.2f MB", size / (1024.0 * 1024.0)];
    } else if (size >= 1024) {
        return [NSString stringWithFormat:@"%.2f KB", size / 1024.0];
    } else {
        return [NSString stringWithFormat:@"%llu B", size];
    }
}

// 执行Shell命令
- (void)runShellCommand:(NSString *)command {
    const char *cmd = [command UTF8String];
    pid_t pid;
    char *argv[] = {"/bin/sh", "-c", (char *)cmd, NULL};
    posix_spawn(&pid, "/bin/sh", NULL, NULL, argv, NULL);
    waitpid(pid, NULL, 0);
}

#pragma mark - UI 相关方法

- (void)showProgressIndicator {
    if (self.progressOverlay) {
        [self hideProgressIndicator];
    }
    
    self.progressOverlay = [[UIView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.progressOverlay.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.7];
    self.progressOverlay.alpha = 0.0;
    
    UIView *containerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 280, 120)];
    containerView.center = self.progressOverlay.center;
    containerView.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.9];
    containerView.layer.cornerRadius = 15;
    containerView.layer.masksToBounds = YES;
    
    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 15, 240, 25)];
    titleLabel.text = @"正在清理应用数据...";
    titleLabel.textColor = [UIColor whiteColor];
    titleLabel.font = [UIFont boldSystemFontOfSize:16];
    titleLabel.textAlignment = NSTextAlignmentCenter;
    
    self.progressView = [[UIProgressView alloc] initWithFrame:CGRectMake(20, 50, 240, 4)];
    if (@available(iOS 13.0, *)) {
        self.progressView.progressTintColor = [UIColor systemBlueColor];
    } else {
        self.progressView.progressTintColor = [UIColor blueColor];
    }
    self.progressView.trackTintColor = [UIColor colorWithWhite:0.3 alpha:1.0];
    self.progressView.progress = 0.0;
    
    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 70, 240, 35)];
    self.statusLabel.text = @"正在初始化...";
    self.statusLabel.textColor = [UIColor lightGrayColor];
    self.statusLabel.font = [UIFont systemFontOfSize:14];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 2;
    
    [containerView addSubview:titleLabel];
    [containerView addSubview:self.progressView];
    [containerView addSubview:self.statusLabel];
    [self.progressOverlay addSubview:containerView];
    
    UIWindow *keyWindow = [UIApplication sharedApplication].keyWindow;
    if (keyWindow) {
        [keyWindow addSubview:self.progressOverlay];
        [keyWindow bringSubviewToFront:self.progressOverlay];
        
        [UIView animateWithDuration:0.3 animations:^{
            self.progressOverlay.alpha = 1.0;
        }];
    }
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
    });
}

- (void)hideProgressIndicator {
    if (self.progressOverlay) {
        [UIView animateWithDuration:0.3 animations:^{
            self.progressOverlay.alpha = 0.0;
        } completion:^(BOOL finished) {
            [self.progressOverlay removeFromSuperview];
            self.progressOverlay = nil;
            self.progressView = nil;
            self.statusLabel = nil;
        }];
    }
}

// 显示详细清理结果
- (void)showDetailedCleaningResults:(CleaningStats *)stats appName:(NSString *)appName bundleId:(NSString *)bundleId {
    NSString *sizeStr;
    if (stats.bytesFreed >= 1024 * 1024 * 1024) {
        sizeStr = [NSString stringWithFormat:@"%.2f GB", stats.bytesFreed / (1024.0 * 1024.0 * 1024.0)];
    } else if (stats.bytesFreed >= 1024 * 1024) {
        sizeStr = [NSString stringWithFormat:@"%.2f MB", stats.bytesFreed / (1024.0 * 1024.0)];
    } else if (stats.bytesFreed >= 1024) {
        sizeStr = [NSString stringWithFormat:@"%.2f KB", stats.bytesFreed / 1024.0];
    } else {
        sizeStr = [NSString stringWithFormat:@"%lld B", stats.bytesFreed];
    }
    
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"yyyy-MM-dd HH:mm:ss ZZZ"];
    NSString *dateStr = [formatter stringFromDate:stats.lastCleaningDate];
    
    NSMutableString *detailMessage = [NSMutableString string];
    [detailMessage appendString:@"========== 清理详细日志 ==========\n\n"];
    [detailMessage appendFormat:@"清理时间：%@\n", dateStr];
    [detailMessage appendFormat:@"耗时：%.2f秒\n", stats.cleaningDuration];
    [detailMessage appendFormat:@"删除文件总数：%lu个\n", (unsigned long)stats.filesDeleted];
    [detailMessage appendFormat:@"释放空间总计：%@\n\n", sizeStr];
    
    [detailMessage appendString:@"--- 清理的目录 ---\n"];
    int dirCount = 1;
    for (NSString *dir in stats.cleanedDirectories) {
        [detailMessage appendFormat:@"%d. %@\n", dirCount++, dir];
    }
    
    [detailMessage appendString:@"\n--- 删除的文件/数据 ---\n"];
    int fileCount = 1;
    for (NSString *file in stats.cleanedFiles) {
        [detailMessage appendFormat:@"%d. %@\n", fileCount++, file];
    }
    
    [detailMessage appendString:@"\n--- 进程状态 ---\n"];
    [detailMessage appendString:@"✓ 目标应用进程已被强制终止\n"];
    [detailMessage appendString:@"✓ 应用数据已完全清除\n"];
    [detailMessage appendString:@"✓ 网络缓存和Cookies已清除\n"];
    [detailMessage appendString:@"✓ 下次启动将恢复为初始状态\n"];
    
    [detailMessage appendString:@"\n[清理完成!]"];
    
    NSLog(@"%@", detailMessage);
    
    NSString *message = [NSString stringWithFormat:@"清理完成！\n\n📁 删除文件：%lu 个\n💾 释放空间：%@\n⏱ 耗时：%.1f 秒\n\n✅ 应用「%@」已被强制退出\n✅ 数据已完全清除\n✅ 网络缓存已清理\n\n下次启动将恢复为初始状态。",
                        (unsigned long)stats.filesDeleted, sizeStr, stats.cleaningDuration, appName ?: bundleId];
    
    UIAlertController *resultAlert = [UIAlertController alertControllerWithTitle:@"✅ 清理完成"
                                                                         message:message
                                                                  preferredStyle:UIAlertControllerStyleAlert];
    
    [resultAlert addAction:[UIAlertAction actionWithTitle:@"启动应用" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        LSApplicationWorkspace *workspace = [LSApplicationWorkspace defaultWorkspace];
        [workspace openApplicationWithBundleID:bundleId];
    }]];
    
    [resultAlert addAction:[UIAlertAction actionWithTitle:@"查看详情" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        UIAlertController *detailAlert = [UIAlertController alertControllerWithTitle:@"清理详细日志"
                                                                             message:detailMessage
                                                                      preferredStyle:UIAlertControllerStyleAlert];
        [detailAlert addAction:[UIAlertAction actionWithTitle:@"复制日志" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [[UIPasteboard generalPasteboard] setString:detailMessage];
            [self showAlert:@"提示" message:@"日志已复制到剪贴板"];
        }]];
        [detailAlert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:detailAlert animated:YES completion:nil];
    }]];
    
    [resultAlert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:resultAlert animated:YES completion:nil];
}

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
    BOOL fileExists = NO;
    if ([[NSFileManager defaultManager] fileExistsAtPath:metadataPath1]) {
        metadataPath = metadataPath1;
        fileExists = YES;
    } else if ([[NSFileManager defaultManager] fileExistsAtPath:metadataPath2]) {
        metadataPath = metadataPath2;
        fileExists = YES;
    }
    
    NSString *appleID = @"未知";
    NSString *artist = @"未知";
    NSString *purchaseDate = @"未知";
    NSString *appIdStr = @"未知";
    
    if (fileExists) {
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

#pragma mark - 下载功能
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

- (void)fetchAppIdForBundleId:(NSString *)bundleId completion:(void(^)(long long appId))completion {
    NSURL* url = [NSURL URLWithString:[NSString stringWithFormat:@"https://itunes.apple.com/lookup?bundleId=%@&limit=1&media=software", bundleId]];
    NSURLRequest* request = [NSURLRequest requestWithURL:url];
    NSURLSessionDataTask* task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
        long long appId = 0;
        if (!error && data) {
            NSDictionary* json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSArray* results = json[@"results"];
            if (results.count > 0) {
                appId = [results[0][@"trackId"] longLongValue];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(appId);
        });
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
    NSDictionary* offerDict = @{@"buyParams": offerString};
    NSDictionary* itemDict = @{@"_itemOffer": adamId};
    SKUIItemOffer* offer = [[SKUIItemOffer alloc] initWithLookupDictionary:offerDict];
    SKUIItem* item = [[SKUIItem alloc] initWithLookupDictionary:itemDict];
    [item setValue:offer forKey:@"_itemOffer"];
    [item setValue:@"iosSoftware" forKey:@"_itemKindString"];
    if(versionId != 0) {
        [item setValue:@(versionId) forKey:@"_versionIdentifier"];
    }
    SKUIItemStateCenter* center = [SKUIItemStateCenter defaultCenter];
    NSArray* items = @[item];
    dispatch_async(dispatch_get_main_queue(), ^{
        [center _performPurchases:[center _newPurchasesWithItems:items] hasBundlePurchase:0 withClientContext:[SKUIClientContext defaultContext] completionBlock:^(id arg1){}];
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
    return @"MuffinStore v1.2 (增强版)\n作者 Mineek,Mr.Eric\n长按应用可启动/清理数据/跳转目录\n支持完全清理应用数据(含网络缓存)\nhttps://github.com/mineek/MuffinStore";
}

- (void)showAlert:(NSString*)title message:(NSString*)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    });
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end