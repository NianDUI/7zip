// SZFolderSession.mm —— 归档导航的 ObjC 外观层。只依赖纯 C++ 的 SZFolderCore，
// 不 include 任何 7-Zip 头（规避 MyWindows.h `int BOOL` 与 ObjC `bool BOOL` 冲突，
// 同时落实 01-architecture.md §2.2 桥接边界单一）。本层只做 std::* → ObjC 值转换。

#import "SevenZipKit/SZFolderSession.h"
#import "SevenZipKit/SZError.h"
#include "SZFolderCore.h"     // 纯 C++，无 7-Zip 头

NSErrorDomain const SZErrorDomain = @"com.7zip.SevenZipKit";

static NSString *SZStr(const std::string &s) {
  return [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding] ?: @"";
}

#pragma mark - SZFolderItem（私有 readwrite）

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

@implementation SZFolderItem
+ (instancetype)itemFromCore:(const SZCoreItem &)c index:(NSUInteger)i {
  SZFolderItem *it = [SZFolderItem new];
  it.index = i;
  it.path = SZStr(c.path);
  it.name = SZStr(c.name);
  it.isDirectory = c.isDir;
  it.size = c.size;
  it.attributes = c.attrib;
  it.modificationDate = (c.mtime >= 0) ? [NSDate dateWithTimeIntervalSince1970:c.mtime] : nil;
  it.crc = c.hasCrc ? @(c.crc) : nil;
  return it;
}
@end

#pragma mark - SZFolderSession

@implementation SZFolderSession {
  SZFolderCore _core;
}

+ (instancetype)sessionWithFileURL:(NSURL *)url error:(NSError **)error {
  SZFolderSession *s = [SZFolderSession new];
  const int rc = s->_core.open(url.fileSystemRepresentation);
  if (rc != 0) {
    if (error) {
      SZErrorCode code = (rc == 1) ? SZErrorCannotOpenFile
                       : (rc == 2) ? SZErrorNotArchive : SZErrorHResult;
      *error = [NSError errorWithDomain:SZErrorDomain code:code
                               userInfo:@{@"SZUnderlyingHRESULT": @(rc)}];
    }
    return nil;
  }
  return s;
}

- (NSArray<SZFolderItem *> *)items {
  const std::vector<SZCoreItem> &v = _core.items();
  NSMutableArray *arr = [NSMutableArray arrayWithCapacity:v.size()];
  for (size_t i = 0; i < v.size(); i++) [arr addObject:[SZFolderItem itemFromCore:v[i] index:i]];
  return arr;
}

- (NSString *)currentPath { return SZStr(_core.currentPath()); }
- (BOOL)canGoToParent { return _core.canGoToParent(); }

- (BOOL)enterFolderAtIndex:(NSUInteger)index error:(NSError **)error {
  if (_core.enterFolderAtIndex(index)) return YES;
  if (error) *error = [NSError errorWithDomain:SZErrorDomain code:SZErrorUnknown userInfo:nil];
  return NO;
}

- (BOOL)enterParentFolder:(NSError **)error {
  if (_core.enterParentFolder()) return YES;
  if (error) *error = [NSError errorWithDomain:SZErrorDomain code:SZErrorUnknown userInfo:nil];
  return NO;
}

- (void)setFlatMode:(BOOL)flat { _core.setFlatMode(flat); }
- (uint32_t)archiveErrorFlags { return _core.archiveErrorFlags(); }
- (uint64_t)archivePhysicalSize { return _core.archivePhysicalSize(); }

@end
