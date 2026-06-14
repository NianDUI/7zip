// SZCompressDialogController.m —— 见 .h。纯 AppKit + SevenZipKit 公开头。
#import "SZCompressDialogController.h"
#import "SevenZipKit/SZArchiveCompressor.h"

// 格式 popup 顺序 / 等级 popup 顺序 / 线程 popup 顺序 / 精度 popup 顺序
static NSString *const kFormats[] = { @"7z", @"zip", @"tar" };
static const NSInteger kLevels[] = { 0, 1, 3, 5, 7, 9 };            // 仅存储/最快/快速/标准/最大/极限
static const NSInteger kThreadCounts[] = { 0, 1, 2, 4, 6, 8, 12, 16 };  // 0=自动
static const NSInteger kPrecValues[] = { -1, 23, 3 };              // 默认 / 100纳秒 / 1纳秒(最高)

// 内存字节格式化（对齐 CompressDialog.cpp::AddMemUsage 的向上取整到 MB/GB/TB）
static NSString *SZFmtMem(uint64_t v) {
  if (v == (uint64_t)-1) return @"?";
  if (v <= ((uint64_t)16 << 30)) return [NSString stringWithFormat:@"%llu MB", (unsigned long long)((v + (1 << 20) - 1) >> 20)];
  if (v <= ((uint64_t)64 << 40)) return [NSString stringWithFormat:@"%llu GB", (unsigned long long)((v + (1 << 30) - 1) >> 30)];
  return [NSString stringWithFormat:@"%llu TB", (unsigned long long)((v + ((uint64_t)1 << 40) - 1) >> 40)];
}

@implementation SZCompressDialogController {
  NSWindow *_window;
  NSWindow *_parent;
  NSArray<NSString *> *_inputs;
  NSTextField *_archiveField;
  NSPopUpButton *_formatPopup;
  NSPopUpButton *_levelPopup;
  NSPopUpButton *_threadsPopup;
  NSTextField *_memoryLabel;
  NSSecureTextField *_passwordField;
  NSButton *_encHeaderCheck;
  NSButton *_mtimeCheck, *_ctimeCheck, *_atimeCheck;
  NSPopUpButton *_precisionPopup;
  NSString *_resultPath;
  SZCompressOptions *_resultOptions;
  void (^_completion)(NSString *, SZCompressOptions *);
}

static NSMutableSet *g_alive;

+ (void)presentForInputs:(NSArray<NSString *> *)inputPaths
      defaultArchivePath:(NSString *)defaultArchivePath
            parentWindow:(NSWindow *)parent
              completion:(void (^)(NSString *, SZCompressOptions *))completion {
  SZCompressDialogController *c = [SZCompressDialogController new];
  if (!g_alive) g_alive = [NSMutableSet new];
  [g_alive addObject:c];
  c->_inputs = inputPaths;
  c->_completion = [completion copy];
  c->_parent = parent;
  [c buildWindowWithDefault:defaultArchivePath];

  __weak typeof(c) wc = c;
  [parent beginSheet:c->_window completionHandler:^(NSModalResponse resp) {
    typeof(c) sc = wc;
    if (sc->_completion) sc->_completion(resp == NSModalResponseOK ? sc->_resultPath : nil,
                                          resp == NSModalResponseOK ? sc->_resultOptions : nil);
    [g_alive removeObject:sc];
  }];
}

- (NSTextField *)label:(NSString *)s {
  NSTextField *t = [NSTextField labelWithString:s];
  t.alignment = NSTextAlignmentRight;
  return t;
}

