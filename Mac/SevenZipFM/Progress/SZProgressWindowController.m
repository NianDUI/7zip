// SZProgressWindowController.m —— 见 .h。纯 AppKit，依赖 SevenZipKit 公开头 SZArchiveExtractor.h。
#import "SZProgressWindowController.h"
#import "SevenZipKit/SZArchiveExtractor.h"

@interface SZProgressWindowController () <SZArchiveExtractDelegate>
@end

@implementation SZProgressWindowController {
  SZArchiveExtractor *_extractor;
  NSWindow *_window;
  NSProgressIndicator *_bar;
  NSTextField *_titleLabel;     // 状态行（正在解压/测试）
  NSTextField *_fileLabel;      // 当前文件名
  NSTextField *_statsLabel;     // Elapsed / Processed / Speed / Files
  NSButton *_cancelButton;
  NSTimer *_timer;

  // 由 delegate 回调更新（主队列），timer 拉取刷 UI（对齐 CProgressSync）
  uint64_t _completedBytes;
  uint64_t _totalBytes;
  NSUInteger _fileCount;
  NSUInteger _errorCount;
  NSString *_currentFile;
  NSDate *_startDate;

  BOOL _finished;
  BOOL _cancelled;
  BOOL _testMode;
  NSString *_verb;          // "解压" / "测试"
  NSString *_archiveName;
  void (^_completion)(BOOL);
}

// self-retain 直到完成，避免调用方不持有时被 ARC 提前释放
static NSMutableSet *g_alive;

- (void)beginExtractArchive:(NSString *)archivePath
                    options:(SZArchiveExtractOptions *)options
                 completion:(void (^)(BOOL))completion {
  if (!g_alive) g_alive = [NSMutableSet new];
  [g_alive addObject:self];
  _completion = [completion copy];
  _archiveName = archivePath.lastPathComponent;
  _testMode = options.testMode;
  _verb = options.testMode ? @"测试" : @"解压";
  _startDate = [NSDate date];

  [self buildWindow];
  [_window makeKeyAndOrderFront:nil];

  _extractor = [SZArchiveExtractor new];
  __weak typeof(self) wself = self;
  [_extractor extractArchive:archivePath options:options delegate:self
                  completion:^(BOOL ok, uint64_t nf, uint64_t nfe, uint64_t noe, NSString *em) {
    [wself finishWithOK:ok errorMessage:em];
  }];

  _timer = [NSTimer scheduledTimerWithTimeInterval:0.2 target:self
                                          selector:@selector(refreshUI) userInfo:nil repeats:YES];
}

- (void)beginTestArchive:(NSString *)archivePath
                password:(NSString *)password
              completion:(void (^)(BOOL))completion {
  SZArchiveExtractOptions *opts = [SZArchiveExtractOptions new];
  opts.testMode = YES;
  if (password.length) opts.password = password;
  [self beginExtractArchive:archivePath options:opts completion:completion];
}

#pragma mark - UI 构建

- (void)buildWindow {
  NSRect frame = NSMakeRect(0, 0, 460, 168);
  _window = [[NSWindow alloc] initWithContentRect:frame
      styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskMiniaturizable)
      backing:NSBackingStoreBuffered defer:NO];
  _window.title = [NSString stringWithFormat:@"%@ %@", _verb, _archiveName];
  [_window center];

  _titleLabel = [NSTextField labelWithString:[NSString stringWithFormat:@"正在%@…", _verb]];
  _titleLabel.font = [NSFont boldSystemFontOfSize:13];

  _fileLabel = [NSTextField labelWithString:@""];
  _fileLabel.font = [NSFont systemFontOfSize:11];
  _fileLabel.textColor = NSColor.secondaryLabelColor;
  _fileLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;

  _bar = [NSProgressIndicator new];
  _bar.indeterminate = NO;
  _bar.minValue = 0; _bar.maxValue = 1;
  _bar.style = NSProgressIndicatorStyleBar;

  _statsLabel = [NSTextField labelWithString:@"已用 0:00   已处理 0 B   速度 –   文件 0"];
  _statsLabel.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
  _statsLabel.textColor = NSColor.secondaryLabelColor;

  _cancelButton = [NSButton buttonWithTitle:@"取消" target:self action:@selector(onCancel:)];
  _cancelButton.keyEquivalent = @"\033"; // Esc

  NSStackView *col = [NSStackView stackViewWithViews:@[_titleLabel, _fileLabel, _bar, _statsLabel]];
  col.orientation = NSUserInterfaceLayoutOrientationVertical;
  col.alignment = NSLayoutAttributeLeading;
  col.spacing = 8;
  col.translatesAutoresizingMaskIntoConstraints = NO;

  NSView *content = _window.contentView;
  [content addSubview:col];
  [content addSubview:_cancelButton];
  _cancelButton.translatesAutoresizingMaskIntoConstraints = NO;
  [NSLayoutConstraint activateConstraints:@[
    [col.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:18],
    [col.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-18],
    [col.topAnchor constraintEqualToAnchor:content.topAnchor constant:16],
    [_bar.widthAnchor constraintEqualToAnchor:col.widthAnchor],
    [_cancelButton.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-18],
    [_cancelButton.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-14],
  ]];
}

#pragma mark - 统计刷新（NSTimer 拉取）

static NSString *FormatBytes(uint64_t b) {
  return [NSByteCountFormatter stringFromByteCount:(long long)b countStyle:NSByteCountFormatterCountStyleFile];
}
static NSString *FormatElapsed(NSTimeInterval s) {
  int t = (int)s; return [NSString stringWithFormat:@"%d:%02d", t / 60, t % 60];
}

