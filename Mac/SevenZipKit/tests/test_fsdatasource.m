// test_fsdatasource.m —— SZFSDataSource（M4-T1）headless 单测：列目录/排序/选择跟随/导航/写操作。
// 纯 Foundation，不链接 7-Zip 引擎（验证 FS 数据源对引擎零依赖）。
#import <Foundation/Foundation.h>
#import "SevenZipKit/SZFSDataSource.h"

static int g_fail = 0;
#define CHECK(cond, msg) do { if (cond) printf("  ✓ %s\n", msg); else { printf("  ✗ %s\n", msg); g_fail++; } } while (0)

static void writeFile(NSString *path, NSUInteger bytes) {
  [[NSMutableData dataWithLength:bytes] writeToFile:path atomically:YES];
}
static NSUInteger indexOfName(SZFSDataSource *s, NSString *name) {
  for (NSUInteger i = 0; i < s.items.count; i++) if ([s.items[i].name isEqualToString:name]) return i;
  return NSNotFound;
}
static BOOL hasName(SZFSDataSource *s, NSString *name) { return indexOfName(s, name) != NSNotFound; }

int main(int argc, const char **argv) {
  @autoreleasepool {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      [@"szfs_" stringByAppendingString:NSUUID.UUID.UUIDString]];
    [fm createDirectoryAtPath:[root stringByAppendingPathComponent:@"dirB"] withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createDirectoryAtPath:[root stringByAppendingPathComponent:@"dirA"] withIntermediateDirectories:YES attributes:nil error:nil];
    writeFile([root stringByAppendingPathComponent:@"apple.txt"], 30);
    writeFile([root stringByAppendingPathComponent:@"banana.txt"], 10);
    writeFile([root stringByAppendingPathComponent:@"file_big.bin"], 100);
    writeFile([root stringByAppendingPathComponent:@"file_small.bin"], 5);
    writeFile([root stringByAppendingPathComponent:@".hidden"], 1);
    writeFile([[root stringByAppendingPathComponent:@"dirA"] stringByAppendingPathComponent:@"inner.txt"], 7);

    printf("== 打开 / 基本属性 ==\n");
    SZFSDataSource *s = [SZFSDataSource sourceWithDirectoryPath:root];
    CHECK(s != nil, "打开目录");
    CHECK(!s.representsArchive, "representsArchive = NO");
    CHECK(s.canUpdate, "canUpdate = YES");
    CHECK([s.currentPath isEqualToString:root], "currentPath = root");
    CHECK([SZFSDataSource sourceWithDirectoryPath:@"/nonexistent/xyz"] == nil, "不存在目录返回 nil");

    printf("== 默认排序（Name 升序，目录在前，隐藏点文件）==\n");
    CHECK(s.items.count == 6, "条目数 = 6（.hidden 已隐藏）");
    CHECK(s.items[0].isDirectory && [s.items[0].name isEqualToString:@"dirA"], "dirA 在最前");
    CHECK([s.items[1].name isEqualToString:@"dirB"], "dirB 次之");
    CHECK([s.items[2].name isEqualToString:@"apple.txt"] && !s.items[2].isDirectory, "文件自然序：apple 首");
    CHECK([s.items[3].name isEqualToString:@"banana.txt"], "banana 次之");
    CHECK(s.items[2].size == 30, "apple 大小 = 30B");

    printf("== Size 排序（新列默认降序，目录恒前）==\n");
    [s sortByColumn:SZSortColumnSize];
    CHECK(s.items[0].isDirectory && s.items[1].isDirectory, "目录仍在前");
    CHECK([s.items[2].name isEqualToString:@"file_big.bin"], "Size 降序：file_big(100) 首");
    CHECK([s.items[5].name isEqualToString:@"file_small.bin"], "Size 降序：file_small(5) 末");

    printf("== 选择（按 name 跟随排序）==\n");
    [s sortByColumn:SZSortColumnName];   // 新列 → 升序
    [s selectIndex:indexOfName(s, @"apple.txt")];
    [s selectIndex:indexOfName(s, @"file_big.bin")];
    CHECK(s.selectedCount == 2, "选中 2 项");
    CHECK(s.selectedSize == 130, "选中合计 = 130B");
    [s sortByColumn:SZSortColumnSize];   // 排序后选择应保持同样两项
    CHECK(s.selectedIndexes.count == 2, "排序后选择保持 2 项");
    CHECK([s isSelectedIndex:indexOfName(s, @"apple.txt")], "apple 仍选中");
    [s selectAll];
    CHECK(s.selectedCount == 6, "全选 = 6");
    [s clearSelection];
    CHECK(s.selectedCount == 0, "清空选择");

    printf("== 导航（进子目录 / 上溯）==\n");
    [s sortByColumn:SZSortColumnName];
    NSError *e = nil;
    CHECK([s enterFolderAtIndex:indexOfName(s, @"dirA") error:&e], "进入 dirA");
    CHECK([s.currentPath isEqualToString:[root stringByAppendingPathComponent:@"dirA"]], "currentPath = dirA");
    CHECK(s.items.count == 1 && [s.items[0].name isEqualToString:@"inner.txt"], "dirA 内含 inner.txt");
    CHECK(s.canGoToParent, "可上溯");
    CHECK([s enterParentFolder:&e], "上溯回 root");
    CHECK([s.currentPath isEqualToString:root], "currentPath 回到 root");
    NSString *p0 = [s fileSystemPathForIndex:0];
    CHECK([p0 hasPrefix:root], "fileSystemPathForIndex 返回绝对路径");

    printf("== 写操作（新建夹 / 重命名 / 添加）==\n");
    CHECK([s createDirectoryNamed:@"newdir" error:&e], "新建文件夹 newdir");
    CHECK(s.items.count == 7, "新建后 = 7 项");
    CHECK(hasName(s, @"newdir"), "newdir 出现");
    CHECK([s renameItemAtIndex:indexOfName(s, @"banana.txt") toName:@"cherry.txt" error:&e], "重命名 banana→cherry");
    CHECK(hasName(s, @"cherry.txt") && !hasName(s, @"banana.txt"), "cherry.txt 取代 banana.txt");
    NSString *extFile = [NSTemporaryDirectory() stringByAppendingPathComponent:
                         [@"szfs_ext_" stringByAppendingString:NSUUID.UUID.UUIDString]];
    writeFile(extFile, 42);
    CHECK([s addFileAtPath:extFile error:&e], "添加外部文件");
    CHECK(hasName(s, extFile.lastPathComponent), "拷入文件出现");

    printf("== 删除（移废纸篓；headless 无废纸篓则容错跳过）==\n");
    NSUInteger cidx = indexOfName(s, @"cherry.txt");
    if (cidx != NSNotFound) {
      if ([s deleteItemsAtIndexes:[NSIndexSet indexSetWithIndex:cidx] error:&e])
        CHECK(!hasName(s, @"cherry.txt"), "删除 cherry.txt（移废纸篓）");
      else
        printf("  ! 删除跳过（无废纸篓）：%s\n", e.localizedDescription.UTF8String);
    }

    [fm removeItemAtPath:root error:nil];
    [fm removeItemAtPath:extFile error:nil];

    if (g_fail) { printf("\n✗ %d 项失败\n", g_fail); return 1; }
    printf("\n✅ 全部通过\n");
    return 0;
  }
}
