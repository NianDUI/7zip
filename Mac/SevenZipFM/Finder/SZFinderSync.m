// SZFinderSync.m —— FinderSync 扩展主体（M5-T2）。
// 沙箱扩展进程：只取 selectedItemURLs 生成右键 7-Zip 级联菜单，菜单项经 NSWorkspace openURL 发
// sevenzip:// URL 唤起主 app 执行（不在扩展内跑引擎，对应 Windows 右键→7zG 子进程，见 docs/04 §3.2）。
// 命令模型 SZShellCommand 与主 app 共享（同源编码/解码）。
#import <Cocoa/Cocoa.h>
#import <FinderSync/FinderSync.h>
#import "SZShellCommand.h"

@interface SZFinderSync : FIFinderSync
@end

@implementation SZFinderSync

- (instancetype)init {
  self = [super init];
  if (self) {
    // 监视整个文件系统根，使任意位置右键都能出 7-Zip 菜单（FinderSync 只在 directoryURLs 子树内回调）。
    FIFinderSyncController.defaultController.directoryURLs =
        [NSSet setWithObject:[NSURL fileURLWithPath:@"/"]];
  }
  return self;
}

#pragma mark 菜单（按选中类型动态构建，对齐 Windows 资源管理器 7-Zip 子菜单）

- (NSMenu *)menuForMenuKind:(FIMenuKind)whichMenu {
  if (whichMenu != FIMenuKindContextualMenuForItems) return nil;   // 仅作用于选中项
  NSArray<NSURL *> *urls = FIFinderSyncController.defaultController.selectedItemURLs;
  NSMutableArray<NSString *> *paths = [NSMutableArray array];
  for (NSURL *u in urls) if (u.isFileURL) [paths addObject:u.path];
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
    [self addTo:sub title:@"打开" op:SZShellOpOpen paths:paths methods:nil];
    [self addTo:sub title:@"解压…" op:SZShellOpExtract paths:paths methods:nil];
    [self addTo:sub title:[NSString stringWithFormat:@"解压到「%@/」", base] op:SZShellOpExtractToFolder paths:paths methods:nil];
    [self addTo:sub title:@"解压到当前位置" op:SZShellOpExtractHere paths:paths methods:nil];
    [self addTo:sub title:@"测试" op:SZShellOpTest paths:paths methods:nil];
    [sub addItem:[NSMenuItem separatorItem]];
  }
  // 压缩（任意选中）
  NSString *abase = [SZShellCommand archiveBaseNameForPaths:paths];
  [self addTo:sub title:@"添加到压缩包…" op:SZShellOpCompress paths:paths methods:nil];
  [self addTo:sub title:[NSString stringWithFormat:@"添加到「%@.7z」", abase] op:SZShellOpCompress7z paths:paths methods:nil];
  [self addTo:sub title:[NSString stringWithFormat:@"添加到「%@.zip」", abase] op:SZShellOpCompressZip paths:paths methods:nil];
  [sub addItem:[NSMenuItem separatorItem]];
  // 校验和子菜单
  [sub addItem:[self hashSubmenuForPaths:paths]];
  return menu;
}

- (void)addTo:(NSMenu *)menu title:(NSString *)title op:(SZShellOp)op
        paths:(NSArray<NSString *> *)paths methods:(NSArray<NSString *> *)methods {
  NSMenuItem *it = [menu addItemWithTitle:title action:@selector(runCommand:) keyEquivalent:@""];
  it.target = self;
  SZShellCommand *cmd = [SZShellCommand commandWithOp:op paths:paths];
  if (methods) cmd.methods = methods;
  it.representedObject = cmd;
}

- (NSMenuItem *)hashSubmenuForPaths:(NSArray<NSString *> *)paths {
  NSMenuItem *root = [[NSMenuItem alloc] initWithTitle:@"校验和" action:NULL keyEquivalent:@""];
  NSMenu *sub = [[NSMenu alloc] initWithTitle:@"校验和"];
  NSArray *spec = @[ @[@"CRC-32", @[@"CRC32"]], @[@"CRC-64", @[@"CRC64"]],
                     @[@"SHA-1", @[@"SHA1"]], @[@"SHA-256", @[@"SHA256"]],
                     @[@"BLAKE2sp", @[@"BLAKE2sp"]] ];
  for (NSArray *s in spec)
    [self addTo:sub title:s[0] op:SZShellOpHash paths:paths methods:s[1]];
  [sub addItem:[NSMenuItem separatorItem]];
  [self addTo:sub title:@"全部 (CRC32 · SHA1 · SHA256)" op:SZShellOpHash paths:paths methods:@[@"CRC32", @"SHA1", @"SHA256"]];
  root.submenu = sub;
  return root;
}

- (void)runCommand:(NSMenuItem *)sender {
  SZShellCommand *cmd = sender.representedObject;
  if (![cmd isKindOfClass:SZShellCommand.class]) return;
  NSURL *url = cmd.url;
  if (url) [[NSWorkspace sharedWorkspace] openURL:url];
}

@end
