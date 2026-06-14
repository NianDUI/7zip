// SZProgressWindowController.m —— 见 .h。纯 AppKit，依赖 SevenZipKit 公开头 SZArchiveExtractor.h。
#import "SZProgressWindowController.h"
#import "SevenZipKit/SZArchiveExtractor.h"
#import "SevenZipKit/SZArchiveCompressor.h"   // 压缩（M3-T2）
#import "SZQuarantine.h"   // 网络来源标记传播（M2-T7）

@interface SZProgressWindowController () <SZArchiveExtractDelegate, SZArchiveCompressDelegate>
@end

@implementation SZProgressWindowController {
  SZArchiveExtractor *_extractor;
  SZArchiveCompressor *_compressor;
  NSWindow *_window;
  NSProgressIndicator *_bar;
  NSTextField *_titleLabel;     // 状态行（正在解压/测试）
  NSTextField *_fileLabel;      // 当前文件名
  NSTextField *_statsLabel;     // Elapsed / Processed / Speed / Files
  NSButton *_cancelButton;
  NSButton *_pauseButton;
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
  BOOL _paused;
  NSDate *_pauseStart;
  NSTimeInterval _pausedDuration;   // 累计暂停时长，从 elapsed 扣除（暂停期不计速度）
  BOOL _testMode;
  NSString *_verb;          // "解压" / "测试"
  NSString *_archiveName;
  NSString *_archivePath;   // 完整路径（quarantine 源，M2-T7）
  NSString *_outputDir;
  NSSet<NSString *> *_preSnapshot;   // 解压前 outputDir 顶层项，diff 出新增项
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
  _archivePath = archivePath;
  _testMode = options.testMode;
  _verb = options.testMode ? @"测试" : @"解压";
  _startDate = [NSDate date];
  // 解压前快照目标目录顶层项，完成后 diff 出新增项以传播 quarantine（M2-T7）
  _outputDir = options.testMode ? nil : options.outputDirectory;
  if (_outputDir) {
    NSArray *before = [NSFileManager.defaultManager contentsOfDirectoryAtPath:_outputDir error:nil];
    _preSnapshot = before ? [NSSet setWithArray:before] : [NSSet set];
  }

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

- (void)beginCompressToArchive:(NSString *)archivePath
                       options:(SZCompressOptions *)options
                    completion:(void (^)(BOOL))completion {
  if (!g_alive) g_alive = [NSMutableSet new];
  [g_alive addObject:self];
  _completion = [completion copy];
  _archiveName = archivePath.lastPathComponent;
  _verb = @"压缩";
  _startDate = [NSDate date];

  [self buildWindow];
  [_window makeKeyAndOrderFront:nil];

  _compressor = [SZArchiveCompressor new];
  __weak typeof(self) wself = self;
  [_compressor compressToArchive:archivePath options:options delegate:self
                      completion:^(BOOL ok, uint64_t size, NSString *em) {
    [wself finishWithOK:ok errorMessage:em];
  }];
  _timer = [NSTimer scheduledTimerWithTimeInterval:0.2 target:self
                                          selector:@selector(refreshUI) userInfo:nil repeats:YES];
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
  _pauseButton = [NSButton buttonWithTitle:@"暂停" target:self action:@selector(onPauseResume:)];

  NSStackView *col = [NSStackView stackViewWithViews:@[_titleLabel, _fileLabel, _bar, _statsLabel]];
  col.orientation = NSUserInterfaceLayoutOrientationVertical;
  col.alignment = NSLayoutAttributeLeading;
  col.spacing = 8;
  col.translatesAutoresizingMaskIntoConstraints = NO;

  NSView *content = _window.contentView;
  [content addSubview:col];
  [content addSubview:_cancelButton];
  [content addSubview:_pauseButton];
  _cancelButton.translatesAutoresizingMaskIntoConstraints = NO;
  _pauseButton.translatesAutoresizingMaskIntoConstraints = NO;
  [NSLayoutConstraint activateConstraints:@[
    [col.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:18],
    [col.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-18],
    [col.topAnchor constraintEqualToAnchor:content.topAnchor constant:16],
    [_bar.widthAnchor constraintEqualToAnchor:col.widthAnchor],
    [_cancelButton.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-18],
    [_cancelButton.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-14],
    [_pauseButton.trailingAnchor constraintEqualToAnchor:_cancelButton.leadingAnchor constant:-10],
    [_pauseButton.centerYAnchor constraintEqualToAnchor:_cancelButton.centerYAnchor],
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

  // elapsed 扣除累计暂停时长（含当前正暂停的时段），使速度/剩余时间不被暂停拉偏
  NSTimeInterval elapsed = -[_startDate timeIntervalSinceNow] - _pausedDuration;
  if (_paused && _pauseStart) elapsed -= -[_pauseStart timeIntervalSinceNow];
  if (elapsed < 0) elapsed = 0;

  NSString *speed = @"–", *remain = @"–";
  if (elapsed > 0.3 && _completedBytes > 0) {
    speed = [NSString stringWithFormat:@"%@/s", FormatBytes((uint64_t)(_completedBytes / elapsed))];
    if (_totalBytes > _completedBytes) {
      NSTimeInterval rem = (double)(_totalBytes - _completedBytes) * elapsed / (double)_completedBytes;
      remain = FormatElapsed(rem);
    }
  }

  _statsLabel.stringValue = [NSString stringWithFormat:@"已用 %@ / 剩余 %@   %@ / %@   速度 %@   文件 %lu%@",
      FormatElapsed(elapsed), remain, FormatBytes(_completedBytes), FormatBytes(_totalBytes), speed,
      (unsigned long)_fileCount,
      _errorCount ? [NSString stringWithFormat:@"   错误 %lu", (unsigned long)_errorCount] : @""];

  if (_currentFile) _fileLabel.stringValue = _currentFile;

  const int pct = _totalBytes ? (int)(100.0 * _completedBytes / _totalBytes) : 0;
  _window.title = [NSString stringWithFormat:@"%@%d%%  %@ %@",
      _paused ? @"[暂停] " : @"", pct, _verb, _archiveName];
}

- (void)onPauseResume:(id)sender {
  _paused = !_paused;
  [_extractor setPaused:_paused];
  [_compressor setPaused:_paused];
  _pauseButton.title = _paused ? @"继续" : @"暂停";
  if (_paused) {
    _pauseStart = [NSDate date];
  } else if (_pauseStart) {
    _pausedDuration += -[_pauseStart timeIntervalSinceNow];
    _pauseStart = nil;
  }
}

#pragma mark - 取消

- (void)onCancel:(id)sender {
  _cancelled = YES;
  _cancelButton.enabled = NO;
  _titleLabel.stringValue = @"正在取消…";
  [_extractor cancel];
  [_compressor cancel];   // nil 调用安全：解压/压缩仅一个非空
}

- (void)finishWithOK:(BOOL)ok errorMessage:(NSString *)em {
  _finished = YES;
  [_timer invalidate]; _timer = nil;
  [_window orderOut:nil];

  // 网络来源标记传播：源归档带 quarantine 时，给本次新解出的顶层项打 quarantine（M2-T7）
  if (ok && _outputDir && SZArchiveHasQuarantine(_archivePath)) {
    NSArray *after = [NSFileManager.defaultManager contentsOfDirectoryAtPath:_outputDir error:nil];
    for (NSString *name in after)
      if (![_preSnapshot containsObject:name])
        SZApplyQuarantineFrom(_archivePath, [_outputDir stringByAppendingPathComponent:name]);
  }

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
  return [self askPassword];
}

- (NSString *)askPassword {
  NSAlert *a = [NSAlert new];
  a.messageText = @"输入密码";
  a.informativeText = [NSString stringWithFormat:@"归档「%@」需要密码：", _archiveName];
  NSSecureTextField *tf = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
  a.accessoryView = tf;
  [a addButtonWithTitle:@"确定"];
  [a addButtonWithTitle:@"取消"];
  [a.window setInitialFirstResponder:tf];
  if ([a runModal] == NSAlertFirstButtonReturn) return tf.stringValue;
  return nil; // 取消
}

#pragma mark - SZArchiveCompressDelegate（压缩进度，M3-T2）

- (void)compressor:(SZArchiveCompressor *)c didUpdateFraction:(double)fraction
    completedBytes:(uint64_t)completed totalBytes:(uint64_t)total {
  _completedBytes = completed; _totalBytes = total;
}
- (void)compressor:(SZArchiveCompressor *)c willAddFile:(NSString *)name {
  _currentFile = name; _fileCount++;
}
- (void)compressor:(SZArchiveCompressor *)c scanError:(NSString *)path message:(NSString *)message {
  _errorCount++;
}
- (NSString *)compressorAskPassword:(SZArchiveCompressor *)c {
  return [self askPassword];
}

@end
