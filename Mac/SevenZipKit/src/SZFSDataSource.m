// SZFSDataSource.m —— 见 .h。纯 ObjC（NSFileManager），不碰 7-Zip / AppKit。
// 选择按 name 跟随（当前目录内 name 唯一）；排序规则与归档面板一致（目录恒在前，自然序）。
#import "SevenZipKit/SZFSDataSource.h"

@implementation SZFSDataSource {
  NSString *_dir;                          // 当前目录绝对路径
  NSArray<SZFolderItem *> *_items;         // 已排序快照
  NSMutableSet<NSString *> *_selectedNames;
  SZSortColumn _sortColumn;
  BOOL _sortAscending;
}

+ (instancetype)sourceWithDirectoryPath:(NSString *)path {
  NSString *std = path.stringByStandardizingPath;
  BOOL isDir = NO;
  if (![NSFileManager.defaultManager fileExistsAtPath:std isDirectory:&isDir] || !isDir) return nil;
  SZFSDataSource *s = [SZFSDataSource new];
  s->_dir = [std copy];
  s->_selectedNames = [NSMutableSet set];
  s->_sortColumn = SZSortColumnName;
  s->_sortAscending = YES;
  s->_hidesDotFiles = YES;
  [s reload];
  return s;
}

#pragma mark 列表 / 地址

- (NSString *)directoryPath { return _dir; }
- (NSString *)currentPath { return _dir; }
- (BOOL)representsArchive { return NO; }
- (BOOL)canUpdate { return YES; }
- (NSArray<SZFolderItem *> *)items { return _items; }
- (SZSortColumn)sortColumn { return _sortColumn; }
- (BOOL)sortAscending { return _sortAscending; }

- (NSString *)fileSystemPathForIndex:(NSUInteger)index {
  if (index >= _items.count) return nil;
  return [_dir stringByAppendingPathComponent:_items[index].name];
}

- (void)reload {
  NSFileManager *fm = NSFileManager.defaultManager;
  NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:_dir error:NULL] ?: @[];
  NSMutableArray<SZFolderItem *> *arr = [NSMutableArray arrayWithCapacity:names.count];
  for (NSString *name in names) {
    if (_hidesDotFiles && [name hasPrefix:@"."]) continue;
    NSString *full = [_dir stringByAppendingPathComponent:name];
    BOOL isDir = NO;
    [fm fileExistsAtPath:full isDirectory:&isDir];          // 跟随符号链接判目标是否目录（双击行为符合直觉）
    NSDictionary<NSFileAttributeKey, id> *at = [fm attributesOfItemAtPath:full error:NULL];
    uint64_t size = isDir ? 0 : [at[NSFileSize] unsignedLongLongValue];
    NSDate *mtime = at[NSFileModificationDate];
    uint32_t attrib = [at[NSFilePosixPermissions] unsignedIntValue];   // 低位存 POSIX 权限（属性列展示）
    [arr addObject:[SZFolderItem itemWithName:name path:name isDirectory:isDir
                                         size:size modificationDate:mtime attributes:attrib]];
  }
  _items = [self sortedItems:arr];
}

- (void)refresh { [self reload]; }   // _selectedNames 不清，选择按 name 跟随

#pragma mark 排序

- (NSArray<SZFolderItem *> *)sortedItems:(NSArray<SZFolderItem *> *)arr {
  const SZSortColumn col = _sortColumn;
  const BOOL asc = _sortAscending;
  return [arr sortedArrayUsingComparator:^NSComparisonResult(SZFolderItem *a, SZFolderItem *b) {
    if (a.isDirectory != b.isDirectory)                       // 目录恒在文件前（不受方向影响）
      return a.isDirectory ? NSOrderedAscending : NSOrderedDescending;
    NSComparisonResult r;
    switch (col) {
      case SZSortColumnSize:
        r = (a.size < b.size) ? NSOrderedAscending : (a.size > b.size ? NSOrderedDescending : NSOrderedSame);
        break;
      case SZSortColumnModified:
        r = [(a.modificationDate ?: NSDate.distantPast) compare:(b.modificationDate ?: NSDate.distantPast)];
        break;
      default:
        r = [a.name localizedStandardCompare:b.name];
        break;
    }
    if (r == NSOrderedSame) r = [a.name localizedStandardCompare:b.name];   // 次级稳定键
    if (asc) return r;
    return r == NSOrderedAscending ? NSOrderedDescending
         : r == NSOrderedDescending ? NSOrderedAscending : NSOrderedSame;
  }];
}

- (void)sortByColumn:(SZSortColumn)column {
  if (column == _sortColumn) {
    _sortAscending = !_sortAscending;
  } else {
    _sortColumn = column;
    _sortAscending = !(column == SZSortColumnSize || column == SZSortColumnModified);
  }
  _items = [self sortedItems:_items];
}

