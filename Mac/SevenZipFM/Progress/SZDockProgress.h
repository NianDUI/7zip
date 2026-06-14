// SZDockProgress.h —— Dock 图标进度（M5 打磨）。
// 解压/压缩/测试等耗时操作期间在 Dock 应用图标底部画进度条；切到别的 app 也能看到进度。
// 单例 + 引用计数：支持并发多操作（显示最近更新的进度），全部结束才恢复正常图标。
#import <AppKit/AppKit.h>
NS_ASSUME_NONNULL_BEGIN

@interface SZDockProgress : NSObject

+ (instancetype)shared;

/// 操作开始（引用计数 +1，首个操作时挂上自绘 dock tile）。
- (void)beginOperation;
/// 更新进度：fraction 0–1；传 <0 表示总量未知（不确定，画脉冲条）。
- (void)updateFraction:(double)fraction;
/// 操作结束（引用计数 -1，归零时恢复正常应用图标）。
- (void)endOperation;

@end

NS_ASSUME_NONNULL_END
