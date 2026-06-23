// SZAppDelegate.m —— 主窗口：双面板（左右各一个独立 SZPanelController + 数据源栈）。
// M4-T5：FAR 风格双面板。活动面板高亮 + Tab 切换；菜单/工具栏作用于活动面板。
#import "SZAppDelegate.h"
#import "SZPanelController.h"
#import "SZProgressWindowController.h"
#import "SZExtractDialogController.h"
#import "SZCompressDialogController.h"
#import "SZHashResultController.h"
#import "SZFileAssocController.h"
#import "SZEditWatcher.h"
#import "SZShellCommand.h"
#import "SevenZipKit/SZPanelModel.h"
#import "SevenZipKit/SZFSDataSource.h"
#import "SevenZipKit/SZFolderSession.h"
#import "SevenZipKit/SZArchiveExtractor.h"
#import "SevenZipKit/SZArchiveCompressor.h"

#pragma mark - 键盘可达 + 焦点感知的 NSTableView

@interface SZTableView : NSTableView
@property (nonatomic, weak) SZPanelController *panel;
@property (nonatomic, copy) void (^onNavigate)(void);
@property (nonatomic, copy) void (^onActivate)(void);   // 成为 first responder（点击/Tab）
@property (nonatomic, copy) void (^onTab)(void);         // Tab → 切换到另一面板
@end

@implementation SZTableView
- (BOOL)becomeFirstResponder {
  BOOL ok = [super becomeFirstResponder];
  if (ok && _onActivate) _onActivate();
  return ok;
}
- (void)keyDown:(NSEvent *)e {
  const unsigned short k = e.keyCode;
  if (k == 48) { if (_onTab) { _onTab(); return; } }   // Tab → 切面板
  if (k == 51 || k == 117) {                            // Backspace / Delete
    if (e.modifierFlags & NSEventModifierFlagCommand) { [_panel deleteSelectionInteractive]; }
    else if ([_panel goToParent] && _onNavigate) _onNavigate();
    return;
  }
  if (k == 36 || k == 76) {                             // Return / Enter
    NSInteger r = self.selectedRow;
    if (r >= 0 && [_panel activateRow:r] && _onNavigate) _onNavigate();
    return;
  }
  [super keyDown:e];
}
@end

#pragma mark - AppDelegate

