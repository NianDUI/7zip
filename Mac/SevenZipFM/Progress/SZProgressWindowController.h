// SZProgressWindowController.h —— 解压进度窗（M2-T4）+ 覆盖/密码阻塞弹框（M2-T2 UI 落地）。
// 对应 Windows ProgressDialog2（04-feature-map-dialogs-finder.md §4）。独立窗口（每操作一个，§2.5）。
// 实现 SZArchiveExtractDelegate：进度回调只更新 ivar，NSTimer 0.2s 拉取刷 UI（对齐 CProgressSync 轮询模型）；
// 覆盖/密码询问在主线程同步弹 NSAlert（引擎工作线程经信号量阻塞等返回）。
#import <Cocoa/Cocoa.h>
NS_ASSUME_NONNULL_BEGIN

@interface SZProgressWindowController : NSObject

/// 弹进度窗并开始解压整档到 destDir。password 可空（加密档会按需弹密码框）。
/// completion 在主线程回调（ok=无错误完成；NO=有错误/取消）。控制器自持至完成。
- (void)beginExtractArchive:(NSString *)archivePath
                toDirectory:(NSString *)destDir
                   password:(nullable NSString *)password
                 completion:(nullable void (^)(BOOL ok))completion;

@end

NS_ASSUME_NONNULL_END
