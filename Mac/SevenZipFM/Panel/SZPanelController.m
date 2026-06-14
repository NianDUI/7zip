// SZPanelController.m
#import "SZPanelController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>   // UTType 图标（macOS 11+，呼应 M1-T4）
#import "SevenZipKit/SZArchiveExtractor.h"                  // Finder 拖出延迟解压（M2-T6）+ 右键打开/解压
#import "SevenZipKit/SZFolderSession.h"                     // supportedArchiveExtensions（判定是否归档）
#import "SZQuarantine.h"                                    // quarantine 传播（M2-T7）
#import "SZExtractDialogController.h"                       // 右键解压对话框
#import "SZCompressDialogController.h"                      // 右键压缩对话框（FS 添加到归档）
#import "SZProgressWindowController.h"                      // 右键解压/测试/压缩进度窗
#import "SevenZipKit/SZArchiveCompressor.h"                // SZCompressOptions

NSString *const SZColID_Name     = @"name";
NSString *const SZColID_Size     = @"size";
NSString *const SZColID_Modified = @"modified";

@implementation SZPanelController {
  NSMutableArray<id<SZPanelSource>> *_stack;     // 数据源栈：栈底 FS，每进入归档 push 一层
  NSMutableArray<NSString *> *_archivePaths;     // 与 _stack 平行：FS 层占位 @""，归档层存归档 FS 路径
  id<SZPanelSource> _source;                     // 缓存 = _stack.lastObject
  __weak NSTableView *_tableView;
  NSByteCountFormatter *_sizeFmt;
  NSDateFormatter *_dateFmt;
  NSOperationQueue *_promiseQueue;   // file promise 后台解压队列（绝不用 mainQueue）
  SZArchiveExtractor *_openExtractor; // 右键「打开」的临时解压器（保活至完成）
}

- (instancetype)initWithSource:(id<SZPanelSource>)source {
  if ((self = [super init])) {
    _stack = [NSMutableArray arrayWithObject:source];
    _archivePaths = [NSMutableArray arrayWithObject:@""];   // 栈底 FS 占位
    _source = source;
    _sizeFmt = [NSByteCountFormatter new];
    _sizeFmt.countStyle = NSByteCountFormatterCountStyleFile;
    _dateFmt = [NSDateFormatter new];
    _dateFmt.dateFormat = @"yyyy-MM-dd HH:mm";
  }
  return self;
}

- (id<SZPanelSource>)source { return _source; }
- (NSString *)archivePath { return _source.representsArchive ? _archivePaths.lastObject : nil; }
- (BOOL)inArchive { return _source.representsArchive; }

// 进入 FS 上的归档文件：push 归档数据源（栈顶），失败弹错误。
- (BOOL)pushArchiveAtFSPath:(NSString *)fsPath {
  NSError *err = nil;
  SZPanelModel *m = [SZPanelModel panelWithFileURL:[NSURL fileURLWithPath:fsPath] error:&err];
  if (!m) {
    NSAlert *a = [NSAlert alertWithError:err ?: [NSError errorWithDomain:@"SZ" code:0 userInfo:nil]];
    a.messageText = @"无法打开归档"; [a addButtonWithTitle:@"好"]; [a runModal];
    return NO;
  }
  [_stack addObject:m];
  [_archivePaths addObject:fsPath];
  _source = m;
  [self reload];
  return YES;
}

// 扩展名是否引擎支持的归档（FS 下双击归档 / 右键解压判定）。
- (BOOL)isArchiveFile:(NSString *)path {
  NSString *ext = path.pathExtension.lowercaseString;
  if (!ext.length) return NO;
  static NSSet *exts; static dispatch_once_t once;
  dispatch_once(&once, ^{ exts = [NSSet setWithArray:[SZFolderSession supportedArchiveExtensions]]; });
  return [exts containsObject:ext];
}

#pragma mark 纯逻辑

- (NSInteger)rowCount { return (NSInteger)_source.items.count; }