- (void)buildWindowWithDefault:(NSString *)defaultArchivePath {
  _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 560, 420)
      styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
  _window.title = @"添加到归档";

  NSTextField *head = [NSTextField labelWithString:
      [NSString stringWithFormat:@"压缩 %lu 个项目", (unsigned long)_inputs.count]];
  head.font = [NSFont boldSystemFontOfSize:13];

  _archiveField = [NSTextField new];
  _archiveField.stringValue = defaultArchivePath ?: @"";
  NSButton *browse = [NSButton buttonWithTitle:@"浏览…" target:self action:@selector(onBrowse:)];
  [_archiveField setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
  NSStackView *arcRow = [NSStackView stackViewWithViews:@[_archiveField, browse]];
  arcRow.orientation = NSUserInterfaceLayoutOrientationHorizontal; arcRow.spacing = 6;

  _formatPopup = [NSPopUpButton new];
  [_formatPopup addItemsWithTitles:@[@"7z", @"zip", @"tar"]];
  _formatPopup.target = self; _formatPopup.action = @selector(onFormatChange:);

  _levelPopup = [NSPopUpButton new];
  [_levelPopup addItemsWithTitles:@[@"仅存储", @"最快", @"快速", @"标准", @"最大", @"极限"]];
  [_levelPopup selectItemAtIndex:3];   // 标准(5)
  _levelPopup.target = self; _levelPopup.action = @selector(onParamChange:);

  _threadsPopup = [NSPopUpButton new];
  [_threadsPopup addItemsWithTitles:@[@"自动", @"1", @"2", @"4", @"6", @"8", @"12", @"16"]];
  _threadsPopup.target = self; _threadsPopup.action = @selector(onParamChange:);

  _memoryLabel = [NSTextField labelWithString:@""];
  _memoryLabel.textColor = [NSColor secondaryLabelColor];

  _passwordField = [NSSecureTextField new];
  [_passwordField.cell setPlaceholderString:@"（留空=不加密）"];

  _encHeaderCheck = [NSButton checkboxWithTitle:@"加密文件名（仅 7z）" target:nil action:nil];

  // —— 时间戳（T3）——
  _mtimeCheck = [NSButton checkboxWithTitle:@"修改时间" target:nil action:nil];
  _mtimeCheck.state = NSControlStateValueOn;   // 引擎默认存 mtime
  _ctimeCheck = [NSButton checkboxWithTitle:@"创建时间" target:nil action:nil];
  _atimeCheck = [NSButton checkboxWithTitle:@"访问时间" target:nil action:nil];
  NSStackView *timeRow = [NSStackView stackViewWithViews:@[_mtimeCheck, _ctimeCheck, _atimeCheck]];
  timeRow.orientation = NSUserInterfaceLayoutOrientationHorizontal; timeRow.spacing = 12;

  _precisionPopup = [NSPopUpButton new];
  [_precisionPopup addItemsWithTitles:@[@"默认", @"100 纳秒", @"纳秒（最高）"]];

  NSGridView *grid = [NSGridView gridViewWithViews:@[
    @[[self label:@"归档："],     arcRow],
    @[[self label:@"格式："],     _formatPopup],
    @[[self label:@"压缩等级："], _levelPopup],
    @[[self label:@"线程："],     _threadsPopup],
    @[[self label:@"需要内存："], _memoryLabel],
    @[[self label:@"密码："],     _passwordField],
    @[[NSGridCell emptyContentView], _encHeaderCheck],
    @[[self label:@"时间戳："],   timeRow],
    @[[self label:@"时间精度："], _precisionPopup],
  ]];
  grid.columnSpacing = 10; grid.rowSpacing = 10;
  [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;

  NSButton *cancel = [NSButton buttonWithTitle:@"取消" target:self action:@selector(onCancel:)];
  cancel.keyEquivalent = @"\033";
  NSButton *ok = [NSButton buttonWithTitle:@"压缩" target:self action:@selector(onOK:)];
  ok.keyEquivalent = @"\r";
  NSView *spacer = [NSView new];
  [spacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
  NSStackView *btnRow = [NSStackView stackViewWithViews:@[spacer, cancel, ok]];
  btnRow.orientation = NSUserInterfaceLayoutOrientationHorizontal; btnRow.spacing = 10;

  NSStackView *col = [NSStackView stackViewWithViews:@[head, grid, btnRow]];
  col.orientation = NSUserInterfaceLayoutOrientationVertical;
  col.alignment = NSLayoutAttributeLeading; col.spacing = 14;
  col.edgeInsets = NSEdgeInsetsMake(18, 18, 18, 18);
  col.translatesAutoresizingMaskIntoConstraints = NO;
  [_window.contentView addSubview:col];
  [NSLayoutConstraint activateConstraints:@[
    [col.leadingAnchor constraintEqualToAnchor:_window.contentView.leadingAnchor],
    [col.trailingAnchor constraintEqualToAnchor:_window.contentView.trailingAnchor],
    [col.topAnchor constraintEqualToAnchor:_window.contentView.topAnchor],
    [col.bottomAnchor constraintEqualToAnchor:_window.contentView.bottomAnchor],
    [_archiveField.widthAnchor constraintGreaterThanOrEqualToConstant:320],
    [_formatPopup.widthAnchor constraintGreaterThanOrEqualToConstant:160],
    [_levelPopup.widthAnchor constraintGreaterThanOrEqualToConstant:160],
    [_threadsPopup.widthAnchor constraintGreaterThanOrEqualToConstant:160],
    [_passwordField.widthAnchor constraintGreaterThanOrEqualToConstant:220],
    [_precisionPopup.widthAnchor constraintGreaterThanOrEqualToConstant:160],
    [btnRow.widthAnchor constraintEqualToAnchor:col.widthAnchor constant:-36],
  ]];
  [self onFormatChange:nil];

  // 让窗口高度贴合内容，避免中部大片空白（col 四边钉死时若窗口偏高会被拉开）。
  [_window.contentView layoutSubtreeIfNeeded];
  [_window setContentSize:NSMakeSize(560, col.fittingSize.height)];
}

#pragma mark - 动作

- (NSString *)selectedFormat { return kFormats[_formatPopup.indexOfSelectedItem]; }

// 格式变化：加密头/时间精度仅 7z；时间戳仅 7z/zip（tar 不支持扩展时间）；同步扩展名与内存。
- (void)onFormatChange:(id)sender {
  NSString *fmt = [self selectedFormat];
  const BOOL is7z  = [fmt isEqualToString:@"7z"];
  const BOOL isTar = [fmt isEqualToString:@"tar"];
  _encHeaderCheck.enabled = is7z;
  if (!is7z) _encHeaderCheck.state = NSControlStateValueOff;
  // 时间戳：tar 禁用整组；时间精度仅 7z
  _mtimeCheck.enabled = _ctimeCheck.enabled = _atimeCheck.enabled = !isTar;
  _precisionPopup.enabled = is7z;
  if (!is7z) [_precisionPopup selectItemAtIndex:0];
  // 把归档扩展名换成当前格式
  NSString *cur = _archiveField.stringValue;
  if (cur.length) {
    NSString *base = cur.stringByDeletingPathExtension;
    _archiveField.stringValue = [base stringByAppendingPathExtension:fmt];
  }
  [self onParamChange:nil];
}

// 等级/格式/线程变化 → 刷新内存估算标签
- (void)onParamChange:(id)sender {
  const NSInteger level = kLevels[_levelPopup.indexOfSelectedItem];
  const NSInteger threads = kThreadCounts[_threadsPopup.indexOfSelectedItem];
  SZMemoryEstimate m = [SZArchiveCompressor memoryEstimateForFormat:[self selectedFormat]
                                                              level:level threads:threads];
  _memoryLabel.stringValue = [NSString stringWithFormat:@"压缩 %@ · 解压 %@",
      SZFmtMem(m.compressBytes), SZFmtMem(m.decompressBytes)];
}

- (void)onBrowse:(id)sender {
  NSSavePanel *p = [NSSavePanel savePanel];
  p.nameFieldStringValue = _archiveField.stringValue.lastPathComponent;
  NSString *dir = _archiveField.stringValue.stringByDeletingLastPathComponent;
  if (dir.length) p.directoryURL = [NSURL fileURLWithPath:dir];
  if ([p runModal] == NSModalResponseOK && p.URL) _archiveField.stringValue = p.URL.path;
}

- (void)onCancel:(id)sender {
  [_parent endSheet:_window returnCode:NSModalResponseCancel];
  [_window orderOut:nil];
}

- (void)onOK:(id)sender {
  NSString *path = _archiveField.stringValue;
  if (!path.length || _inputs.count == 0) { NSBeep(); return; }
  NSString *fmt = [self selectedFormat];
  // 确保扩展名与格式一致
  if (![path.pathExtension.lowercaseString isEqualToString:fmt])
    path = [path.stringByDeletingPathExtension stringByAppendingPathExtension:fmt];

  SZCompressOptions *o = [SZCompressOptions new];
  o.format = fmt;
  o.level = kLevels[_levelPopup.indexOfSelectedItem];
  o.threads = kThreadCounts[_threadsPopup.indexOfSelectedItem];
  o.inputPaths = _inputs;
  if (_passwordField.stringValue.length) o.password = _passwordField.stringValue;
  o.encryptHeader = ([fmt isEqualToString:@"7z"] && _encHeaderCheck.state == NSControlStateValueOn);
  // 时间戳：仅在该组可用（非 tar）时采纳；精度仅 7z
  if (![fmt isEqualToString:@"tar"]) {
    o.storeMTime = (_mtimeCheck.state == NSControlStateValueOn);
    o.storeCTime = (_ctimeCheck.state == NSControlStateValueOn);
    o.storeATime = (_atimeCheck.state == NSControlStateValueOn);
  }
  if ([fmt isEqualToString:@"7z"])
    o.timePrecision = (SZTimePrecision)kPrecValues[_precisionPopup.indexOfSelectedItem];

  _resultPath = path;
  _resultOptions = o;

  [_parent endSheet:_window returnCode:NSModalResponseOK];
  [_window orderOut:nil];
}

@end
