// SZFileAssocController.m —— 文件关联配置窗。
// 经 LaunchServices（LSCopy/LSSetDefaultRoleHandlerForContentType）查询/设置某 UTI 的默认打开程序。
#import "SZFileAssocController.h"
#import <CoreServices/CoreServices.h>

#pragma mark - LaunchServices 封装（LSSet/Copy 在 12.0 标记弃用但仍可用，且为同步 API，最贴合此处需求）

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
static NSString *SZCurrentHandler(NSString *uti) {
  CFStringRef h = LSCopyDefaultRoleHandlerForContentType((__bridge CFStringRef)uti, kLSRolesAll);
  return h ? (__bridge_transfer NSString *)h : nil;
}
static OSStatus SZSetHandler(NSString *uti, NSString *bundleID) {
  return LSSetDefaultRoleHandlerForContentType((__bridge CFStringRef)uti, kLSRolesAll,
                                               (__bridge CFStringRef)bundleID);
}
#pragma clang diagnostic pop

#pragma mark - 单个格式的关联状态

@interface SZAssocFormat : NSObject
@property (copy) NSString *name;            // 显示名（7z / Zip …）
@property (copy) NSString *exts;            // 扩展名（用于显示）
@property (copy) NSString *uti;             // 内容类型标识
@property (copy) NSString *fallback;        // 取消勾选时恢复到的 handler bundle id（nil=仅本 app 支持，不可取消）
@property (copy) NSString *currentHandler;  // 当前默认 handler bundle id
@property (assign) BOOL mine;               // 当前默认是否本 app
@end
@implementation SZAssocFormat
@end

#pragma mark - 控制器

@interface SZFileAssocController () <NSTableViewDataSource, NSTableViewDelegate>
@end

@implementation SZFileAssocController {
  NSTableView *_table;
  NSArray<SZAssocFormat *> *_formats;
  NSString *_bundleID;
}

static SZFileAssocController *gShared;

+ (void)presentWithParentWindow:(NSWindow *)parent {
  if (!gShared) gShared = [SZFileAssocController new];
  [gShared reload];
  [gShared.window center];
  [gShared.window makeKeyAndOrderFront:nil];
  [NSApp activateIgnoringOtherApps:YES];
}

- (instancetype)init {
  NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 520, 392)
      styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
      backing:NSBackingStoreBuffered defer:NO];
  w.title = @"文件关联";
  self = [super initWithWindow:w];
  if (self) {
    _bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"com.niandui.SevenZipFM";
    [self buildFormats];
    [self buildUI];
  }
  return self;
}

// 格式表：{显示名, 扩展名, UTI, 取消勾选时恢复的 handler}。""=自定义类型仅本 app 支持，不允许取消。
- (void)buildFormats {
  NSArray<NSArray *> *spec = @[
    @[@"7z",    @"7z",  @"org.7-zip.7-zip-archive", @""],
    @[@"Zip",   @"zip", @"public.zip-archive",      @"com.apple.archiveutility"],
    @[@"Rar",   @"rar", @"com.rarlab.rar-archive",  @""],
    @[@"Tar",   @"tar", @"public.tar-archive",      @"com.apple.archiveutility"],
    @[@"GZip",  @"gz",  @"org.gnu.gnu-zip-archive", @"com.apple.archiveutility"],
    @[@"BZip2", @"bz2", @"public.bzip2-archive",    @"com.apple.archiveutility"],
    @[@"Xz",    @"xz",  @"org.tukaani.xz-archive",  @"com.apple.archiveutility"],
    @[@"Zstd",  @"zst", @"org.7-zip.zstd-archive",  @""],
  ];
  NSMutableArray<SZAssocFormat *> *arr = [NSMutableArray array];
  for (NSArray *s in spec) {
    SZAssocFormat *f = [SZAssocFormat new];
    f.name = s[0]; f.exts = s[1]; f.uti = s[2];
    NSString *preset = s[3];
    NSString *cur = SZCurrentHandler(f.uti);
    BOOL mine = cur && [cur caseInsensitiveCompare:_bundleID] == NSOrderedSame;
    // 恢复目标：优先记录加载时的真实 handler（非本 app）；已是本 app 则用预设；预设空则不可取消
    f.fallback = (cur && !mine) ? cur : (preset.length ? preset : nil);
    [arr addObject:f];
  }
  _formats = arr;
}

