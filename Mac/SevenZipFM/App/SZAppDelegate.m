// SZAppDelegate.m —— 主窗口：地址栏 + NSTableView(view-based 列) + 状态栏。
// M4-T2：导航（FS↔归档进出、逐层退回）由 SZPanelController 数据源栈自包含；app 只管布局与 chrome。
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

#pragma mark - 键盘可达的 NSTableView

@interface SZTableView : NSTableView
@property (nonatomic, weak) SZPanelController *panel;
@property (nonatomic, copy) void (^onNavigate)(void);
@end

@implementation SZTableView
- (void)keyDown:(NSEvent *)e {
  const unsigned short k = e.keyCode;
  if (k == 51 || k == 117) {                 // Backspace / Delete → 上级（栈顶逐层退回）
    if ([_panel goToParent] && _onNavigate) _onNavigate();
    return;
  }
  if (k == 36 || k == 76) {                   // Return / Enter → 进入选中目录 / 打开文件 / 进归档
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
  SZTableView *_table;
  SZPanelController *_panel;
  NSTextField *_address;
  NSTextField *_status;
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
  NSRect frame = NSMakeRect(0, 0, 760, 480);
  _window = [[NSWindow alloc] initWithContentRect:frame
      styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                 NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable)
      backing:NSBackingStoreBuffered defer:NO];
  _window.title = @"7-Zip";
  _window.frameAutosaveName = @"SZMainWindow";
  [_window center];

  _address = [NSTextField labelWithString:@"/"];
  _address.font = [NSFont systemFontOfSize:12];
  _address.lineBreakMode = NSLineBreakByTruncatingMiddle;
  _status  = [NSTextField labelWithString:@""];
  _status.font = [NSFont systemFontOfSize:11];
  _status.textColor = NSColor.secondaryLabelColor;

  _table = [SZTableView new];
  _table.usesAlternatingRowBackgroundColors = YES;
  _table.allowsMultipleSelection = YES;
  _table.rowHeight = 20;
  [self addColumn:SZColID_Name title:@"名称"     width:340];
  [self addColumn:SZColID_Size title:@"大小"     width:110];
  [self addColumn:SZColID_Modified title:@"修改时间" width:170];

  NSScrollView *scroll = [NSScrollView new];
  scroll.documentView = _table;
  scroll.hasVerticalScroller = YES;
  scroll.autohidesScrollers = YES;
  scroll.borderType = NSBezelBorder;

  // 工具栏按钮 + 地址栏同一行（上级/解压/测试可见可点）。
  NSButton *upBtn      = [NSButton buttonWithTitle:@"↑ 上级" target:self action:@selector(goUp:)];
  NSButton *extractBtn = [NSButton buttonWithTitle:@"解压" target:self action:@selector(extractTo:)];
  NSButton *testBtn    = [NSButton buttonWithTitle:@"测试" target:self action:@selector(testArchive:)];
  [_address setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
  NSStackView *topRow = [NSStackView stackViewWithViews:@[upBtn, extractBtn, testBtn, _address]];
  topRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  topRow.spacing = 8;

  NSStackView *stack = [NSStackView stackViewWithViews:@[topRow, scroll, _status]];
  stack.orientation = NSUserInterfaceLayoutOrientationVertical;
  stack.spacing = 4;
  stack.edgeInsets = NSEdgeInsetsMake(8, 8, 8, 8);
  [stack setHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationVertical];
  scroll.translatesAutoresizingMaskIntoConstraints = NO;
  [scroll setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationVertical];
  _window.contentView = stack;

  [_window makeKeyAndOrderFront:nil];
  [NSApp activateIgnoringOtherApps:YES];

  // 入口：命令行参数 = 归档→归档面板 / = 目录→该目录 / = 普通文件→其所在目录 / 无参→home。
  NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
  NSString *arg = (args.count > 1) ? args[1] : nil;
  BOOL isDir = NO;
  if (arg && [NSFileManager.defaultManager fileExistsAtPath:arg isDirectory:&isDir]) {
    if (isDir) [self openDirectory:arg];
    else if ([self isArchivePath:arg]) [self openArchiveURL:[NSURL fileURLWithPath:arg]];
    else [self openDirectory:arg.stringByDeletingLastPathComponent];
  } else {
    [self openDirectory:NSHomeDirectory()];
  }

  // 从 Finder / 外部加文件后切回 app → 自动刷新（仅 FS 模式）
  [NSNotificationCenter.defaultCenter addObserver:self
      selector:@selector(appDidBecomeActive:)
          name:NSApplicationDidBecomeActiveNotification object:nil];
}

- (void)addColumn:(NSString *)identifier title:(NSString *)title width:(CGFloat)w {
  NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:identifier];
  col.title = title;
  col.width = w;
  col.resizingMask = NSTableColumnUserResizingMask | NSTableColumnAutoresizingMask;
  [_table addTableColumn:col];
}

#pragma mark - 面板装载 / 打开

- (void)installPanelWithSource:(id<SZPanelSource>)source {
  _panel = [[SZPanelController alloc] initWithSource:source];
  _table.panel = _panel;
  __weak typeof(self) ws = self;
  _table.onNavigate = ^{ [ws refreshChrome]; };
  _panel.onReload = ^{ [ws refreshChrome]; };
  [_panel bindTableView:_table];
  [self refreshChrome];
  [_window makeFirstResponder:_table];
}

