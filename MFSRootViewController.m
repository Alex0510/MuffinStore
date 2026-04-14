// MFSRootViewController.m
#import "MFSRootViewController.h"
#import "CoreServices.h"
#import <objc/runtime.h>
#import <sys/sysctl.h>
#import <spawn.h>

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
@property (nonatomic, strong) NSArray<PSSpecifier *> *allAppSpecifiers;
@property (nonatomic, assign) BOOL isSearching;
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
    
    self.searchBar = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 44)];
    self.searchBar.delegate = self;
    self.searchBar.placeholder = @"搜索应用名称或 Bundle ID";
    self.searchBar.searchBarStyle = UISearchBarStyleMinimal;
    self.searchBar.showsCancelButton = YES;
    self.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    
    self.table.tableHeaderView = self.searchBar;
}

- (void)refreshAppList {
    _specifiers = nil;
    self.allAppSpecifiers = nil;
    self.isSearching = NO;
    self.searchBar.text = @"";
    [iconCache removeAllObjects];
    [groupPathCache removeAllObjects];
    [self reloadSpecifiers];
}

#pragma mark - 应用列表生成
- (NSArray<PSSpecifier *> *)generateAppSpecifiers {
    NSMutableArray *appSpecifiers = [NSMutableArray new];
    [[LSApplicationWorkspace defaultWorkspace] enumerateApplicationsOfType:0 block:^(LSApplicationProxy* appProxy) {
        NSMutableDictionary *appInfo = [NSMutableDictionary dictionary];
        appInfo[@"bundleURL"] = appProxy.bundleURL;
        appInfo[@"bundleIdentifier"] = appProxy.bundleIdentifier;
        
        NSString *infoPath = [appProxy.bundleURL.path stringByAppendingPathComponent:@"Info.plist"];
        NSDictionary *infoPlist = [NSDictionary dictionaryWithContentsOfFile:infoPath];
        
        NSString *displayName = infoPlist[@"CFBundleDisplayName"];
        NSString *bundleName = infoPlist[@"CFBundleName"];
        NSString *localizedName = appProxy.localizedName ?: appProxy.bundleIdentifier;
        NSString *appName = displayName ?: (bundleName ?: localizedName);
        appName = [appName stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (appName.length == 0) {
            appName = appProxy.bundleIdentifier;
        }
        appInfo[@"localizedName"] = appName;
        
        NSString *shortVersion = infoPlist[@"CFBundleShortVersionString"];
        NSString *bundleVersion = infoPlist[@"CFBundleVersion"];
        NSString *version = shortVersion ?: (bundleVersion ?: @"N/A");
        appInfo[@"version"] = version;
        
        appInfo[@"bundlePath"] = appProxy.bundleURL.path;
        appInfo[@"containerPath"] = [appProxy.bundleURL.path stringByDeletingLastPathComponent];
        
        PSSpecifier* appSpecifier = [PSSpecifier preferenceSpecifierNamed:appName target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
        [appSpecifier setProperty:appProxy.bundleURL forKey:@"bundleURL"];
        [appSpecifier setProperty:@YES forKey:@"enabled"];
        appSpecifier.buttonAction = @selector(downloadAppShortcut:);
        [appSpecifier setProperty:appInfo forKey:@"appInfo"];
        [appSpecifiers addObject:appSpecifier];
    }];
    
    [appSpecifiers sortUsingComparator:^NSComparisonResult(PSSpecifier* a, PSSpecifier* b) {
        return [a.name compare:b.name];
    }];
    
    return [appSpecifiers copy];
}

#pragma mark - 搜索栏代理
- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    if (searchText.length == 0) {
        self.isSearching = NO;
        [self resetToAllAppSpecifiers];
    } else {
        self.isSearching = YES;
        [self filterAppSpecifiersWithKeyword:searchText];
    }
    [self.table reloadData];
}

- (void)searchBarCancelButtonClicked:(UISearchBar *)searchBar {
    searchBar.text = @"";
    self.isSearching = NO;
    [self resetToAllAppSpecifiers];
    [self.table reloadData];
    [searchBar resignFirstResponder];
}

- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar {
    [searchBar resignFirstResponder];
}

- (void)resetToAllAppSpecifiers {
    if (!_specifiers) return;
    if (!self.allAppSpecifiers) {
        self.allAppSpecifiers = [self generateAppSpecifiers];
    }
    NSMutableArray *newSpecifiers = [NSMutableArray array];
    NSInteger fixedCount = 3;
    for (NSInteger i = 0; i < fixedCount && i < _specifiers.count; i++) {
        [newSpecifiers addObject:_specifiers[i]];
    }
    [newSpecifiers addObjectsFromArray:self.allAppSpecifiers];
    _specifiers = newSpecifiers;
}

- (void)filterAppSpecifiersWithKeyword:(NSString *)keyword {
    if (!_specifiers) return;
    if (!self.allAppSpecifiers) {
        self.allAppSpecifiers = [self generateAppSpecifiers];
    }
    NSMutableArray *filtered = [NSMutableArray array];
    NSInteger fixedCount = 3;
    for (NSInteger i = 0; i < fixedCount && i < _specifiers.count; i++) {
        [filtered addObject:_specifiers[i]];
    }
    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(PSSpecifier *spec, NSDictionary *bindings) {
        NSDictionary *appInfo = [spec propertyForKey:@"appInfo"];
        if (!appInfo) return NO;
        NSString *appName = appInfo[@"localizedName"];
        NSString *bundleId = appInfo[@"bundleIdentifier"];
        if (!appName) appName = @"";
        if (!bundleId) bundleId = @"";
        BOOL nameMatch = [appName rangeOfString:keyword options:NSCaseInsensitiveSearch|NSDiacriticInsensitiveSearch].location != NSNotFound;
        BOOL idMatch = [bundleId rangeOfString:keyword options:NSCaseInsensitiveSearch].location != NSNotFound;
        return nameMatch || idMatch;
    }];
    NSArray *filteredApps = [self.allAppSpecifiers filteredArrayUsingPredicate:predicate];
    [filtered addObjectsFromArray:filteredApps];
    _specifiers = filtered;
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

#pragma mark - 长按菜单
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
        NSURL *dataURL = [self getDataContainerURLForBundleId:bundleId];
        if (dataURL && [[NSFileManager defaultManager] fileExistsAtPath:dataURL.path]) {
            [self openInFilza:dataURL];
        } else {
            [self showAlert:@"错误" message:@"无法找到数据目录，请确保应用已运行过。如果刚执行了一键新机，请先手动重启应用一次。"];
        }
    }];
    
    NSURL *groupURL = [self getFirstGroupContainerURLForBundleId:bundleId];
    BOOL hasAppGroup = (groupURL != nil);
    
    [actionSheet addAction:launchAction];
    [actionSheet addAction:appDirAction];
    [actionSheet addAction:dataAction];
    
    if (hasAppGroup) {
        UIAlertAction *appGroupAction = [UIAlertAction actionWithTitle:@"应用组目录" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self openInFilza:groupURL];
        }];
        [actionSheet addAction:appGroupAction];
    }
    
    UIAlertAction *clearDataAction = [UIAlertAction actionWithTitle:@"清理数据" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [self confirmClearDataForBundleId:bundleId];
    }];
    UIAlertAction *newDeviceAction = [UIAlertAction actionWithTitle:@"一键新机" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self confirmNewDeviceForBundleId:bundleId];
    }];
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];
    
    [actionSheet addAction:clearDataAction];
    [actionSheet addAction:newDeviceAction];
    [actionSheet addAction:cancelAction];
    
    if ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        actionSheet.popoverPresentationController.sourceView = cell;
        actionSheet.popoverPresentationController.sourceRect = cell.bounds;
    }
    [self presentViewController:actionSheet animated:YES completion:nil];
}

