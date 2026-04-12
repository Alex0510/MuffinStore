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
        [[LSApplicationWorkspace defaultWorkspace] enumerateApplicationsOfType:0 block:^(LSApplicationProxy *appProxy) {
            id proxy = (id)appProxy;  // 强制转换为 id 以调用私有方法
            
            // 获取图标
            UIImage *icon = nil;
            if ([proxy respondsToSelector:@selector(applicationIcon)]) {
                icon = [proxy applicationIcon];
            }
            
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
            
            // 主标题：应用名 (版本号)
            NSString *title = [NSString stringWithFormat:@"%@ (%@)", appProxy.localizedName, version];
            // 副标题：Bundle ID | Apple ID
            NSString *subtitle = [NSString stringWithFormat:@"%@ | %@", appProxy.bundleIdentifier, appleID];
            
            PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:title
                                                                target:self
                                                                   set:nil
                                                                   get:nil
                                                                detail:nil
                                                                  cell:PSSubtitleCell
                                                                  edit:nil];
            [spec setProperty:bundleURL forKey:@"bundleURL"];
            [spec setProperty:@YES forKey:@"enabled"];
            if (icon) [spec setProperty:icon forKey:@"iconImage"];
            [spec setProperty:subtitle forKey:@"subtitle"];
            spec.buttonAction = @selector(downloadAppShortcut:);
            [appSpecifiers addObject:spec];
        }];
        
        [appSpecifiers sortUsingComparator:^NSComparisonResult(PSSpecifier *a, PSSpecifier *b) {
            return [a.name compare:b.name];
        }];
        [_specifiers addObjectsFromArray:appSpecifiers];
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

#pragma mark - 原有功能（保持不变）

- (void)downloadAppShortcut:(PSSpecifier*)specifier {
    NSURL *bundleURL = [specifier propertyForKey:@"bundleURL"];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[bundleURL.path stringByAppendingPathComponent:@"Info.plist"]];
    NSString *bundleId = info[@"CFBundleIdentifier"];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"https://itunes.apple.com/lookup?bundleId=%@&limit=1&media=software", bundleId]];
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:[NSURLRequest requestWithURL:url] completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) { dispatch_async(dispatch_get_main_queue(), ^{ [self showAlert:@"Error" message:error.localizedDescription]; }); return; }
        NSError *jsonErr = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
        if (jsonErr) { dispatch_async(dispatch_get_main_queue(), ^{ [self showAlert:@"JSON Error" message:jsonErr.localizedDescription]; }); return; }
        NSArray *results = json[@"results"];
        if (results.count == 0) { dispatch_async(dispatch_get_main_queue(), ^{ [self showAlert:@"Error" message:@"No results"]; }); return; }
        [self getAllAppVersionIdsAndPrompt:[results[0][@"trackId"] longLongValue]];
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
        if (error) { dispatch_async(dispatch_get_main_queue(), ^{ [self showAlert:@"Error" message:error.localizedDescription]; }); return; }
        NSError *jsonErr = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
        if (jsonErr) { dispatch_async(dispatch_get_main_queue(), ^{ [self showAlert:@"JSON Error" message:jsonErr.debugDescription]; }); return; }
        NSArray *versions = json[@"data"];
        if (versions.count == 0) { dispatch_async(dispatch_get_main_queue(), ^{ [self showAlert:@"Error" message:@"No version IDs"]; }); return; }
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Version ID" message:@"Select version" preferredStyle:UIAlertControllerStyleActionSheet];
            for (NSDictionary *v in versions) {
                [alert addAction:[UIAlertAction actionWithTitle:v[@"bundle_version"] style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
                    [self downloadAppWithAppId:appId versionId:[v[@"external_identifier"] longLongValue]];
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
        [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.placeholder = @"Version ID"; }];
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
    NSString *offerString = versionId == 0 ?
        [NSString stringWithFormat:@"productType=C&price=0&salableAdamId=%@&pricingParameters=pricingParameter&clientBuyId=1&installed=0&trolled=1", adamId] :
        [NSString stringWithFormat:@"productType=C&price=0&salableAdamId=%@&pricingParameters=pricingParameter&appExtVrsId=%@&clientBuyId=1&installed=0&trolled=1", adamId, appExtVrsId];
    
    SKUIItemOffer *offer = [[SKUIItemOffer alloc] initWithLookupDictionary:@{@"buyParams": offerString}];
    SKUIItem *item = [[SKUIItem alloc] initWithLookupDictionary:@{@"_itemOffer": adamId}];
    [item setValue:offer forKey:@"_itemOffer"];
    [item setValue:@"iosSoftware" forKey:@"_itemKindString"];
    if (versionId != 0) [item setValue:@(versionId) forKey:@"_versionIdentifier"];
    
    SKUIItemStateCenter *center = [SKUIItemStateCenter defaultCenter];
    dispatch_async(dispatch_get_main_queue(), ^{
        [center _performPurchases:[center _newPurchasesWithItems:@[item]] hasBundlePurchase:0 withClientContext:[SKUIClientContext defaultContext] completionBlock:^(id arg1){}];
    });
}

- (void)downloadAppWithLink:(NSString*)link {
    NSString *target = nil;
    if ([link containsString:@"id"]) {
        NSArray *parts = [link componentsSeparatedByString:@"id"];
        if (parts.count < 2) { [self showAlert:@"Error" message:@"Invalid link"]; return; }
        target = [[parts[1] componentsSeparatedByString:@"?"] firstObject];
    } else {
        [self showAlert:@"Error" message:@"Invalid link"]; return;
    }
    [self getAllAppVersionIdsAndPrompt:[target longLongValue]];
}

- (void)downloadApp {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"App Link" message:@"Enter App Store link" preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.placeholder = @"https://apps.apple.com/..."; }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Download" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [self downloadAppWithLink:alert.textFields.firstObject.text];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