- (void)refreshUI {
  if (_finished) return;
  if (_totalBytes > 0)
    _bar.doubleValue = (double)_completedBytes / (double)_totalBytes;

  const NSTimeInterval elapsed = -[_startDate timeIntervalSinceNow];
  NSString *speed = @"–";
  if (elapsed > 0.3 && _completedBytes > 0)
    speed = [NSString stringWithFormat:@"%@/s", FormatBytes((uint64_t)(_completedBytes / elapsed))];

  _statsLabel.stringValue = [NSString stringWithFormat:@"已用 %@   已处理 %@   速度 %@   文件 %lu%@",
      FormatElapsed(elapsed), FormatBytes(_completedBytes), speed, (unsigned long)_fileCount,
      _errorCount ? [NSString stringWithFormat:@"   错误 %lu", (unsigned long)_errorCount] : @""];

  if (_currentFile) _fileLabel.stringValue = _currentFile;

  const int pct = _totalBytes ? (int)(100.0 * _completedBytes / _totalBytes) : 0;
  _window.title = [NSString stringWithFormat:@"%d%%  %@ %@", pct, _verb, _archiveName];
}

#pragma mark - 取消

- (void)onCancel:(id)sender {
  _cancelled = YES;
  _cancelButton.enabled = NO;
  _titleLabel.stringValue = @"正在取消…";
  [_extractor cancel];
}

- (void)finishWithOK:(BOOL)ok errorMessage:(NSString *)em {
  _finished = YES;
  [_timer invalidate]; _timer = nil;
  [_window orderOut:nil];

  if (!_cancelled) {
    if (!ok && em.length) {
      NSAlert *a = [NSAlert new];
      a.messageText = [NSString stringWithFormat:@"%@未完全成功", _verb];
      a.informativeText = em;
      [a addButtonWithTitle:@"好"];
      [a runModal];
    } else if (ok && _testMode) {
      NSAlert *a = [NSAlert new];        // 对齐 7zz t 的「没有错误」
      a.messageText = @"测试完成";
      a.informativeText = [NSString stringWithFormat:@"「%@」没有错误。", _archiveName];
      [a addButtonWithTitle:@"好"];
      [a runModal];
    }
  }
  if (_completion) _completion(ok);
  [g_alive removeObject:self];   // 释放自持
}

#pragma mark - SZArchiveExtractDelegate（进度回调：仅更新 ivar，主队列）

- (void)extractor:(SZArchiveExtractor *)ex didUpdateFraction:(double)fraction
    completedBytes:(uint64_t)completed totalBytes:(uint64_t)total {
  _completedBytes = completed; _totalBytes = total;
}

- (void)extractor:(SZArchiveExtractor *)ex willStartFile:(NSString *)name isDirectory:(BOOL)isDir {
  _currentFile = name;
  if (!isDir) _fileCount++;
}

- (void)extractor:(SZArchiveExtractor *)ex didFailFile:(NSString *)name message:(NSString *)message {
  _errorCount++;
}

#pragma mark - SZArchiveExtractDelegate（阻塞询问：主线程同步弹框）

- (SZOverwriteResponse)extractor:(SZArchiveExtractor *)ex
            askOverwriteExisting:(NSString *)existingPath
                       existSize:(uint64_t)existSize existDate:(NSDate *)existDate
                         withNew:(NSString *)newPath
                         newSize:(uint64_t)newSize newDate:(NSDate *)newDate {
  NSAlert *a = [NSAlert new];
  a.messageText = @"确认替换文件";
  a.informativeText = [NSString stringWithFormat:@"目标位置已存在同名文件：\n%@\n\n已有：%@\n归档：%@\n是否替换？",
      existingPath.lastPathComponent, FormatBytes(existSize), FormatBytes(newSize)];
  // 顺序须与 switch 一致（Windows AskOverwrite 全档）
  [a addButtonWithTitle:@"替换"];        // Yes
  [a addButtonWithTitle:@"全部替换"];    // YesToAll
  [a addButtonWithTitle:@"跳过"];        // No
  [a addButtonWithTitle:@"全部跳过"];    // NoToAll
  [a addButtonWithTitle:@"自动重命名"];  // AutoRename
  [a addButtonWithTitle:@"取消"];        // Cancel
  switch ([a runModal]) {
    case NSAlertFirstButtonReturn:        return SZOverwriteResponseYes;
    case NSAlertFirstButtonReturn + 1:    return SZOverwriteResponseYesToAll;
    case NSAlertFirstButtonReturn + 2:    return SZOverwriteResponseNo;
    case NSAlertFirstButtonReturn + 3:    return SZOverwriteResponseNoToAll;
    case NSAlertFirstButtonReturn + 4:    return SZOverwriteResponseAutoRename;
    default:                              return SZOverwriteResponseCancel;
  }
}

- (NSString *)extractorAskPassword:(SZArchiveExtractor *)ex {
  NSAlert *a = [NSAlert new];
  a.messageText = @"输入密码";
  a.informativeText = [NSString stringWithFormat:@"归档「%@」已加密，请输入密码：", _archiveName];
  NSSecureTextField *tf = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
  a.accessoryView = tf;
  [a addButtonWithTitle:@"确定"];
  [a addButtonWithTitle:@"取消"];
  // 让密码框获得焦点
  [a.window setInitialFirstResponder:tf];
  if ([a runModal] == NSAlertFirstButtonReturn) return tf.stringValue;
  return nil; // 取消
}

@end