@implementation SZAppDelegate {
  NSWindow *_window;
  SZTableView *_table[2];
  SZPanelController *_panel[2];
  NSTextField *_addr[2];
  NSView *_panelView[2];
  NSTextField *_status;
  int _activeSide;   // 0=左 1=右
  BOOL _twoPanels;
  NSArray<NSLayoutConstraint *> *_dualConstraints;   // 双面板专属（右面板就位 + 左右等宽）
  NSArray<NSLayoutConstraint *> *_soloConstraints;   // 单面板专属（左面板 trailing 撑满）
  NSMutableArray<NSURL *> *_pendingURLs;   // 冷启动时 openURLs 早于面板就绪 → 先缓存，didFinishLaunching 后执行
  BOOL _launched;
  BOOL _mainWindowEverShown;   // 主文件管理器窗口是否曾对用户显示（决定 Finder 右键一次性操作完成后是否退出 app）
  NSInteger _liveShellOps;     // 进行中的 Finder 右键一次性操作数（解压/压缩/测试/校验和）
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
  _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1040, 520)
      styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                 NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable)
      backing:NSBackingStoreBuffered defer:NO];
  _window.title = @"7-Zip";
  _window.frameAutosaveName = @"SZMainWindow";
  [_window center];

  _status = [NSTextField labelWithString:@""];
  _status.font = [NSFont systemFontOfSize:11];
  _status.textColor = NSColor.secondaryLabelColor;

  NSView *leftView  = [self buildPanelSide:0];
  NSView *rightView = [self buildPanelSide:1];

  // 工具栏（作用于活动面板）
  NSButton *upBtn      = [self toolButton:@"arrow.up"            title:@"上级" action:@selector(goUp:)];
  NSButton *copyBtn    = [self toolButton:@"doc.on.doc"          title:@"复制" action:@selector(copyToOther:)];
  NSButton *moveBtn    = [self toolButton:@"arrow.right"         title:@"移动" action:@selector(moveToOther:)];
  NSButton *extractBtn = [self toolButton:@"arrow.down.doc"      title:@"解压" action:@selector(extractTo:)];
  NSButton *testBtn    = [self toolButton:@"checkmark.circle"    title:@"测试" action:@selector(testArchive:)];
  NSButton *panelsBtn  = [self toolButton:@"rectangle.split.2x1" title:@"单/双" action:@selector(toggleTwoPanels:)];
  NSStackView *topRow = [NSStackView stackViewWithViews:@[upBtn, copyBtn, moveBtn, extractBtn, testBtn, panelsBtn]];
  topRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  topRow.spacing = 8;

  // 手动约束布局：工具栏顶部横贯，状态栏底部横贯，左面板恒在；右面板按单/双切换。
  NSView *content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1040, 520)];
  for (NSView *v in @[topRow, leftView, rightView, _status]) {
    v.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:v];
  }
  const CGFloat pad = 8;
  [NSLayoutConstraint activateConstraints:@[
    [topRow.topAnchor constraintEqualToAnchor:content.topAnchor constant:pad],
    [topRow.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:pad],
    [topRow.trailingAnchor constraintLessThanOrEqualToAnchor:content.trailingAnchor constant:-pad],
    [leftView.topAnchor constraintEqualToAnchor:topRow.bottomAnchor constant:6],
    [leftView.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:pad],
    [leftView.bottomAnchor constraintEqualToAnchor:_status.topAnchor constant:-4],
    [_status.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:pad],
    [_status.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-pad],
    [_status.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-pad],
  ]];
  _dualConstraints = @[
    [rightView.topAnchor constraintEqualToAnchor:leftView.topAnchor],
    [rightView.leadingAnchor constraintEqualToAnchor:leftView.trailingAnchor constant:6],
    [rightView.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-pad],
    [rightView.bottomAnchor constraintEqualToAnchor:leftView.bottomAnchor],
    [rightView.widthAnchor constraintEqualToAnchor:leftView.widthAnchor],   // 左右等宽
  ];
  _soloConstraints = @[
    [leftView.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-pad],
  ];
  _window.contentView = content;

  // Finder 右键的一次性命令（解压/压缩/测试/校验和）冷启动时，openURLs 已缓存到 _pendingURLs；
  // 这类操作不该弹出文件管理器主窗口（对齐 Windows 右键→独立 7zG 子进程，做完即走）。
  if ([self pendingURLsNeedMainWindow]) [self showMainWindow];

  // 两面板各装载入口位置（命令行参数给左面板，右面板用 home）
  NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
  NSString *arg = (args.count > 1) ? args[1] : nil;
  [self loadEntry:arg onSide:0];
  [self loadEntry:nil onSide:1];

  _activeSide = 0;
  [self setActiveSide:0];
  [self setTwoPanels:NO];   // 默认单面板（双面板经 ⌘\ 或工具栏「单/双」切换）
  [_window makeFirstResponder:_table[0]];

  [NSNotificationCenter.defaultCenter addObserver:self
      selector:@selector(appDidBecomeActive:)
          name:NSApplicationDidBecomeActiveNotification object:nil];

  // 面板就绪。执行冷启动期间缓存的 URL（右键/双击在 app 未运行时唤起，URL 早于本方法到达）。
  _launched = YES;
  if (_pendingURLs.count) {
    NSArray<NSURL *> *pending = [_pendingURLs copy];
    [_pendingURLs removeAllObjects];
    [self handleURLs:pending];
  }
}