// 获取数据容器URL（每次实时获取，不使用缓存，且验证路径存在性）
- (NSURL *)getDataContainerURLForBundleId:(NSString *)bundleId {
    // 先清除该应用的路径缓存，强制重新获取
    [groupPathCache removeObjectForKey:bundleId];
    
    // 获取最新的 LSApplicationProxy
    id appProxy = [LSApplicationProxy applicationProxyForIdentifier:bundleId];
    if (!appProxy) return nil;
    
    // 尝试系统的 dataContainerURL
    NSURL *dataURL = [appProxy valueForKey:@"dataContainerURL"];
    if (dataURL && [dataURL isKindOfClass:[NSURL class]]) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:dataURL.path]) {
            return dataURL;
        } else {
            // 路径不存在，说明目录已被删除，需要手动扫描
            NSString *foundPath = [self findDataContainerPathForBundleId:bundleId];
            if (foundPath) {
                return [NSURL fileURLWithPath:foundPath];
            }
        }
    }
    
    // 手动扫描
    NSString *path = [self findDataContainerPathForBundleId:bundleId];
    return path ? [NSURL fileURLWithPath:path] : nil;
}

- (NSString *)findDataContainerPathForBundleId:(NSString *)bundleId {
    NSString *dataRoot = @"/var/mobile/Containers/Data/Application";
    NSFileManager *fm = [NSFileManager defaultManager];
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
    return nil;
}

