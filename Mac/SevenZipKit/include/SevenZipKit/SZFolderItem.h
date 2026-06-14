// SZFolderItem.h —— 归档"当前文件夹"内一项的元数据快照（PROPVARIANT → ObjC）。
// 公开头：纯 Foundation。属性对应 PropID.h 的 kpid*（见 02-core-bridge.md §4.3/§5）。
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

@interface SZFolderItem : NSObject

/// 当前文件夹内序号（非 IInArchive 条目号；用于 enterFolderAtIndex: 等导航，见 03-explorer-agent §2.4）。
@property (nonatomic, readonly) NSUInteger index;
@property (nonatomic, readonly, copy) NSString *name;             // 末级名（kpidName / path 末段）
@property (nonatomic, readonly, copy) NSString *path;             // 档内相对路径（kpidPath，分隔符已归一）
@property (nonatomic, readonly) BOOL isDirectory;                 // kpidIsDir
@property (nonatomic, readonly) uint64_t size;                    // kpidSize
@property (nonatomic, readonly, nullable) NSDate *modificationDate; // kpidMTime（FILETIME→NSDate，§5）
@property (nonatomic, readonly) uint32_t attributes;             // kpidAttrib（高 16 位含 UNIX st_mode）
@property (nonatomic, readonly, nullable) NSNumber *crc;          // kpidCRC（可能缺失→nil）

/// 供文件系统数据源（SZFSDataSource）构造磁盘项；归档项内部走 itemFromCore:。
+ (instancetype)itemWithName:(NSString *)name
                        path:(NSString *)path
                 isDirectory:(BOOL)isDirectory
                        size:(uint64_t)size
            modificationDate:(nullable NSDate *)modificationDate
                  attributes:(uint32_t)attributes;

@end

NS_ASSUME_NONNULL_END
