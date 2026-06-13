// SZPanelController.m
#import "SZPanelController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>   // UTType 图标（macOS 11+，呼应 M1-T4）

NSString *const SZColID_Name     = @"name";
NSString *const SZColID_Size     = @"size";
NSString *const SZColID_Modified = @"modified";

@implementation SZPanelController {
  SZPanelModel *_model;
  __weak NSTableView *_tableView;
  NSByteCountFormatter *_sizeFmt;
  NSDateFormatter *_dateFmt;
}

- (instancetype)initWithModel:(SZPanelModel *)model {
  if ((self = [super init])) {
    _model = model;
    _sizeFmt = [NSByteCountFormatter new];
    _sizeFmt.countStyle = NSByteCountFormatterCountStyleFile;
    _dateFmt = [NSDateFormatter new];
    _dateFmt.dateFormat = @"yyyy-MM-dd HH:mm";
  }
  return self;
}

- (SZPanelModel *)model { return _model; }

#pragma mark 纯逻辑

- (NSInteger)rowCount { return (NSInteger)_model.items.count; }

- (NSString *)stringForColumn:(NSString *)columnID row:(NSInteger)row {
  if (row < 0 || row >= (NSInteger)_model.items.count) return @"";
  SZFolderItem *it = _model.items[(NSUInteger)row];
  if ([columnID isEqualToString:SZColID_Name]) return it.name;
  if ([columnID isEqualToString:SZColID_Size]) return it.isDirectory ? @"" : [_sizeFmt stringFromByteCount:(long long)it.size];
  if ([columnID isEqualToString:SZColID_Modified]) return it.modificationDate ? [_dateFmt stringFromDate:it.modificationDate] : @"";
  return @"";
}

- (NSImage *)iconForRow:(NSInteger)row {
  if (row < 0 || row >= (NSInteger)_model.items.count) return nil;
  SZFolderItem *it = _model.items[(NSUInteger)row];
  NSWorkspace *ws = NSWorkspace.sharedWorkspace;
  if (it.isDirectory) return [ws iconForContentType:UTTypeFolder];
  NSString *ext = it.name.pathExtension;
  UTType *t = ext.length ? [UTType typeWithFilenameExtension:ext] : nil;
  return [ws iconForContentType:(t ?: UTTypeData)];
}

- (BOOL)activateRow:(NSInteger)row {
  if (row < 0 || row >= (NSInteger)_model.items.count) return NO;
  if (!_model.items[(NSUInteger)row].isDirectory) return NO;   // 文件：M1 只读壳不打开内容（M2/M4）
  NSError *err = nil;
  if ([_model enterFolderAtIndex:(NSUInteger)row error:&err]) { [self reload]; return YES; }
  return NO;
}

- (BOOL)goToParent {
  NSError *err = nil;
  if (_model.canGoToParent && [_model enterParentFolder:&err]) { [self reload]; return YES; }
  return NO;
}

- (void)sortByColumnID:(NSString *)columnID {
  SZSortColumn col = SZSortColumnName;
  if ([columnID isEqualToString:SZColID_Size]) col = SZSortColumnSize;
  else if ([columnID isEqualToString:SZColID_Modified]) col = SZSortColumnModified;
  [_model sortByColumn:col];
  [self reload];
}

- (void)reload {
  [_tableView reloadData];
  if (self.onReload) self.onReload();
}

#pragma mark 地址 / 状态栏

- (NSString *)addressText {
  NSString *p = _model.currentPath;
  return p.length ? p : @"/";
}

- (NSString *)statusText {
  NSUInteger n = _model.items.count, sel = _model.selectedCount;
  NSString *base = [NSString stringWithFormat:@"%lu 项", (unsigned long)n];
  if (sel > 0) {
    NSString *sz = [_sizeFmt stringFromByteCount:(long long)_model.selectedSize];
    return [NSString stringWithFormat:@"%@，选中 %lu（%@）", base, (unsigned long)sel, sz];
  }
  return base;
}

#pragma mark NSTableView 绑定

- (void)bindTableView:(NSTableView *)tableView {
  _tableView = tableView;
  if (!tableView) return;
  tableView.dataSource = self;
  tableView.delegate = self;
  tableView.doubleAction = @selector(onDoubleClick:);
  tableView.target = self;
  [tableView reloadData];
}

- (void)onDoubleClick:(id)sender {
  NSInteger row = _tableView.clickedRow;
  if (row >= 0) [self activateRow:row];
}

#pragma mark NSTableViewDataSource / Delegate

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { return [self rowCount]; }

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
  NSString *cid = col.identifier;
  NSTableCellView *cell = [tableView makeViewWithIdentifier:cid owner:self];
  if (!cell) {
    cell = [NSTableCellView new];
    cell.identifier = cid;
    NSTextField *tf = [NSTextField labelWithString:@""];
    tf.lineBreakMode = NSLineBreakByTruncatingTail;
    cell.textField = tf;
    [cell addSubview:tf];
    tf.translatesAutoresizingMaskIntoConstraints = NO;
    if ([cid isEqualToString:SZColID_Name]) {
      NSImageView *iv = [NSImageView new];
      iv.translatesAutoresizingMaskIntoConstraints = NO;
      cell.imageView = iv;
      [cell addSubview:iv];
      [NSLayoutConstraint activateConstraints:@[
        [iv.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:2],
        [iv.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
        [iv.widthAnchor constraintEqualToConstant:16], [iv.heightAnchor constraintEqualToConstant:16],
        [tf.leadingAnchor constraintEqualToAnchor:iv.trailingAnchor constant:4],
        [tf.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-2],
        [tf.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
      ]];
    } else {
      [NSLayoutConstraint activateConstraints:@[
        [tf.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:2],
        [tf.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-2],
        [tf.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
      ]];
    }
  }
  cell.textField.stringValue = [self stringForColumn:cid row:row];
  if ([cid isEqualToString:SZColID_Name]) cell.imageView.image = [self iconForRow:row];
  return cell;
}

- (void)tableView:(NSTableView *)tableView didClickTableColumn:(NSTableColumn *)tableColumn {
  [self sortByColumnID:tableColumn.identifier];
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
  // 同步选择到 model（按当前可见行）
  [_model clearSelection];
  [_tableView.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
    [_model selectIndex:idx];
  }];
  if (self.onReload) self.onReload();   // 刷新状态栏
}

@end
