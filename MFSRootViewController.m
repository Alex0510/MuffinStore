#import "MFSRootViewController.h"
#import "CoreServices.h"

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

@implementation MFSRootViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    // 左上角按钮：直接输入 App ID 进行下载
    UIBarButtonItem *inputIDButton = [[UIBarButtonItem alloc] initWithTitle:@"Input ID"
                                                                      style:UIBarButtonItemStylePlain
                                                                     target:self
                                                                     action:@selector(inputIDButtonTapped)];
    self.navigationItem.leftBarButtonItem = inputIDButton;
    
    // 右上角按钮：刷新应用列表
    UIBarButtonItem *refreshButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                                                   target:self
                                                                                   action:@selector(refreshButtonTapped)];
    self.navigationItem.rightBarButtonItem = refreshButton;
}

- (void)loadView {
    [super loadView];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadSpecifiers) name:UIApplicationWillEnterForegroundNotification object:nil];
}

- (NSMutableArray*)specifiers {
    if(!_specifiers) {
        _specifiers = [NSMutableArray new];
        
        // Download 组
        PSSpecifier* downloadGroupSpecifier = [PSSpecifier emptyGroupSpecifier];
        downloadGroupSpecifier.name = @"Download";
        [_specifiers addObject:downloadGroupSpecifier];
        
        PSSpecifier* downloadSpecifier = [PSSpecifier preferenceSpecifierNamed:@"Download" target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
        downloadSpecifier.identifier = @"download";
        [downloadSpecifier setProperty:@YES forKey:@"enabled"];
        downloadSpecifier.buttonAction = @selector(downloadApp);
        [_specifiers addObject:downloadSpecifier];
        
        NSString* aboutText = [self getAboutText];
        [downloadGroupSpecifier setProperty:aboutText forKey:@"footerText"];
        
        // 已安装应用组
        PSSpecifier* installedGroupSpecifier = [PSSpecifier emptyGroupSpecifier];
        installedGroupSpecifier.name = @"Installed Apps";
        [_specifiers addObject:installedGroupSpecifier];
        
        NSMutableArray *appSpecifiers = [NSMutableArray new];
        [[LSApplicationWorkspace defaultWorkspace] enumerateApplicationsOfType:0 block:^(LSApplicationProxy* appProxy) {
            // 获取应用图标（私有 API，使用 performSelector 避免编译错误）
            UIImage *iconImage = nil;
            if ([appProxy respondsToSelector:@selector(applicationIcon)]) {
                iconImage = [appProxy performSelector:@selector(applicationIcon)];
            }
            if (!iconImage) {
                iconImage = [UIImage imageNamed:@"AppIconPlaceholder"]; // 占位图，若无则忽略
            }
            
            // 获取版本号
            NSString *version = @"Unknown";
            NSURL *bundleURL = appProxy.bundleURL;
            if (bundleURL) {
                NSString *infoPath = [bundleURL.path stringByAppendingPathComponent:@"Info.plist"];
                NSDictionary *infoPlist = [NSDictionary dictionaryWithContentsOfFile:infoPath];
                if (infoPlist) {
                    version = infoPlist[@"CFBundleShortVersionString"];
                    if (!version) version = infoPlist[@"CFBundleVersion"];
                    if (!version) version = @"Unknown";
                }
            }
            
            // 获取下载账号的 Apple ID（私有属性，通过 KVC 获取）
            NSString *appleID = @"Unknown";
            @try {
                id installerAppleID = [(id)appProxy valueForKey:@"installerAppleID"];
                if (installerAppleID && [installerAppleID isKindOfClass:[NSString class]]) {
                    appleID = installerAppleID;
                }
            } @catch (NSException *exception) {
                // 忽略异常
            }
            
            // 主标题：应用名称 + 版本号
            NSString *title = [NSString stringWithFormat:@"%@ (%@)", appProxy.localizedName, version];
            // 副标题：Bundle ID + Apple ID
            NSString *subtitle = [NSString stringWithFormat:@"%@ | %@", appProxy.bundleIdentifier, appleID];
            
            // 使用 PSLinkCell（枚举值 4）支持图标和副标题，且可执行按钮动作
            PSSpecifier* appSpecifier = [PSSpecifier preferenceSpecifierNamed:title
                                                                        target:self
                                                                           set:nil
                                                                           get:nil
                                                                        detail:nil
                                                                          cell:4  // PSLinkCell
                                                                          edit:nil];
            [appSpecifier setProperty:bundleURL forKey:@"bundleURL"];
            [appSpecifier setProperty:@YES forKey:@"enabled"];
            if (iconImage) {
                [appSpecifier setProperty:iconImage forKey:@"iconImage"];
            }
            [appSpecifier setProperty:subtitle forKey:@"subtitle"]; // 副标题
            appSpecifier.buttonAction = @selector(downloadAppShortcut:);
            [appSpecifiers addObject:appSpecifier];
        }];
        
        // 按应用名称排序
        [appSpecifiers sortUsingComparator:^NSComparisonResult(PSSpecifier* a, PSSpecifier* b) {
            return [a.name compare:b.name];
        }];
        [_specifiers addObjectsFromArray:appSpecifiers];
    }
    self.navigationItem.title = @"MuffinStore";
    return _specifiers;
}

#pragma mark - 按钮动作

- (void)inputIDButtonTapped {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Enter App ID"
                                                                   message:@"Please enter the App Store ID (trackId) of the app you want to download"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"App ID (e.g. 123456789)";
        textField.keyboardType = UIKeyboardTypeNumberPad;
    }];
    UIAlertAction *confirmAction = [UIAlertAction actionWithTitle:@"Download"
                                                            style:UIAlertActionStyleDefault
                                                          handler:^(UIAlertAction *action) {
        NSString *idString = alert.textFields.firstObject.text;
        if (idString.length > 0) {
            long long appId = [idString longLongValue];
            [self getAllAppVersionIdsAndPrompt:appId];
        } else {
            [self showAlert:@"Error" message:@"Invalid App ID"];
        }
    }];
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
    [alert addAction:confirmAction];
    [alert addAction:cancelAction];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)refreshButtonTapped {
    _specifiers = nil;
    [self reloadSpecifiers];
}