#pragma mark 导航

- (BOOL)canGoToParent { return ![_dir isEqualToString:@"/"]; }

- (BOOL)enterFolderAtIndex:(NSUInteger)index error:(NSError **)error {
  if (index >= _items.count || !_items[index].isDirectory) return NO;
  NSString *target = [_dir stringByAppendingPathComponent:_items[index].name];
  BOOL isDir = NO;
  if (![NSFileManager.defaultManager fileExistsAtPath:target isDirectory:&isDir] || !isDir) return NO;
  _dir = [target copy];
  [_selectedNames removeAllObjects];
  [self reload];
  return YES;
}

- (BOOL)enterParentFolder:(NSError **)error {
  if (![self canGoToParent]) return NO;
  NSString *parent = _dir.stringByDeletingLastPathComponent;
  _dir = parent.length ? [parent copy] : @"/";
  [_selectedNames removeAllObjects];
  [self reload];
  return YES;
}

#pragma mark 选择（按 name 跟随）

- (BOOL)isSelectedIndex:(NSUInteger)index {
  return index < _items.count && [_selectedNames containsObject:_items[index].name];
}
- (void)selectIndex:(NSUInteger)index {
  if (index < _items.count) [_selectedNames addObject:_items[index].name];
}
- (void)deselectIndex:(NSUInteger)index {
  if (index < _items.count) [_selectedNames removeObject:_items[index].name];
}
- (void)toggleIndex:(NSUInteger)index {
  [self isSelectedIndex:index] ? [self deselectIndex:index] : [self selectIndex:index];
}
- (void)selectAll {
  for (SZFolderItem *it in _items) [_selectedNames addObject:it.name];
}
- (void)invertSelection {
  for (SZFolderItem *it in _items) {
    if ([_selectedNames containsObject:it.name]) [_selectedNames removeObject:it.name];
    else                                         [_selectedNames addObject:it.name];
  }
}
- (void)clearSelection { [_selectedNames removeAllObjects]; }

- (NSIndexSet *)selectedIndexes {
  NSMutableIndexSet *set = [NSMutableIndexSet indexSet];
  for (NSUInteger i = 0; i < _items.count; i++)
    if ([_selectedNames containsObject:_items[i].name]) [set addIndex:i];
  return set;
}
- (NSUInteger)selectedCount {
  NSUInteger c = 0;
  for (SZFolderItem *it in _items) if ([_selectedNames containsObject:it.name]) c++;
  return c;
}
- (uint64_t)selectedSize {
  uint64_t s = 0;
  for (SZFolderItem *it in _items) if ([_selectedNames containsObject:it.name]) s += it.size;
  return s;
}

#pragma mark 写操作（M4-T1 最小实现，M4-T4 接 UI 与跨面板）

- (BOOL)deleteItemsAtIndexes:(NSIndexSet *)indexes error:(NSError **)error {
  NSFileManager *fm = NSFileManager.defaultManager;
  NSMutableArray<NSString *> *paths = [NSMutableArray array];   // 先收集路径，避免删一个后下标漂移
  [indexes enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
    if (i < self->_items.count) [paths addObject:[self->_dir stringByAppendingPathComponent:self->_items[i].name]];
  }];
  BOOL ok = YES;
  for (NSString *p in paths) {
    NSError *e = nil;
    if (![fm trashItemAtURL:[NSURL fileURLWithPath:p] resultingItemURL:nil error:&e]) {
      ok = NO; if (error) *error = e;
    }
  }
  [_selectedNames removeAllObjects];
  [self reload];
  return ok;
}

- (BOOL)renameItemAtIndex:(NSUInteger)index toName:(NSString *)newName error:(NSError **)error {
  if (index >= _items.count) return NO;
  NSString *src = [_dir stringByAppendingPathComponent:_items[index].name];
  NSString *dst = [_dir stringByAppendingPathComponent:newName];
  if (![NSFileManager.defaultManager moveItemAtPath:src toPath:dst error:error]) return NO;
  [self reload];
  return YES;
}

- (BOOL)addFileAtPath:(NSString *)fsPath error:(NSError **)error {
  NSString *dst = [_dir stringByAppendingPathComponent:fsPath.lastPathComponent];
  if ([dst isEqualToString:fsPath.stringByStandardizingPath]) return YES;   // 同目录拖入自身，忽略
  if (![NSFileManager.defaultManager copyItemAtPath:fsPath toPath:dst error:error]) return NO;
  [self reload];
  return YES;
}

- (BOOL)createDirectoryNamed:(NSString *)name error:(NSError **)error {
  NSString *dst = [_dir stringByAppendingPathComponent:name];
  if (![NSFileManager.defaultManager createDirectoryAtPath:dst withIntermediateDirectories:NO
                                                attributes:nil error:error]) return NO;
  [self reload];
  return YES;
}

@end
