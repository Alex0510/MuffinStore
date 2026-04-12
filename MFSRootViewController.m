#import "MFSRootViewController.h"
#import "CoreServices.h"

// PSSubtitleCell 在 Preferences 框架中的值为 9
#define PSSubtitleCell 9

@interface SKUIItemStateCenter : NSObject
+ (id)defaultCenter;
- (id)_newPurchasesWithItems:(id)items;
- (void)_performPurchases:(id)purchases hasBundlePurchase:(BOOL)purchase withClientContext:(id)context completionBlock:(id /* block */)block;
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

@implementation MFSRootViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    // 左上角：直接输入 App ID 下载
    UIBarButtonItem *inputIDButton = [[UIBarButtonItem alloc] initWithTitle:@"Input ID"
                                                                      style:UIBarButtonItemStylePlain
                                                                     target:self
                                                                     action:@selector(inputIDButtonTapped)];
    self.navigationItem.leftBarButtonItem = inputIDButton;
    
    // 右上角：刷新列表
    UIBarButtonItem *refreshButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                                                   target:self
                                                                                   action:@selector(refreshButtonTapped)];
    self.navigationItem.rightBarButtonItem = refreshButton;
}

- (void)loadView {
    [super loadView];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadSpecifiers) name:UIApplicationWillEnterForegroundNotification object:nil];
}

#pragma mark - 获取已安装应用列表（多种后备方案）

- (NSArray<LSApplicationProxy *> *)getAllInstalledApps {
    LSApplicationWorkspace *workspace = [LSApplicationWorkspace defaultWorkspace];
    NSArray *apps = nil;
    
    // 方案1：allInstalledApplications（最常用）
    if ([workspace respondsToSelector:@selector(allInstalledApplications)]) {
        apps = [workspace performSelector:@selector(allInstalledApplications)];
        if (apps.count > 0) {
            NSLog(@"[MuffinStore] Got %lu apps via allInstalledApplications", (unsigned long)apps.count);
            return apps;
        }
    }
    
    // 方案2：installedApplications
    if ([workspace respondsToSelector:@selector(installedApplications)]) {
        apps = [workspace performSelector:@selector(installedApplications)];
        if (apps.count > 0) {
            NSLog(@"[MuffinStore] Got %lu apps via installedApplications", (unsigned long)apps.count);
            return apps;
        }
    }
    
    // 方案3：enumerateApplicationsOfType:0
    NSMutableArray *enumApps = [NSMutableArray array];
    [workspace enumerateApplicationsOfType:0 block:^(LSApplicationProxy *app) {
        [enumApps addObject:app];
    }];
    if (enumApps.count > 0) {
        NSLog(@"[MuffinStore] Got %lu apps via enumerateApplicationsOfType", (unsigned long)enumApps.count);
        return enumApps;
    }
    
    // 方案4：LSEnumerator
    LSEnumerator *enumerator = [LSEnumerator enumeratorForApplicationProxiesWithOptions:0];
    enumerator.predicate = [NSPredicate predicateWithFormat:@"isPlaceholder = NO AND isInstalled = YES"];
    NSMutableArray *enumApps2 = [NSMutableArray array];
    for (LSApplicationProxy *app in enumerator) {
        [enumApps2 addObject:app];
    }
    if (enumApps2.count > 0) {
        NSLog(@"[MuffinStore] Got %lu apps via LSEnumerator", (unsigned long)enumApps2.count);
        return enumApps2;
    }
    
    NSLog(@"[MuffinStore] Warning: No apps found via any private API");
    return @[];
}