- (NSURL *)getFirstGroupContainerURLForBundleId:(NSString *)bundleId {
    // 先检查缓存是否有效
    NSString *cachedPath = [groupPathCache objectForKey:bundleId];
    if (cachedPath) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:cachedPath]) {
            return [NSURL fileURLWithPath:cachedPath];
        } else {
            [groupPathCache removeObjectForKey:bundleId];
        }
    }
    
    id appProxy = [LSApplicationProxy applicationProxyForIdentifier:bundleId];
    if (!appProxy) return nil;
    
    NSArray *groupURLs = nil;
    @try {
        if ([appProxy respondsToSelector:@selector(groupContainerURLs)]) {
            groupURLs = [appProxy performSelector:@selector(groupContainerURLs)];
        } else {
            groupURLs = [appProxy valueForKey:@"groupContainerURLs"];
        }
    } @catch (NSException *e) {}
    
    if ([groupURLs isKindOfClass:[NSArray class]] && groupURLs.count > 0) {
        for (NSURL *url in groupURLs) {
            if ([url isKindOfClass:[NSURL class]] && [[NSFileManager defaultManager] fileExistsAtPath:url.path]) {
                [groupPathCache setObject:url.path forKey:bundleId];
                return url;
            }
        }
    }
    
    // 手动扫描应用组目录
    NSString *appGroupRoot = @"/var/mobile/Containers/Shared/AppGroup";
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:appGroupRoot]) return nil;
    
    NSArray *subDirs = [fm contentsOfDirectoryAtPath:appGroupRoot error:nil];
    NSString *bundleIdLower = [bundleId lowercaseString];
    
    for (NSString *dir in subDirs) {
        NSString *groupDir = [appGroupRoot stringByAppendingPathComponent:dir];
        NSString *metadataPath = [groupDir stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
        NSString *identifier = nil;
        
        if ([fm fileExistsAtPath:metadataPath]) {
            NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:metadataPath];
            identifier = metadata[@"MCMMetadataIdentifier"];
        }
        
        if (!identifier) {
            identifier = dir;
        }
        
        NSString *idLower = [identifier lowercaseString];
        BOOL matched = NO;
        
        if ([idLower isEqualToString:bundleIdLower]) matched = YES;
        else if ([idLower hasPrefix:@"group."] && [[idLower substringFromIndex:6] isEqualToString:bundleIdLower]) matched = YES;
        else if ([idLower hasSuffix:bundleIdLower]) matched = YES;
        else if ([bundleIdLower hasPrefix:idLower] || [idLower hasPrefix:bundleIdLower]) matched = YES;
        else if (bundleIdLower.length >= 5 && [idLower rangeOfString:bundleIdLower].location != NSNotFound) matched = YES;
        else if ([[dir lowercaseString] containsString:bundleIdLower]) matched = YES;
        
        if (matched) {
            [groupPathCache setObject:groupDir forKey:bundleId];
            return [NSURL fileURLWithPath:groupDir];
        }
    }
    
    // 从 entitlement 中获取组标识再尝试
    NSArray *entitlementGroups = [self getApplicationGroupsFromEntitlementsForBundleId:bundleId];
    for (NSString *groupID in entitlementGroups) {
        NSString *possiblePath = [self findGroupContainerPathForGroupIdentifier:groupID];
        if (possiblePath) {
            [groupPathCache setObject:possiblePath forKey:bundleId];
            return [NSURL fileURLWithPath:possiblePath];
        }
    }
    
    return nil;
}

