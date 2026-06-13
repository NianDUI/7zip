// SZExtractDialogController.m —— 见 .h。纯 AppKit + SevenZipKit 公开头。
#import "SZExtractDialogController.h"
#import "SevenZipKit/SZArchiveExtractor.h"

// 目标目录历史（≤16，对齐 Windows CExtractDialog 历史）。首版用 NSUserDefaults 独立 key；
// 与 ZipRegistry_mac 的 NExtract::CInfo.Paths 统一留 M4 选项页（标注）。
static NSString *const kDestHistoryKey = @"SZExtractDestHistory";

static NSArray<NSString *> *LoadHistory(void) {
  return [NSUserDefaults.standardUserDefaults stringArrayForKey:kDestHistoryKey] ?: @[];
}
static void SaveHistory(NSString *path) {
  if (!path.length) return;
  NSMutableArray *h = [LoadHistory() mutableCopy];
  [h removeObject:path];
  [h insertObject:path atIndex:0];
  while (h.count > 16) [h removeLastObject];
  [NSUserDefaults.standardUserDefaults setObject:h forKey:kDestHistoryKey];
}

@implementation SZExtractDialogController {
  NSWindow *_window;
  NSWindow *_parent;
  NSComboBox *_destCombo;
  NSPopUpButton *_pathModePopup;
  NSPopUpButton *_overwritePopup;
  NSSecureTextField *_passwordField;
  NSButton *_elimDupCheck;
  SZArchiveExtractOptions *_result;     // 确定时填
  void (^_completion)(SZArchiveExtractOptions *);
}

static NSMutableSet *g_alive;

+ (void)presentForArchive:(NSString *)archiveName
       defaultDestination:(NSString *)defaultDest
             parentWindow:(NSWindow *)parent
               completion:(void (^)(SZArchiveExtractOptions *))completion {
  SZExtractDialogController *c = [SZExtractDialogController new];
  if (!g_alive) g_alive = [NSMutableSet new];
  [g_alive addObject:c];
  c->_completion = [completion copy];
  c->_parent = parent;
  [c buildWindowForArchive:archiveName defaultDest:defaultDest];

  __weak typeof(c) wc = c;
  [parent beginSheet:c->_window completionHandler:^(NSModalResponse resp) {
    typeof(c) sc = wc;
    if (sc->_completion) sc->_completion(resp == NSModalResponseOK ? sc->_result : nil);
    [g_alive removeObject:sc];
  }];
}

#pragma mark - 构建

- (NSTextField *)rowLabel:(NSString *)s {
  NSTextField *t = [NSTextField labelWithString:s];
  t.alignment = NSTextAlignmentRight;
  return t;
}

