// SZFolderItem_Private.h —— SZFolderItem 的 readwrite 私有接口（SevenZipKit 内部）。
// 让数据类实现（SZFolderItem.m，纯 Foundation）与归档项填充（SZFolderSession.mm）共用 setter。
#import "SevenZipKit/SZFolderItem.h"
NS_ASSUME_NONNULL_BEGIN
@interface SZFolderItem ()
@property (nonatomic) NSUInteger index;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *path;
@property (nonatomic) BOOL isDirectory;
@property (nonatomic) uint64_t size;
@property (nonatomic, nullable) NSDate *modificationDate;
@property (nonatomic) uint32_t attributes;
@property (nonatomic, nullable) NSNumber *crc;
@end
NS_ASSUME_NONNULL_END
