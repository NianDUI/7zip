// SZFileAssocController —— 文件关联配置窗（对应 Windows 7-Zip 选项 → 系统页）。
// 列出归档格式，勾选即把双击默认设为本 app（LaunchServices），取消即恢复系统默认。
#import <AppKit/AppKit.h>

@interface SZFileAssocController : NSWindowController
+ (void)presentWithParentWindow:(NSWindow *)parent;
@end