- (NSMutableArray*)specifiers {
    if (!_specifiers) {
        _specifiers = [NSMutableArray new];
        
        // Download 组
        PSSpecifier *downloadGroup = [PSSpecifier emptyGroupSpecifier];
        downloadGroup.name = @"Download";
        [_specifiers addObject:downloadGroup];
        
        PSSpecifier *downloadBtn = [PSSpecifier preferenceSpecifierNamed:@"Download"
                                                                   target:self
                                                                      set:nil
                                                                      get:nil
                                                                   detail:nil
                                                                     cell:PSButtonCell
                                                                     edit:nil];
        downloadBtn.identifier = @"download";
        [downloadBtn setProperty:@YES forKey:@"enabled"];
        downloadBtn.buttonAction = @selector(downloadApp);
        [_specifiers addObject:downloadBtn];
        
        [downloadGroup setProperty:[self getAboutText] forKey:@"footerText"];
        
        // 已安装应用组
        PSSpecifier *installedGroup = [PSSpecifier emptyGroupSpecifier];
        installedGroup.name = @"Installed Apps";
        [_specifiers addObject:installedGroup];
        
        NSMutableArray *appSpecifiers = [NSMutableArray new];
        
        // 获取所有已安装应用
        NSArray *allApps = [self getAllInstalledApps];
        
        for (LSApplicationProxy *appProxy in allApps) {
            // 基础过滤
            if (appProxy.isPlaceholder || !appProxy.isInstalled) continue;
            
            // 可选：只显示用户应用（非系统）
            NSString *appType = appProxy.applicationType;
            if (appType && ![appType isEqualToString:@"User"] && ![appType isEqualToString:@"System"]) {
                // 如果既不是 User 也不是 System，可能是第三方但标记为其他，保留
            }
            // 排除明显的系统应用
            NSString *bundleID = appProxy.bundleIdentifier;
            if ([bundleID hasPrefix:@"com.apple."]) continue;
            
            id proxy = (id)appProxy;
            
            // 获取图标（KVC）
            UIImage *icon = nil;
            @try {
                icon = [proxy valueForKey:@"applicationIcon"];
            } @catch (NSException *e) {}
            
            // 获取版本号
            NSString *version = @"Unknown";
            NSURL *bundleURL = appProxy.bundleURL;
            if (bundleURL) {
                NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[bundleURL.path stringByAppendingPathComponent:@"Info.plist"]];
                if (info) {
                    version = info[@"CFBundleShortVersionString"] ?: info[@"CFBundleVersion"] ?: @"Unknown";
                }
            }
            
            // 获取下载账号的 Apple ID
            NSString *appleID = @"Unknown";
            @try {
                id aid = [proxy valueForKey:@"installerAppleID"];
                if ([aid isKindOfClass:[NSString class]]) appleID = aid;
            } @catch (NSException *e) {}
            
            // 显示名称
            NSString *appName = appProxy.localizedName ?: bundleID;
            NSString *title = [NSString stringWithFormat:@"%@ (%@)", appName, version];
            NSString *subtitle = [NSString stringWithFormat:@"%@ | %@", bundleID, appleID];
            
            PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:title
                                                                target:self
                                                                   set:nil
                                                                   get:nil
                                                                detail:nil
                                                                  cell:PSSubtitleCell
                                                                  edit:nil];
            [spec setProperty:bundleURL forKey:@"bundleURL"];
            [spec setProperty:bundleID forKey:@"bundleID"];
            [spec setProperty:@YES forKey:@"enabled"];
            if (icon) [spec setProperty:icon forKey:@"iconImage"];
            [spec setProperty:subtitle forKey:@"subtitle"];
            spec.buttonAction = @selector(downloadAppShortcut:);
            [appSpecifiers addObject:spec];
        }
        
        // 排序
        [appSpecifiers sortUsingComparator:^NSComparisonResult(PSSpecifier *a, PSSpecifier *b) {
            return [a.name compare:b.name];
        }];
        [_specifiers addObjectsFromArray:appSpecifiers];
        
        // 如果仍然没有应用，添加一个提示
        if (appSpecifiers.count == 0) {
            PSSpecifier *noAppSpec = [PSSpecifier preferenceSpecifierNamed:@"No apps found - check system logs"
                                                                    target:nil
                                                                       set:nil
                                                                       get:nil
                                                                    detail:nil
                                                                      cell:PSStaticTextCell
                                                                      edit:nil];
            [_specifiers addObject:noAppSpec];
        }
    }
    self.navigationItem.title = @"MuffinStore";
    return _specifiers;
}

#pragma mark - 按钮事件

- (void)inputIDButtonTapped {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Enter App ID"
                                                                   message:@"App Store trackId"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"e.g. 123456789";
        tf.keyboardType = UIKeyboardTypeNumberPad;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Download" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        NSString *str = alert.textFields.firstObject.text;
        if (str.length) [self getAllAppVersionIdsAndPrompt:[str longLongValue]];
        else [self showAlert:@"Error" message:@"Invalid ID"];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)refreshButtonTapped {
    _specifiers = nil;
    [self reloadSpecifiers];
}

#pragma mark - 应用快捷下载

- (void)downloadAppShortcut:(PSSpecifier*)specifier {
    NSString *bundleID = [specifier propertyForKey:@"bundleID"];
    if (!bundleID) {
        NSURL *bundleURL = [specifier propertyForKey:@"bundleURL"];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[bundleURL.path stringByAppendingPathComponent:@"Info.plist"]];
        bundleID = info[@"CFBundleIdentifier"];
    }
    if (!bundleID) {
        [self showAlert:@"Error" message:@"Unable to get bundle identifier"];
        return;
    }
    
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://itunes.apple.com/lookup?bundleId=%@&limit=1&media=software", bundleID]];
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:[NSURLRequest requestWithURL:url] completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self showAlert:@"Error" message:error.localizedDescription]; });
            return;
        }
        NSError *jsonErr = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
        if (jsonErr) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self showAlert:@"JSON Error" message:jsonErr.localizedDescription]; });
            return;
        }
        NSArray *results = json[@"results"];
        if (results.count == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self showAlert:@"Error" message:@"No results for this bundle ID"]; });
            return;
        }
        NSNumber *trackId = results[0][@"trackId"];
        if (trackId) {
            [self getAllAppVersionIdsAndPrompt:[trackId longLongValue]];
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{ [self showAlert:@"Error" message:@"trackId not found"]; });
        }
    }];
    [task resume];
}

