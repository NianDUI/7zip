// main.m —— SevenZipFM 入口（M1-T7 单面板只读壳）。
#import <AppKit/AppKit.h>
#import "SZAppDelegate.h"

int main(int argc, const char **argv) {
  @autoreleasepool {
    NSApplication *app = NSApplication.sharedApplication;
    app.activationPolicy = NSApplicationActivationPolicyRegular;

    SZAppDelegate *delegate = [SZAppDelegate new];
    app.delegate = delegate;

    // 菜单：应用菜单（关于/退出）+ 文件菜单（解压）
    NSMenu *mainMenu = [NSMenu new];
    NSMenuItem *appItem = [NSMenuItem new];
    [mainMenu addItem:appItem];
    NSMenu *appMenu = [NSMenu new];
    [appMenu addItemWithTitle:@"关于 7-Zip" action:NULL keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"退出 7-Zip" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;

    NSMenuItem *fileItem = [NSMenuItem new];
    [mainMenu addItem:fileItem];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"文件"];
    [fileMenu addItemWithTitle:@"新建归档…" action:@selector(newArchive:) keyEquivalent:@"n"];
    [fileMenu addItem:[NSMenuItem separatorItem]];
    [fileMenu addItemWithTitle:@"解压到…" action:@selector(extractTo:) keyEquivalent:@"e"];
    [fileMenu addItemWithTitle:@"测试" action:@selector(testArchive:) keyEquivalent:@"t"];
    fileItem.submenu = fileMenu;

    // 编辑菜单（标准剪切/复制/粘贴/全选）——缺它则文本框/密码框的 Cmd+C/V 无法工作，
    // 因为这些命令经 responder chain 的 cut:/copy:/paste:/selectAll: 分发，须有菜单项承载。
    NSMenuItem *editItem = [NSMenuItem new];
    [mainMenu addItem:editItem];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"编辑"];
    [editMenu addItemWithTitle:@"撤销" action:@selector(undo:) keyEquivalent:@"z"];
    NSMenuItem *redo = [editMenu addItemWithTitle:@"重做" action:@selector(redo:) keyEquivalent:@"z"];
    redo.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    [editMenu addItem:[NSMenuItem separatorItem]];
    [editMenu addItemWithTitle:@"剪切" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"复制" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"粘贴" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"全选" action:@selector(selectAll:) keyEquivalent:@"a"];
    editItem.submenu = editMenu;

    app.mainMenu = mainMenu;

    [app run];
  }
  return 0;
}
