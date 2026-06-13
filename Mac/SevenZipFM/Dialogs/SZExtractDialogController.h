// SZExtractDialogController.h —— 解压对话框（M2-T3，对应 Windows CExtractDialog）。
// 以 sheet 弹出，收集目标目录（含历史）、路径模式、覆盖模式、密码、消除重复路径，产出 SZArchiveExtractOptions。
// 自用裁剪：NtSecurity 复选隐藏（mac 无意义）；路径模式无 Relative（对齐 Windows CExtractDialog 也无）。
#import <Cocoa/Cocoa.h>
@class SZArchiveExtractOptions;
NS_ASSUME_NONNULL_BEGIN

@interface SZExtractDialogController : NSObject

/// 以 sheet 在 parent 上弹出。completion(options)：options 非 nil=确定，nil=取消。
+ (void)presentForArchive:(NSString *)archiveName
       defaultDestination:(NSString *)defaultDest
             parentWindow:(NSWindow *)parent
               completion:(void (^)(SZArchiveExtractOptions * _Nullable options))completion;

@end

NS_ASSUME_NONNULL_END
