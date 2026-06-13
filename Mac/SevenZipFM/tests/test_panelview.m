// test_panelview.m —— M1-T7 SZPanelController 纯逻辑 headless 验证（不开窗口）。
#import <AppKit/AppKit.h>
#import "SevenZipKit/SZPanelModel.h"
#import "SZPanelController.h"

static int gFails = 0;
#define EXPECT(c, m) do { if (!(c)) { printf("  ✗ FAIL: %s\n", m); gFails++; } else printf("  ✓ %s\n", m); } while (0)

int main(int argc, const char **argv) {
  @autoreleasepool {
    NSString *path = (argc > 1) ? @(argv[1]) : @"/tmp/szsort_t6/test.7z";
    NSError *e = nil;
    SZPanelModel *m = [SZPanelModel panelWithFileURL:[NSURL fileURLWithPath:path] error:&e];
    if (!m) { printf("open fail: %s\n", e.description.UTF8String); return 1; }
    SZPanelController *c = [[SZPanelController alloc] initWithModel:m];
    if (m.items.count == 1 && m.items[0].isDirectory) [c activateRow:0];  // 进 src

    printf("== M1-T7 SZPanelController headless ==\n地址: %s\n状态: %s\n\n",
           c.addressText.UTF8String, c.statusText.UTF8String);

    EXPECT(c.rowCount == (NSInteger)m.items.count, "rowCount == items.count");

    NSInteger aRow = -1, dRow = -1, fRow = -1;
    for (NSInteger i = 0; i < c.rowCount; i++) {
      if ([[c stringForColumn:SZColID_Name row:i] isEqualToString:@"a.txt"]) aRow = i;
      if (m.items[(NSUInteger)i].isDirectory && dRow < 0) dRow = i;
      if (!m.items[(NSUInteger)i].isDirectory && fRow < 0) fRow = i;
    }
    EXPECT(aRow >= 0, "stringForColumn Name 命中 a.txt");
    EXPECT([[c stringForColumn:SZColID_Size row:aRow] length] > 0, "文件 size 列有文本（NSByteCountFormatter）");
    EXPECT([[c stringForColumn:SZColID_Modified row:aRow] length] > 0, "文件 modified 列有文本");
    EXPECT([[c stringForColumn:SZColID_Size row:dRow] isEqualToString:@""], "目录 size 列为空");

    printf("\n[排序] 点击 Size：\n");
    [c sortByColumnID:SZColID_Size];
    EXPECT(!m.sortAscending, "点击 Size 默认降序");
    [c sortByColumnID:SZColID_Name];

    printf("\n[导航] 双击目录进入 / 文件不进 / Backspace 上溯：\n");
    NSString *before = c.addressText;
    NSInteger d = -1; for (NSInteger i = 0; i < c.rowCount; i++) if (m.items[(NSUInteger)i].isDirectory) { d = i; break; }
    EXPECT(d >= 0 && [c activateRow:d], "双击目录进入");
    EXPECT(![c.addressText isEqualToString:before], "地址栏路径变化");
    NSInteger f = -1; for (NSInteger i = 0; i < c.rowCount; i++) if (!m.items[(NSUInteger)i].isDirectory) { f = i; break; }
    if (f >= 0) EXPECT(![c activateRow:f], "双击文件不导航（M1 只读壳）");
    EXPECT([c goToParent], "Backspace 上溯成功");

    printf("\n%s（%d 失败）\n",
           gFails == 0 ? "===== M1-T7 SZPanelController 逻辑通过 =====" : "===== 有失败 =====", gFails);
    return gFails ? 1 : 0;
  }
}
