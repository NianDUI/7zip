// SZFolderItem.m —— 面板项数据类实现（纯 Foundation，不依赖 7-Zip / NSFileManager）。
// 归档项由 SZFolderSession.mm 经 readwrite 私有接口填充；磁盘项走 itemWithName:（SZFSDataSource 用）。
#import "SZFolderItem_Private.h"

@implementation SZFolderItem

+ (instancetype)itemWithName:(NSString *)name path:(NSString *)path
                 isDirectory:(BOOL)isDirectory size:(uint64_t)size
            modificationDate:(NSDate *)modificationDate attributes:(uint32_t)attributes {
  SZFolderItem *it = [SZFolderItem new];
  it.index = 0;                    // FS 面板用数组下标导航，不依赖此字段
  it.name = name;
  it.path = path;
  it.isDirectory = isDirectory;
  it.size = size;
  it.attributes = attributes;
  it.modificationDate = modificationDate;
  it.crc = nil;
  return it;
}

@end