- (void)openDirectory:(NSString *)path {
  SZFSDataSource *fs = [SZFSDataSource sourceWithDirectoryPath:path];
  if (!fs) { NSBeep(); return; }
  [self installPanelWithSource:fs];
}

- (void)openArchiveURL:(NSURL *)url {
  SZFSDataSource *fs = [SZFSDataSource sourceWithDirectoryPath:url.path.stringByDeletingLastPathComponent];
  if (!fs) { NSBeep(); return; }
  [self installPanelWithSource:fs];
  [_panel pushArchiveAtFSPath:url.path];   // 栈底 FS + 归档层（归档根上溯回 FS 目录）
}

- (void)refreshChrome {
  _status.stringValue = _panel.statusText;
  _address.stringValue = _panel.addressText;
  _window.title = [NSString stringWithFormat:@"7-Zip · %@", _panel.addressText];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app { return YES; }

#pragma mark - 是否归档

- (BOOL)isArchivePath:(NSString *)path {
  NSString *ext = path.pathExtension.lowercaseString;
  if (!ext.length) return NO;
  static NSSet *exts; static dispatch_once_t once;
  dispatch_once(&once, ^{ exts = [NSSet setWithArray:[SZFolderSession supportedArchiveExtensions]]; });
  return [exts containsObject:ext];
}

#pragma mark - 菜单 / 工具栏动作

- (void)goUp:(id)sender { if ([_panel goToParent]) [self refreshChrome]; }

// 刷新（Cmd+R）：重读当前层。
- (void)refresh:(id)sender { [_panel refresh]; }

// app 重新激活：FS 模式自动重读磁盘（归档不重读）。
- (void)appDidBecomeActive:(NSNotification *)note {
  if (!_panel.inArchive) [_panel refresh];
}

- (void)openLocation:(id)sender {
  NSOpenPanel *p = [NSOpenPanel openPanel];
  p.canChooseFiles = YES;
  p.canChooseDirectories = YES;
  p.allowsMultipleSelection = NO;
  p.prompt = @"打开";
  p.message = @"选择要打开的文件夹或归档";
  if ([p runModal] != NSModalResponseOK || !p.URL) return;
  NSString *path = p.URL.path;
  BOOL isDir = NO;
  [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDir];
  if (isDir) [self openDirectory:path];
  else if ([self isArchivePath:path]) [self openArchiveURL:p.URL];
  else [NSWorkspace.sharedWorkspace openURL:p.URL];
}

// 解压（Cmd+E）：弹解压对话框 → 进度窗。目标 = 栈顶归档 / FS 选中的归档文件。
- (void)extractTo:(id)sender {
  NSString *arc = [_panel currentArchiveFSPath];
  if (!arc) { NSBeep(); return; }
  NSString *defDest = arc.stringByDeletingLastPathComponent;
  [SZExtractDialogController presentForArchive:arc.lastPathComponent
                            defaultDestination:defDest
                                  parentWindow:_window
                                    completion:^(SZArchiveExtractOptions *options) {
    if (!options) return;
    SZProgressWindowController *pc = [SZProgressWindowController new];
    [pc beginExtractArchive:arc options:options completion:nil];
  }];
}

// 测试归档完整性（testMode，不落盘）
- (void)testArchive:(id)sender {
  NSString *arc = [_panel currentArchiveFSPath];
  if (!arc) { NSBeep(); return; }
  SZProgressWindowController *pc = [SZProgressWindowController new];
  [pc beginTestArchive:arc password:nil completion:nil];
}

// 新建归档（M3-T2）：选输入文件 → 压缩对话框 → 进度窗。
- (void)newArchive:(id)sender {
  NSOpenPanel *p = [NSOpenPanel openPanel];
  p.canChooseFiles = YES;
  p.canChooseDirectories = YES;
  p.allowsMultipleSelection = YES;
  p.prompt = @"添加";
  p.message = @"选择要压缩的文件或文件夹";
  if ([p runModal] != NSModalResponseOK || p.URLs.count == 0) return;

  NSMutableArray<NSString *> *inputs = [NSMutableArray array];
  for (NSURL *u in p.URLs) [inputs addObject:u.path];
  NSString *first = p.URLs.firstObject.path;
  NSString *base = [first.lastPathComponent stringByDeletingPathExtension];
  if (!base.length) base = @"archive";
  NSString *defArc = [[first stringByDeletingLastPathComponent]
      stringByAppendingPathComponent:[base stringByAppendingPathExtension:@"7z"]];

  [SZCompressDialogController presentForInputs:inputs
                            defaultArchivePath:defArc
                                  parentWindow:_window
                                    completion:^(NSString *archivePath, SZCompressOptions *options) {
    if (!archivePath || !options) return;
    SZProgressWindowController *pc = [SZProgressWindowController new];
    [pc beginCompressToArchive:archivePath options:options completion:nil];
  }];
}

// 仅在有目标归档时启用解压/测试
- (BOOL)validateMenuItem:(NSMenuItem *)item {
  if (item.action == @selector(extractTo:) || item.action == @selector(testArchive:))
    return [_panel currentArchiveFSPath] != nil;
  return YES;
}

@end
