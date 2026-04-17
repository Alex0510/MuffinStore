// Tweak.xm
#import <UIKit/UIKit.h>
#import <Security/Security.h>

#define TASK_FILE_PATH @"/var/mobile/Documents/muffinstore_task.plist"

%hook UIApplication

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    BOOL result = %orig;
    
    // 检查是否有清理任务
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        if ([fm fileExistsAtPath:TASK_FILE_PATH]) {
            NSDictionary *task = [NSDictionary dictionaryWithContentsOfFile:TASK_FILE_PATH];
            if (task) {
                NSString *targetBundleId = task[@"bundleId"];
                NSString *currentBundleId = [[NSBundle mainBundle] bundleIdentifier];
                
                if ([targetBundleId isEqualToString:currentBundleId]) {
                    // 清理 Keychain
                    NSArray *secClasses = @[
                        (__bridge id)kSecClassGenericPassword,
                        (__bridge id)kSecClassInternetPassword,
                        (__bridge id)kSecClassCertificate,
                        (__bridge id)kSecClassKey,
                        (__bridge id)kSecClassIdentity
                    ];
                    for (id secClass in secClasses) {
                        NSDictionary *query = @{(__bridge id)kSecClass: secClass};
                        SecItemDelete((__bridge CFDictionaryRef)query);
                    }
                    
                    // 清理沙盒
                    NSString *docPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
                    NSString *libPath = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) firstObject];
                    NSString *cachePath = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) firstObject];
                    NSString *tmpPath = NSTemporaryDirectory();
                    NSArray *paths = @[docPath, libPath, cachePath, tmpPath];
                    for (NSString *path in paths) {
                        if (!path) continue;
                        NSArray *contents = [fm contentsOfDirectoryAtPath:path error:nil];
                        for (NSString *item in contents) {
                            if ([item isEqualToString:@"."] || [item isEqualToString:@".."]) continue;
                            [fm removeItemAtPath:[path stringByAppendingPathComponent:item] error:nil];
                        }
                    }
                    
                    // 清理 NSUserDefaults
                    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
                    NSString *prefPath = [NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@.plist", bundleId];
                    [fm removeItemAtPath:prefPath error:nil];
                    
                    // 删除任务文件
                    [fm removeItemAtPath:TASK_FILE_PATH error:nil];
                    
                    // 退出应用
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        exit(0);
                    });
                }
            }
        }
    });
    
    return result;
}

%end