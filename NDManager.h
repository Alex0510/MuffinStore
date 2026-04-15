#import <Foundation/Foundation.h>

@interface NDManager : NSObject

+ (instancetype)shared;

- (void)cleanSandbox;
- (void)cleanKeychain;
- (void)resetUserDefaults;

@end