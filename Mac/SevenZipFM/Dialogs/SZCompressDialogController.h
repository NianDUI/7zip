// SZCompressDialogController.h —— 压缩对话框（M3-T2/T1/T3，对应 Windows CCompressDialog）。
// 字段：归档名/格式/等级/线程/密码/加密文件名 + 实时内存估算（T1）+ 时间戳/精度（T3）+ 输入列表。
// 内存估算移植 CompressDialog.cpp::GetMemoryUsage_Threads_Dict_DecompMem（见 SZArchiveCompressor）。
#import <Cocoa/Cocoa.h>
@class SZCompressOptions;
NS_ASSUME_NONNULL_BEGIN

@interface SZCompressDialogController : NSObject

/// 以 sheet 弹出。completion(archivePath, options)：非 nil=确定，nil=取消。
+ (void)presentForInputs:(NSArray<NSString *> *)inputPaths
      defaultArchivePath:(NSString *)defaultArchivePath
            parentWindow:(NSWindow *)parent
              completion:(void (^)(NSString * _Nullable archivePath,
                                   SZCompressOptions * _Nullable options))completion;

@end

NS_ASSUME_NONNULL_END