- (NSView *)buildPanelSide:(int)side {
  NSTextField *addr = [[NSTextField alloc] init];
  addr.editable = YES;
  addr.selectable = YES;
  addr.bezeled = YES;
  addr.bezelStyle = NSTextFieldSquareBezel;
  addr.drawsBackground = YES;
  addr.backgroundColor = NSColor.clearColor;
  addr.font = [NSFont systemFontOfSize:11];
  addr.lineBreakMode = NSLineBreakByTruncatingMiddle;
  addr.maximumNumberOfLines = 1;
  addr.placeholderString = @"输入路径回车跳转";
  addr.target = self;
  addr.action = @selector(addressEntered:);
  [addr.cell setSendsActionOnEndEditing:NO];   // 仅回车触发，失焦不跳转

  SZTableView *table = [SZTableView new];
  table.usesAlternatingRowBackgroundColors = YES;
  table.allowsMultipleSelection = YES;
  table.rowHeight = 20;
  for (NSArray *c in @[ @[SZColID_Name, @"名称", @300], @[SZColID_Size, @"大小", @90], @[SZColID_Modified, @"修改时间", @150] ]) {
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:c[0]];
    col.title = c[1]; col.width = [c[2] doubleValue];
    col.resizingMask = NSTableColumnUserResizingMask | NSTableColumnAutoresizingMask;
    [table addTableColumn:col];
  }
  NSScrollView *scroll = [NSScrollView new];
  scroll.documentView = table;
  scroll.hasVerticalScroller = YES;
  scroll.autohidesScrollers = YES;
  scroll.borderType = NSBezelBorder;

  NSStackView *col = [NSStackView stackViewWithViews:@[addr, scroll]];
  col.orientation = NSUserInterfaceLayoutOrientationVertical;
  col.spacing = 2;
  scroll.translatesAutoresizingMaskIntoConstraints = NO;
  [scroll setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationVertical];

  _table[side] = table;
  _addr[side] = addr;
  _panelView[side] = col;
  return col;
}

- (NSButton *)toolButton:(NSString *)symbol title:(NSString *)title action:(SEL)action {
  NSButton *b = [NSButton buttonWithTitle:title target:self action:action];
  NSImage *img = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:title];
  if (img) { b.image = img; b.imagePosition = NSImageLeading; }
  b.toolTip = title;
  return b;
}

#pragma mark 活动面板

- (SZPanelController *)activePanel { return _panel[_activeSide]; }
- (SZPanelController *)otherPanel  { return _panel[_activeSide ^ 1]; }
- (SZTableView *)activeTable       { return _table[_activeSide]; }

- (void)setActiveSide:(int)side {
  _activeSide = side;
  for (int s = 0; s < 2; s++)
    _addr[s].backgroundColor = (s == side) ? NSColor.selectedTextBackgroundColor : NSColor.clearColor;
  [self refreshChrome];
}

- (void)switchActivePanel {
  if (!_twoPanels) return;                        // 单面板模式无另一面板
  int other = _activeSide ^ 1;
  [_window makeFirstResponder:_table[other]];     // becomeFirstResponder → onActivate → setActiveSide
}

- (void)setTwoPanels:(BOOL)two {
  _twoPanels = two;
  if (two) {
    [NSLayoutConstraint deactivateConstraints:_soloConstraints];
    _panelView[1].hidden = NO;
    [NSLayoutConstraint activateConstraints:_dualConstraints];
  } else {
    [NSLayoutConstraint deactivateConstraints:_dualConstraints];
    _panelView[1].hidden = YES;
    [NSLayoutConstraint activateConstraints:_soloConstraints];
    if (_activeSide == 1) [_window makeFirstResponder:_table[0]];   // 活动面板切回左
  }
  [self refreshChrome];
}
- (void)toggleTwoPanels:(id)sender { [self setTwoPanels:!_twoPanels]; }

#pragma mark 装载

- (BOOL)isArchivePath:(NSString *)path {
  NSString *ext = path.pathExtension.lowercaseString;
  if (!ext.length) return NO;
  static NSSet *exts; static dispatch_once_t once;
  dispatch_once(&once, ^{ exts = [NSSet setWithArray:[SZFolderSession supportedArchiveExtensions]]; });
  return [exts containsObject:ext];
}