- (void)buildUI {
  NSView *cv = self.window.contentView;

  NSTextField *title = [NSTextField labelWithString:@"勾选要默认用 7-Zip 打开的归档格式"];
  title.font = [NSFont boldSystemFontOfSize:13];
  NSTextField *sub = [NSTextField wrappingLabelWithString:
      @"双击该类型文件将用 7-Zip 打开浏览；取消勾选则恢复为系统默认程序。\n（更改即时生效，无需重启。）"];
  sub.font = [NSFont systemFontOfSize:11];
  sub.textColor = NSColor.secondaryLabelColor;

  NSScrollView *sv = [[NSScrollView alloc] init];
  sv.hasVerticalScroller = YES;
  sv.borderType = NSBezelBorder;
  _table = [[NSTableView alloc] init];
  _table.dataSource = self;
  _table.delegate = self;
  _table.usesAlternatingRowBackgroundColors = YES;
  _table.rowHeight = 26;
  _table.allowsEmptySelection = YES;
  NSArray *cols = @[ @[@"on", @"用 7-Zip 打开", @130], @[@"fmt", @"格式", @130], @[@"cur", @"当前默认程序", @200] ];
  for (NSArray *c in cols) {
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:c[0]];
    col.title = c[1];
    col.width = [c[2] doubleValue];
    [_table addTableColumn:col];
  }
  sv.documentView = _table;

  NSButton *checkAll = [NSButton buttonWithTitle:@"全选" target:self action:@selector(assocCheckAll:)];
  NSButton *uncheckAll = [NSButton buttonWithTitle:@"全不选" target:self action:@selector(assocUncheckAll:)];
  NSButton *done = [NSButton buttonWithTitle:@"完成" target:self action:@selector(assocClose:)];
  done.keyEquivalent = @"\r";

  for (NSView *v in @[title, sub, sv, checkAll, uncheckAll, done]) {
    v.translatesAutoresizingMaskIntoConstraints = NO;
    [cv addSubview:v];
  }

  [NSLayoutConstraint activateConstraints:@[
    [title.topAnchor constraintEqualToAnchor:cv.topAnchor constant:16],
    [title.leadingAnchor constraintEqualToAnchor:cv.leadingAnchor constant:20],
    [title.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor constant:-20],

    [sub.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:6],
    [sub.leadingAnchor constraintEqualToAnchor:cv.leadingAnchor constant:20],
    [sub.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor constant:-20],

    [sv.topAnchor constraintEqualToAnchor:sub.bottomAnchor constant:12],
    [sv.leadingAnchor constraintEqualToAnchor:cv.leadingAnchor constant:20],
    [sv.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor constant:-20],
    [sv.bottomAnchor constraintEqualToAnchor:done.topAnchor constant:-14],

    [checkAll.leadingAnchor constraintEqualToAnchor:cv.leadingAnchor constant:20],
    [checkAll.bottomAnchor constraintEqualToAnchor:cv.bottomAnchor constant:-16],
    [uncheckAll.leadingAnchor constraintEqualToAnchor:checkAll.trailingAnchor constant:8],
    [uncheckAll.centerYAnchor constraintEqualToAnchor:checkAll.centerYAnchor],

    [done.trailingAnchor constraintEqualToAnchor:cv.trailingAnchor constant:-20],
    [done.centerYAnchor constraintEqualToAnchor:checkAll.centerYAnchor],
  ]];
}

// 重新查询每个 UTI 的当前 handler 并刷新表
- (void)reload {
  for (SZAssocFormat *f in _formats) {
    f.currentHandler = SZCurrentHandler(f.uti);
    f.mine = f.currentHandler && [f.currentHandler caseInsensitiveCompare:_bundleID] == NSOrderedSame;
  }
  [_table reloadData];
}

- (NSString *)appNameForBundleID:(NSString *)bid {
  if (!bid.length) return nil;
  NSURL *u = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:bid];
  if (!u) return bid;   // 已卸载/未注册：退化显示 bundle id
  NSString *n = [NSFileManager.defaultManager displayNameAtPath:u.path];
  return n.length ? n.stringByDeletingPathExtension : bid;
}

#pragma mark - 表数据源 / 委托

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv { return _formats.count; }

- (NSView *)tableView:(NSTableView *)tv viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
  SZAssocFormat *f = _formats[row];
  if ([col.identifier isEqualToString:@"on"]) {
    NSButton *cb = [NSButton checkboxWithTitle:@"" target:self action:@selector(toggleRow:)];
    cb.tag = row;
    cb.state = f.mine ? NSControlStateValueOn : NSControlStateValueOff;
    return cb;
  }
  NSTextField *tf = [NSTextField labelWithString:@""];
  if ([col.identifier isEqualToString:@"fmt"]) {
    tf.stringValue = [NSString stringWithFormat:@"%@  (.%@)", f.name, f.exts];
  } else {
    NSString *appName = [self appNameForBundleID:f.currentHandler];
    tf.stringValue = appName ?: @"（无）";
    if (f.mine) tf.textColor = NSColor.controlAccentColor;
  }
  return tf;
}

#pragma mark - 动作

- (void)toggleRow:(NSButton *)sender {
  NSInteger row = sender.tag;
  if (row < 0 || row >= (NSInteger)_formats.count) return;
  SZAssocFormat *f = _formats[row];
  NSString *target;
  if (sender.state == NSControlStateValueOn) {
    target = _bundleID;
  } else {
    if (!f.fallback) {   // 自定义类型仅本 app 支持，无可恢复目标
      NSBeep();
      sender.state = NSControlStateValueOn;
      NSAlert *a = [NSAlert new];
      a.messageText = [NSString stringWithFormat:@"%@ 仅 7-Zip 支持", f.name];
      a.informativeText = @"该格式没有其他可用的打开程序，无法取消关联。";
      [a addButtonWithTitle:@"好"];
      [a beginSheetModalForWindow:self.window completionHandler:nil];
      return;
    }
    target = f.fallback;
  }
  OSStatus st = SZSetHandler(f.uti, target);
  if (st != noErr) {
    NSBeep();
    sender.state = f.mine ? NSControlStateValueOn : NSControlStateValueOff;
    return;
  }
  [self reload];
}

- (void)setAll:(BOOL)on {
  for (SZAssocFormat *f in _formats) {
    if (!on && !f.fallback) continue;   // 不可取消的跳过
    SZSetHandler(f.uti, on ? _bundleID : f.fallback);
  }
  [self reload];
}

- (void)assocCheckAll:(id)sender   { [self setAll:YES]; }
- (void)assocUncheckAll:(id)sender { [self setAll:NO]; }
- (void)assocClose:(id)sender      { [self.window close]; }

@end