- (NSString*)getAboutText {
    return @"MuffinStore v1.2\nMade by Mineek\nEnhanced by IPMan\nhttps://github.com/mineek/MuffinStore";
}

- (void)showAlert:(NSString*)title message:(NSString*)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    });
}

#pragma mark - 版本选择与下载

- (void)getAllAppVersionIdsFromServer:(long long)appId {
    NSString *serverURL = @"https://apis.bilin.eu.org/history/";
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@%lld", serverURL, appId]];
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:[NSURLRequest requestWithURL:url] completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self showAlert:@"Error" message:error.localizedDescription]; });
            return;
        }
        NSError *jsonErr = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
        if (jsonErr) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self showAlert:@"JSON Error" message:jsonErr.debugDescription]; });
            return;
        }
        NSArray *versions = json[@"data"];
        if (versions.count == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self showAlert:@"Error" message:@"No version IDs"]; });
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Version ID" message:@"Select version" preferredStyle:UIAlertControllerStyleActionSheet];
            for (NSDictionary *v in versions) {
                NSString *bundleVersion = v[@"bundle_version"] ?: @"Unknown";
                NSNumber *extId = v[@"external_identifier"];
                [alert addAction:[UIAlertAction actionWithTitle:bundleVersion style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                    [self downloadAppWithAppId:appId versionId:[extId longLongValue]];
                }]];
            }
            [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
            if ([UIDevice currentDevice].userInterfaceIdiom == UIUserInterfaceIdiomPad) {
                alert.popoverPresentationController.sourceView = self.view;
                alert.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 0, 0);
            }
            [self presentViewController:alert animated:YES completion:nil];
        });
    }];
    [task resume];
}

- (void)promptForVersionId:(long long)appId {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Version ID" message:@"Enter external_identifier" preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.placeholder = @"Version ID"; tf.keyboardType = UIKeyboardTypeNumberPad; }];
        [alert addAction:[UIAlertAction actionWithTitle:@"Download" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            long long vid = [alert.textFields.firstObject.text longLongValue];
            [self downloadAppWithAppId:appId versionId:vid];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    });
}

- (void)getAllAppVersionIdsAndPrompt:(long long)appId {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Version ID" message:@"Manual or Server?" preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Manual" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [self promptForVersionId:appId];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Server" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [self getAllAppVersionIdsFromServer:appId];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    });
}

- (void)downloadAppWithAppId:(long long)appId versionId:(long long)versionId {
    NSString *adamId = [NSString stringWithFormat:@"%lld", appId];
    NSString *appExtVrsId = [NSString stringWithFormat:@"%lld", versionId];
    NSString *offerString = (versionId == 0) ?
        [NSString stringWithFormat:@"productType=C&price=0&salableAdamId=%@&pricingParameters=pricingParameter&clientBuyId=1&installed=0&trolled=1", adamId] :
        [NSString stringWithFormat:@"productType=C&price=0&salableAdamId=%@&pricingParameters=pricingParameter&appExtVrsId=%@&clientBuyId=1&installed=0&trolled=1", adamId, appExtVrsId];
    
    SKUIItemOffer *offer = [[SKUIItemOffer alloc] initWithLookupDictionary:@{@"buyParams": offerString}];
    SKUIItem *item = [[SKUIItem alloc] initWithLookupDictionary:@{@"_itemOffer": adamId}];
    [item setValue:offer forKey:@"_itemOffer"];
    [item setValue:@"iosSoftware" forKey:@"_itemKindString"];
    if (versionId != 0) {
        [item setValue:@(versionId) forKey:@"_versionIdentifier"];
    }
    
    SKUIItemStateCenter *center = [SKUIItemStateCenter defaultCenter];
    dispatch_async(dispatch_get_main_queue(), ^{
        [center _performPurchases:[center _newPurchasesWithItems:@[item]] hasBundlePurchase:0 withClientContext:[SKUIClientContext defaultContext] completionBlock:^(id arg1){}];
    });
}

- (void)downloadAppWithLink:(NSString*)link {
    NSString *target = nil;
    if ([link containsString:@"id"]) {
        NSArray *parts = [link componentsSeparatedByString:@"id"];
        if (parts.count < 2) {
            [self showAlert:@"Error" message:@"Invalid link"];
            return;
        }
        target = [[parts[1] componentsSeparatedByString:@"?"] firstObject];
    } else {
        [self showAlert:@"Error" message:@"Invalid link"];
        return;
    }
    [self getAllAppVersionIdsAndPrompt:[target longLongValue]];
}

- (void)downloadApp {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"App Link" message:@"Enter App Store link" preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"https://apps.apple.com/...";
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Download" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self downloadAppWithLink:alert.textFields.firstObject.text];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