// 入口路径分发：目录→进目录；归档→进归档；普通文件→所在目录；nil/无效→home。
- (void)loadEntry:(NSString *)arg onSide:(int)side {
  BOOL isDir = NO;
  if (arg && [NSFileManager.defaultManager fileExistsAtPath:arg isDirectory:&isDir]) {
    if (isDir) [self installSource:[SZFSDataSource sourceWithDirectoryPath:arg] onSide:side];
    else if ([self isArchivePath:arg]) {
      [self installSource:[SZFSDataSource sourceWithDirectoryPath:arg.stringByDeletingLastPathComponent] onSide:side];
      [_panel[side] pushArchiveAtFSPath:arg];
    } else {
      [self installSource:[SZFSDataSource sourceWithDirectoryPath:arg.stringByDeletingLastPathComponent] onSide:side];
    }
  } else {
    [self installSource:[SZFSDataSource sourceWithDirectoryPath:NSHomeDirectory()] onSide:side];
  }
}

- (void)installSource:(id<SZPanelSource>)source onSide:(int)side {
  if (!source) { NSBeep(); return; }
  SZPanelController *panel = [[SZPanelController alloc] initWithSource:source];
  _panel[side] = panel;
  SZTableView *table = _table[side];
  table.panel = panel;
  __weak typeof(self) ws = self;
  table.onNavigate = ^{ [ws refreshChromeForSide:side]; };
  table.onActivate = ^{ [ws setActiveSide:side]; };
  table.onTab      = ^{ [ws switchActivePanel]; };
  panel.onReload   = ^{ [ws refreshChromeForSide:side]; };
  [panel bindTableView:table];
  [self refreshChromeForSide:side];
}

// 打开（活动面板）：目录/归档。供「打开…」菜单。
- (void)openDirectory:(NSString *)path { [self installSource:[SZFSDataSource sourceWithDirectoryPath:path] onSide:_activeSide]; [self refreshChrome]; }
- (void)openArchiveURL:(NSURL *)url {
  [self installSource:[SZFSDataSource sourceWithDirectoryPath:url.path.stringByDeletingLastPathComponent] onSide:_activeSide];
  [_panel[_activeSide] pushArchiveAtFSPath:url.path];
  [self refreshChrome];
}

// 地址栏回车：输入目录→进目录；输入归档→开归档；无效→beep 并恢复显示。
- (void)addressEntered:(NSTextField *)sender {
  int side = (sender == _addr[1]) ? 1 : 0;
  NSString *path = sender.stringValue.stringByExpandingTildeInPath.stringByStandardizingPath;
  NSFileManager *fm = NSFileManager.defaultManager;
  BOOL isDir = NO;
  if (path.length && [fm fileExistsAtPath:path isDirectory:&isDir] && isDir) {
    [self installSource:[SZFSDataSource sourceWithDirectoryPath:path] onSide:side];
    [self setActiveSide:side];
  } else if (path.length && [fm fileExistsAtPath:path] && [self isArchivePath:path]) {
    [self installSource:[SZFSDataSource sourceWithDirectoryPath:path.stringByDeletingLastPathComponent] onSide:side];
    [_panel[side] pushArchiveAtFSPath:path];
    [self setActiveSide:side];
  } else {
    NSBeep();
    [self refreshChromeForSide:side];   // 恢复原地址显示
  }
}

#pragma mark chrome

- (void)refreshChromeForSide:(int)side {
  _addr[side].stringValue = _panel[side].addressText;
  if (side == _activeSide) {
    _status.stringValue = _panel[side].statusText;
    _window.title = [NSString stringWithFormat:@"7-Zip · %@", _panel[side].addressText];
  }
}
- (void)refreshChrome { for (int s = 0; s < 2; s++) [self refreshChromeForSide:s]; }

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app { return YES; }

#pragma mark 菜单 / 工具栏动作（作用于活动面板）

- (void)goUp:(id)sender { if ([self.activePanel goToParent]) [self refreshChrome]; }
- (void)refresh:(id)sender { [self.activePanel refresh]; }
- (void)appDidBecomeActive:(NSNotification *)note {
  for (int s = 0; s < 2; s++) if (!_panel[s].inArchive) [_panel[s] refresh];
  // 切回 app：检查归档内已打开的文件是否被外部程序修改，询问写回（M4-T7）
  [[SZEditWatcher shared] checkAndPromptWithParentWindow:_window];
}

