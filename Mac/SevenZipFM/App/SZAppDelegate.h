// SZAppDelegate.h —— SevenZipFM 应用入口（M1-T7 单面板只读壳）。
#import <AppKit/AppKit.h>
@interface SZAppDelegate : NSObject <NSApplicationDelegate>
- (void)openArchiveURL:(NSURL *)url;
@end