- (NSString *)stringForColumn:(NSString *)columnID row:(NSInteger)row {
  if (row < 0 || row >= (NSInteger)_source.items.count) return @"";
  SZFolderItem *it = _source.items[(NSUInteger)row];
  if ([columnID isEqualToString:SZColID_Name]) return it.name;
  if ([columnID isEqualToString:SZColID_Size]) return it.isDirectory ? @"" : [_sizeFmt stringFromByteCount:(long long)it.size];
  if ([columnID isEqualToString:SZColID_Modified]) return it.modificationDate ? [_dateFmt stringFromDate:it.modificationDate] : @"";
  return @"";
}

- (NSImage *)iconForRow:(NSInteger)row {
  if (row < 0 || row >= (NSInteger)_source.items.count) return nil;
  SZFolderItem *it = _source.items[(NSUInteger)row];
  NSWorkspace *ws = NSWorkspace.sharedWorkspace;
  // FS 项有磁盘实体 → 用真实文件图标（应用图标、缩略图回退等）。
  NSString *fsPath = [_source fileSystemPathForIndex:(NSUInteger)row];
  if (fsPath) return [ws iconForFile:fsPath];
  if (it.isDirectory) return [ws iconForContentType:UTTypeFolder];
  NSString *ext = it.name.pathExtension;
  UTType *t = ext.length ? [UTType typeWithFilenameExtension:ext] : nil;
  return [ws iconForContentType:(t ?: UTTypeData)];
}

- (BOOL)activateRow:(NSInteger)row {
  if (row < 0 || row >= (NSInteger)_source.items.count) return NO;
  SZFolderItem *it = _source.items[(NSUInteger)row];
  if (it.isDirectory) {
    NSError *err = nil;
    if ([_source enterFolderAtIndex:(NSUInteger)row error:&err]) { [self reload]; return YES; }
    return NO;
  }
  // 文件：仅 FS 数据源在面板内处理（归档内文件双击留待右键「打开」解压临时）。
  if (_source.representsArchive) return NO;
  NSString *fsPath = [_source fileSystemPathForIndex:(NSUInteger)row];
  if (!fsPath) return NO;
  if ([self isArchiveFile:fsPath]) return [self pushArchiveAtFSPath:fsPath];   // 进入归档（push 栈）
  [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:fsPath]];        // 普通文件 → 系统默认程序
  return YES;
}

- (BOOL)goToParent {
  NSError *err = nil;
  if (_source.canGoToParent && [_source enterParentFolder:&err]) { [self reload]; return YES; }
  // 已在当前数据源根：若栈深 > 1，pop 回下层（归档根 → 回到归档所在 FS 目录，FS 状态保留）
  if (_stack.count > 1) {
    [_stack removeLastObject];
    [_archivePaths removeLastObject];
    _source = _stack.lastObject;
    [self reload];
    return YES;
  }
  return NO;
}

- (void)sortByColumnID:(NSString *)columnID {
  SZSortColumn col = SZSortColumnName;
  if ([columnID isEqualToString:SZColID_Size]) col = SZSortColumnSize;
  else if ([columnID isEqualToString:SZColID_Modified]) col = SZSortColumnModified;
  [_source sortByColumn:col];
  [self reload];
}

- (void)reload {
  [_tableView reloadData];
  if (self.onReload) self.onReload();
}

- (void)refresh {
  [_source refresh];
  [_tableView reloadData];
  NSIndexSet *sel = _source.selectedIndexes;   // 按 name/path 跟随后的下标
  if (sel.count) [_tableView selectRowIndexes:sel byExtendingSelection:NO];
  if (self.onReload) self.onReload();
}

- (void)createFolderInteractive {
  if (![_source respondsToSelector:@selector(createDirectoryNamed:error:)]) { NSBeep(); return; }   // 仅 FS
  NSAlert *a = [NSAlert new];
  a.messageText = @"新建文件夹"; a.informativeText = @"输入文件夹名称：";
  NSTextField *tf = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
  tf.stringValue = @"未命名文件夹"; a.accessoryView = tf;
  [a addButtonWithTitle:@"创建"]; [a addButtonWithTitle:@"取消"];
  [a.window setInitialFirstResponder:tf];
  if ([a runModal] != NSAlertFirstButtonReturn) return;
  NSString *name = tf.stringValue;
  if (!name.length) return;
  NSError *err = nil;
  if ([_source createDirectoryNamed:name error:&err]) [self reload];
  else { NSAlert *e = [NSAlert alertWithError:err]; e.messageText = @"新建失败"; [e runModal]; }
}

