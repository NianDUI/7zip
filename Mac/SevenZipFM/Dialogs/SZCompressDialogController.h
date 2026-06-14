// SZCompressDialogController.h —— 压缩对话框（M3-T2，对应 Windows CCompressDialog）。
// 首版核心字段：归档名/格式/等级/密码/加密文件名 + 输入文件列表。
// 完整 1:1（方法/字典/Order/Solid/线程/内存估算/分卷/联动矩阵）随 T1 内存估算 + 后续迭代补。
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
