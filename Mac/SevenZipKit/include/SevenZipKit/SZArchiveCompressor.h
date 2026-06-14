// SZArchiveCompressor.h —— 压缩任务的 ObjC 外观（M3-T2/T4）。对称 SZArchiveExtractor。
// 公开头纯 Foundation；压缩跑后台串行队列，回调/completion 回主队列。命名 SZArchive* 避开系统类。
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

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

@end

NS_ASSUME_NONNULL_END
