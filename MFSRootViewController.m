// MFSRootViewController.m
#import "MFSRootViewController.h"
#import "CoreServices.h"
#import <objc/runtime.h>

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

@implementation MFSRootViewController

+ (void)initialize {
    if (self == [MFSRootViewController class]) {
        iconCache = [[NSCache alloc] init];
    }
}

- (void)loadView {
    [super loadView];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadSpecifiers) name:UIApplicationWillEnterForegroundNotification object:nil];
    
    // 右上角刷新按钮
    UIBarButtonItem *refreshButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(refreshAppList)];
    self.navigationItem.rightBarButtonItem = refreshButton;
    
    // 左上角：直接输入软件ID下载按钮
    UIBarButtonItem *idDownloadButton = [[UIBarButtonItem alloc] initWithTitle:@"ID下载" style:UIBarButtonItemStylePlain target:self action:@selector(promptForAppIdDownload)];
    self.navigationItem.leftBarButtonItem = idDownloadButton;
}

#pragma mark - 左上角按钮：直接输入软件ID查询版本并下载
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

#pragma mark - 长按菜单（启动、数据目录、应用组目录、清理数据、在 Filza 中显示）
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
    PSSpecifier *specifier = objc_getAssociatedObject(cell, "specifier");
    if (!appInfo) return;
    
    NSString *bundleId = appInfo[@"bundleIdentifier"];
    NSString *bundlePath = appInfo[@"bundlePath"];
    id appProxy = [LSApplicationProxy applicationProxyForIdentifier:bundleId];
    
    UIAlertController *actionSheet = [UIAlertController alertControllerWithTitle:appInfo[@"localizedName"] message:@"选择操作" preferredStyle:UIAlertControllerStyleActionSheet];
    
    // 启动应用
    UIAlertAction *launchAction = [UIAlertAction actionWithTitle:@"启动" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self launchAppWithBundleId:bundleId];
    }];
    // 数据目录（具体应用的数据目录）
    UIAlertAction *dataAction = [UIAlertAction actionWithTitle:@"数据目录" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *dataPath = nil;
        NSURL *dataContainerURL = [appProxy valueForKey:@"dataContainerURL"];
        if (dataContainerURL && [dataContainerURL isKindOfClass:[NSURL class]]) {
            dataPath = [(NSURL *)dataContainerURL path];
        }
        if (!dataPath || ![[NSFileManager defaultManager] fileExistsAtPath:dataPath]) {
            dataPath = [self findDataContainerPathForBundleId:bundleId];
        }
        if (dataPath && [[NSFileManager defaultManager] fileExistsAtPath:dataPath]) {
            [self openInFilza:dataPath];
        } else {
            [self showAlert:@"错误" message:@"无法找到数据目录，请确保应用已运行过"];
        }
    }];
    // 应用组目录（固定根目录）
    UIAlertAction *appGroupAction = [UIAlertAction actionWithTitle:@"应用组目录" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self openInFilza:@"/var/mobile/Containers/Shared/AppGroup"];
    }];
    // 清理数据
    UIAlertAction *clearDataAction = [UIAlertAction actionWithTitle:@"清理数据" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [self confirmClearDataForAppProxy:appProxy bundleId:bundleId];
    }];
    // 在 Filza 中显示（应用目录 /var/containers/Bundle/Application/...）
    UIAlertAction *showInFilzaAction = [UIAlertAction actionWithTitle:@"应用目录" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        if (bundlePath && [[NSFileManager defaultManager] fileExistsAtPath:bundlePath]) {
            [self openInFilza:bundlePath];
        } else {
            [self showAlert:@"错误" message:@"应用目录不存在"];
        }
    }];
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];
    
    [actionSheet addAction:launchAction];
    [actionSheet addAction:dataAction];
    [actionSheet addAction:appGroupAction];
    [actionSheet addAction:clearDataAction];
    [actionSheet addAction:showInFilzaAction];
    [actionSheet addAction:cancelAction];
    
    if ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        actionSheet.popoverPresentationController.sourceView = cell;
        actionSheet.popoverPresentationController.sourceRect = cell.bounds;
    }
    [self presentViewController:actionSheet animated:YES completion:nil];
}

// 查找数据容器路径
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

#pragma mark - 辅助功能
- (void)launchAppWithBundleId:(NSString *)bundleId {
    LSApplicationWorkspace *workspace = [LSApplicationWorkspace defaultWorkspace];
    BOOL success = [workspace openApplicationWithBundleID:bundleId];
    if (!success) {
        [self showAlert:@"错误" message:@"无法启动该应用"];
    }
}

