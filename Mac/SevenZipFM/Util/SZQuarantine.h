// SZQuarantine.h —— quarantine 传播（M2-T7，对应 Windows WriteZoneIdExtract）。
// 网络来源的归档（带 com.apple.quarantine）解压出的文件应继承该标记，Gatekeeper 据此对可执行文件检查。
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

/// 源归档是否带 com.apple.quarantine（即网络/不可信来源）。
BOOL SZArchiveHasQuarantine(NSString *archivePath);

/// 把源归档的 quarantine 属性递归传播到解压出的 destPath（文件或目录及其全部子项）。
/// 源无 quarantine 或 dest 不存在则静默跳过。
void SZApplyQuarantineFrom(NSString *archivePath, NSString *destPath);

NS_ASSUME_NONNULL_END
