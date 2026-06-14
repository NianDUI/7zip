// SZShellCommand.h —— Shell 命令模型（M5-T2）。主 app 与 FinderSync 扩展共享（对齐 docs/04 §1.9 SevenZipCommandModel）。
// 纯 Foundation；扩展进程只用它「生成菜单 + 编码 URL」，主 app 用它「解码 URL + 分发执行」。
// 通信走 sevenzip:// URL scheme（扩展沙箱不跑引擎，唤起主 app 执行；对应 Windows 右键→7zG 子进程）。
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, SZShellOp) {
  SZShellOpUnknown = 0,
  SZShellOpOpen,             ///< 打开归档（主 app 浏览）
  SZShellOpExtract,          ///< 解压…（弹对话框）
  SZShellOpExtractHere,      ///< 解压到当前位置
  SZShellOpExtractToFolder,  ///< 解压到「名/」子文件夹
  SZShellOpTest,             ///< 测试
  SZShellOpCompress,         ///< 添加到压缩包…（弹对话框）
  SZShellOpCompress7z,       ///< 快速压缩到「名.7z」
  SZShellOpCompressZip,      ///< 快速压缩到「名.zip」
  SZShellOpHash,             ///< CRC/SHA 校验和（methods 指定算法）
};

@interface SZShellCommand : NSObject

@property (nonatomic) SZShellOp op;
@property (nonatomic, copy) NSArray<NSString *> *paths;     ///< 目标文件/目录绝对路径
@property (nonatomic, copy) NSArray<NSString *> *methods;   ///< 仅 Hash：算法名（CRC32/SHA256…）

+ (instancetype)commandWithOp:(SZShellOp)op paths:(NSArray<NSString *> *)paths;

/// 编码为 sevenzip:// URL（paths→base64url(JSON)，methods→csv）。
- (nullable NSURL *)url;
/// 从 sevenzip:// URL 解码；scheme/op 非法返回 nil。
+ (nullable instancetype)commandFromURL:(NSURL *)url;

#pragma mark 共享启发式（扩展菜单标题 + 主 app 执行同源）

/// 归档解压的基础名（去最后一层扩展名）：archive.7z→archive、x.tar.gz→x.tar。
+ (NSString *)baseNameForArchive:(NSString *)archivePath;
/// 快速压缩的归档基础名：单选去扩展名；多选用共同父目录名（空则 "Archive"）。
+ (NSString *)archiveBaseNameForPaths:(NSArray<NSString *> *)paths;
/// op ↔ URL host 字符串。
+ (NSString *)stringForOp:(SZShellOp)op;
+ (SZShellOp)opForString:(nullable NSString *)s;

/// 路径是否常见归档（按扩展名硬编码；供 FinderSync 扩展判定，扩展不链引擎）。
+ (BOOL)isArchivePath:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
