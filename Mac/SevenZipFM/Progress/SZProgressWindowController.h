// SZProgressWindowController.h —— 解压进度窗（M2-T4）+ 覆盖/密码阻塞弹框（M2-T2 UI 落地）。
// 对应 Windows ProgressDialog2（04-feature-map-dialogs-finder.md §4）。独立窗口（每操作一个，§2.5）。
// 实现 SZArchiveExtractDelegate：进度回调只更新 ivar，NSTimer 0.2s 拉取刷 UI（对齐 CProgressSync 轮询模型）；
// 覆盖/密码询问在主线程同步弹 NSAlert（引擎工作线程经信号量阻塞等返回）。
#import <Cocoa/Cocoa.h>
@class SZArchiveExtractOptions;
NS_ASSUME_NONNULL_BEGIN

@interface SZProgressWindowController : NSObject

/// 弹进度窗并开始解压（options 含目标/路径模式/覆盖模式/密码/testMode）。
/// completion 在主线程回调（ok=无错误完成；NO=有错误/取消）。控制器自持至完成。
- (void)beginExtractArchive:(NSString *)archivePath
                    options:(SZArchiveExtractOptions *)options
                 completion:(nullable void (^)(BOOL ok))completion;

/// 测试模式（testMode）便利方法：校验完整性不落盘，完成弹「没有错误」或错误汇总。
- (void)beginTestArchive:(NSString *)archivePath
                password:(nullable NSString *)password
              completion:(nullable void (^)(BOOL ok))completion;

@end

NS_ASSUME_NONNULL_END
