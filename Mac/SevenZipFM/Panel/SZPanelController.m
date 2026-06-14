// SZPanelController.m
#import "SZPanelController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>   // UTType 图标（macOS 11+，呼应 M1-T4）
#import "SevenZipKit/SZArchiveExtractor.h"                  // Finder 拖出延迟解压（M2-T6）+ 右键打开/解压
#import "SZQuarantine.h"                                    // quarantine 传播（M2-T7）
#import "SZExtractDialogController.h"                       // 右键解压对话框
#import "SZProgressWindowController.h"                      // 右键解压/测试进度窗

NSString *const SZColID_Name     = @"name";
NSString *const SZColID_Size     = @"size";
NSString *const SZColID_Modified = @"modified";

@implementation SZPanelController {
  SZPanelModel *_model;
  __weak NSTableView *_tableView;
  NSByteCountFormatter *_sizeFmt;
  NSDateFormatter *_dateFmt;
  NSOperationQueue *_promiseQueue;   // file promise 后台解压队列（绝不用 mainQueue）
  SZArchiveExtractor *_openExtractor; // 右键「打开」的临时解压器（保活至完成）
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
  tableView.menu = [self buildContextMenu];                                     // 右键菜单（M3-T5 GUI 接入）
  [tableView reloadData];
}

#pragma mark - 右键上下文菜单（对齐 Windows 7zFM 归档内右键）

- (NSMenu *)buildContextMenu {
  NSMenu *m = [[NSMenu alloc] init];
  m.autoenablesItems = NO;
  void (^add)(NSString *, SEL) = ^(NSString *title, SEL action) {
    NSMenuItem *it = [m addItemWithTitle:title action:action keyEquivalent:@""];
    it.target = self;
  };
  add(@"打开", @selector(ctxOpen:));
  add(@"解压…", @selector(ctxExtract:));
  add(@"测试", @selector(ctxTest:));
  [m addItem:[NSMenuItem separatorItem]];
  add(@"删除", @selector(ctxDelete:));
  add(@"重命名…", @selector(ctxRename:));
  [m addItem:[NSMenuItem separatorItem]];
  add(@"属性", @selector(ctxProperties:));
  return m;
}

// 右键目标行：clickedRow 在选中集则用整个选中集，否则用 clickedRow 单行
- (NSIndexSet *)contextTargetRows {
  NSInteger clicked = _tableView.clickedRow;
  NSIndexSet *sel = _tableView.selectedRowIndexes;
  if (clicked >= 0 && [sel containsIndex:(NSUInteger)clicked]) return sel;
  if (clicked >= 0) return [NSIndexSet indexSetWithIndex:(NSUInteger)clicked];
  return sel;
}

- (NSString *)fullArchivePathForRow:(NSInteger)row {
  if (row < 0 || row >= (NSInteger)_model.items.count) return nil;
  NSString *cur = _model.currentPath, *name = _model.items[(NSUInteger)row].name;
  return cur.length ? [NSString stringWithFormat:@"%@/%@", cur, name] : name;
}

- (NSArray<NSString *> *)fullArchivePathsForRows:(NSIndexSet *)rows {
  NSMutableArray *a = [NSMutableArray array];
  [rows enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
    NSString *p = [self fullArchivePathForRow:(NSInteger)i];
    if (p) [a addObject:p];
  }];
  return a;
}

- (NSWindow *)win { return _tableView.window; }

// —— 打开：目录则进入；文件则解压到临时 + 系统默认程序打开（="打开方式"效果）——
- (void)ctxOpen:(id)sender {
  NSInteger row = _tableView.clickedRow >= 0 ? _tableView.clickedRow : _tableView.selectedRow;
  if (row < 0 || !self.archivePath) return;
  SZFolderItem *it = _model.items[(NSUInteger)row];
  if (it.isDirectory) { if ([self activateRow:row]) [self reload]; return; }

  NSString *fullPath = [self fullArchivePathForRow:row];
  NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
  [NSFileManager.defaultManager createDirectoryAtPath:tmp withIntermediateDirectories:YES attributes:nil error:nil];
  SZArchiveExtractOptions *o = [SZArchiveExtractOptions new];
  o.outputDirectory = tmp; o.pathMode = SZExtractPathModeFull;
  o.overwriteMode = SZExtractOverwriteModeOverwrite; o.selectedPaths = @[fullPath];

  NSString *extracted = [tmp stringByAppendingPathComponent:fullPath];
  __weak typeof(self) ws = self;
  _openExtractor = [SZArchiveExtractor new];
  [_openExtractor extractArchive:self.archivePath options:o delegate:nil
                      completion:^(BOOL ok, uint64_t nf, uint64_t nfe, uint64_t noe, NSString *em) {
    if (ok) [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:extracted]];
    typeof(self) ss = ws;
    if (ss) ss->_openExtractor = nil;
  }];
}

