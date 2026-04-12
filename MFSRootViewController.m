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
    
    // 左上角按钮：直接输入 App ID 下载
    UIBarButtonItem *inputIDButton = [[UIBarButtonItem alloc] initWithTitle:@"Input ID"
                                                                      style:UIBarButtonItemStylePlain
                                                                     target:self
                                                                     action:@selector(inputIDButtonTapped)];
    self.navigationItem.leftBarButtonItem = inputIDButton;
    
    // 右上角按钮：刷新列表
    UIBarButtonItem *refreshButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                                                   target:self
                                                                                   action:@selector(refreshButtonTapped)];
    self.navigationItem.rightBarButtonItem = refreshButton;
}

- (void)loadView {
    [super loadView];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadSpecifiers) name:UIApplicationWillEnterForegroundNotification object:nil];
}

#pragma mark - 获取已安装应用（多重后备方案）
- (NSArray<LSApplicationProxy *> *)getAllInstalledApps {
    LSApplicationWorkspace *workspace = [LSApplicationWorkspace defaultWorkspace];
    NSArray *apps = nil;
    
    // 方案1: allInstalledApplications (最常用)
    if ([workspace respondsToSelector:@selector(allInstalledApplications)]) {
        apps = [workspace performSelector:@selector(allInstalledApplications)];
        if (apps.count > 0) return apps;
    }
    
    // 方案2: installedApplications
    if ([workspace respondsToSelector:@selector(installedApplications)]) {
        apps = [workspace performSelector:@selector(installedApplications)];
        if (apps.count > 0) return apps;
    }
    
    // 方案3: enumerateApplicationsOfType (原方案)
    NSMutableArray *enumApps = [NSMutableArray array];
    [workspace enumerateApplicationsOfType:0 block:^(LSApplicationProxy *app) {
        [enumApps addObject:app];
    }];
    if (enumApps.count > 0) return enumApps;
    
    // 方案4: LSEnumerator
    LSEnumerator *enumerator = [LSEnumerator enumeratorForApplicationProxiesWithOptions:0];
    enumerator.predicate = [NSPredicate predicateWithFormat:@"isPlaceholder = NO AND isInstalled = YES"];
    NSMutableArray *enumApps2 = [NSMutableArray array];
    for (LSApplicationProxy *app in enumerator) {
        [enumApps2 addObject:app];
    }
    return enumApps2;
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
        NSArray *allApps = [self getAllInstalledApps];
        
        for (LSApplicationProxy *appProxy in allApps) {
            // 过滤占位和未安装
            if (appProxy.isPlaceholder || !appProxy.isInstalled) continue;
            // 过滤系统应用（可选）
            NSString *bundleID = appProxy.bundleIdentifier;
            if ([bundleID hasPrefix:@"com.apple."]) continue;
            
            id proxy = (id)appProxy;
            
            // 获取图标 (KVC)
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
            
            // 获取下载账号 Apple ID
            NSString *appleID = @"Unknown";
            @try {
                id aid = [proxy valueForKey:@"installerAppleID"];
                if ([aid isKindOfClass:[NSString class]]) appleID = aid;
            } @catch (NSException *e) {}
            
            NSString *title = [NSString stringWithFormat:@"%@ (%@)", appProxy.localizedName ?: bundleID, version];
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
        
        [appSpecifiers sortUsingComparator:^NSComparisonResult(PSSpecifier *a, PSSpecifier *b) {
            return [a.name compare:b.name];
        }];
        [_specifiers addObjectsFromArray:appSpecifiers];
        
        // 如果仍无应用，显示提示
        if (appSpecifiers.count == 0) {
            PSSpecifier *noAppSpec = [PSSpecifier preferenceSpecifierNamed:@"No apps found"
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
    [alert addAction:[UIAlertAction actionWithTitle:@"Download" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
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

#pragma mark - 原有下载功能（未改动，仅保留）
- (void)downloadAppShortcut:(PSSpecifier*)specifier {
    NSURL *bundleURL = [specifier propertyForKey:@"bundleURL"];
    NSDictionary *infoPlist = [NSDictionary dictionaryWithContentsOfFile:[bundleURL.path stringByAppendingPathComponent:@"Info.plist"]];
    NSString *bundleId = infoPlist[@"CFBundleIdentifier"];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://itunes.apple.com/lookup?bundleId=%@&limit=1&media=software", bundleId]];
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:[NSURLRequest requestWithURL:url] completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self showAlert:@"Error" message:error.localizedDescription]; });
            return;
        }
        NSError *jsonError = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (jsonError) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self showAlert:@"JSON Error" message:jsonError.localizedDescription]; });
            return;
        }
        NSArray *results = json[@"results"];
        if (results.count == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self showAlert:@"Error" message:@"No results"]; });
            return;
        }
        NSDictionary *app = results[0];
        [self getAllAppVersionIdsAndPrompt:[app[@"trackId"] longLongValue]];
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

