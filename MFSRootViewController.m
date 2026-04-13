// MFSRootViewController.m （终极完整融合版）

#import "MFSRootViewController.h"
#import "CoreServices.h"
#import <objc/runtime.h>

@interface SKUIItemStateCenter : NSObject
+ (id)defaultCenter;
- (id)_newPurchasesWithItems:(id)items;
- (void)_performPurchases:(id)purchases hasBundlePurchase:(_Bool)purchase withClientContext:(id)context completionBlock:(id)block;
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

static NSCache *iconCache;
static NSCache *groupPathCache;

@implementation MFSRootViewController

#pragma mark - 初始化

+ (void)initialize {
    if (self == [MFSRootViewController class]) {
        iconCache = [NSCache new];
        groupPathCache = [NSCache new];
    }
}

#pragma mark - UI

- (void)loadView {
    [super loadView];

    UIBarButtonItem *refresh = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
        target:self
        action:@selector(refreshAppList)];

    UIBarButtonItem *idDownload = [[UIBarButtonItem alloc]
        initWithTitle:@"ID下载"
        style:UIBarButtonItemStylePlain
        target:self
        action:@selector(promptForAppIdDownload)];

    self.navigationItem.rightBarButtonItem = refresh;
    self.navigationItem.leftBarButtonItem = idDownload;
}

- (void)refreshAppList {
    _specifiers = nil;
    [iconCache removeAllObjects];
    [groupPathCache removeAllObjects];
    [self reloadSpecifiers];
}

#pragma mark - Filza 修复（关键）

- (void)openInFilza:(NSString *)path {
    if (!path.length) {
        [self showAlert:@"错误" message:@"路径无效"];
        return;
    }

    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [self showAlert:@"错误" message:@"路径不存在"];
        return;
    }

    NSString *encoded = [path stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"filza://%@", encoded]];

    UIApplication *app = UIApplication.sharedApplication;

    if ([app canOpenURL:url]) {
        [app openURL:url options:@{} completionHandler:nil];
    } else {
        NSURL *fallback = [NSURL URLWithString:[NSString stringWithFormat:@"filza://%@", path]];
        [app openURL:fallback options:@{} completionHandler:nil];
    }
}

#pragma mark - AppGroup（增强）

- (NSArray *)getAllGroupPaths:(NSString *)bundleId appProxy:(id)appProxy {
    NSMutableArray *arr = [NSMutableArray array];
    NSFileManager *fm = NSFileManager.defaultManager;

    @try {
        NSArray *urls = [appProxy valueForKey:@"groupContainerURLs"];
        for (NSURL *url in urls) {
            if ([fm fileExistsAtPath:url.path]) {
                [arr addObject:url.path];
            }
        }
    } @catch (NSException *e) {}

    NSString *root = @"/var/mobile/Containers/Shared/AppGroup";
    NSArray *dirs = [fm contentsOfDirectoryAtPath:root error:nil];
    NSString *lower = bundleId.lowercaseString;

    for (NSString *dir in dirs) {
        NSString *full = [root stringByAppendingPathComponent:dir];
        NSString *meta = [full stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];

        NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:meta];
        NSString *idStr = [plist[@"MCMMetadataIdentifier"] lowercaseString];

        if (!idStr) continue;

        if ([idStr containsString:lower] || [lower containsString:idStr]) {
            if (![arr containsObject:full]) {
                [arr addObject:full];
            }
        }
    }

    return arr;
}

- (void)showAllAppGroups:(NSString *)bundleId appProxy:(id)appProxy {
    NSArray *groups = [self getAllGroupPaths:bundleId appProxy:appProxy];

    if (groups.count == 0) {
        [self showAlert:@"提示" message:@"没有 AppGroup"];
        return;
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"AppGroup"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    for (NSString *path in groups) {
        [alert addAction:[UIAlertAction actionWithTitle:path.lastPathComponent
                                                  style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *a) {
            [self openInFilza:path];
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:1 handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 数据路径

- (NSString *)getDataContainerPathForBundleId:(NSString *)bundleId appProxy:(id)appProxy {
    NSURL *url = [appProxy valueForKey:@"dataContainerURL"];
    if ([url isKindOfClass:NSURL.class]) {
        return url.path;
    }
    return nil;
}

#pragma mark - 备份 & 恢复

- (void)backupAppData:(NSString *)bundleId appProxy:(id)appProxy {
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        NSString *data = [self getDataContainerPathForBundleId:bundleId appProxy:appProxy];
        NSString *backupDir = @"/var/mobile/Documents/MuffinBackup";

        NSFileManager *fm = NSFileManager.defaultManager;
        [fm createDirectoryAtPath:backupDir withIntermediateDirectories:YES attributes:nil error:nil];

        NSString *target = [backupDir stringByAppendingPathComponent:bundleId];
        [fm removeItemAtPath:target error:nil];

        if (data) {
            [fm copyItemAtPath:data toPath:target error:nil];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [self showAlert:@"完成" message:@"备份完成"];
        });
    });
}

- (void)restoreAppData:(NSString *)bundleId appProxy:(id)appProxy {
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        NSString *backup = [@"/var/mobile/Documents/MuffinBackup" stringByAppendingPathComponent:bundleId];
        NSString *data = [self getDataContainerPathForBundleId:bundleId appProxy:appProxy];

        NSFileManager *fm = NSFileManager.defaultManager;

        if (![fm fileExistsAtPath:backup]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showAlert:@"错误" message:@"没有备份"];
            });
            return;
        }

        for (NSString *f in [fm contentsOfDirectoryAtPath:data error:nil]) {
            [fm removeItemAtPath:[data stringByAppendingPathComponent:f] error:nil];
        }

        for (NSString *f in [fm contentsOfDirectoryAtPath:backup error:nil]) {
            [fm copyItemAtPath:[backup stringByAppendingPathComponent:f]
                        toPath:[data stringByAppendingPathComponent:f]
                         error:nil];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            [self showAlert:@"完成" message:@"恢复完成"];
        });
    });
}