// —— 解压…：弹解压对话框，限定选中项 ——
- (void)ctxExtract:(id)sender {
  if (!self.archivePath) return;
  NSArray<NSString *> *sel = [self fullArchivePathsForRows:[self contextTargetRows]];
  NSString *dest = self.archivePath.stringByDeletingLastPathComponent;
  [SZExtractDialogController presentForArchive:self.archivePath.lastPathComponent
                            defaultDestination:dest parentWindow:[self win]
                                    completion:^(SZArchiveExtractOptions *o) {
    if (!o) return;
    if (sel.count) o.selectedPaths = sel;   // 空=整档
    SZProgressWindowController *pc = [SZProgressWindowController new];
    [pc beginExtractArchive:self.archivePath options:o completion:nil];
  }];
}

- (void)ctxTest:(id)sender {
  if (!self.archivePath) return;
  SZProgressWindowController *pc = [SZProgressWindowController new];
  [pc beginTestArchive:self.archivePath password:nil completion:nil];
}

// —— 删除（M3-T5）——
- (void)ctxDelete:(id)sender {
  NSIndexSet *rows = [self contextTargetRows];
  if (rows.count == 0) return;
  if (!_model.canUpdate) {
    NSAlert *a = [NSAlert new];
    a.messageText = @"该归档格式不支持修改"; [a addButtonWithTitle:@"好"]; [a runModal]; return;
  }
  NSAlert *c = [NSAlert new];
  c.messageText = [NSString stringWithFormat:@"删除选中的 %lu 项？", (unsigned long)rows.count];
  c.informativeText = @"此操作会重写归档，无法撤销。";
  [c addButtonWithTitle:@"删除"]; [c addButtonWithTitle:@"取消"];
  if ([c runModal] != NSAlertFirstButtonReturn) return;
  NSError *err = nil;
  if ([_model deleteItemsAtIndexes:rows error:&err]) [self reload];
  else { NSAlert *a = [NSAlert alertWithError:err]; a.messageText = @"删除失败"; [a runModal]; }
}

// —— 重命名（M3-T5）——
- (void)ctxRename:(id)sender {
  NSInteger row = _tableView.clickedRow >= 0 ? _tableView.clickedRow : _tableView.selectedRow;
  if (row < 0) return;
  if (!_model.canUpdate) {
    NSAlert *a = [NSAlert new];
    a.messageText = @"该归档格式不支持修改"; [a addButtonWithTitle:@"好"]; [a runModal]; return;
  }
  SZFolderItem *it = _model.items[(NSUInteger)row];
  NSAlert *a = [NSAlert new];
  a.messageText = @"重命名"; a.informativeText = @"输入新名称：";
  NSTextField *tf = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
  tf.stringValue = it.name; a.accessoryView = tf;
  [a addButtonWithTitle:@"确定"]; [a addButtonWithTitle:@"取消"];
  [a.window setInitialFirstResponder:tf];
  if ([a runModal] != NSAlertFirstButtonReturn) return;
  NSString *newName = tf.stringValue;
  if (!newName.length || [newName isEqualToString:it.name]) return;
  NSError *err = nil;
  if ([_model renameItemAtIndex:(NSUInteger)row toName:newName error:&err]) [self reload];
  else { NSAlert *e = [NSAlert alertWithError:err]; e.messageText = @"重命名失败"; [e runModal]; }
}

- (void)ctxProperties:(id)sender {
  NSInteger row = _tableView.clickedRow >= 0 ? _tableView.clickedRow : _tableView.selectedRow;
  if (row < 0) return;
  SZFolderItem *it = _model.items[(NSUInteger)row];
  NSMutableString *s = [NSMutableString string];
  [s appendFormat:@"名称：%@\n", it.name];
  [s appendFormat:@"类型：%@\n", it.isDirectory ? @"文件夹" : @"文件"];
  if (!it.isDirectory) [s appendFormat:@"大小：%@\n", [_sizeFmt stringFromByteCount:(long long)it.size]];
  if (it.modificationDate) [s appendFormat:@"修改时间：%@\n", [_dateFmt stringFromDate:it.modificationDate]];
  NSAlert *a = [NSAlert new];
  a.messageText = @"属性"; a.informativeText = s;
  [a addButtonWithTitle:@"好"]; [a runModal];
}

// 菜单项启用控制：删除/重命名仅在可更新时启用
- (BOOL)validateMenuItem:(NSMenuItem *)item {
  if (item.action == @selector(ctxDelete:) || item.action == @selector(ctxRename:))
    return _model.canUpdate;
  return YES;
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
    if (!err) SZApplyQuarantineFrom(arch, url.path);                // 网络来源标记传播（M2-T7）
  } else {
    err = [NSError errorWithDomain:@"SZ" code:1
                          userInfo:@{NSLocalizedDescriptionKey: @"拖出解压失败"}];
  }
  [fm removeItemAtPath:tmp error:nil];
  completionHandler(err);
}

@end
