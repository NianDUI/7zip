// SZHashResultController.m —— 校验和结果窗（M5；表格化）。
// 多文件多算法时表格一眼对齐：文件名 + 大小 + 各算法分列；底部数据总和 + 统计；可复制（对齐 7zz 文本）。
#import "SZHashResultController.h"
#import "SevenZipKit/SZHashCalculator.h"
#import "SZDockProgress.h"   // Dock 图标进度（M5 打磨）

@interface SZHashResultController () <SZHashDelegate, NSTableViewDataSource, NSTableViewDelegate>
@end

@implementation SZHashResultController {
  NSWindow *_window;
  NSTableView *_table;
  NSMutableArray<SZHashItem *> *_items;
  NSProgressIndicator *_progress;
  NSTextField *_statusLabel;
  NSTextField *_sumLabel;        // 数据总和（多行）
  NSButton *_copyButton;
  NSButton *_cancelButton;
  SZHashCalculator *_calc;
  NSArray<NSString *> *_methods;
  SZHashSummary *_summary;
  NSByteCountFormatter *_sizeFmt;
  BOOL _done;
}

static NSMutableSet<SZHashResultController *> *gLive;

// 列标识：name / size / 算法名本身（CRC32…）
static NSString *const kColName = @"__name";
static NSString *const kColSize = @"__size";

+ (void)presentForPaths:(NSArray<NSString *> *)paths
                methods:(NSArray<NSString *> *)methods
           parentWindow:(NSWindow *)parent {
  if (paths.count == 0 || methods.count == 0) { NSBeep(); return; }
  static dispatch_once_t once; dispatch_once(&once, ^{ gLive = [NSMutableSet set]; });
  SZHashResultController *c = [[SZHashResultController alloc] initWithMethods:methods];
  [gLive addObject:c];
  [c showRelativeTo:parent];
  [c startWithPaths:paths];
}

- (instancetype)initWithMethods:(NSArray<NSString *> *)methods {
  if ((self = [super init])) {
    _methods = [methods copy];
    _items = [NSMutableArray array];
    _sizeFmt = [NSByteCountFormatter new];
  }
  return self;
}

#pragma mark 列宽估算（等宽哈希值，按 digest 字符数）

static CGFloat HashColWidth(NSString *method) {
  // 大算法小写 64 hex（SHA256）/128（SHA512）；小算法 8（CRC32）。按字符数 *7.5 + padding，封顶 300。
  NSUInteger len = 16;
  NSString *m = method.uppercaseString;
  if ([m hasPrefix:@"SHA512"]) len = 128;
  else if ([m hasPrefix:@"SHA384"]) len = 96;
  else if ([m hasPrefix:@"SHA256"] || [m hasPrefix:@"SHA3"] || [m hasPrefix:@"BLAKE"]) len = 64;
  else if ([m hasPrefix:@"SHA1"]) len = 40;
  else if ([m hasPrefix:@"MD5"]) len = 32;
  else len = 16;   // CRC32/CRC64/XXH64
  CGFloat w = len * 7.5 + 16;
  return MIN(w, 300);
}

