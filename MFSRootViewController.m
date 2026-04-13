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
    
    // 添加右上角刷新按钮
    UIBarButtonItem *refreshButton = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(refreshAppList)];
    self.navigationItem.rightBarButtonItem = refreshButton;
}

- (void)refreshAppList {
    // 清除缓存，强制重新构建 specifiers
    _specifiers = nil;
    [iconCache removeAllObjects];
    [self reloadSpecifiers];
}

- (NSMutableArray*)specifiers {
    if(!_specifiers) {
        _specifiers = [NSMutableArray new];
        
        // Download 分组
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
        
        // Installed Apps 分组
        PSSpecifier* installedGroupSpecifier = [PSSpecifier emptyGroupSpecifier];
        installedGroupSpecifier.name = @"已安装应用";
        [_specifiers addObject:installedGroupSpecifier];
        
        NSMutableArray *appSpecifiers = [NSMutableArray new];
        [[LSApplicationWorkspace defaultWorkspace] enumerateApplicationsOfType:0 block:^(LSApplicationProxy* appProxy) {
            NSMutableDictionary *appInfo = [NSMutableDictionary dictionary];
            appInfo[@"bundleURL"] = appProxy.bundleURL;
            appInfo[@"bundleIdentifier"] = appProxy.bundleIdentifier;
            appInfo[@"localizedName"] = appProxy.localizedName ?: @"未知";
            
            // 获取版本号
            NSString *infoPath = [appProxy.bundleURL.path stringByAppendingPathComponent:@"Info.plist"];
            NSDictionary *infoPlist = [NSDictionary dictionaryWithContentsOfFile:infoPath];
            NSString *version = infoPlist[@"CFBundleShortVersionString"] ?: infoPlist[@"CFBundleVersion"] ?: @"N/A";
            appInfo[@"version"] = version;
            
            // 存储应用路径（.app 目录）
            appInfo[@"bundlePath"] = appProxy.bundleURL.path;
            // 存储 .app 所在的上层目录（UUID 目录），用于查找 iTunesMetadata.plist
            appInfo[@"containerPath"] = [appProxy.bundleURL.path stringByDeletingLastPathComponent];
            
            PSSpecifier* appSpecifier = [PSSpecifier preferenceSpecifierNamed:appProxy.localizedName target:self set:nil get:nil detail:nil cell:PSButtonCell edit:nil];
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

#pragma mark - UITableView 定制（显示图标、版本号、Bundle ID）

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [super tableView:tableView cellForRowAtIndexPath:indexPath];
    PSSpecifier *specifier = [self specifierAtIndexPath:indexPath];
    NSDictionary *appInfo = [specifier propertyForKey:@"appInfo"];
    
    if (appInfo && specifier.identifier != nil && ![specifier.identifier isEqualToString:@"download"]) {
        // 应用名称
        cell.textLabel.text = appInfo[@"localizedName"];
        
        // 副标题：版本号 + Bundle ID
        NSString *version = appInfo[@"version"];
        NSString *bundleId = appInfo[@"bundleIdentifier"];
        cell.detailTextLabel.text = [NSString stringWithFormat:@"v%@ • %@", version, bundleId];
        cell.detailTextLabel.textColor = [UIColor grayColor];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
        
        // 图标（缓存）
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
        
        // 详情按钮
        UIButton *infoButton = [UIButton buttonWithType:UIButtonTypeDetailDisclosure];
        [infoButton addTarget:self action:@selector(showAppDetails:) forControlEvents:UIControlEventTouchUpInside];
        objc_setAssociatedObject(infoButton, "appInfo", appInfo, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        cell.accessoryView = infoButton;
        cell.selectionStyle = UITableViewCellSelectionStyleBlue;
    } else {
        cell.accessoryView = nil;
        cell.detailTextLabel.text = nil;
        cell.imageView.image = nil;
    }
    return cell;
}

// 显示应用详情（实时读取 iTunesMetadata.plist，优先查找同级目录）
- (void)showAppDetails:(UIButton *)sender {
    NSDictionary *appInfo = objc_getAssociatedObject(sender, "appInfo");
    if (!appInfo) return;
    
    NSString *bundlePath = appInfo[@"bundlePath"];      // .app 路径
    NSString *containerPath = appInfo[@"containerPath"]; // UUID 目录路径
    NSString *bundleId = appInfo[@"bundleIdentifier"];
    NSString *version = appInfo[@"version"];
    
    // 1. 优先在 UUID 目录下查找 iTunesMetadata.plist（与 .app 同级）
    NSString *metadataPath1 = [containerPath stringByAppendingPathComponent:@"iTunesMetadata.plist"];
    // 2. 其次在 .app 内部查找
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
    
    NSString *accountInfo;
    if (!fileExists) {
        accountInfo = [NSString stringWithFormat:@"未找到 iTunesMetadata.plist\n尝试路径:\n%@\n%@", metadataPath1, metadataPath2];
    } else {
        NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:metadataPath];
        if (metadata) {
            NSString *appleID = metadata[@"AppleID"] ?: @"未知";
            NSString *artist = metadata[@"artistName"] ?: @"未知";
            NSString *purchaseDate = metadata[@"purchaseDate"] ?: @"未知";
            accountInfo = [NSString stringWithFormat:@"Apple ID: %@\n开发者: %@\n购买日期: %@", appleID, artist, purchaseDate];
        } else {
            accountInfo = [NSString stringWithFormat:@"文件存在但无法解析:\n%@", metadataPath];
        }
    }
    
    NSString *message = [NSString stringWithFormat:
                         @"路径: %@\n\nBundle ID: %@\n版本: %@\n\n%@",
                         bundlePath, bundleId, version, accountInfo];
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"应用详情"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 辅助方法：加载应用图标

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

#pragma mark - 下载相关功能（所有提示已中文化）

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
    return @"MuffinStore v1.2\n作者 Mineek\nhttps://github.com/mineek/MuffinStore";
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
            if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPad) {
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