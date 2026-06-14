// SZAppDelegate.m —— 主窗口：双面板（左右各一个独立 SZPanelController + 数据源栈）。
// M4-T5：FAR 风格双面板。活动面板高亮 + Tab 切换；菜单/工具栏作用于活动面板。
#import "SZAppDelegate.h"
#import "SZPanelController.h"
#import "SZProgressWindowController.h"
#import "SZExtractDialogController.h"
#import "SZCompressDialogController.h"
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
  NSButton *upBtn      = [NSButton buttonWithTitle:@"↑ 上级" target:self action:@selector(goUp:)];
  NSButton *copyBtn    = [NSButton buttonWithTitle:@"复制→" target:self action:@selector(copyToOther:)];
  NSButton *moveBtn    = [NSButton buttonWithTitle:@"移动→" target:self action:@selector(moveToOther:)];
  NSButton *extractBtn = [NSButton buttonWithTitle:@"解压" target:self action:@selector(extractTo:)];
  NSButton *testBtn    = [NSButton buttonWithTitle:@"测试" target:self action:@selector(testArchive:)];
  NSButton *panelsBtn  = [NSButton buttonWithTitle:@"单/双" target:self action:@selector(toggleTwoPanels:)];
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

  [_window makeKeyAndOrderFront:nil];
  [NSApp activateIgnoringOtherApps:YES];

  // 两面板各装载入口位置（命令行参数给左面板，右面板用 home）
  NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
  NSString *arg = (args.count > 1) ? args[1] : nil;
  [self loadEntry:arg onSide:0];
  [self loadEntry:nil onSide:1];

  _activeSide = 0;
  [self setActiveSide:0];
  [self setTwoPanels:YES];   // 默认双面板（激活右面板约束）
  [_window makeFirstResponder:_table[0]];

  [NSNotificationCenter.defaultCenter addObserver:self
      selector:@selector(appDidBecomeActive:)
          name:NSApplicationDidBecomeActiveNotification object:nil];
}

- (NSView *)buildPanelSide:(int)side {
  NSTextField *addr = [NSTextField labelWithString:@"/"];
  addr.drawsBackground = YES;
  addr.backgroundColor = NSColor.clearColor;
  addr.font = [NSFont systemFontOfSize:11];
  addr.lineBreakMode = NSLineBreakByTruncatingMiddle;
  addr.maximumNumberOfLines = 1;

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
- (void)appDidBecomeActive:(NSNotification *)note { for (int s = 0; s < 2; s++) if (!_panel[s].inArchive) [_panel[s] refresh]; }

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

- (BOOL)validateMenuItem:(NSMenuItem *)item {
  if (item.action == @selector(extractTo:) || item.action == @selector(testArchive:))
    return [self.activePanel currentArchiveFSPath] != nil;
  return YES;
}

@end
