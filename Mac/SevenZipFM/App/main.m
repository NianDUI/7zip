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
    [fileMenu addItemWithTitle:@"解压到…" action:@selector(extractTo:) keyEquivalent:@"e"];
    fileItem.submenu = fileMenu;

    app.mainMenu = mainMenu;

    [app run];
  }
  return 0;
}
