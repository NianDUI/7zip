// SZAppDelegate.m —— 主窗口：地址栏 + NSTableView(view-based 3 列) + 状态栏；双击/Backspace/Enter 导航。
#import "SZAppDelegate.h"
#import "SZPanelController.h"
#import "SevenZipKit/SZPanelModel.h"

#pragma mark - 键盘可达的 NSTableView

@interface SZTableView : NSTableView
@property (nonatomic, weak) SZPanelController *panel;
@property (nonatomic, copy) void (^onNavigate)(void);
@end

@implementation SZTableView
- (void)keyDown:(NSEvent *)e {
  const unsigned short k = e.keyCode;
  if (k == 51 || k == 117) {                 // Backspace / Delete → 上级
    if ([_panel goToParent] && _onNavigate) _onNavigate();
    return;
  }
  if (k == 36 || k == 76) {                   // Return / Enter → 进入选中目录
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
  NSURL *_archiveURL;
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
  NSRect frame = NSMakeRect(0, 0, 760, 480);
  _window = [[NSWindow alloc] initWithContentRect:frame
      styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                 NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable)
      backing:NSBackingStoreBuffered defer:NO];
  _window.title = @"7-Zip";   // 对齐 Windows 版窗口标题（FM.cpp:247）
  _window.frameAutosaveName = @"SZMainWindow";
  [_window center];

  _address = [NSTextField labelWithString:@"/"];
  _address.font = [NSFont systemFontOfSize:12];
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

  NSStackView *stack = [NSStackView stackViewWithViews:@[_address, scroll, _status]];
  stack.orientation = NSUserInterfaceLayoutOrientationVertical;
  stack.spacing = 4;
  stack.edgeInsets = NSEdgeInsetsMake(8, 8, 8, 8);
  [stack setHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationVertical];
  scroll.translatesAutoresizingMaskIntoConstraints = NO;
  [scroll setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationVertical];
  _window.contentView = stack;

  [_window makeKeyAndOrderFront:nil];
  [NSApp activateIgnoringOtherApps:YES];

  // 命令行参数指定归档，否则弹打开面板
  NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
  if (args.count > 1 && [NSFileManager.defaultManager fileExistsAtPath:args[1]])
    [self openArchiveURL:[NSURL fileURLWithPath:args[1]]];
  else
    [self presentOpenPanel];
}

- (void)addColumn:(NSString *)identifier title:(NSString *)title width:(CGFloat)w {
  NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:identifier];
  col.title = title;
  col.width = w;
  col.resizingMask = NSTableColumnUserResizingMask | NSTableColumnAutoresizingMask;
  [_table addTableColumn:col];
}

- (void)presentOpenPanel {
  NSOpenPanel *p = [NSOpenPanel openPanel];
  p.allowsMultipleSelection = NO;
  p.canChooseDirectories = NO;
  if ([p runModal] == NSModalResponseOK && p.URL) [self openArchiveURL:p.URL];
  else [NSApp terminate:nil];
}

- (void)openArchiveURL:(NSURL *)url {
  NSError *err = nil;
  SZPanelModel *model = [SZPanelModel panelWithFileURL:url error:&err];
  if (!model) {
    NSAlert *a = [NSAlert alertWithError:err ?: [NSError errorWithDomain:@"SZ" code:0 userInfo:nil]];
    a.messageText = @"无法打开归档";
    [a runModal];
    return;
  }
  _archiveURL = url;
  _panel = [[SZPanelController alloc] initWithModel:model];
  _table.panel = _panel;
  __weak typeof(self) weakSelf = self;
  _table.onNavigate = ^{ [weakSelf refreshChrome]; };
  _panel.onReload = ^{ [weakSelf refreshChrome]; };
  [_panel bindTableView:_table];
  [self refreshChrome];
}

- (void)refreshChrome {
  _address.stringValue = _panel.addressText;
  _status.stringValue = _panel.statusText;
  _window.title = [NSString stringWithFormat:@"7-Zip — %@", _archiveURL.lastPathComponent];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app { return YES; }

@end