- (void)newFolder:(id)sender {
  if (self.activePanel.inArchive) {
    NSAlert *a = [NSAlert new];
    a.messageText = @"归档内暂不支持新建文件夹"; a.informativeText = @"请切换到文件系统目录再新建。";
    [a addButtonWithTitle:@"好"]; [a runModal]; return;
  }
  [self.activePanel createFolderInteractive];
}
- (void)closeWindow:(id)sender { [_window performClose:sender]; }
- (void)revealInFinder:(id)sender { [self.activePanel revealSelectionInFinder]; }
- (void)invertSelection:(id)sender { [self.activePanel invertSelectionInPanel]; [self refreshChrome]; }
- (void)deleteSelected:(id)sender { [self.activePanel deleteSelectionInteractive]; }
- (void)sortByName:(id)sender { [self.activePanel sortByColumnID:SZColID_Name]; }
- (void)sortBySize:(id)sender { [self.activePanel sortByColumnID:SZColID_Size]; }
- (void)sortByDate:(id)sender { [self.activePanel sortByColumnID:SZColID_Modified]; }

- (void)openLocation:(id)sender {
  NSOpenPanel *p = [NSOpenPanel openPanel];
  p.canChooseFiles = YES; p.canChooseDirectories = YES; p.allowsMultipleSelection = NO;
  p.prompt = @"打开"; p.message = @"选择要打开的文件夹或归档";
  if ([p runModal] != NSModalResponseOK || !p.URL) return;
  NSString *path = p.URL.path; BOOL isDir = NO;
  [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDir];
  if (isDir) [self openDirectory:path];
  else if ([self isArchivePath:path]) [self openArchiveURL:p.URL];
  else [NSWorkspace.sharedWorkspace openURL:p.URL];
}

- (void)extractTo:(id)sender {
  NSString *arc = [self.activePanel currentArchiveFSPath];
  if (!arc) { NSBeep(); return; }
  NSString *defDest = arc.stringByDeletingLastPathComponent;
  [SZExtractDialogController presentForArchive:arc.lastPathComponent defaultDestination:defDest parentWindow:_window
                                    completion:^(SZArchiveExtractOptions *options) {
    if (!options) return;
    SZProgressWindowController *pc = [SZProgressWindowController new];
    [pc beginExtractArchive:arc options:options completion:nil];
  }];
}
- (void)testArchive:(id)sender {
  NSString *arc = [self.activePanel currentArchiveFSPath];
  if (!arc) { NSBeep(); return; }
  SZProgressWindowController *pc = [SZProgressWindowController new];
  [pc beginTestArchive:arc password:nil completion:nil];
}

// 校验和（CRC/SHA）：对活动面板选中的 FS 文件/目录算哈希；无选中→当前目录。sender.representedObject=算法名数组。
- (void)calcChecksum:(id)sender {
  if (self.activePanel.inArchive) {
    NSAlert *a = [NSAlert new];
    a.messageText = @"归档内项暂不支持校验和";
    a.informativeText = @"请选择文件系统中的文件或文件夹。";
    [a addButtonWithTitle:@"好"]; [a runModal]; return;
  }
  NSArray<NSString *> *paths = [self.activePanel selectedFileSystemPaths];
  if (paths.count == 0) {
    NSString *dir = [self.activePanel currentDirectoryFSPath];
    if (dir) paths = @[dir];   // 无选中 → 对当前整个目录
  }
  if (paths.count == 0) { NSBeep(); return; }
  NSArray<NSString *> *methods = [sender isKindOfClass:NSMenuItem.class] ? [(NSMenuItem *)sender representedObject] : nil;
  if (methods.count == 0) methods = @[@"CRC32", @"SHA256"];
  [SZHashResultController presentForPaths:paths methods:methods parentWindow:_window];
}

- (void)showFileAssociations:(id)sender {
  [SZFileAssocController presentWithParentWindow:_window];
}

