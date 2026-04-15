#import "NDManager.h"
#import <Security/Security.h>

@implementation NDManager

+ (instancetype)shared {
    static NDManager *m;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        m = [[NDManager alloc] init];
    });
    return m;
}

#pragma mark - 沙盒清理

- (void)cleanSandbox {
    NSString *home = NSHomeDirectory();
    NSArray *paths = @[
        @"Documents",
        @"Library/Caches",
        @"Library/Application Support",
        @"tmp"
    ];

    for (NSString *p in paths) {
        NSString *full = [home stringByAppendingPathComponent:p];
        [[NSFileManager defaultManager] removeItemAtPath:full error:nil];
        [[NSFileManager defaultManager] createDirectoryAtPath:full
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
    }

    NSLog(@"[NewDevice] 沙盒清理完成");
}

#pragma mark - Keychain 清理

- (void)cleanKeychain {
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

    NSLog(@"[NewDevice] Keychain 清理完成");
}

#pragma mark - NSUserDefaults 重置

- (void)resetUserDefaults {
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    [[NSUserDefaults standardUserDefaults] removePersistentDomainForName:bundleID];
    [[NSUserDefaults standardUserDefaults] synchronize];

    NSLog(@"[NewDevice] UserDefaults 已重置");
}

@end