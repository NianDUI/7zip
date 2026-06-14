// SZPanelModel.mm —— 面板数据模型实现。纯 ObjC（仅依赖 SevenZipKit 公开头，不碰 7-Zip）。

#import "SevenZipKit/SZPanelModel.h"

#pragma mark - SZColumn

@interface SZColumn ()
@property (nonatomic, copy) NSString *title;
@property (nonatomic) SZSortColumn sortColumn;
@end

@implementation SZColumn
+ (instancetype)title:(NSString *)t column:(SZSortColumn)c visible:(BOOL)v width:(double)w {
  SZColumn *col = [SZColumn new];
  col.title = t; col.sortColumn = c; col.visible = v; col.width = w;
  return col;
}
@end

#pragma mark - SZPanelModel

@implementation SZPanelModel {
  SZFolderSession *_session;
  NSMutableSet<NSString *> *_selectedPaths;   // 按项路径存，排序/刷新不丢
  NSArray<SZColumn *> *_columns;
}

+ (instancetype)panelWithFileURL:(NSURL *)url error:(NSError **)error {
  SZFolderSession *session = [SZFolderSession sessionWithFileURL:url error:error];
  if (!session) return nil;
  SZPanelModel *m = [SZPanelModel new];
  m->_session = session;
  m->_selectedPaths = [NSMutableSet set];
  m->_columns = @[
    [SZColumn title:@"名称"   column:SZSortColumnName       visible:YES width:320],
    [SZColumn title:@"大小"   column:SZSortColumnSize       visible:YES width:100],
    [SZColumn title:@"修改时间" column:SZSortColumnModified   visible:YES width:160],
    [SZColumn title:@"类型"   column:SZSortColumnType       visible:NO  width:100],
    [SZColumn title:@"属性"   column:SZSortColumnAttributes visible:NO  width:100],
  ];
  return m;
}

- (NSArray<SZFolderItem *> *)items { return _session.items; }
- (NSString *)currentPath { return _session.currentPath; }
- (NSArray<SZColumn *> *)columns { return _columns; }
- (SZSortColumn)sortColumn { return _session.sortColumn; }
- (BOOL)sortAscending { return _session.sortAscending; }
- (BOOL)canGoToParent { return _session.canGoToParent; }
- (uint32_t)archiveErrorFlags { return _session.archiveErrorFlags; }
- (BOOL)canUpdate { return _session.canUpdate; }

- (BOOL)deleteItemsAtIndexes:(NSIndexSet *)indexes error:(NSError **)error {
  if (![_session deleteItemsAtIndexes:indexes error:error]) return NO;
  [_selectedPaths removeAllObjects];   // 删除后重置选择
  return YES;
}

- (BOOL)renameItemAtIndex:(NSUInteger)index toName:(NSString *)newName error:(NSError **)error {
  return [_session renameItemAtIndex:index toName:newName error:error];
}

- (BOOL)addFileAtPath:(NSString *)fsPath error:(NSError **)error {
  return [_session addFileAtPath:fsPath error:error];
}

#pragma mark 排序

- (void)sortByColumn:(SZSortColumn)column {
  BOOL ascending;
  if (column == _session.sortColumn) {
    ascending = !_session.sortAscending;                 // 同列：切换方向
  } else {
    // 新列默认方向：Size/Modified 降序，其余升序（PanelSort.cpp:264-272）
    ascending = !(column == SZSortColumnSize || column == SZSortColumnModified);
  }
  [_session setSortColumn:column ascending:ascending];
}

#pragma mark 导航

- (BOOL)enterFolderAtIndex:(NSUInteger)index error:(NSError **)error {
  if (![_session enterFolderAtIndex:index error:error]) return NO;
  [_selectedPaths removeAllObjects];                     // 新层重置选择
  return YES;
}

- (BOOL)enterParentFolder:(NSError **)error {
  if (![_session enterParentFolder:error]) return NO;
  [_selectedPaths removeAllObjects];
  return YES;
}

#pragma mark 选择（按 path 跟随）

- (BOOL)isSelectedIndex:(NSUInteger)index {
  NSArray<SZFolderItem *> *its = self.items;
  return index < its.count && [_selectedPaths containsObject:its[index].path];
}

- (void)selectIndex:(NSUInteger)index {
  NSArray<SZFolderItem *> *its = self.items;
  if (index < its.count) [_selectedPaths addObject:its[index].path];
}

- (void)deselectIndex:(NSUInteger)index {
  NSArray<SZFolderItem *> *its = self.items;
  if (index < its.count) [_selectedPaths removeObject:its[index].path];
}

- (void)toggleIndex:(NSUInteger)index {
  [self isSelectedIndex:index] ? [self deselectIndex:index] : [self selectIndex:index];
}

- (void)selectAll {
  for (SZFolderItem *it in self.items) [_selectedPaths addObject:it.path];
}

- (void)invertSelection {
  for (SZFolderItem *it in self.items) {
    if ([_selectedPaths containsObject:it.path]) [_selectedPaths removeObject:it.path];
    else                                          [_selectedPaths addObject:it.path];
  }
}

- (void)clearSelection { [_selectedPaths removeAllObjects]; }

- (NSIndexSet *)selectedIndexes {
  NSMutableIndexSet *set = [NSMutableIndexSet indexSet];
  NSArray<SZFolderItem *> *its = self.items;
  for (NSUInteger i = 0; i < its.count; i++)
    if ([_selectedPaths containsObject:its[i].path]) [set addIndex:i];
  return set;
}

- (NSUInteger)selectedCount {
  NSUInteger c = 0;
  for (SZFolderItem *it in self.items) if ([_selectedPaths containsObject:it.path]) c++;
  return c;
}

- (uint64_t)selectedSize {
  uint64_t s = 0;
  for (SZFolderItem *it in self.items) if ([_selectedPaths containsObject:it.path]) s += it.size;
  return s;
}

@end
