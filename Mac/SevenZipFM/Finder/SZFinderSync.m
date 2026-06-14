// SZFinderSync.m —— FinderSync 扩展主体（M5-T2）。
// 沙箱扩展进程：只取 selectedItemURLs 生成右键 7-Zip 级联菜单，菜单项经 NSWorkspace openURL 发
// sevenzip:// URL 唤起主 app 执行（不在扩展内跑引擎，对应 Windows 右键→7zG 子进程，见 docs/04 §3.2）。
// 命令模型 SZShellCommand 与主 app 共享（同源编码/解码）。
//
// 关键约束（踩坑记录）：FinderSync 菜单跨进程（扩展生成→Finder 显示→点击回扩展），NSMenuItem 的
// representedObject 在跨进程时被丢弃（连 NSString 也不传），只有 tag（整数）保留。故命令用 tag 编码，
// 点击时用 selectedItemURLs 重新取选中项重建命令。
#import <Cocoa/Cocoa.h>
#import <FinderSync/FinderSync.h>
#import <pwd.h>
#import "SZShellCommand.h"

// 校验和命令的 tag 编码：tag = kHashTagBase + 表索引（普通命令 tag = SZShellOp 值 1–9）。
static const NSInteger kHashTagBase = 100;
static NSArray<NSArray<NSString *> *> *SZHashTable(void) {
  static NSArray *t; static dispatch_once_t once;
  dispatch_once(&once, ^{
    t = @[ @[@"CRC32"], @[@"CRC64"], @[@"SHA1"], @[@"SHA256"], @[@"BLAKE2sp"],
           @[@"CRC32", @"SHA1", @"SHA256"] ];
  });
  return t;
}

@interface SZFinderSync : FIFinderSync
@end

@implementation SZFinderSync

- (instancetype)init {
  self = [super init];
  if (self) {
    // FinderSync 只在 directoryURLs 子树内回调。监视「/」常被系统静默忽略，改为真实主目录 + 常见根。
    NSMutableSet<NSURL *> *dirs = [NSMutableSet set];
    struct passwd *pw = getpwuid(getuid());
    if (pw && pw->pw_dir)
      [dirs addObject:[NSURL fileURLWithPath:[NSString stringWithUTF8String:pw->pw_dir]]];
    for (NSString *p in @[@"/Users", @"/Volumes", @"/private/tmp", @"/tmp", @"/Applications"])
      [dirs addObject:[NSURL fileURLWithPath:p]];
    FIFinderSyncController.defaultController.directoryURLs = dirs;
  }
  return self;
}

#pragma mark 菜单（按选中类型动态构建，对齐 Windows 资源管理器 7-Zip 子菜单）

- (NSMenu *)menuForMenuKind:(FIMenuKind)whichMenu {
  if (whichMenu != FIMenuKindContextualMenuForItems) return nil;   // 仅作用于选中项
  NSArray<NSString *> *paths = [self selectedPaths];
  if (paths.count == 0) return nil;

  NSMenu *menu = [[NSMenu alloc] initWithTitle:@""];
  NSMenuItem *root = [menu addItemWithTitle:@"7-Zip" action:NULL keyEquivalent:@""];
  NSImage *icon = [NSImage imageWithSystemSymbolName:@"doc.zipper" accessibilityDescription:@"7-Zip"];
  if (icon) root.image = icon;
  NSMenu *sub = [[NSMenu alloc] initWithTitle:@"7-Zip"];
  root.submenu = sub;

  // 单选归档 → 打开/解压系列/测试
  if (paths.count == 1 && [SZShellCommand isArchivePath:paths[0]]) {
    NSString *base = [SZShellCommand baseNameForArchive:paths[0]];
    [self add:sub title:@"打开" tag:SZShellOpOpen];
    [self add:sub title:@"解压…" tag:SZShellOpExtract];
    [self add:sub title:[NSString stringWithFormat:@"解压到「%@/」", base] tag:SZShellOpExtractToFolder];
    [self add:sub title:@"解压到当前位置" tag:SZShellOpExtractHere];
    [self add:sub title:@"测试" tag:SZShellOpTest];
    [sub addItem:[NSMenuItem separatorItem]];
  }
  // 压缩（任意选中）
  NSString *abase = [SZShellCommand archiveBaseNameForPaths:paths];
  [self add:sub title:@"添加到压缩包…" tag:SZShellOpCompress];
  [self add:sub title:[NSString stringWithFormat:@"添加到「%@.7z」", abase] tag:SZShellOpCompress7z];
  [self add:sub title:[NSString stringWithFormat:@"添加到「%@.zip」", abase] tag:SZShellOpCompressZip];
  [sub addItem:[NSMenuItem separatorItem]];

  // 校验和子菜单（tag = kHashTagBase + 表索引）
  NSMenuItem *hashRoot = [[NSMenuItem alloc] initWithTitle:@"校验和" action:NULL keyEquivalent:@""];
  NSMenu *hsub = [[NSMenu alloc] initWithTitle:@"校验和"];
  NSArray<NSString *> *titles = @[@"CRC-32", @"CRC-64", @"SHA-1", @"SHA-256", @"BLAKE2sp", @"全部 (CRC32 · SHA1 · SHA256)"];
  for (NSInteger i = 0; i < (NSInteger)titles.count; i++) {
    if (i == 5) [hsub addItem:[NSMenuItem separatorItem]];
    [self add:hsub title:titles[i] tag:kHashTagBase + i];
  }
  hashRoot.submenu = hsub;
  [sub addItem:hashRoot];
  return menu;
}

- (void)add:(NSMenu *)menu title:(NSString *)title tag:(NSInteger)tag {
  NSMenuItem *it = [menu addItemWithTitle:title action:@selector(runCommand:) keyEquivalent:@""];
  it.target = self;
  it.tag = tag;   // tag 跨进程保留（representedObject 不传）
}

#pragma mark 点击 → 唤起主 app

- (void)runCommand:(NSMenuItem *)sender {
  NSArray<NSString *> *paths = [self selectedPaths];   // 点击时重取（representedObject 跨进程丢失）
  if (paths.count == 0) return;

  NSInteger tag = sender.tag;
  SZShellOp op;
  NSArray<NSString *> *methods = nil;
  if (tag >= kHashTagBase) {
    op = SZShellOpHash;
    NSInteger idx = tag - kHashTagBase;
    NSArray<NSArray<NSString *> *> *table = SZHashTable();
    if (idx < 0 || idx >= (NSInteger)table.count) return;
    methods = table[idx];
  } else {
    op = (SZShellOp)tag;
  }

  SZShellCommand *cmd = [SZShellCommand commandWithOp:op paths:paths];
  if (methods) cmd.methods = methods;
  NSURL *url = cmd.url;
  if (!url) return;
  [[NSWorkspace sharedWorkspace] openURL:url
                          configuration:[NSWorkspaceOpenConfiguration configuration]
                      completionHandler:nil];
}

- (NSArray<NSString *> *)selectedPaths {
  NSArray<NSURL *> *urls = FIFinderSyncController.defaultController.selectedItemURLs;
  NSMutableArray<NSString *> *paths = [NSMutableArray array];
  for (NSURL *u in urls) if (u.isFileURL) [paths addObject:u.path];
  return paths;
}

@end
