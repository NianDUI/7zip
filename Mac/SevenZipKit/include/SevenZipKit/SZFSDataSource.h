// SZFSDataSource.h —— 真实文件系统面板数据源（M4-T1）。adopt SZPanelSource，
// 让 7zFM 面板能像浏览归档一样浏览磁盘目录（NSFileManager 列目录 → SZFolderItem）。
// 公开头：纯 Foundation，不碰 AppKit / 7-Zip。
#import <Foundation/Foundation.h>
#import "SZPanelSource.h"
NS_ASSUME_NONNULL_BEGIN

@interface SZFSDataSource : NSObject <SZPanelSource>

/// 以某目录为当前层创建。path 不存在或非目录返回 nil。
+ (nullable instancetype)sourceWithDirectoryPath:(NSString *)path;

/// 当前目录绝对路径（= currentPath）。
@property (nonatomic, readonly, copy) NSString *directoryPath;

/// 是否隐藏点文件（默认 YES，对齐 Finder）。
@property (nonatomic) BOOL hidesDotFiles;

/// 重新读取当前目录（外部改动 / 文件操作后刷新）。
- (void)reload;

/// 在当前目录新建文件夹（M4-T4 接 UI）。
- (BOOL)createDirectoryNamed:(NSString *)name error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
