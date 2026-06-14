// SZHashResultController.m —— 校验和结果窗实现（M5）。
#import "SZHashResultController.h"
#import "SevenZipKit/SZHashCalculator.h"

@interface SZHashResultController () <SZHashDelegate>
@end

@implementation SZHashResultController {
  NSWindow *_window;
  NSTextView *_textView;
  NSProgressIndicator *_progress;
  NSTextField *_statusLabel;
  NSButton *_copyButton;
  NSButton *_cancelButton;
  SZHashCalculator *_calc;
  NSArray<NSString *> *_methods;
  BOOL _done;
}

// 自我保活：窗口存活期间留在集合里，关闭时移除。
static NSMutableSet<SZHashResultController *> *gLive;

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
  if ((self = [super init])) { _methods = [methods copy]; }
  return self;
}

- (void)showRelativeTo:(NSWindow *)parent {
  _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 640, 440)
      styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable)
      backing:NSBackingStoreBuffered defer:NO];
  _window.title = [NSString stringWithFormat:@"校验和 · %@", [_methods componentsJoinedByString:@" / "]];
  _window.releasedWhenClosed = NO;
  _window.delegate = (id)self;
  [_window center];

  NSView *content = _window.contentView;

  _progress = [[NSProgressIndicator alloc] init];
  _progress.style = NSProgressIndicatorStyleBar;
  _progress.indeterminate = NO;
  _progress.minValue = 0; _progress.maxValue = 1;

  _statusLabel = [NSTextField labelWithString:@"计算中…"];
  _statusLabel.font = [NSFont systemFontOfSize:11];
  _statusLabel.textColor = NSColor.secondaryLabelColor;

  NSScrollView *scroll = [[NSScrollView alloc] init];
  scroll.hasVerticalScroller = YES;
  scroll.borderType = NSBezelBorder;
  _textView = [[NSTextView alloc] init];
  _textView.editable = NO;
  _textView.richText = NO;
  _textView.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
  _textView.automaticQuoteSubstitutionEnabled = NO;
  _textView.minSize = NSMakeSize(0, 0);
  _textView.maxSize = NSMakeSize(FLT_MAX, FLT_MAX);
  _textView.verticallyResizable = YES;
  _textView.horizontallyResizable = NO;
  _textView.textContainer.widthTracksTextView = YES;
  scroll.documentView = _textView;

  _copyButton = [NSButton buttonWithTitle:@"复制结果" target:self action:@selector(copyAll:)];
  _copyButton.enabled = NO;
  _cancelButton = [NSButton buttonWithTitle:@"取消" target:self action:@selector(cancelOrClose:)];
  _cancelButton.keyEquivalent = @"\033";   // Esc

  NSStackView *buttons = [NSStackView stackViewWithViews:@[_copyButton, _cancelButton]];
  buttons.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  buttons.spacing = 10;

  for (NSView *v in @[_progress, _statusLabel, scroll, buttons]) {
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

    [buttons.topAnchor constraintEqualToAnchor:scroll.bottomAnchor constant:10],
    [buttons.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-pad],
    [buttons.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-pad],
  ]];

  if (parent && parent.isVisible)
    [_window setFrameOrigin:NSMakePoint(NSMidX(parent.frame) - 320, NSMidY(parent.frame) - 220)];
  [_window makeKeyAndOrderFront:nil];
}

- (void)startWithPaths:(NSArray<NSString *> *)paths {
  _calc = [SZHashCalculator new];
  __weak typeof(self) ws = self;
  [_calc calculateForPaths:paths methods:_methods delegate:self completion:^(SZHashSummary *sum) {
    [ws finishWithSummary:sum];
  }];
}

#pragma mark 文本输出

- (void)append:(NSString *)s {
  [_textView.textStorage.mutableString appendString:s];
  [_textView scrollRangeToVisible:NSMakeRange(_textView.string.length, 0)];
}

- (void)hashCalculator:(SZHashCalculator *)calc
     didUpdateFraction:(double)fraction
        completedBytes:(uint64_t)completed
            totalBytes:(uint64_t)total {
  _progress.doubleValue = fraction;
}

- (void)hashCalculator:(SZHashCalculator *)calc didFinishFile:(SZHashItem *)item {
  NSByteCountFormatter *fmt = [NSByteCountFormatter new];
  NSMutableString *block = [NSMutableString string];
  [block appendFormat:@"%@  (%@)\n", item.path.length ? item.path : @"(空名)",
                      [fmt stringFromByteCount:(long long)item.size]];
  for (NSString *m in _methods) {
    NSString *h = [item hashForMethod:m] ?: @"";
    [block appendFormat:@"  %-9@ %@\n", m, h];
  }
  [block appendString:@"\n"];
  [self append:block];
}

- (void)hashCalculator:(SZHashCalculator *)calc didEncounterError:(NSString *)path message:(NSString *)message {
  [self append:[NSString stringWithFormat:@"⚠️ %@：%@\n\n", path, message]];
}

- (void)finishWithSummary:(SZHashSummary *)sum {
  _done = YES;
  _progress.doubleValue = sum.ok ? 1.0 : _progress.doubleValue;
  _progress.hidden = YES;

  if (sum.dataSum.count > 0 && sum.numFiles > 0) {
    NSMutableString *tail = [NSMutableString stringWithString:@"───────── 数据总和 ─────────\n"];
    for (NSString *m in _methods) {
      NSString *h = sum.dataSum[m] ?: @"";
      [tail appendFormat:@"  %-9@ %@\n", m, h];
    }
    [self append:tail];
  }

  NSString *stat = [NSString stringWithFormat:@"%@%lu 文件，%lu 文件夹，%lu 错误",
                    sum.ok ? @"✓ 完成：" : @"完成（有错误）：",
                    (unsigned long)sum.numFiles, (unsigned long)sum.numDirs, (unsigned long)sum.numErrors];
  if (sum.errorMessage.length) stat = [stat stringByAppendingFormat:@" · %@", sum.errorMessage];
  _statusLabel.stringValue = stat;
  _statusLabel.textColor = sum.ok ? NSColor.secondaryLabelColor : NSColor.systemRedColor;

  _copyButton.enabled = (_textView.string.length > 0);
  _cancelButton.title = @"关闭";
}

#pragma mark 动作

- (void)copyAll:(id)sender {
  NSPasteboard *pb = NSPasteboard.generalPasteboard;
  [pb clearContents];
  [pb setString:_textView.string forType:NSPasteboardTypeString];
}

- (void)cancelOrClose:(id)sender {
  if (!_done) [_calc cancel];
  [_window close];
}

- (void)windowWillClose:(NSNotification *)note {
  if (!_done) [_calc cancel];
  [gLive removeObject:self];   // 释放保活引用
}

@end