// 修复 Filza 跳转：使用 filza:/// 绝对路径格式
- (void)openInFilza:(NSString *)path {
    if (!path || path.length == 0) {
        [self showAlert:@"错误" message:@"路径无效"];
        return;
    }
    // 确保路径存在
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [self showAlert:@"错误" message:[NSString stringWithFormat:@"路径不存在:\n%@", path]];
        return;
    }
    // Filza URL Scheme: filza:///absolute/path （三个斜杠）
    // 需要确保 path 以 / 开头，然后整体编码
    NSString *encodedPath = [path stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
    NSString *urlString = [NSString stringWithFormat:@"filza://%@", encodedPath];
    NSURL *url = [NSURL URLWithString:urlString];
    if ([[UIApplication sharedApplication] canOpenURL:url]) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:^(BOOL success) {
            if (!success) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self showAlert:@"错误" message:@"无法打开Filza，请确保已安装最新版Filza"];
                });
            }
        }];
    } else {
        [self showAlert:@"错误" message:@"未安装Filza文件管理器，请先安装Filza"];
    }
}

// 确认清理数据
- (void)confirmClearDataForAppProxy:(id)appProxy bundleId:(NSString *)bundleId {
    UIAlertController *confirm = [UIAlertController alertControllerWithTitle:@"确认清理数据" message:@"这将删除该应用的所有文档和数据，且无法恢复。是否继续？" preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *clear = [UIAlertAction actionWithTitle:@"清理" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [self performClearDataForAppProxy:appProxy bundleId:bundleId];
    }];
    UIAlertAction *cancel = [UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil];
    [confirm addAction:clear];
    [confirm addAction:cancel];
    [self presentViewController:confirm animated:YES completion:nil];
}

- (void)performClearDataForAppProxy:(id)appProxy bundleId:(NSString *)bundleId {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        // 数据目录
        NSString *dataPath = nil;
        NSURL *dataContainerURL = [appProxy valueForKey:@"dataContainerURL"];
        if (dataContainerURL && [dataContainerURL isKindOfClass:[NSURL class]]) {
            dataPath = [(NSURL *)dataContainerURL path];
        }
        if (!dataPath || ![fm fileExistsAtPath:dataPath]) {
            dataPath = [self findDataContainerPathForBundleId:bundleId];
        }
        if (dataPath && [fm fileExistsAtPath:dataPath]) {
            for (NSString *item in [fm contentsOfDirectoryAtPath:dataPath error:nil]) {
                NSString *fullPath = [dataPath stringByAppendingPathComponent:item];
                [fm removeItemAtPath:fullPath error:nil];
            }
        }
        // 应用组目录
        NSArray *groupURLs = [(id)appProxy valueForKey:@"groupContainerURLs"];
        if ([groupURLs isKindOfClass:[NSArray class]] && groupURLs.count) {
            for (NSURL *groupURL in groupURLs) {
                if ([groupURL isKindOfClass:[NSURL class]] && [fm fileExistsAtPath:groupURL.path]) {
                    for (NSString *item in [fm contentsOfDirectoryAtPath:groupURL.path error:nil]) {
                        NSString *fullPath = [groupURL.path stringByAppendingPathComponent:item];
                        [fm removeItemAtPath:fullPath error:nil];
                    }
                }
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self showAlert:@"完成" message:@"数据已清理，应用可能需要重启才能生效"];
        });
    });
}

#pragma mark - 原有代码（保持不变）
- (void)refreshAppList {
    _specifiers = nil;
    [iconCache removeAllObjects];
    [self reloadSpecifiers];
}

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
    
    NSString *accountInfoStr;
    if (!fileExists) {
        accountInfoStr = [NSString stringWithFormat:@"未找到 iTunesMetadata.plist\n尝试路径:\n%@\n%@", metadataPath1, metadataPath2];
    } else {
        NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:metadataPath];
        if (metadata) {
            NSString *artist = metadata[@"artistName"] ?: @"未知";
            NSDictionary *downloadInfo = metadata[@"com.apple.iTunesStore.downloadInfo"];
            NSString *appleID = nil;
            NSString *purchaseDate = nil;
            if (downloadInfo && [downloadInfo isKindOfClass:[NSDictionary class]]) {
                NSDictionary *accountInfoDict = downloadInfo[@"accountInfo"];
                if (accountInfoDict && [accountInfoDict isKindOfClass:[NSDictionary class]]) {
                    appleID = accountInfoDict[@"AppleID"];
                }
                purchaseDate = downloadInfo[@"purchaseDate"];
            }
            if (!appleID) appleID = metadata[@"AppleID"];
            if (!purchaseDate) purchaseDate = metadata[@"purchaseDate"];
            if (!appleID) appleID = @"未知";
            if (!purchaseDate) purchaseDate = @"未知";
            accountInfoStr = [NSString stringWithFormat:@"Apple ID: %@\n开发者: %@\n购买日期: %@", appleID, artist, purchaseDate];
        } else {
            accountInfoStr = [NSString stringWithFormat:@"文件存在但无法解析:\n%@", metadataPath];
        }
    }
    
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

#pragma mark - 原有下载功能（完全保留）
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
                [self showAlert:@"错误" message:@"无结果"];
            });
            return;
        }
        NSDictionary* app = results[0];
        [self getAllAppVersionIdsAndPrompt:[app[@"trackId"] longLongValue]];
    }];
    [task resume];
}

- (NSString*)getAboutText {
    return @"MuffinStore v1.2 (增强版)\n作者 Mineek\n长按应用可启动/清理数据/跳转目录\nhttps://github.com/mineek/MuffinStore";
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