#pragma mark - 原有功能（未改动核心逻辑，仅修复编译警告）

- (void)downloadAppShortcut:(PSSpecifier*)specifier {
    NSURL* bundleURL = [specifier propertyForKey:@"bundleURL"];
    NSDictionary* infoPlist = [NSDictionary dictionaryWithContentsOfFile:[bundleURL.path stringByAppendingPathComponent:@"Info.plist"]];
    NSString* bundleId = infoPlist[@"CFBundleIdentifier"];
    NSURL* url = [NSURL URLWithString:[NSString stringWithFormat:@"https://itunes.apple.com/lookup?bundleId=%@&limit=1&media=software", bundleId]];
    NSURLRequest* request = [NSURLRequest requestWithURL:url];
    NSURLSessionDataTask* task = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
        if(error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showAlert:@"Error" message:error.localizedDescription];
            });
            return;
        }
        NSError* jsonError = nil;
        NSDictionary* json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if(jsonError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showAlert:@"JSON Error" message:jsonError.localizedDescription];
            });
            return;
        }
        NSArray* results = json[@"results"];
        if(results.count == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showAlert:@"Error" message:@"No results"];
            });
            return;
        }
        NSDictionary* app = results[0];
        [self getAllAppVersionIdsAndPrompt:[app[@"trackId"] longLongValue]];
    }];
    [task resume];
}

- (NSString*)getAboutText {
    return @"MuffinStore v1.3\nMade by Mineek\nEnhanced by IPMan\nhttps://github.com/mineek/MuffinStore";
}

- (void)showAlert:(NSString*)title message:(NSString*)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
        UIAlertAction* okAction = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil];
        [alert addAction:okAction];
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
                [self showAlert:@"Error" message:error.localizedDescription];
            });
            return;
        }
        NSError* jsonError = nil;
        NSDictionary* json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        if(jsonError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showAlert:@"JSON Error" message:jsonError.debugDescription];
            });
            return;
        }
        NSArray* versionIds = json[@"data"];
        if(versionIds.count == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showAlert:@"Error" message:@"No version IDs, internal error maybe?"];
            });
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController* versionAlert = [UIAlertController alertControllerWithTitle:@"Version ID" message:@"Select the version ID of the app you want to download" preferredStyle:UIAlertControllerStyleActionSheet];
            for(NSDictionary* versionId in versionIds) {
                UIAlertAction* versionAction = [UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@", versionId[@"bundle_version"]] style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
                    [self downloadAppWithAppId:appId versionId:[versionId[@"external_identifier"] longLongValue]];
                }];
                [versionAlert addAction:versionAction];
            }
            UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
            [versionAlert addAction:cancelAction];
            // iPad 适配，修复废弃 API
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
        UIAlertController* versionAlert = [UIAlertController alertControllerWithTitle:@"Version ID" message:@"Enter the version ID of the app you want to download" preferredStyle:UIAlertControllerStyleAlert];
        [versionAlert addTextFieldWithConfigurationHandler:^(UITextField* textField) {
            textField.placeholder = @"Version ID";
        }];
        UIAlertAction* downloadAction = [UIAlertAction actionWithTitle:@"Download" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
            long long versionId = [versionAlert.textFields.firstObject.text longLongValue];
            [self downloadAppWithAppId:appId versionId:versionId];
        }];
        [versionAlert addAction:downloadAction];
        UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
        [versionAlert addAction:cancelAction];
        [self presentViewController:versionAlert animated:YES completion:nil];
    });
}

- (void)getAllAppVersionIdsAndPrompt:(long long)appId {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController* promptAlert = [UIAlertController alertControllerWithTitle:@"Version ID" message:@"Do you want to enter the version ID manually or request the list of version IDs from the server?" preferredStyle:UIAlertControllerStyleAlert];
        UIAlertAction* manualAction = [UIAlertAction actionWithTitle:@"Manual" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
            [self promptForVersionId:appId];
        }];
        [promptAlert addAction:manualAction];
        UIAlertAction* serverAction = [UIAlertAction actionWithTitle:@"Server" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
            [self getAllAppVersionIdsFromServer:appId];
        }];
        [promptAlert addAction:serverAction];
        UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
        [promptAlert addAction:cancelAction];
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
            [self showAlert:@"Error" message:@"Invalid link"];
            return;
        }
        NSArray* idComponents = [components[1] componentsSeparatedByString:@"?"];
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
    UIAlertController* linkAlert = [UIAlertController alertControllerWithTitle:@"App Link" message:@"Enter the link to the app you want to download" preferredStyle:UIAlertControllerStyleAlert];
    [linkAlert addTextFieldWithConfigurationHandler:^(UITextField* textField) {
        textField.placeholder = @"App Link";
    }];
    UIAlertAction* downloadAction = [UIAlertAction actionWithTitle:@"Download" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action) {
        [self downloadAppWithLink:linkAlert.textFields.firstObject.text];
    }];
    [linkAlert addAction:downloadAction];
    UIAlertAction* cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil];
    [linkAlert addAction:cancelAction];
    [self presentViewController:linkAlert animated:YES completion:nil];
}

@end