- (void)buildWindowForArchive:(NSString *)archiveName defaultDest:(NSString *)defaultDest {
  _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 520, 250)
      styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
  _window.title = @"解压";

  NSTextField *head = [NSTextField labelWithString:[NSString stringWithFormat:@"解压「%@」", archiveName]];
  head.font = [NSFont boldSystemFontOfSize:13];

  // 目标目录：可编辑历史下拉 + 浏览
  _destCombo = [NSComboBox new];
  _destCombo.completes = YES;
  [_destCombo addItemsWithObjectValues:LoadHistory()];
  _destCombo.stringValue = defaultDest ?: @"";
  NSButton *browse = [NSButton buttonWithTitle:@"浏览…" target:self action:@selector(onBrowse:)];
  [_destCombo setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
  NSStackView *destRow = [NSStackView stackViewWithViews:@[_destCombo, browse]];
  destRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  destRow.spacing = 6;

  // 路径模式（顺序对齐 SZExtractPathMode）
  _pathModePopup = [NSPopUpButton new];
  [_pathModePopup addItemsWithTitles:@[@"完整路径", @"无路径（铺平）", @"绝对路径"]];

  // 覆盖模式（顺序对齐 SZExtractOverwriteMode）
  _overwritePopup = [NSPopUpButton new];
  [_overwritePopup addItemsWithTitles:@[@"询问", @"直接覆盖", @"跳过已存在", @"自动重命名", @"重命名已有文件"]];

  _passwordField = [NSSecureTextField new];
  [_passwordField.cell setPlaceholderString:@"（加密档才需要）"];

  _elimDupCheck = [NSButton checkboxWithTitle:@"消除重复的根目录" target:nil action:nil];

  NSGridView *grid = [NSGridView gridViewWithViews:@[
    @[[self rowLabel:@"解压到："], destRow],
    @[[self rowLabel:@"路径模式："], _pathModePopup],
    @[[self rowLabel:@"覆盖方式："], _overwritePopup],
    @[[self rowLabel:@"密码："], _passwordField],
    @[[NSGridCell emptyContentView], _elimDupCheck],
  ]];
  grid.columnSpacing = 10;
  grid.rowSpacing = 10;
  [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
  [grid columnAtIndex:1].xPlacement = NSGridCellPlacementFill;

  NSButton *cancel = [NSButton buttonWithTitle:@"取消" target:self action:@selector(onCancel:)];
  cancel.keyEquivalent = @"\033";
  NSButton *ok = [NSButton buttonWithTitle:@"解压" target:self action:@selector(onOK:)];
  ok.keyEquivalent = @"\r";
  NSView *btnSpacer = [NSView new];
  [btnSpacer setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
  NSStackView *btnRow = [NSStackView stackViewWithViews:@[btnSpacer, cancel, ok]];
  btnRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  btnRow.spacing = 10;

  NSStackView *col = [NSStackView stackViewWithViews:@[head, grid, btnRow]];
  col.orientation = NSUserInterfaceLayoutOrientationVertical;
  col.alignment = NSLayoutAttributeLeading;
  col.spacing = 14;
  col.edgeInsets = NSEdgeInsetsMake(18, 18, 18, 18);
  col.translatesAutoresizingMaskIntoConstraints = NO;
  [_window.contentView addSubview:col];
  [NSLayoutConstraint activateConstraints:@[
    [col.leadingAnchor constraintEqualToAnchor:_window.contentView.leadingAnchor],
    [col.trailingAnchor constraintEqualToAnchor:_window.contentView.trailingAnchor],
    [col.topAnchor constraintEqualToAnchor:_window.contentView.topAnchor],
    [col.bottomAnchor constraintEqualToAnchor:_window.contentView.bottomAnchor],
    // 让 grid/按钮行撑满对话框内宽（col.width 减去左右各 18 的 edgeInsets），
    // grid 第 1 列(控件列)为 Fill，于是目标框/下拉随之变宽，路径不再被压窄。
    [grid.widthAnchor constraintEqualToAnchor:col.widthAnchor constant:-36],
    [btnRow.widthAnchor constraintEqualToAnchor:col.widthAnchor constant:-36],
  ]];
}

#pragma mark - 动作

- (void)onBrowse:(id)sender {
  NSOpenPanel *p = [NSOpenPanel openPanel];
  p.canChooseDirectories = YES;
  p.canChooseFiles = NO;
  p.canCreateDirectories = YES;
  p.prompt = @"选择";
  p.message = @"选择解压目标目录";
  NSString *cur = _destCombo.stringValue;
  if (cur.length) p.directoryURL = [NSURL fileURLWithPath:cur];
  // 用独立 runModal（非 sheet）：作为小对话框的 sheet 会被父窗尺寸压缩成简化工具栏，
  // 独立弹出才是标准全尺寸 Finder 面板（完整视图切换/列头/侧栏）。
  if ([p runModal] == NSModalResponseOK && p.URL)
    _destCombo.stringValue = p.URL.path;
}

- (void)onCancel:(id)sender {
  [_parent endSheet:_window returnCode:NSModalResponseCancel];
  [_window orderOut:nil];
}

- (void)onOK:(id)sender {
  NSString *dest = _destCombo.stringValue;
  if (!dest.length) { NSBeep(); return; }

  SZArchiveExtractOptions *o = [SZArchiveExtractOptions new];
  o.outputDirectory = dest;
  o.pathMode = (SZExtractPathMode)_pathModePopup.indexOfSelectedItem;
  o.overwriteMode = (SZExtractOverwriteMode)_overwritePopup.indexOfSelectedItem;
  o.eliminateDuplicatePaths = (_elimDupCheck.state == NSControlStateValueOn);
  if (_passwordField.stringValue.length) o.password = _passwordField.stringValue;
  _result = o;

  SaveHistory(dest);
  [_parent endSheet:_window returnCode:NSModalResponseOK];
  [_window orderOut:nil];
}

@end
