// MFSRootViewController.h
#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <objc/runtime.h>

@interface MFSRootViewController : PSListController

// 悬浮窗相关方法
- (void)showFloatingWindow;
- (void)hideFloatingWindow;
- (void)createEnhancedFloatingWindow;

@end