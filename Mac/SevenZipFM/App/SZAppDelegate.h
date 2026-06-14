// SZAppDelegate.h —— SevenZipFM 应用入口。M4-T1/T2：启动进真实文件系统，
// FS 浏览 ↔ 归档浏览无缝切换由 SZPanelController 的数据源栈自包含（双击归档 push、上溯 pop）。
#import <AppKit/AppKit.h>
NS_ASSUME_NONNULL_BEGIN
@interface SZAppDelegate : NSObject <NSApplicationDelegate>
/// 以真实文件系统目录为当前面板（重置导航栈）。
- (void)openDirectory:(NSString *)path;
/// 打开归档：以其所在 FS 目录为栈底，再 push 归档层（上溯可退回该目录）。
- (void)openArchiveURL:(NSURL *)url;
@end
NS_ASSUME_NONNULL_END