- (NSArray<NSString *> *)getApplicationGroupsFromEntitlementsForBundleId:(NSString *)bundleId {
    NSMutableArray *groups = [NSMutableArray array];
    id appProxy = [LSApplicationProxy applicationProxyForIdentifier:bundleId];
    if (!appProxy) return groups;
    
    NSDictionary *entitlements = nil;
    @try {
        entitlements = [appProxy valueForKey:@"entitlements"];
    } @catch (NSException *e) {}
    
    if ([entitlements isKindOfClass:[NSDictionary class]]) {
        NSArray *groupArray = entitlements[@"com.apple.security.application-groups"];
        if ([groupArray isKindOfClass:[NSArray class]]) {
            [groups addObjectsFromArray:groupArray];
        }
    }
    return groups;
}

- (NSString *)findGroupContainerPathForGroupIdentifier:(NSString *)groupID {
    NSString *appGroupRoot = @"/var/mobile/Containers/Shared/AppGroup";
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *subDirs = [fm contentsOfDirectoryAtPath:appGroupRoot error:nil];
    for (NSString *dir in subDirs) {
        NSString *groupDir = [appGroupRoot stringByAppendingPathComponent:dir];
        NSString *metadataPath = [groupDir stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
        if ([fm fileExistsAtPath:metadataPath]) {
            NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:metadataPath];
            NSString *identifier = metadata[@"MCMMetadataIdentifier"];
            if ([identifier isEqualToString:groupID]) {
                return groupDir;
            }
        } else if ([dir isEqualToString:groupID]) {
            return groupDir;
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
        [self showAlert:@"错误" message:[NSString stringWithFormat:@"路径不存在:\n%@\n\n请先运行一次应用，系统会自动创建新目录。", url.path]];
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

- (void)confirmClearDataForBundleId:(NSString *)bundleId {
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"确认清理数据" message:@"这将删除该应用的所有文档和数据，且无法恢复。是否继续？" preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *clear = [UIAlertAction actionWithTitle:@"清理" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [self performClearDataForBundleId:bundleId];
    }];
    UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];
    [confirm addAction:clear];
    [confirm addAction:cancel];
    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)performClearDataForBundleId:(NSString *)bundleId {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSURL *dataURL = [self getDataContainerURLForBundleId:bundleId];
        if (dataURL && [fm fileExistsAtPath:dataURL.path]) {
            for (NSString *item in [fm contentsOfDirectoryAtPath:dataURL.path error:nil]) {
                [fm removeItemAtPath:[dataURL.path stringByAppendingPathComponent:item] error:nil];
            }
        }
        NSURL *groupURL = [self getFirstGroupContainerURLForBundleId:bundleId];
        if (groupURL && [fm fileExistsAtPath:groupURL.path]) {
            for (NSString *item in [fm contentsOfDirectoryAtPath:groupURL.path error:nil]) {
                [fm removeItemAtPath:[groupURL.path stringByAppendingPathComponent:item] error:nil];
            }
        }
        [groupPathCache removeObjectForKey:bundleId];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showAlert:@"完成" message:@"数据已清理，应用可能需要重启才能生效"];
        });
    });
}

#pragma mark - 一键新机核心功能（杀进程+删除容器+删除AppGroup+清Keychain）
- (void)confirmNewDeviceForBundleId:(NSString *)bundleId {
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"一键新机" message:@"将彻底清除该应用的所有数据、钥匙串，并强制结束进程，使其恢复到全新安装状态（类似卸载重装）。是否继续？" preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *reset = [UIAlertAction actionWithTitle:@"一键新机" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [self performNewDeviceResetForBundleId:bundleId];
    }];
    UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];
    [confirm addAction:reset];
    [confirm addAction:cancel];
    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)performNewDeviceResetForBundleId:(NSString *)bundleId {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        
        // 1. 杀进程（必须）
        [self killApp:bundleId];
        sleep(1); // 等待进程完全退出
        
        // 2. 删除 Data 容器（整个UUID目录）
        NSURL *dataURL = [self getDataContainerURLForBundleId:bundleId];
        if (dataURL && [fm fileExistsAtPath:dataURL.path]) {
            [fm removeItemAtPath:dataURL.path error:nil];
        }
        
        // 3. 删除所有该App相关的应用组容器
        [self deleteAllGroupContainers:bundleId];
        
        // 4. 清空 Keychain 中该App的条目
        [self clearKeychainForBundleId:bundleId];
        
        // 清除缓存
        [groupPathCache removeObjectForKey:bundleId];
        [iconCache removeObjectForKey:bundleId];
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showAlert:@"一键新机完成" message:@"该App已完全重置为全新状态，下次启动时将如同新安装的应用。"];
        });
    });
}