- (void)showRelativeTo:(NSWindow *)parent {
  CGFloat width = 320;   // 名称 + 大小
  for (NSString *m in _methods) width += HashColWidth(m) + 3;
  width = MIN(MAX(width, 480), 1100);

  _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, width, 460)
      styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable)
      backing:NSBackingStoreBuffered defer:NO];
  _window.title = [NSString stringWithFormat:@"校验和 · %@", [_methods componentsJoinedByString:@" / "]];
  _window.releasedWhenClosed = NO;
  _window.delegate = (id)self;
  [_window center];
  NSView *content = _window.contentView;

  _progress = [[NSProgressIndicator alloc] init];
  _progress.style = NSProgressIndicatorStyleBar;
  _progress.indeterminate = NO; _progress.minValue = 0; _progress.maxValue = 1;

  _statusLabel = [NSTextField labelWithString:@"计算中…"];
  _statusLabel.font = [NSFont systemFontOfSize:11];
  _statusLabel.textColor = NSColor.secondaryLabelColor;

  // 表格
  _table = [[NSTableView alloc] init];
  _table.usesAlternatingRowBackgroundColors = YES;
  _table.allowsMultipleSelection = YES;
  _table.rowHeight = 18;
  _table.dataSource = self;
  _table.delegate = self;
  _table.columnAutoresizingStyle = NSTableViewNoColumnAutoresizing;
  { NSTableColumn *c = [[NSTableColumn alloc] initWithIdentifier:kColName];
    c.title = @"名称"; c.width = 220; c.minWidth = 100; [_table addTableColumn:c]; }
  { NSTableColumn *c = [[NSTableColumn alloc] initWithIdentifier:kColSize];
    c.title = @"大小"; c.width = 84; c.minWidth = 60; [_table addTableColumn:c]; }
  for (NSString *m in _methods) {
    NSTableColumn *c = [[NSTableColumn alloc] initWithIdentifier:m];
    c.title = m; c.width = HashColWidth(m); c.minWidth = 60; [_table addTableColumn:c];
  }
  NSScrollView *scroll = [[NSScrollView alloc] init];
  scroll.documentView = _table;
  scroll.hasVerticalScroller = YES;
  scroll.hasHorizontalScroller = YES;
  scroll.borderType = NSBezelBorder;

  _sumLabel = [NSTextField labelWithString:@""];
  _sumLabel.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
  _sumLabel.textColor = NSColor.secondaryLabelColor;
  _sumLabel.selectable = YES;
  [_sumLabel setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

  _copyButton = [NSButton buttonWithTitle:@"复制结果" target:self action:@selector(copyAll:)];
  _copyButton.enabled = NO;
  _cancelButton = [NSButton buttonWithTitle:@"取消" target:self action:@selector(cancelOrClose:)];
  _cancelButton.keyEquivalent = @"\033";
  NSStackView *buttons = [NSStackView stackViewWithViews:@[_copyButton, _cancelButton]];
  buttons.spacing = 10;

  for (NSView *v in @[_progress, _statusLabel, scroll, _sumLabel, buttons]) {
    v.translatesAutoresizingMaskIntoConstraints = NO;
    [content addSubview:v];
  }
  const CGFloat pad = 14;
  [NSLayoutConstraint activateConstraints:@[
    [_progress.topAnchor constraintEqualToAnchor:content.topAnchor constant:pad],
    [_progress.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:pad],
    [_progress.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-pad],
    [_statusLabel.topAnchor constraintEqualToAnchor:_progress.bottomAnchor constant:6],
    [_statusLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:pad],
    [_statusLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-pad],
    [scroll.topAnchor constraintEqualToAnchor:_statusLabel.bottomAnchor constant:8],
    [scroll.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:pad],
    [scroll.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-pad],
    [_sumLabel.topAnchor constraintEqualToAnchor:scroll.bottomAnchor constant:8],
    [_sumLabel.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:pad],
    [_sumLabel.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-pad],
    [buttons.topAnchor constraintEqualToAnchor:_sumLabel.bottomAnchor constant:10],
    [buttons.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-pad],
    [buttons.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-pad],
  ]];

  if (parent && parent.isVisible)
    [_window setFrameOrigin:NSMakePoint(NSMidX(parent.frame) - width / 2, NSMidY(parent.frame) - 230)];
  [_window makeKeyAndOrderFront:nil];
}

- (void)startWithPaths:(NSArray<NSString *> *)paths {
  _calc = [SZHashCalculator new];
  [[SZDockProgress shared] beginOperation];
  __weak typeof(self) ws = self;
  [_calc calculateForPaths:paths methods:_methods delegate:self completion:^(SZHashSummary *sum) {
    [ws finishWithSummary:sum];
  }];
}

