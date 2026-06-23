// SZHashResultController.h —— 校验和（CRC/SHA）结果窗（M5）。
// 对齐 Windows 7-Zip 的「CRC SHA」结果对话框：流式列出每文件每算法哈希 + 数据总和 + 统计，支持复制。
#import <AppKit/AppKit.h>
NS_ASSUME_NONNULL_BEGIN

@interface SZHashResultController : NSObject

/// 对一组路径（文件/目录，目录递归）按 methods 算哈希并弹结果窗。窗口非模态，自我保活到关闭。
+ (void)presentForPaths:(NSArray<NSString *> *)paths
                methods:(NSArray<NSString *> *)methods
           parentWindow:(nullable NSWindow *)parent;

/// 同上，但结果窗关闭时回调 onClose（供 Finder 右键无主窗口场景：关闭后决定是否退出 app）。
+ (void)presentForPaths:(NSArray<NSString *> *)paths
                methods:(NSArray<NSString *> *)methods
           parentWindow:(nullable NSWindow *)parent
                onClose:(nullable void (^)(void))onClose;

@end

NS_ASSUME_NONNULL_END