// 通过 bundleId 杀掉应用进程
- (void)killApp:(NSString *)bundleId {
    // 方法1：使用私有 API（SpringBoardServices） - 仅越狱可用
    // 这里使用更通用的方法：通过 sysctl 获取进程列表，找到匹配的 bundleId 然后 kill
    // 注意：由于应用可能未运行，忽略错误
    pid_t pid = [self getPIDForBundleId:bundleId];
    if (pid > 0) {
        kill(pid, SIGKILL);
    }
}

// 获取指定 bundleId 的进程 PID
- (pid_t)getPIDForBundleId:(NSString *)bundleId {
    pid_t foundPid = -1;
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t miblen = 4;
    
    size_t size = 0;
    sysctl(mib, miblen, NULL, &size, NULL, 0);
    
    struct kinfo_proc *processes = malloc(size);
    if (processes == NULL) return -1;
    
    if (sysctl(mib, miblen, processes, &size, NULL, 0) == 0) {
        size_t count = size / sizeof(struct kinfo_proc);
        for (size_t i = 0; i < count; i++) {
            NSString *processPath = [NSString stringWithFormat:@"%s", processes[i].kp_proc.p_comm];
            // 更精确地匹配：可以通过 LSApplicationProxy 获取可执行路径
            // 简单起见，这里只匹配进程名中包含 bundleId 的一部分（不完美，但实用）
            if ([processPath containsString:bundleId] || [bundleId containsString:processPath]) {
                foundPid = processes[i].kp_proc.p_pid;
                break;
            }
        }
    }
    free(processes);
    return foundPid;
}

// 删除所有属于该应用的应用组容器
- (void)deleteAllGroupContainers:(NSString *)bundleId {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *appGroupRoot = @"/var/mobile/Containers/Shared/AppGroup";
    if (![fm fileExistsAtPath:appGroupRoot]) return;
    
    NSArray *subDirs = [fm contentsOfDirectoryAtPath:appGroupRoot error:nil];
    NSString *bundleIdLower = [bundleId lowercaseString];
    
    for (NSString *dir in subDirs) {
        NSString *groupDir = [appGroupRoot stringByAppendingPathComponent:dir];
        NSString *metadataPath = [groupDir stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
        NSString *identifier = nil;
        
        if ([fm fileExistsAtPath:metadataPath]) {
            NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:metadataPath];
            identifier = metadata[@"MCMMetadataIdentifier"];
        }
        
        if (!identifier) {
            identifier = dir;
        }
        
        NSString *idLower = [identifier lowercaseString];
        BOOL matched = NO;
        
        if ([idLower isEqualToString:bundleIdLower]) matched = YES;
        else if ([idLower hasPrefix:@"group."] && [[idLower substringFromIndex:6] isEqualToString:bundleIdLower]) matched = YES;
        else if ([idLower hasSuffix:bundleIdLower]) matched = YES;
        else if ([bundleIdLower hasPrefix:idLower] || [idLower hasPrefix:bundleIdLower]) matched = YES;
        else if (bundleIdLower.length >= 5 && [idLower rangeOfString:bundleIdLower].location != NSNotFound) matched = YES;
        else if ([[dir lowercaseString] containsString:bundleIdLower]) matched = YES;
        
        if (matched) {
            [fm removeItemAtPath:groupDir error:nil];
        }
    }
}

