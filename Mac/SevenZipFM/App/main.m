// main.m —— SevenZipFM 入口 + 完整菜单栏（M4-T3）。
#import <AppKit/AppKit.h>
#import "SZAppDelegate.h"

static NSMenuItem *AddItem(NSMenu *menu, NSString *title, SEL action, NSString *key) {
  return [menu addItemWithTitle:title action:action keyEquivalent:key];
}
static void SetMods(NSMenuItem *item, NSEventModifierFlags mods) {
  item.keyEquivalentModifierMask = mods;
}

int main(int argc, const char **argv) {
  @autoreleasepool {
    NSApplication *app = NSApplication.sharedApplication;
    app.activationPolicy = NSApplicationActivationPolicyRegular;

    SZAppDelegate *delegate = [SZAppDelegate new];
    app.delegate = delegate;

    NSMenu *mainMenu = [NSMenu new];

    // —— 应用菜单 ——
    NSMenuItem *appItem = [NSMenuItem new]; [mainMenu addItem:appItem];
    NSMenu *appMenu = [NSMenu new];
    AddItem(appMenu, @"关于 7-Zip", NULL, @"");
    [appMenu addItem:[NSMenuItem separatorItem]];
    AddItem(appMenu, @"文件关联…", @selector(showFileAssociations:), @",");   // 偏好位置：设双击归档默认用 7-Zip
    [appMenu addItem:[NSMenuItem separatorItem]];
    AddItem(appMenu, @"隐藏 7-Zip", @selector(hide:), @"h");
    SetMods(AddItem(appMenu, @"隐藏其他", @selector(hideOtherApplications:), @"h"),
            NSEventModifierFlagCommand | NSEventModifierFlagOption);
    AddItem(appMenu, @"显示全部", @selector(unhideAllApplications:), @"");
    [appMenu addItem:[NSMenuItem separatorItem]];
    AddItem(appMenu, @"退出 7-Zip", @selector(terminate:), @"q");
    appItem.submenu = appMenu;

    // —— 文件 ——
    NSMenuItem *fileItem = [NSMenuItem new]; [mainMenu addItem:fileItem];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"文件"];
    AddItem(fileMenu, @"打开…", @selector(openLocation:), @"o");
    [fileMenu addItem:[NSMenuItem separatorItem]];
    AddItem(fileMenu, @"新建归档…", @selector(newArchive:), @"n");
    SetMods(AddItem(fileMenu, @"新建文件夹", @selector(newFolder:), @"n"),
            NSEventModifierFlagCommand | NSEventModifierFlagShift);
    [fileMenu addItem:[NSMenuItem separatorItem]];
    AddItem(fileMenu, @"解压到…", @selector(extractTo:), @"e");
    AddItem(fileMenu, @"测试", @selector(testArchive:), @"t");
    [fileMenu addItem:[NSMenuItem separatorItem]];
    // 校验和（CRC/SHA）子菜单：对选中 FS 项算哈希；representedObject=算法名数组。
    NSMenuItem *hashRoot = [[NSMenuItem alloc] initWithTitle:@"校验和" action:NULL keyEquivalent:@""];
    NSMenu *hashMenu = [[NSMenu alloc] initWithTitle:@"校验和"];
    hashMenu.autoenablesItems = NO;
    NSArray *hashSpec = @[ @[@"CRC-32", @[@"CRC32"]], @[@"CRC-64", @[@"CRC64"]],
                           @[@"SHA-1", @[@"SHA1"]], @[@"SHA-256", @[@"SHA256"]],
                           @[@"BLAKE2sp", @[@"BLAKE2sp"]] ];
    for (NSArray *spec in hashSpec) {
      NSMenuItem *it = [hashMenu addItemWithTitle:spec[0] action:@selector(calcChecksum:) keyEquivalent:@""];
      it.representedObject = spec[1];
    }
    [hashMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *allIt = [hashMenu addItemWithTitle:@"全部 (CRC32 · SHA1 · SHA256)"
                                            action:@selector(calcChecksum:) keyEquivalent:@""];
    allIt.representedObject = @[@"CRC32", @"SHA1", @"SHA256"];
    hashRoot.submenu = hashMenu;
    [fileMenu addItem:hashRoot];
    [fileMenu addItem:[NSMenuItem separatorItem]];
    SetMods(AddItem(fileMenu, @"在 Finder 中显示", @selector(revealInFinder:), @"r"),
            NSEventModifierFlagCommand | NSEventModifierFlagShift);
    [fileMenu addItem:[NSMenuItem separatorItem]];
    SetMods(AddItem(fileMenu, @"复制到另一面板", @selector(copyToOther:),
                    [NSString stringWithFormat:@"%C", (unichar)NSF5FunctionKey]), NSEventModifierFlagFunction);
    SetMods(AddItem(fileMenu, @"移动到另一面板", @selector(moveToOther:),
                    [NSString stringWithFormat:@"%C", (unichar)NSF6FunctionKey]), NSEventModifierFlagFunction);
    [fileMenu addItem:[NSMenuItem separatorItem]];
    AddItem(fileMenu, @"关闭窗口", @selector(closeWindow:), @"w");
    fileItem.submenu = fileMenu;

    // —— 编辑（标准剪切/复制/粘贴/全选；文本框 Cmd+C/V 须有菜单项承载）——
    NSMenuItem *editItem = [NSMenuItem new]; [mainMenu addItem:editItem];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"编辑"];
    AddItem(editMenu, @"撤销", @selector(undo:), @"z");
    SetMods(AddItem(editMenu, @"重做", @selector(redo:), @"z"),
            NSEventModifierFlagCommand | NSEventModifierFlagShift);
    [editMenu addItem:[NSMenuItem separatorItem]];
    AddItem(editMenu, @"剪切", @selector(cut:), @"x");
    AddItem(editMenu, @"复制", @selector(copy:), @"c");
    AddItem(editMenu, @"粘贴", @selector(paste:), @"v");
    AddItem(editMenu, @"全选", @selector(selectAll:), @"a");
    SetMods(AddItem(editMenu, @"反选", @selector(invertSelection:), @"a"),
            NSEventModifierFlagCommand | NSEventModifierFlagShift);
    [editMenu addItem:[NSMenuItem separatorItem]];
    SetMods(AddItem(editMenu, @"删除", @selector(deleteSelected:),
                    [NSString stringWithFormat:@"%C", (unichar)NSBackspaceCharacter]),
            NSEventModifierFlagCommand);
    editItem.submenu = editMenu;

    // —— 显示 ——
    NSMenuItem *viewItem = [NSMenuItem new]; [mainMenu addItem:viewItem];
    NSMenu *viewMenu = [[NSMenu alloc] initWithTitle:@"显示"];
    AddItem(viewMenu, @"刷新", @selector(refresh:), @"r");
    SetMods(AddItem(viewMenu, @"上级目录", @selector(goUp:),
                    [NSString stringWithFormat:@"%C", (unichar)NSUpArrowFunctionKey]),
            NSEventModifierFlagCommand);
    [viewMenu addItem:[NSMenuItem separatorItem]];
    AddItem(viewMenu, @"切换单/双面板", @selector(toggleTwoPanels:), @"\\");
    [viewMenu addItem:[NSMenuItem separatorItem]];
    AddItem(viewMenu, @"按名称排序", @selector(sortByName:), @"1");
    AddItem(viewMenu, @"按大小排序", @selector(sortBySize:), @"2");
    AddItem(viewMenu, @"按修改时间排序", @selector(sortByDate:), @"3");
    viewItem.submenu = viewMenu;

    // 菜单项启用改手动控制（避免自动启用机制把自定义 action 项误判为禁用，致快捷键不触发）。
    for (NSMenuItem *top in mainMenu.itemArray) top.submenu.autoenablesItems = NO;
    app.mainMenu = mainMenu;

    [app run];
  }
  return 0;
}
