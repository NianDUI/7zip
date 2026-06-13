// SZPanelController.m
#import "SZPanelController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>   // UTType 图标（macOS 11+，呼应 M1-T4）
#import "SevenZipKit/SZArchiveExtractor.h"                  // Finder 拖出延迟解压（M2-T6）

NSString *const SZColID_Name     = @"name";
NSString *const SZColID_Size     = @"size";
NSString *const SZColID_Modified = @"modified";

@implementation SZPanelController {
  SZPanelModel *_model;
  __weak NSTableView *_tableView;
  NSByteCountFormatter *_sizeFmt;
  NSDateFormatter *_dateFmt;
  NSOperationQueue *_promiseQueue;   // file promise 后台解压队列（绝不用 mainQueue）
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
  [tableView setDraggingSourceOperationMask:NSDragOperationCopy forLocal:NO];   // 拖出到 Finder（M2-T6）
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

#pragma mark - Finder 拖出（NSFilePromiseProvider 延迟解压，M2-T6）

// 每个被拖行 → 一个 file promise；落点真正接收时才解压（writePromiseToURL）。
- (id<NSPasteboardWriting>)tableView:(NSTableView *)tableView pasteboardWriterForRow:(NSInteger)row {
  if (!self.archivePath || row < 0 || row >= (NSInteger)_model.items.count) return nil;
  SZFolderItem *it = _model.items[(NSUInteger)row];
  NSString *typeID;
  if (it.isDirectory) {
    typeID = UTTypeFolder.identifier;
  } else {
    NSString *ext = it.name.pathExtension;
    UTType *t = ext.length ? [UTType typeWithFilenameExtension:ext] : nil;
    typeID = (t ?: UTTypeData).identifier;
  }
  // 完整档内路径 = 当前层路径 + 项名（item.path 在子层是相对当前 folder，而 censor 需从根的完整路径）
  NSString *cur = _model.currentPath;
  NSString *fullPath = cur.length ? [NSString stringWithFormat:@"%@/%@", cur, it.name] : it.name;
  NSFilePromiseProvider *p = [[NSFilePromiseProvider alloc] initWithFileType:typeID delegate:self];
  p.userInfo = @{ @"path": fullPath, @"name": it.name };
  return p;
}

- (NSString *)filePromiseProvider:(NSFilePromiseProvider *)provider fileNameForType:(NSString *)fileType {
  return provider.userInfo[@"name"] ?: @"未命名";
}

- (NSOperationQueue *)operationQueueForFilePromiseProvider:(NSFilePromiseProvider *)provider {
  if (!_promiseQueue) {
    _promiseQueue = [NSOperationQueue new];
    _promiseQueue.qualityOfService = NSQualityOfServiceUserInitiated;
    _promiseQueue.maxConcurrentOperationCount = 1;  // 同一归档引擎不可并发（§2.5），串行落点
  }
  return _promiseQueue;
}

// 在后台队列：把该项解压到临时目录，再移动到落点 URL。
- (void)filePromiseProvider:(NSFilePromiseProvider *)provider
          writePromiseToURL:(NSURL *)url
          completionHandler:(void (^)(NSError * _Nullable))completionHandler {
  NSString *itemPath = provider.userInfo[@"path"];
  NSString *arch = self.archivePath;
  NSFileManager *fm = NSFileManager.defaultManager;
  NSError *err = nil;

  NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
  [fm createDirectoryAtPath:tmp withIntermediateDirectories:YES attributes:nil error:nil];

  SZArchiveExtractOptions *o = [SZArchiveExtractOptions new];
  o.outputDirectory = tmp;
  o.pathMode = SZExtractPathModeFull;                   // 保留档内结构（含目录递归内容）
  o.overwriteMode = SZExtractOverwriteModeOverwrite;
  o.selectedPaths = @[itemPath];

  SZArchiveExtractor *ex = [SZArchiveExtractor new];
  BOOL ok = [ex extractArchiveSync:arch options:o];
  if (ok) {
    NSString *src = [tmp stringByAppendingPathComponent:itemPath];  // 解压出的项本体
    [fm removeItemAtURL:url error:nil];                             // 落点已存在则先清
    if (![fm moveItemAtPath:src toPath:url.path error:&err]) {
      // 兜底：复制
      err = nil;
      [fm copyItemAtPath:src toPath:url.path error:&err];
    }
  } else {
    err = [NSError errorWithDomain:@"SZ" code:1
                          userInfo:@{NSLocalizedDescriptionKey: @"拖出解压失败"}];
  }
  [fm removeItemAtPath:tmp error:nil];
  completionHandler(err);
}

@end