- (void)newArchive:(id)sender {
  NSOpenPanel *p = [NSOpenPanel openPanel];
  p.canChooseFiles = YES; p.canChooseDirectories = YES; p.allowsMultipleSelection = YES;
  p.prompt = @"添加"; p.message = @"选择要压缩的文件或文件夹";
  if ([p runModal] != NSModalResponseOK || p.URLs.count == 0) return;
  NSMutableArray<NSString *> *inputs = [NSMutableArray array];
  for (NSURL *u in p.URLs) [inputs addObject:u.path];
  NSString *first = p.URLs.firstObject.path;
  NSString *base = [first.lastPathComponent stringByDeletingPathExtension];
  if (!base.length) base = @"archive";
  NSString *defArc = [[first stringByDeletingLastPathComponent] stringByAppendingPathComponent:[base stringByAppendingPathExtension:@"7z"]];
  [SZCompressDialogController presentForInputs:inputs defaultArchivePath:defArc parentWindow:_window
                                    completion:^(NSString *archivePath, SZCompressOptions *options) {
    if (!archivePath || !options) return;
    SZProgressWindowController *pc = [SZProgressWindowController new];
    [pc beginCompressToArchive:archivePath options:options completion:nil];
  }];
}

#pragma mark 跨面板复制 / 移动（F5 / F6，M4-T5）

- (void)copyToOther:(id)sender { [self.activePanel transferSelectionToPanel:self.otherPanel move:NO parent:_window]; [self refreshChrome]; }
- (void)moveToOther:(id)sender { [self.activePanel transferSelectionToPanel:self.otherPanel move:YES parent:_window]; [self refreshChrome]; }

#pragma mark - sevenzip:// URL 命令（FinderSync 扩展唤起，M5-T2）

// Finder 扩展经 NSWorkspace openURL 发来命令。解码 SZShellCommand 后分发到现有 解压/压缩/测试/哈希 流程。
- (void)application:(NSApplication *)application openURLs:(NSArray<NSURL *> *)urls {
  if (!_launched) {   // 冷启动：面板尚未建好（openURLs 早于 didFinishLaunching），先缓存
    if (!_pendingURLs) _pendingURLs = [NSMutableArray array];
    [_pendingURLs addObjectsFromArray:urls];
    return;
  }
  [self handleURLs:urls];
}

- (void)handleURLs:(NSArray<NSURL *> *)urls {
  for (NSURL *u in urls) {
    if ([u.scheme isEqualToString:@"sevenzip"]) {      // FinderSync 扩展命令
      SZShellCommand *cmd = [SZShellCommand commandFromURL:u];
      if (cmd) [self executeShellCommand:cmd]; else NSBeep();
    } else if (u.isFileURL) {                            // 双击归档/文件（M5-T3 文件关联）
      [self openFileURL:u];
    }
  }
}

// 双击归档→进归档浏览；双击目录→进目录；其他文件→打开所在目录。装载到活动面板。
- (void)openFileURL:(NSURL *)url {
  NSString *path = url.path;
  BOOL isDir = NO;
  if (![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDir]) { NSBeep(); return; }
  [self showMainWindow];
  if (isDir) [self openDirectory:path];
  else if ([self isArchivePath:path]) [self openArchiveURL:url];
  else [self openDirectory:path.stringByDeletingLastPathComponent];
}

#pragma mark Finder 右键一次性操作：主窗口显隐 + 完成后退出

// 显示文件管理器主窗口（「打开」命令、双击文件、普通启动）。一旦显示，shell 操作完成后不再自动退出。
- (void)showMainWindow {
  _mainWindowEverShown = YES;
  [_window makeKeyAndOrderFront:nil];
  [NSApp activateIgnoringOtherApps:YES];
}

// 主窗口可见时作 sheet 宿主；不可见（纯右键命令冷启动）时返回 nil → 对话框独立窗口呈现。
- (NSWindow *)shellDialogParent { return _window.isVisible ? _window : nil; }

- (void)beginShellOp { _liveShellOps++; }
- (void)endShellOp {
  if (_liveShellOps > 0) _liveShellOps--;
  [self terminateIfDoneShellOps];
}

