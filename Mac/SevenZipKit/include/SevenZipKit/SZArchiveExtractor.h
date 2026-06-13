// SZArchiveExtractor.h —— 解压任务的 ObjC 外观（M2-T1 桥接的对外 API；M2-T2 阻塞式询问机制）。
// 公开头：纯 Foundation，不暴露 7-Zip / SZExtractCore 的 C++ 类型。
// 线程模型：解压在后台串行队列执行；所有 delegate 回调与 completion 均回主队列。
// 阻塞式询问（覆盖/密码/内存）：delegate 方法在主队列被调，其返回值即答案，引擎工作线程经
// dispatch_semaphore 阻塞等待——保持 Windows「工作线程阻塞等用户答复」语义（02-core-bridge.md §5）。
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

/// 路径模式（对齐 NExtract::NPathMode；自用裁剪 CurPaths/NoPathsAlt）。
typedef NS_ENUM(NSInteger, SZExtractPathMode) {
    SZExtractPathModeFull = 0,   ///< 完整路径（默认）
    SZExtractPathModeNone,       ///< 不含路径（全部铺平到目标目录）
    SZExtractPathModeAbsolute,
};

/// 覆盖模式（对齐 NExtract::NOverwriteMode）。
typedef NS_ENUM(NSInteger, SZExtractOverwriteMode) {
    SZExtractOverwriteModeAsk = 0,        ///< 逐个询问（触发 delegate askOverwrite）
    SZExtractOverwriteModeOverwrite,
    SZExtractOverwriteModeSkip,
    SZExtractOverwriteModeRename,         ///< 自动重命名新文件
    SZExtractOverwriteModeRenameExisting, ///< 自动重命名已存在文件
};

/// 覆盖询问的答复（对齐 NOverwriteAnswer）。
typedef NS_ENUM(NSInteger, SZOverwriteResponse) {
    SZOverwriteResponseYes = 0,
    SZOverwriteResponseYesToAll,
    SZOverwriteResponseNo,
    SZOverwriteResponseNoToAll,
    SZOverwriteResponseAutoRename,
    SZOverwriteResponseCancel,
};

/// 解压选项（映射 CExtractOptions 子集）。
@interface SZArchiveExtractOptions : NSObject
@property (nonatomic, copy, nullable) NSString *outputDirectory;  ///< 目标目录；testMode 时忽略
@property (nonatomic) SZExtractPathMode pathMode;                 ///< 默认 Full
@property (nonatomic) SZExtractOverwriteMode overwriteMode;       ///< 默认 Ask
@property (nonatomic) BOOL testMode;                             ///< 测试模式（不落盘）
@property (nonatomic) BOOL eliminateDuplicatePaths;             ///< ElimDup
@property (nonatomic, copy, nullable) NSString *password;        ///< 预设密码（nil=未知，按需询问）
@property (nonatomic, copy, nullable) NSArray<NSString *> *selectedPaths; ///< 档内相对路径白名单；nil/空=全选
@end

@class SZArchiveExtractor;

@protocol SZArchiveExtractDelegate <NSObject>
@optional
// —— 进度（主队列；高频，UI 端自行节流）——
- (void)extractor:(SZArchiveExtractor *)extractor
    didUpdateFraction:(double)fraction
       completedBytes:(uint64_t)completed
           totalBytes:(uint64_t)total;
- (void)extractor:(SZArchiveExtractor *)extractor willStartFile:(NSString *)name isDirectory:(BOOL)isDir;
- (void)extractor:(SZArchiveExtractor *)extractor didFailFile:(NSString *)name message:(NSString *)message;

// —— 阻塞式询问（主队列；返回值即答案，引擎工作线程阻塞等待）——
/// 目标文件已存在。返回处理方式（…ToAll 会被引擎记住，后续不再询问）。
- (SZOverwriteResponse)extractor:(SZArchiveExtractor *)extractor
            askOverwriteExisting:(NSString *)existingPath
                       existSize:(uint64_t)existSize
                       existDate:(nullable NSDate *)existDate
                         withNew:(NSString *)newPath
                         newSize:(uint64_t)newSize
                         newDate:(nullable NSDate *)newDate;
/// 需要密码（加密档且无预设/前次密码错误）。返回 nil = 用户取消解压。
- (nullable NSString *)extractorAskPassword:(SZArchiveExtractor *)extractor;
/// 内存需求超限。返回 YES=放行继续，NO=跳过该档/中止。
- (BOOL)extractor:(SZArchiveExtractor *)extractor
    askKeepGoingOnMemoryRequired:(uint64_t)requiredBytes
                         allowed:(uint64_t)allowedBytes;
@end

/// 解压任务执行器。一个实例可复用于多次解压（但同一时刻只跑一个任务）。
@interface SZArchiveExtractor : NSObject

/// 解压单个归档（便利方法，内部转多档版）。
- (void)extractArchive:(NSString *)archivePath
               options:(SZArchiveExtractOptions *)options
              delegate:(nullable id<SZArchiveExtractDelegate>)delegate
            completion:(void (^)(BOOL ok,
                                 uint64_t numFiles,
                                 uint64_t numFileErrors,
                                 uint64_t numOpenErrors,
                                 NSString * _Nullable errorMessage))completion;

/// 解压多个归档（批量编排，统计聚合；单档失败不中断其余，M2-T5）。
- (void)extractArchives:(NSArray<NSString *> *)archivePaths
                options:(SZArchiveExtractOptions *)options
               delegate:(nullable id<SZArchiveExtractDelegate>)delegate
             completion:(void (^)(BOOL ok,
                                  uint64_t numFiles,
                                  uint64_t numFileErrors,
                                  uint64_t numOpenErrors,
                                  NSString * _Nullable errorMessage))completion;

/// 请求取消（线程安全；引擎在下一回调点返回 E_ABORT）。
- (void)cancel;

/// 暂停/继续（线程安全；引擎在下一回调点就地 sleep 轮询等待，不占 CPU、不结束任务）。
- (void)setPaused:(BOOL)paused;
@property (nonatomic, readonly, getter=isPaused) BOOL paused;

/// 同步解压（在调用线程阻塞执行，无进度回调/无询问）。供 Finder 拖出的 file promise 在后台队列直接调用。
/// 返回 ok（无错误完成）。务必在后台线程调用，勿在主线程。
- (BOOL)extractArchiveSync:(NSString *)archivePath options:(SZArchiveExtractOptions *)options;

@end

NS_ASSUME_NONNULL_END
