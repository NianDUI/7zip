// test_panelmodel.mm —— M1-T6 PanelModel 排序/选择/列单测（纯 ObjC，仅公开头）。
#import <Foundation/Foundation.h>
#import "SevenZipKit/SZPanelModel.h"

static int gFails = 0;
#define EXPECT(cond, msg) do { if (!(cond)) { printf("  ✗ FAIL: %s\n", msg); gFails++; } else { printf("  ✓ %s\n", msg); } } while (0)

static void Dump(SZPanelModel *m, const char *title) {
  printf("-- %s (sortCol=%ld asc=%d) --\n", title, (long)m.sortColumn, m.sortAscending);
  NSUInteger i = 0;
  for (SZFolderItem *it in m.items) {
    printf("   [%lu] %-14s %s size=%-5llu %s\n", (unsigned long)i, it.name.UTF8String,
           it.isDirectory ? "<DIR>" : "     ", it.size, [m isSelectedIndex:i] ? "*SEL" : "");
    i++;
  }
}

static NSUInteger IndexOfName(SZPanelModel *m, NSString *name) {
  NSUInteger i = 0;
  for (SZFolderItem *it in m.items) { if ([it.name isEqualToString:name]) return i; i++; }
  return NSNotFound;
}

int main(int argc, const char **argv) {
  @autoreleasepool {
    NSString *path = (argc > 1) ? @(argv[1]) : @"/tmp/szsort_t6/test.7z";
    NSError *err = nil;
    SZPanelModel *m = [SZPanelModel panelWithFileURL:[NSURL fileURLWithPath:path] error:&err];
    if (!m) { printf("open fail: %s\n", err.description.UTF8String); return 1; }
    if (m.items.count == 1 && m.items[0].isDirectory) [m enterFolderAtIndex:0 error:&err]; // 进入 src

    printf("== M1-T6 PanelModel 测试 ==\n\n[1] 列模型：%lu 列\n", (unsigned long)m.columns.count);
    for (SZColumn *c in m.columns)
      printf("   %s sortCol=%ld visible=%d width=%.0f\n", c.title.UTF8String, (long)c.sortColumn, c.visible, c.width);

    printf("\n[2] 默认 Name 升序：\n"); Dump(m, "Name 升序");
    BOOL seenFile = NO;
    for (SZFolderItem *it in m.items) { if (!it.isDirectory) seenFile = YES; else EXPECT(!seenFile, "目录恒在文件前"); }
    NSUInteger i2 = IndexOfName(m, @"file2.txt"), i10 = IndexOfName(m, @"file10.txt");
    EXPECT(i2 != NSNotFound && i10 != NSNotFound && i2 < i10, "自然排序 file2 在 file10 前");

    printf("\n[3] 点击 Size（首次应降序）：\n"); [m sortByColumn:SZSortColumnSize]; Dump(m, "Size");
    EXPECT(!m.sortAscending, "Size 首次点击默认降序");
    uint64_t last = UINT64_MAX; BOOL ok = YES;
    for (SZFolderItem *it in m.items) { if (it.isDirectory) continue; if (it.size > last) ok = NO; last = it.size; }
    EXPECT(ok, "文件区按 size 降序");

    printf("\n[4] 再点 Size（应切升序）+ 回 Name：\n");
    [m sortByColumn:SZSortColumnSize]; EXPECT(m.sortAscending, "同列再点切升序");
    [m sortByColumn:SZSortColumnName]; EXPECT(m.sortAscending && m.sortColumn == SZSortColumnName, "Name 新列升序");

    printf("\n[5] 选择集：\n");
    [m selectAll]; EXPECT(m.selectedCount == m.items.count, "selectAll 选中全部");
    uint64_t total = 0; for (SZFolderItem *it in m.items) total += it.size;
    EXPECT(m.selectedSize == total, "selectedSize = 合计");
    [m invertSelection]; EXPECT(m.selectedCount == 0, "全选后反选为空");
    [m clearSelection]; [m selectIndex:0]; [m toggleIndex:1];
    EXPECT(m.selectedCount == 2, "选 2 项");

    printf("\n[6] 选择跟随排序（按项不按索引）：\n");
    NSString *sel0 = m.items[0].name;
    [m sortByColumn:SZSortColumnSize];
    NSUInteger ni = IndexOfName(m, sel0);
    EXPECT(ni != NSNotFound && [m isSelectedIndex:ni], "排序后仍选中相同项");

    printf("\n[7] 导航重置选择：\n");
    [m sortByColumn:SZSortColumnName];
    for (NSUInteger i = 0; i < m.items.count; i++)
      if (m.items[i].isDirectory) { [m enterFolderAtIndex:i error:&err]; break; }
    EXPECT(m.selectedCount == 0, "进入子目录后选择重置");
    EXPECT(m.canGoToParent, "可上溯父目录");

    printf("\n%s（%d 失败）\n",
           gFails == 0 ? "===== M1-T6 PanelModel 全部通过 =====" : "===== 有失败 =====", gFails);
    return gFails == 0 ? 0 : 1;
  }
}