// 一次性命令全部结束、且文件管理器主窗口从未显示（app 是为该命令而冷启动）→ 退出，不在 Dock 残留。
// 延到下一 runloop 执行：避免在 didFinishLaunching/完成回调的同步栈里 terminate，并二次确认防竞态。
- (void)terminateIfDoneShellOps {
  if (_liveShellOps != 0 || _mainWindowEverShown) return;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self->_liveShellOps == 0 && !self->_mainWindowEverShown) [NSApp terminate:nil];
  });
}

// 该批 URL 是否需要文件管理器主窗口：双击文件 / 「打开」命令需要；纯一次性命令（解压/压缩/测试/哈希）不需要。
- (BOOL)urlNeedsMainWindow:(NSURL *)u {
  if (u.isFileURL) return YES;
  if ([u.scheme isEqualToString:@"sevenzip"]) {
    SZShellCommand *cmd = [SZShellCommand commandFromURL:u];
    return !cmd || cmd.op == SZShellOpOpen;   // 解码失败也显示主窗口（保守）
  }
  return YES;
}
- (BOOL)pendingURLsNeedMainWindow {
  if (_pendingURLs.count == 0) return YES;   // 普通启动（双击 app）→ 显示主窗口
  for (NSURL *u in _pendingURLs) if ([self urlNeedsMainWindow:u]) return YES;
  return NO;
}

- (void)executeShellCommand:(SZShellCommand *)cmd {
  NSArray<NSString *> *paths = cmd.paths;
  if (paths.count == 0) { NSBeep(); [self terminateIfDoneShellOps]; return; }
  NSString *first = paths.firstObject;
  __weak typeof(self) ws = self;

  switch (cmd.op) {
    case SZShellOpOpen:
      [self showMainWindow];   // 「打开」要进文件管理器浏览
      [self openArchiveURL:[NSURL fileURLWithPath:first]];
      break;
    case SZShellOpExtract:        [self shellExtract:first dialog:YES toFolder:NO]; break;
    case SZShellOpExtractHere:    [self shellExtract:first dialog:NO  toFolder:NO]; break;
    case SZShellOpExtractToFolder:[self shellExtract:first dialog:NO  toFolder:YES]; break;
    case SZShellOpTest: {
      [self beginShellOp];
      SZProgressWindowController *pc = [SZProgressWindowController new];
      [pc beginTestArchive:first password:nil completion:^(BOOL ok){ [ws endShellOp]; }];
      break;
    }
    case SZShellOpCompress:    [self shellCompress:paths format:nil    dialog:YES]; break;
    case SZShellOpCompress7z:  [self shellCompress:paths format:@"7z"  dialog:NO];  break;
    case SZShellOpCompressZip: [self shellCompress:paths format:@"zip" dialog:NO];  break;
    case SZShellOpHash: {
      [self beginShellOp];
      NSArray<NSString *> *methods = cmd.methods.count ? cmd.methods : @[@"CRC32", @"SHA256"];
      [SZHashResultController presentForPaths:paths methods:methods
                                 parentWindow:[self shellDialogParent]
                                      onClose:^{ [ws endShellOp]; }];
      break;
    }
    default: NSBeep(); [self terminateIfDoneShellOps];
  }
}

// 仅由 executeShellCommand 调用（Finder 右键）。整条链路记一次 shell 操作：beginShellOp →
// 取消 / 进度窗完成 时 endShellOp，使无主窗口的冷启动场景在收尾后退出。
- (void)shellExtract:(NSString *)archive dialog:(BOOL)dialog toFolder:(BOOL)toFolder {
  if (![NSFileManager.defaultManager fileExistsAtPath:archive]) { NSBeep(); [self terminateIfDoneShellOps]; return; }
  [self beginShellOp];
  __weak typeof(self) ws = self;
  NSString *parent = archive.stringByDeletingLastPathComponent;
  if (dialog) {
    [SZExtractDialogController presentForArchive:archive.lastPathComponent defaultDestination:parent parentWindow:[self shellDialogParent]
                                      completion:^(SZArchiveExtractOptions *options) {
      if (!options) { [ws endShellOp]; return; }   // 取消对话框 → 操作结束
      SZProgressWindowController *pc = [SZProgressWindowController new];
      [pc beginExtractArchive:archive options:options completion:^(BOOL ok){ [ws endShellOp]; }];
    }];
    return;
  }
  NSString *dest = parent;
  if (toFolder) dest = [self uniqueDirInParent:parent base:[SZShellCommand baseNameForArchive:archive]];
  SZArchiveExtractOptions *o = [SZArchiveExtractOptions new];
  o.outputDirectory = dest;
  o.pathMode = SZExtractPathModeFull;
  o.overwriteMode = toFolder ? SZExtractOverwriteModeOverwrite : SZExtractOverwriteModeAsk;
  SZProgressWindowController *pc = [SZProgressWindowController new];
  [pc beginExtractArchive:archive options:o completion:^(BOOL ok){ [ws endShellOp]; }];
}

