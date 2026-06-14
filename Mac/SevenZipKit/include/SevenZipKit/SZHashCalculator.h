// SZHashCalculator.h —— 哈希计算（CRC/SHA 校验和）的 ObjC 外观（M5）。
// 公开头纯 Foundation，不暴露 7-Zip / SZHashCore 的 C++ 类型。
// 线程模型：计算在后台串行队列执行；进度/每文件结果/完成回调均 hop 主队列。哈希无阻塞式询问（无覆盖/密码）。
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

// —— 算法注册名常量（与 7zz i 的 Hashers 段一致）——
extern NSString * const SZHashMethodCRC32;
extern NSString * const SZHashMethodCRC64;
extern NSString * const SZHashMethodSHA1;
extern NSString * const SZHashMethodSHA256;
extern NSString * const SZHashMethodSHA384;
extern NSString * const SZHashMethodSHA512;
extern NSString * const SZHashMethodSHA3_256;
extern NSString * const SZHashMethodBLAKE2sp;
extern NSString * const SZHashMethodXXH64;
extern NSString * const SZHashMethodMD5;

/// 单个文件的哈希结果（小算法十六进制为大写反序数值，大算法为小写原序，对齐 7zz h）。
@interface SZHashItem : NSObject
@property (nonatomic, copy, readonly) NSString *path;                          ///< 相对显示路径
@property (nonatomic, readonly) uint64_t size;
@property (nonatomic, copy, readonly) NSDictionary<NSString *, NSString *> *hashes; ///< method → hex
- (nullable NSString *)hashForMethod:(NSString *)method;
@end

/// 一次哈希任务的汇总结果。
@interface SZHashSummary : NSObject
@property (nonatomic, readonly) BOOL ok;                                       ///< hresult==0 且 numErrors==0
@property (nonatomic, copy, readonly) NSArray<SZHashItem *> *items;
@property (nonatomic, copy, readonly) NSDictionary<NSString *, NSString *> *dataSum; ///< 数据总和（每算法）
@property (nonatomic, readonly) uint64_t numFiles;
@property (nonatomic, readonly) uint64_t numDirs;
@property (nonatomic, readonly) uint64_t numErrors;
@property (nonatomic, readonly) uint64_t totalSize;
@property (nonatomic, copy, readonly, nullable) NSString *errorMessage;
@end

@class SZHashCalculator;

@protocol SZHashDelegate <NSObject>
@optional
- (void)hashCalculator:(SZHashCalculator *)calc
     didUpdateFraction:(double)fraction
        completedBytes:(uint64_t)completed
            totalBytes:(uint64_t)total;
/// 单个文件哈希完成（供 UI 流式刷新列表）。
- (void)hashCalculator:(SZHashCalculator *)calc didFinishFile:(SZHashItem *)item;
/// 扫描/打开错误（不中断，累计 numErrors）。
- (void)hashCalculator:(SZHashCalculator *)calc didEncounterError:(NSString *)path message:(NSString *)message;
@end

/// 哈希任务执行器。一个实例可复用（但同一时刻只跑一个任务）。
@interface SZHashCalculator : NSObject

/// 支持的算法注册名（按 GUI 展示常用序）。
@property (class, nonatomic, readonly) NSArray<NSString *> *supportedMethods;

/// 计算多路径（文件/目录，目录递归）的多算法哈希。
- (void)calculateForPaths:(NSArray<NSString *> *)paths
                  methods:(NSArray<NSString *> *)methods
                 delegate:(nullable id<SZHashDelegate>)delegate
               completion:(void (^)(SZHashSummary *summary))completion;

/// 请求取消（线程安全；引擎在下一回调点返回 E_ABORT）。
- (void)cancel;

@end

NS_ASSUME_NONNULL_END
