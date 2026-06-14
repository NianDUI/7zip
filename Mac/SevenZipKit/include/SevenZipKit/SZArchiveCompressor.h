// SZArchiveCompressor.h —— 压缩任务的 ObjC 外观（M3-T2/T4）。对称 SZArchiveExtractor。
// 公开头纯 Foundation；压缩跑后台串行队列，回调/completion 回主队列。命名 SZArchive* 避开系统类。
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

/// 压缩内存估算（对应 7zFM CompressDialog 的「需要内存 / 解压需要」，纯提示）。
/// 字段为字节；(uint64_t)-1 表示未知（如等级 0 仅存储或不支持的方法）。
typedef struct SZMemoryEstimate {
  uint64_t compressBytes;     ///< 压缩占用内存
  uint64_t decompressBytes;   ///< 解压占用内存
} SZMemoryEstimate;

/// 时间精度（7z 专有，对应 -mtp）。引擎仅接受 默认/100ns/1ns 三档（7zHandlerOut 校验）。
typedef NS_ENUM(NSInteger, SZTimePrecision) {
  SZTimePrecisionDefault = -1,   ///< 不下发，按引擎默认
  SZTimePrecision100ns   = 23,   ///< k_PropVar_TimePrec_100ns（Windows FILETIME）
  SZTimePrecision1ns     = 3,    ///< k_PropVar_TimePrec_HighPrec（纳秒，保留 APFS 全精度）
};

/// 压缩选项（映射 SZCompressRequest 子集）。
@interface SZCompressOptions : NSObject
@property (nonatomic, copy, nullable) NSString *format;     ///< "7z"/"zip"/"tar"…；nil=按归档扩展名
@property (nonatomic) NSInteger level;                      ///< 0(仅存储)–9(极限)，默认 5
@property (nonatomic, copy, nullable) NSString *method;     ///< 主方法（如 LZMA2）；nil=格式默认
@property (nonatomic) uint64_t dictSize;                    ///< 字典字节；0=等级默认
@property (nonatomic) NSInteger threads;                    ///< 线程；0=引擎默认
@property (nonatomic) BOOL solid;                           ///< 固实（7z），默认 YES
@property (nonatomic, copy, nullable) NSString *password;
@property (nonatomic) BOOL encryptHeader;                   ///< 加密文件名（7z）
@property (nonatomic, copy) NSArray<NSString *> *inputPaths;///< 输入文件/目录 FS 路径
// —— 时间戳（T3 二级选项；映射 7z/zip 的 -mtm/-mtc/-mta/-mtp）——
@property (nonatomic) BOOL storeMTime;                      ///< 存修改时间，默认 YES
@property (nonatomic) BOOL storeCTime;                      ///< 存创建时间，默认 NO
@property (nonatomic) BOOL storeATime;                      ///< 存访问时间，默认 NO
@property (nonatomic) SZTimePrecision timePrecision;        ///< 时间精度（7z），默认 SZTimePrecisionDefault
@end

@class SZArchiveCompressor;

@protocol SZArchiveCompressDelegate <NSObject>
@optional
- (void)compressor:(SZArchiveCompressor *)c didUpdateFraction:(double)fraction
    completedBytes:(uint64_t)completed totalBytes:(uint64_t)total;
- (void)compressor:(SZArchiveCompressor *)c willAddFile:(NSString *)name;
- (void)compressor:(SZArchiveCompressor *)c scanError:(NSString *)path message:(NSString *)message;
/// 加密但未预设密码时询问；返回 nil=不加密/取消。
- (nullable NSString *)compressorAskPassword:(SZArchiveCompressor *)c;
@end

@interface SZArchiveCompressor : NSObject

- (void)compressToArchive:(NSString *)archivePath
                  options:(SZCompressOptions *)options
                 delegate:(nullable id<SZArchiveCompressDelegate>)delegate
               completion:(void (^)(BOOL ok, uint64_t archiveSize, NSString * _Nullable errorMessage))completion;

- (void)setPaused:(BOOL)paused;
@property (nonatomic, readonly, getter=isPaused) BOOL paused;
- (void)cancel;

/// 估算压缩/解压内存（移植 CompressDialog.cpp::GetMemoryUsage_Threads_Dict_DecompMem，
/// LZMA2/Deflate 分支 + 引擎同款等级→字典公式）。threads<=0 时按本机核数估算。
/// 纯函数，无需创建实例。format=nil/未知 或 等级 0 仅存储时 compressBytes 可能为 -1。
+ (SZMemoryEstimate)memoryEstimateForFormat:(nullable NSString *)format
                                      level:(NSInteger)level
                                    threads:(NSInteger)threads;

@end

NS_ASSUME_NONNULL_END