// 仅由 executeShellCommand 调用（Finder 右键）。op 生命周期同 shellExtract。
- (void)shellCompress:(NSArray<NSString *> *)inputs format:(NSString *)format dialog:(BOOL)dialog {
  if (inputs.count == 0) { NSBeep(); [self terminateIfDoneShellOps]; return; }
  [self beginShellOp];
  __weak typeof(self) ws = self;
  NSString *parent = [inputs.firstObject stringByDeletingLastPathComponent];
  NSString *base = [SZShellCommand archiveBaseNameForPaths:inputs];
  NSString *ext = format ?: @"7z";
  NSString *defArc = [parent stringByAppendingPathComponent:[base stringByAppendingPathExtension:ext]];
  if (dialog) {
    [SZCompressDialogController presentForInputs:inputs defaultArchivePath:defArc parentWindow:[self shellDialogParent]
                                      completion:^(NSString *archivePath, SZCompressOptions *options) {
      if (!archivePath || !options) { [ws endShellOp]; return; }   // 取消对话框 → 操作结束
      SZProgressWindowController *pc = [SZProgressWindowController new];
      [pc beginCompressToArchive:archivePath options:options completion:^(BOOL ok){ [ws endShellOp]; }];
    }];
    return;
  }
  // 快速压缩：默认选项，不弹对话框；目标不覆盖（名 1/名 2…）。
  SZCompressOptions *o = [SZCompressOptions new];
  o.format = ext;
  o.inputPaths = inputs;
  o.level = 5;
  o.solid = [ext isEqualToString:@"7z"];
  o.storeMTime = YES;
  SZProgressWindowController *pc = [SZProgressWindowController new];
  [pc beginCompressToArchive:[self uniqueArchivePath:defArc] options:o completion:^(BOOL ok){ [ws endShellOp]; }];
}

// 不覆盖的目标目录名（名/名 1/名 2…）
- (NSString *)uniqueDirInParent:(NSString *)parent base:(NSString *)base {
  NSFileManager *fm = NSFileManager.defaultManager;
  NSString *cand = [parent stringByAppendingPathComponent:base];
  if (![fm fileExistsAtPath:cand]) return cand;
  for (int i = 1; i < 1000; i++) {
    cand = [parent stringByAppendingPathComponent:[NSString stringWithFormat:@"%@ %d", base, i]];
    if (![fm fileExistsAtPath:cand]) return cand;
  }
  return cand;
}

// 不覆盖的归档文件名（名.7z/名 1.7z…）
- (NSString *)uniqueArchivePath:(NSString *)path {
  NSFileManager *fm = NSFileManager.defaultManager;
  if (![fm fileExistsAtPath:path]) return path;
  NSString *dir = path.stringByDeletingLastPathComponent;
  NSString *base = path.lastPathComponent.stringByDeletingPathExtension;
  NSString *ext = path.pathExtension;
  for (int i = 1; i < 1000; i++) {
    NSString *cand = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@ %d.%@", base, i, ext]];
    if (![fm fileExistsAtPath:cand]) return cand;
  }
  return path;
}

- (BOOL)validateMenuItem:(NSMenuItem *)item {
  if (item.action == @selector(extractTo:) || item.action == @selector(testArchive:))
    return [self.activePanel currentArchiveFSPath] != nil;
  return YES;
}

@end
