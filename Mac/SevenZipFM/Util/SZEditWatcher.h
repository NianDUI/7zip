// SZEditWatcher —— 归档内文件「编辑回写」监视（对应 Windows 7zFM PanelItemOpen 的编辑回写）。
// 归档内文件解压到临时并用外部程序打开后登记于此；app 重新激活时比对临时文件 mtime/size，
// 若被外部程序修改则询问是否更新回归档（独立 session 重写归档）。
#import <AppKit/AppKit.h>

@interface SZEditWatcher : NSObject
+ (instancetype)shared;

// 登记一个待监视的编辑临时文件。localFile 的 basename 必须与归档内文件名一致（覆盖更新依赖此）。
- (void)watchFile:(NSString *)localFile
        inArchive:(NSString *)archiveFSPath
     internalPath:(NSString *)internalPath;

// app 激活时调用：检查所有监视项是否变更，逐个询问并写回（sheet 弹在 parent 上）。
- (void)checkAndPromptWithParentWindow:(NSWindow *)parent;
@end