- (void)revealSelectionInFinder {
  NSMutableArray<NSURL *> *urls = [NSMutableArray array];
  if (_source.representsArchive) {
    if (self.archivePath) [urls addObject:[NSURL fileURLWithPath:self.archivePath]];   // 归档本身
  } else {
    [_tableView.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
      NSString *p = [self->_source fileSystemPathForIndex:i];
      if (p) [urls addObject:[NSURL fileURLWithPath:p]];
    }];
    if (urls.count == 0 && _source.currentPath.length)
      [urls addObject:[NSURL fileURLWithPath:_source.currentPath]];   // 无选中 → 当前目录
  }
  if (urls.count) [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:urls];
  else NSBeep();
}

- (void)invertSelectionInPanel {
  [_source invertSelection];
  [_tableView selectRowIndexes:_source.selectedIndexes byExtendingSelection:NO];
  if (self.onReload) self.onReload();
}

#pragma mark - 跨面板传输（M4-T5：F5 复制 / F6 移动）

- (NSString *)currentDirectoryFSPath {
  return _source.representsArchive ? nil : _source.currentPath;
}

- (NSArray<NSString *> *)selectedFileSystemPaths {
  NSMutableArray<NSString *> *a = [NSMutableArray array];
  [_tableView.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
    NSString *p = [self->_source fileSystemPathForIndex:i];
    if (p) [a addObject:p];
  }];
  return a;
}

- (void)transferSelectionToPanel:(SZPanelController *)dst move:(BOOL)move parent:(NSWindow *)parent {
  if (!dst || dst == self) { NSBeep(); return; }
  NSIndexSet *rows = _tableView.selectedRowIndexes;
  if (rows.count == 0) { NSBeep(); return; }
  const BOOL srcArc = _source.representsArchive;
  const BOOL dstArc = dst.source.representsArchive;

  // FS → FS：复制 / 移动磁盘文件
  if (!srcArc && !dstArc) {
    NSString *dstDir = [dst currentDirectoryFSPath];
    if (!dstDir) { NSBeep(); return; }
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL any = NO;
    for (NSString *src in [self selectedFileSystemPaths]) {
      NSString *to = [dstDir stringByAppendingPathComponent:src.lastPathComponent];
      if ([to isEqualToString:src]) continue;             // 同目录跳过
      [fm removeItemAtPath:to error:nil];                 // 目标同名先清（覆盖）
      NSError *e = nil;
      BOOL ok = move ? [fm moveItemAtPath:src toPath:to error:&e]
                     : [fm copyItemAtPath:src toPath:to error:&e];
      if (ok) any = YES;
      else { NSAlert *al = [NSAlert alertWithError:e]; al.messageText = move ? @"移动失败" : @"复制失败"; [al runModal]; }
    }
    if (any) { [self refresh]; [dst refresh]; }
    return;
  }

  // FS → 归档：把选中文件添加到目标归档当前层（move 暂等同 copy，不删源）
  if (!srcArc && dstArc) {
    if (!dst.source.canUpdate) { NSBeep(); return; }
    BOOL any = NO;
    for (NSString *p in [self selectedFileSystemPaths]) {
      NSError *e = nil;
      if ([dst.source addFileAtPath:p error:&e]) any = YES;
    }
    if (any) [dst refresh];
    return;
  }

  // 归档 → FS：解压选中档内项到目标目录（move 暂等同 copy，不从归档删）
  if (srcArc && !dstArc) {
    NSString *dstDir = [dst currentDirectoryFSPath];
    if (!dstDir || !self.archivePath) { NSBeep(); return; }
    SZArchiveExtractOptions *o = [SZArchiveExtractOptions new];
    o.outputDirectory = dstDir; o.pathMode = SZExtractPathModeFull;
    o.overwriteMode = SZExtractOverwriteModeOverwrite;
    o.selectedPaths = [self fullArchivePathsForRows:rows];
    __weak SZPanelController *wdst = dst;
    SZProgressWindowController *pc = [SZProgressWindowController new];
    [pc beginExtractArchive:self.archivePath options:o completion:^(BOOL ok) { if (ok) [wdst refresh]; }];
    return;
  }

  // 归档 → 归档：暂不支持
  NSAlert *a = [NSAlert new];
  a.messageText = @"暂不支持归档到归档的直接传输";
  a.informativeText = @"请先解压到文件系统再压缩。";
  [a addButtonWithTitle:@"好"]; [a runModal];
}