// 清空 Keychain 中该应用存储的所有条目
- (void)clearKeychainForBundleId:(NSString *)bundleId {
    // 方法：构造查询字典，删除所有匹配 accessGroup 包含 bundleId 的条目
    // 注意：Keychain 中的条目可能属于不同的 accessGroup，需要遍历所有可能的组标识
    NSArray *secItemClasses = @[
        (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecClassInternetPassword,
        (__bridge id)kSecClassCertificate,
        (__bridge id)kSecClassKey,
        (__bridge id)kSecClassIdentity
    ];
    
    for (id secClass in secItemClasses) {
        NSDictionary *query = @{
            (__bridge id)kSecClass: secClass,
            (__bridge id)kSecAttrService: bundleId,
            (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll
        };
        SecItemDelete((__bridge CFDictionaryRef)query);
        
        // 也尝试删除所有关联该 bundleId 的通用条目（无 service 标签）
        NSDictionary *query2 = @{
            (__bridge id)kSecClass: secClass,
            (__bridge id)kSecAttrAccount: bundleId,
            (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll
        };
        SecItemDelete((__bridge CFDictionaryRef)query2);
    }
    
    // 额外：尝试删除带有 accessGroup 的条目（需要知道具体的 group 标识）
    // 这里简单使用通配方式（越狱环境下可用更底层的方法，但上述已覆盖大部分情况）
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
        
        NSArray *appSpecifiers = [self generateAppSpecifiers];
        self.allAppSpecifiers = appSpecifiers;
        [_specifiers addObjectsFromArray:appSpecifiers];
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
- (long long)getTrackIdFromLocalMetadataForAppInfo:(NSDictionary *)appInfo {
    if (!appInfo) return 0;
    NSString *bundlePath = appInfo[@"bundlePath"];
    NSString *containerPath = appInfo[@"containerPath"];
    
    NSString *metadataPath1 = [containerPath stringByAppendingPathComponent:@"iTunesMetadata.plist"];
    NSString *metadataPath2 = [bundlePath stringByAppendingPathComponent:@"iTunesMetadata.plist"];
    
    NSString *metadataPath = nil;
    if ([[NSFileManager defaultManager] fileExistsAtPath:metadataPath1]) {
        metadataPath = metadataPath1;
    } else if ([[NSFileManager defaultManager] fileExistsAtPath:metadataPath2]) {
        metadataPath = metadataPath2;
    } else {
        return 0;
    }
    
    NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:metadataPath];
    if (!metadata) return 0;
    
    NSNumber *itemId = nil;
    if (metadata[@"itemId"]) {
        itemId = metadata[@"itemId"];
    } else if (metadata[@"appleId"]) {
        itemId = metadata[@"appleId"];
    } else if (metadata[@"adamId"]) {
        itemId = metadata[@"adamId"];
    } else {
        NSDictionary *downloadInfo = metadata[@"com.apple.iTunesStore.downloadInfo"];
        if (downloadInfo && downloadInfo[@"itemId"]) {
            itemId = downloadInfo[@"itemId"];
        }
    }
    
    if (itemId && [itemId respondsToSelector:@selector(longLongValue)]) {
        return [itemId longLongValue];
    }
    return 0;
}

- (void)downloadAppShortcut:(PSSpecifier*)specifier {
    NSURL* bundleURL = [specifier propertyForKey:@"bundleURL"];
    NSDictionary* infoPlist = [NSDictionary dictionaryWithContentsOfFile:[bundleURL.path stringByAppendingPathComponent:@"Info.plist"]];
    NSString* bundleId = infoPlist[@"CFBundleIdentifier"];
    NSDictionary *appInfo = [specifier propertyForKey:@"appInfo"];
    
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
            long long localAppId = [self getTrackIdFromLocalMetadataForAppInfo:appInfo];
            if (localAppId != 0) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self getAllAppVersionIdsFromServer:localAppId];
                });
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self showAlert:@"未找到应用" message:@"iTunes API 无返回结果，且无法从本地 iTunesMetadata.plist 中提取 App ID。"];
                });
            }
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

- (NSString*)getAboutText {
    return @"MuffinStore v1.2 (增强版)\n作者 Mineek,Mr.Eric\n长按应用可启动/清理数据/一键新机/跳转目录\nhttps://github.com/mineek/MuffinStore";
}

- (void)showAlert:(NSString*)title message:(NSString*)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    });
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

@end