#pragma mark NSTableView 数据

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { return (NSInteger)_items.count; }

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
  SZHashItem *item = _items[(NSUInteger)row];
  NSString *cid = col.identifier;
  NSString *text; BOOL mono = NO;
  if ([cid isEqualToString:kColName]) text = item.path.length ? item.path : @"(空名)";
  else if ([cid isEqualToString:kColSize]) text = [_sizeFmt stringFromByteCount:(long long)item.size];
  else { text = [item hashForMethod:cid] ?: @""; mono = YES; }

  NSTextField *tf = [tableView makeViewWithIdentifier:col.identifier owner:self];
  if (!tf) {
    tf = [NSTextField labelWithString:@""];
    tf.identifier = col.identifier;
    tf.font = mono ? [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular]
                   : [NSFont systemFontOfSize:11];
    tf.lineBreakMode = NSLineBreakByTruncatingMiddle;
  }
  tf.stringValue = text;
  tf.toolTip = text;   // 完整值（哈希长，截断时悬停看全）
  return tf;
}

#pragma mark 进度 / 结果回调

- (void)hashCalculator:(SZHashCalculator *)calc
     didUpdateFraction:(double)fraction
        completedBytes:(uint64_t)completed
            totalBytes:(uint64_t)total {
  _progress.doubleValue = fraction;
  [[SZDockProgress shared] updateFraction:fraction];
}

- (void)hashCalculator:(SZHashCalculator *)calc didFinishFile:(SZHashItem *)item {
  [_items addObject:item];
  [_table reloadData];
  [_table scrollRowToVisible:(NSInteger)_items.count - 1];
}

- (void)hashCalculator:(SZHashCalculator *)calc didEncounterError:(NSString *)path message:(NSString *)message {
  _statusLabel.stringValue = [NSString stringWithFormat:@"⚠️ %@：%@", path, message];
  _statusLabel.textColor = NSColor.systemOrangeColor;
}

- (void)finishWithSummary:(SZHashSummary *)sum {
  [[SZDockProgress shared] endOperation];
  _done = YES; _summary = sum;
  _progress.hidden = YES;

  if (sum.dataSum.count > 0 && sum.numFiles > 0) {
    NSMutableString *s = [NSMutableString stringWithString:@"数据总和：  "];
    for (NSString *m in _methods) {
      NSString *h = sum.dataSum[m] ?: @"";
      [s appendFormat:@"%@=%@   ", m, h];
    }
    _sumLabel.stringValue = s;
  }

  NSString *stat = [NSString stringWithFormat:@"%@%lu 文件，%lu 文件夹，%lu 错误",
                    sum.ok ? @"✓ 完成：" : @"完成（有错误）：",
                    (unsigned long)sum.numFiles, (unsigned long)sum.numDirs, (unsigned long)sum.numErrors];
  if (sum.errorMessage.length) stat = [stat stringByAppendingFormat:@" · %@", sum.errorMessage];
  _statusLabel.stringValue = stat;
  _statusLabel.textColor = sum.ok ? NSColor.secondaryLabelColor : NSColor.systemRedColor;

  _copyButton.enabled = (_items.count > 0);
  _cancelButton.title = @"关闭";
}

#pragma mark 动作

// 复制为文本（对齐 7zz 风格：每文件多行 method=hash + 数据总和）
- (NSString *)resultText {
  NSMutableString *s = [NSMutableString string];
  for (SZHashItem *item in _items) {
    [s appendFormat:@"%@  (%@)\n", item.path.length ? item.path : @"(空名)",
                    [_sizeFmt stringFromByteCount:(long long)item.size]];
    for (NSString *m in _methods)
      [s appendFormat:@"  %-9@ %@\n", m, [item hashForMethod:m] ?: @""];
    [s appendString:@"\n"];
  }
  if (_summary.dataSum.count > 0 && _summary.numFiles > 0) {
    [s appendString:@"───────── 数据总和 ─────────\n"];
    for (NSString *m in _methods)
      [s appendFormat:@"  %-9@ %@\n", m, _summary.dataSum[m] ?: @""];
  }
  return s;
}

- (void)copyAll:(id)sender {
  NSPasteboard *pb = NSPasteboard.generalPasteboard;
  [pb clearContents];
  [pb setString:[self resultText] forType:NSPasteboardTypeString];
}

- (void)cancelOrClose:(id)sender {
  if (!_done) [_calc cancel];
  [_window close];
}

- (void)windowWillClose:(NSNotification *)note {
  if (!_done) [_calc cancel];
  [gLive removeObject:self];
}

@end