#pragma mark 地址 / 状态栏

- (NSString *)addressText {
  NSMutableString *s = [NSMutableString string];
  for (NSUInteger i = 0; i < _stack.count; i++) {
    id<SZPanelSource> src = _stack[i];
    if (!src.representsArchive) {
      NSString *p = src.currentPath;
      [s appendString:p.length ? p : @"/"];
    } else {
      [s appendFormat:@" › %@", _archivePaths[i].lastPathComponent];
      if (src.currentPath.length) [s appendFormat:@"/%@", src.currentPath];
    }
  }
  return s;
}

- (NSString *)statusText {
  NSUInteger n = _source.items.count, sel = _source.selectedCount;
  NSString *base = [NSString stringWithFormat:@"%lu 项", (unsigned long)n];
  if (sel > 0) {
    NSString *sz = [_sizeFmt stringFromByteCount:(long long)_source.selectedSize];
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
  [tableView registerForDraggedTypes:@[NSPasteboardTypeFileURL]];               // 接收 Finder 文件拖入（M3）
  tableView.menu = [self buildContextMenu];                                     // 右键菜单（M3-T5 GUI 接入）
  [tableView reloadData];
}

#pragma mark - 拖入接收（Finder 文件拖入 → 添加到当前层；FS=拷贝进目录，归档=添加）

- (NSDragOperation)tableView:(NSTableView *)tableView
                validateDrop:(id<NSDraggingInfo>)info
                 proposedRow:(NSInteger)row
       proposedDropOperation:(NSTableViewDropOperation)op {
  if (info.draggingSource == tableView) return NSDragOperationNone;   // 自己拖出的不接收
  if (!_source.canUpdate) return NSDragOperationNone;                 // 只读格式不可加
  [tableView setDropRow:-1 dropOperation:NSTableViewDropOn];          // 落到整个面板（当前层）
  return NSDragOperationCopy;
}

- (BOOL)tableView:(NSTableView *)tableView
       acceptDrop:(id<NSDraggingInfo>)info
              row:(NSInteger)row
    dropOperation:(NSTableViewDropOperation)op {
  if (!_source.canUpdate) return NO;
  NSArray<NSURL *> *urls = [info.draggingPasteboard
      readObjectsForClasses:@[NSURL.class]
                    options:@{NSPasteboardURLReadingFileURLsOnlyKey: @YES}];
  BOOL any = NO;
  for (NSURL *u in urls) {
    NSError *err = nil;
    if ([_source addFileAtPath:u.path error:&err]) any = YES;
  }
  if (any) [self reload];
  return any;
}

#pragma mark - 右键上下文菜单（对齐 Windows 7zFM）

- (NSMenu *)buildContextMenu {
  NSMenu *m = [[NSMenu alloc] init];
  m.autoenablesItems = NO;
  m.delegate = self;     // 右键弹出前按上下文动态构建（menuNeedsUpdate:）
  return m;
}

// 动态右键菜单：FS 选中归档 → 解压…/解压到「名/」/测试；FS 任意选中 → 压缩…；归档内 → 解压…/测试。
- (void)menuNeedsUpdate:(NSMenu *)menu {
  [menu removeAllItems];
  void (^add)(NSString *, SEL) = ^(NSString *title, SEL action) {
    NSMenuItem *it = [menu addItemWithTitle:title action:action keyEquivalent:@""];
    it.target = self;
  };
  NSInteger row = _tableView.clickedRow >= 0 ? _tableView.clickedRow : _tableView.selectedRow;
  const BOOL inArchive = _source.representsArchive;
  NSString *fsTarget = (!inArchive && row >= 0) ? [_source fileSystemPathForIndex:row] : nil;
  const BOOL targetIsArchive = fsTarget && [self isArchiveFile:fsTarget];

  add(@"打开", @selector(ctxOpen:));
  [menu addItem:[NSMenuItem separatorItem]];
  if (inArchive) {
    add(@"解压…", @selector(ctxExtract:));
    add(@"测试", @selector(ctxTest:));
  } else {
    if (targetIsArchive) {
      add(@"解压…", @selector(ctxExtract:));
      NSString *base = fsTarget.lastPathComponent.stringByDeletingPathExtension;
      NSString *destName = [self uniqueDirectoryInParent:fsTarget.stringByDeletingLastPathComponent baseName:base].lastPathComponent;
      add([NSString stringWithFormat:@"解压到 “%@/”", destName], @selector(ctxExtractToFolder:));
      add(@"测试", @selector(ctxTest:));
    }
    add(@"压缩…", @selector(ctxCompress:));
  }
  [menu addItem:[NSMenuItem separatorItem]];
  add(@"删除", @selector(ctxDelete:));
  add(@"重命名…", @selector(ctxRename:));
  [menu addItem:[NSMenuItem separatorItem]];
  add(@"属性", @selector(ctxProperties:));
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
  if (row < 0 || row >= (NSInteger)_source.items.count) return nil;
  NSString *cur = _source.currentPath, *name = _source.items[(NSUInteger)row].name;
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

// 右键作用的归档文件磁盘路径：归档数据源用 self.archivePath；FS 数据源用右键那行（须是归档文件）。
- (NSString *)contextArchiveFSPath {
  if (_source.representsArchive) return self.archivePath;
  NSInteger row = _tableView.clickedRow >= 0 ? _tableView.clickedRow : _tableView.selectedRow;
  if (row < 0) return nil;
  NSString *p = [_source fileSystemPathForIndex:(NSUInteger)row];
  return (p && [self isArchiveFile:p]) ? p : nil;
}

// 工具栏「解压/测试」目标：栈顶归档→其路径；FS→选中的归档文件。
- (NSString *)currentArchiveFSPath {
  if (_source.representsArchive) return self.archivePath;
  NSInteger row = _tableView.selectedRow;
  if (row < 0) return nil;
  NSString *p = [_source fileSystemPathForIndex:(NSUInteger)row];
  return (p && [self isArchiveFile:p]) ? p : nil;
}

- (NSWindow *)win { return _tableView.window; }

// —— 打开：目录则进入；FS 文件走系统打开/进归档；归档内文件解压临时 + 系统打开 ——
- (void)ctxOpen:(id)sender {
  NSInteger row = _tableView.clickedRow >= 0 ? _tableView.clickedRow : _tableView.selectedRow;
  if (row < 0) return;
  SZFolderItem *it = _source.items[(NSUInteger)row];
  if (it.isDirectory || !_source.representsArchive) { [self activateRow:row]; return; }

  if (!self.archivePath) return;
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

// —— 解压…：归档内=限定选中项；FS=右键归档文件整档 ——
- (void)ctxExtract:(id)sender {
  NSString *arc = [self contextArchiveFSPath];
  if (!arc) { NSBeep(); return; }
  NSArray<NSString *> *sel = _source.representsArchive ? [self fullArchivePathsForRows:[self contextTargetRows]] : @[];
  NSString *dest = arc.stringByDeletingLastPathComponent;
  __weak typeof(self) ws = self;
  [SZExtractDialogController presentForArchive:arc.lastPathComponent
                            defaultDestination:dest parentWindow:[self win]
                                    completion:^(SZArchiveExtractOptions *o) {
    if (!o) return;
    if (sel.count) o.selectedPaths = sel;   // 空=整档
    SZProgressWindowController *pc = [SZProgressWindowController new];
    [pc beginExtractArchive:arc options:o completion:^(BOOL ok) { if (ok) [ws refresh]; }];
  }];
}

// 当前目录下不与现有项冲突的目标文件夹路径：base →「base」→「base 1」→「base 2」…
- (NSString *)uniqueDirectoryInParent:(NSString *)parent baseName:(NSString *)base {
  NSFileManager *fm = NSFileManager.defaultManager;
  NSString *candidate = [parent stringByAppendingPathComponent:base];
  NSUInteger n = 1;
  while ([fm fileExistsAtPath:candidate])
    candidate = [parent stringByAppendingPathComponent:[NSString stringWithFormat:@"%@ %lu", base, (unsigned long)n++]];
  return candidate;
}

// —— 解压到「<归档名>/」：解压到同名子文件夹；若已存在则用「名 1」「名 2」…新文件夹，绝不覆盖 ——
- (void)ctxExtractToFolder:(id)sender {
  NSString *arc = [self contextArchiveFSPath];
  if (!arc) { NSBeep(); return; }
  NSString *parent = arc.stringByDeletingLastPathComponent;
  NSString *base = arc.lastPathComponent.stringByDeletingPathExtension;
  NSString *dest = [self uniqueDirectoryInParent:parent baseName:base];
  [NSFileManager.defaultManager createDirectoryAtPath:dest withIntermediateDirectories:YES attributes:nil error:nil];
  SZArchiveExtractOptions *o = [SZArchiveExtractOptions new];
  o.outputDirectory = dest;
  o.pathMode = SZExtractPathModeFull;
  o.overwriteMode = SZExtractOverwriteModeOverwrite;   // 全新空目录，无冲突
  __weak typeof(self) ws = self;
  SZProgressWindowController *pc = [SZProgressWindowController new];
  [pc beginExtractArchive:arc options:o completion:^(BOOL ok) { if (ok) [ws refresh]; }];
}

// —— 压缩…：把 FS 选中的文件/文件夹压缩成归档（弹压缩对话框）——
- (void)ctxCompress:(id)sender {
  if (_source.representsArchive) { NSBeep(); return; }   // 归档内不支持
  NSIndexSet *rows = [self contextTargetRows];
  if (rows.count == 0) { NSBeep(); return; }
  NSMutableArray<NSString *> *inputs = [NSMutableArray array];
  [rows enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
    NSString *p = [self->_source fileSystemPathForIndex:i];
    if (p) [inputs addObject:p];
  }];
  if (inputs.count == 0) { NSBeep(); return; }
  NSString *first = inputs.firstObject;
  NSString *dir = first.stringByDeletingLastPathComponent;
  NSString *base = (inputs.count == 1) ? first.lastPathComponent.stringByDeletingPathExtension
                                       : dir.lastPathComponent;
  if (!base.length) base = @"archive";
  NSString *defArc = [dir stringByAppendingPathComponent:[base stringByAppendingPathExtension:@"7z"]];
  __weak typeof(self) ws = self;
  [SZCompressDialogController presentForInputs:inputs defaultArchivePath:defArc parentWindow:[self win]
                                    completion:^(NSString *archivePath, SZCompressOptions *options) {
    if (!archivePath || !options) return;
    SZProgressWindowController *pc = [SZProgressWindowController new];
    [pc beginCompressToArchive:archivePath options:options completion:^(BOOL ok) { if (ok) [ws refresh]; }];
  }];
}

- (void)ctxTest:(id)sender {
  NSString *arc = [self contextArchiveFSPath];
  if (!arc) { NSBeep(); return; }
  SZProgressWindowController *pc = [SZProgressWindowController new];
  [pc beginTestArchive:arc password:nil completion:nil];
}

// —— 删除（归档 M3-T5 / FS：移到废纸篓）——
- (void)deleteRows:(NSIndexSet *)rows {
  if (rows.count == 0) { NSBeep(); return; }
  if (!_source.canUpdate) {
    NSAlert *a = [NSAlert new];
    a.messageText = @"该归档格式不支持修改"; [a addButtonWithTitle:@"好"]; [a runModal]; return;
  }
  NSAlert *c = [NSAlert new];
  c.messageText = [NSString stringWithFormat:@"删除选中的 %lu 项？", (unsigned long)rows.count];
  c.informativeText = _source.representsArchive ? @"此操作会重写归档，无法撤销。" : @"文件将移到废纸篓。";
  [c addButtonWithTitle:@"删除"]; [c addButtonWithTitle:@"取消"];
  if ([c runModal] != NSAlertFirstButtonReturn) return;
  NSError *err = nil;
  if ([_source deleteItemsAtIndexes:rows error:&err]) [self reload];
  else { NSAlert *a = [NSAlert alertWithError:err]; a.messageText = @"删除失败"; [a runModal]; }
}

- (void)ctxDelete:(id)sender { [self deleteRows:[self contextTargetRows]]; }            // 右键
- (void)deleteSelectionInteractive { [self deleteRows:_tableView.selectedRowIndexes]; }  // Cmd+Delete / 菜单

// —— 重命名（归档 M3-T5 / FS M4-T1）——
- (void)ctxRename:(id)sender {
  NSInteger row = _tableView.clickedRow >= 0 ? _tableView.clickedRow : _tableView.selectedRow;
  if (row < 0) return;
  if (!_source.canUpdate) {
    NSAlert *a = [NSAlert new];
    a.messageText = @"该归档格式不支持修改"; [a addButtonWithTitle:@"好"]; [a runModal]; return;
  }
  SZFolderItem *it = _source.items[(NSUInteger)row];
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
  if ([_source renameItemAtIndex:(NSUInteger)row toName:newName error:&err]) [self reload];
  else { NSAlert *e = [NSAlert alertWithError:err]; e.messageText = @"重命名失败"; [e runModal]; }
}

- (void)ctxProperties:(id)sender {
  NSInteger row = _tableView.clickedRow >= 0 ? _tableView.clickedRow : _tableView.selectedRow;
  if (row < 0) return;
  SZFolderItem *it = _source.items[(NSUInteger)row];
  NSMutableString *s = [NSMutableString string];
  [s appendFormat:@"名称：%@\n", it.name];
  [s appendFormat:@"类型：%@\n", it.isDirectory ? @"文件夹" : @"文件"];
  if (!it.isDirectory) [s appendFormat:@"大小：%@\n", [_sizeFmt stringFromByteCount:(long long)it.size]];
  if (it.modificationDate) [s appendFormat:@"修改时间：%@\n", [_dateFmt stringFromDate:it.modificationDate]];
  NSString *fsPath = [_source fileSystemPathForIndex:(NSUInteger)row];
  if (fsPath) [s appendFormat:@"路径：%@\n", fsPath];
  NSAlert *a = [NSAlert new];
  a.messageText = @"属性"; a.informativeText = s;
  [a addButtonWithTitle:@"好"]; [a runModal];
}

// 菜单项启用控制：删除/重命名仅在可更新时启用；解压/测试需有目标归档。
- (BOOL)validateMenuItem:(NSMenuItem *)item {
  if (item.action == @selector(ctxDelete:) || item.action == @selector(ctxRename:))
    return _source.canUpdate;
  if (item.action == @selector(ctxExtract:) || item.action == @selector(ctxTest:))
    return [self contextArchiveFSPath] != nil;
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
  // 同步选择到 source（按当前可见行）
  [_source clearSelection];
  [_tableView.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
    [_source selectIndex:idx];
  }];
  if (self.onReload) self.onReload();   // 刷新状态栏
}

#pragma mark - Finder 拖出（FS=直接文件 URL；归档=NSFilePromiseProvider 延迟解压 M2-T6）

- (id<NSPasteboardWriting>)tableView:(NSTableView *)tableView pasteboardWriterForRow:(NSInteger)row {
  if (row < 0 || row >= (NSInteger)_source.items.count) return nil;
  if (!_source.representsArchive) {
    NSString *fsPath = [_source fileSystemPathForIndex:(NSUInteger)row];
    return fsPath ? [NSURL fileURLWithPath:fsPath] : nil;   // FS 项直接拖文件 URL
  }
  if (!self.archivePath) return nil;
  SZFolderItem *it = _source.items[(NSUInteger)row];
  NSString *typeID;
  if (it.isDirectory) {
    typeID = UTTypeFolder.identifier;
  } else {
    NSString *ext = it.name.pathExtension;
    UTType *t = ext.length ? [UTType typeWithFilenameExtension:ext] : nil;
    typeID = (t ?: UTTypeData).identifier;
  }
  // 完整档内路径 = 当前层路径 + 项名（item.path 在子层是相对当前 folder，而 censor 需从根的完整路径）
  NSString *cur = _source.currentPath;
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