#pragma mark - 长按菜单（增强）

- (void)handleLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;

    UITableViewCell *cell = (UITableViewCell *)g.view;
    NSDictionary *appInfo = objc_getAssociatedObject(cell, "appInfo");

    NSString *bundleId = appInfo[@"bundleIdentifier"];
    id proxy = [LSApplicationProxy applicationProxyForIdentifier:bundleId];

    UIAlertController *menu = [UIAlertController alertControllerWithTitle:appInfo[@"localizedName"]
                                                                  message:nil
                                                           preferredStyle:0];

    [menu addAction:[UIAlertAction actionWithTitle:@"启动" style:0 handler:^(id a){
        [[LSApplicationWorkspace defaultWorkspace] openApplicationWithBundleID:bundleId];
    }]];

    [menu addAction:[UIAlertAction actionWithTitle:@"应用目录" style:0 handler:^(id a){
        [self openInFilza:appInfo[@"bundlePath"]];
    }]];

    [menu addAction:[UIAlertAction actionWithTitle:@"数据目录" style:0 handler:^(id a){
        [self openInFilza:[self getDataContainerPathForBundleId:bundleId appProxy:proxy]];
    }]];

    [menu addAction:[UIAlertAction actionWithTitle:@"应用组目录" style:0 handler:^(id a){
        [self showAllAppGroups:bundleId appProxy:proxy];
    }]];

    [menu addAction:[UIAlertAction actionWithTitle:@"备份数据" style:0 handler:^(id a){
        [self backupAppData:bundleId appProxy:proxy];
    }]];

    [menu addAction:[UIAlertAction actionWithTitle:@"恢复数据" style:0 handler:^(id a){
        [self restoreAppData:bundleId appProxy:proxy];
    }]];

    [menu addAction:[UIAlertAction actionWithTitle:@"清理数据" style:2 handler:^(id a){
        [self performClearDataForAppProxy:proxy bundleId:bundleId];
    }]];

    [menu addAction:[UIAlertAction actionWithTitle:@"取消" style:1 handler:nil]];

    [self presentViewController:menu animated:YES completion:nil];
}

#pragma mark - 下载功能（完整保留）

- (void)downloadAppWithAppId:(long long)appId versionId:(long long)versionId {

    NSString *adamId = [NSString stringWithFormat:@"%lld", appId];
    NSString *offer = [NSString stringWithFormat:
        @"productType=C&price=0&salableAdamId=%@&appExtVrsId=%lld",
        adamId, versionId];

    NSDictionary *offerDict = @{@"buyParams": offer};
    NSDictionary *itemDict = @{@"_itemOffer": adamId};

    SKUIItemOffer *o = [[SKUIItemOffer alloc] initWithLookupDictionary:offerDict];
    SKUIItem *item = [[SKUIItem alloc] initWithLookupDictionary:itemDict];

    [item setValue:o forKey:@"_itemOffer"];
    [item setValue:@"iosSoftware" forKey:@"_itemKindString"];
    [item setValue:@(versionId) forKey:@"_versionIdentifier"];

    SKUIItemStateCenter *center = [SKUIItemStateCenter defaultCenter];

    [center _performPurchases:
        [center _newPurchasesWithItems:@[item]]
        hasBundlePurchase:0
        withClientContext:[SKUIClientContext defaultContext]
        completionBlock:^(id x){}];
}

#pragma mark - Alert

- (void)showAlert:(NSString *)title message:(NSString *)msg {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:1];
    [a addAction:[UIAlertAction actionWithTitle:@"确定" style:0 handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

@end