- (void)getAllAppVersionIdsFromServer:(long long)appId {
    NSString *serverURL = @"https://apis.bilin.eu.org/history/";
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"%@%lld", serverURL, appId]];
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:[NSURLRequest requestWithURL:url] completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self showAlert:@"Error" message:error.localizedDescription]; });
            return;
        }
        NSError *jsonError = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if (jsonError) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self showAlert:@"JSON Error" message:jsonError.debugDescription]; });
            return;
        }
        NSArray *versionIds = json[@"data"];
        if (versionIds.count == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self showAlert:@"Error" message:@"No version IDs"]; });
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *versionAlert = [UIAlertController alertControllerWithTitle:@"Version ID" message:@"Select the version" preferredStyle:UIAlertControllerStyleActionSheet];
            for (NSDictionary *versionId in versionIds) {
                UIAlertAction *versionAction = [UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@", versionId[@"bundle_version"]] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                    [self downloadAppWithAppId:appId versionId:[versionId[@"external_identifier"] longLongValue]];
                }];
                [versionAlert addAction:versionAction];
            }
            UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
            [versionAlert addAction:cancelAction];
            // iPad 适配
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
        UIAlertController *versionAlert = [UIAlertController alertControllerWithTitle:@"Version ID" message:@"Enter the version ID" preferredStyle:UIAlertControllerStyleAlert];
        [versionAlert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
            textField.placeholder = @"Version ID";
            textField.keyboardType = UIKeyboardTypeNumberPad;
        }];
        UIAlertAction *downloadAction = [UIAlertAction actionWithTitle:@"Download" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            long long versionId = [versionAlert.textFields.firstObject.text longLongValue];
            [self downloadAppWithAppId:appId versionId:versionId];
        }];
        [versionAlert addAction:downloadAction];
        UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
        [versionAlert addAction:cancelAction];
        [self presentViewController:versionAlert animated:YES completion:nil];
    });
}

- (void)getAllAppVersionIdsAndPrompt:(long long)appId {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *promptAlert = [UIAlertController alertControllerWithTitle:@"Version ID" message:@"Manual or Server?" preferredStyle:UIAlertControllerStyleAlert];
        UIAlertAction *manualAction = [UIAlertAction actionWithTitle:@"Manual" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self promptForVersionId:appId];
        }];
        [promptAlert addAction:manualAction];
        UIAlertAction *serverAction = [UIAlertAction actionWithTitle:@"Server" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [self getAllAppVersionIdsFromServer:appId];
        }];
        [promptAlert addAction:serverAction];
        UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
        [promptAlert addAction:cancelAction];
        [self presentViewController:promptAlert animated:YES completion:nil];
    });
}

- (void)downloadAppWithAppId:(long long)appId versionId:(long long)versionId {
    NSString *adamId = [NSString stringWithFormat:@"%lld", appId];
    NSString *pricingParameters = @"pricingParameter";
    NSString *appExtVrsId = [NSString stringWithFormat:@"%lld", versionId];
    NSString *installed = @"0";
    NSString *offerString = nil;
    if (versionId == 0) {
        offerString = [NSString stringWithFormat:@"productType=C&price=0&salableAdamId=%@&pricingParameters=%@&clientBuyId=1&installed=%@&trolled=1", adamId, pricingParameters, installed];
    } else {
        offerString = [NSString stringWithFormat:@"productType=C&price=0&salableAdamId=%@&pricingParameters=%@&appExtVrsId=%@&clientBuyId=1&installed=%@&trolled=1", adamId, pricingParameters, appExtVrsId, installed];
    }
    NSDictionary *offerDict = @{@"buyParams": offerString};
    NSDictionary *itemDict = @{@"_itemOffer": adamId};
    SKUIItemOffer *offer = [[SKUIItemOffer alloc] initWithLookupDictionary:offerDict];
    SKUIItem *item = [[SKUIItem alloc] initWithLookupDictionary:itemDict];
    [item setValue:offer forKey:@"_itemOffer"];
    [item setValue:@"iosSoftware" forKey:@"_itemKindString"];
    if (versionId != 0) {
        [item setValue:@(versionId) forKey:@"_versionIdentifier"];
    }
    SKUIItemStateCenter *center = [SKUIItemStateCenter defaultCenter];
    NSArray *items = @[item];
    dispatch_async(dispatch_get_main_queue(), ^{
        [center _performPurchases:[center _newPurchasesWithItems:items] hasBundlePurchase:0 withClientContext:[SKUIClientContext defaultContext] completionBlock:^(id arg1){}];
    });
}

- (void)downloadAppWithLink:(NSString*)link {
    NSString *targetAppIdParsed = nil;
    if ([link containsString:@"id"]) {
        NSArray *components = [link componentsSeparatedByString:@"id"];
        if (components.count < 2) {
            [self showAlert:@"Error" message:@"Invalid link"];
            return;
        }
        NSArray *idComponents = [components[1] componentsSeparatedByString:@"?"];
        targetAppIdParsed = idComponents[0];
    } else {
        [self showAlert:@"Error" message:@"Invalid link"];
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [self getAllAppVersionIdsAndPrompt:[targetAppIdParsed longLongValue]];
    });
}

- (void)downloadApp {
    UIAlertController *linkAlert = [UIAlertController alertControllerWithTitle:@"App Link" message:@"Enter the link to the app you want to download" preferredStyle:UIAlertControllerStyleAlert];
    [linkAlert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"App Link";
    }];
    UIAlertAction *downloadAction = [UIAlertAction actionWithTitle:@"Download" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self downloadAppWithLink:linkAlert.textFields.firstObject.text];
    }];
    [linkAlert addAction:downloadAction];
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
    [linkAlert addAction:cancelAction];
    [self presentViewController:linkAlert animated:YES completion:nil];
}

@end
