// test_navloop.mm —— 重现崩溃：归档进子目录/退回的反复操作 + 反复 open/release。
// 对应崩溃栈 SZFolderCore::enterParentFolder→reload→CAgentFolder::GetNumberOfItems 野指针。
#import <Foundation/Foundation.h>
#import "SevenZipKit/SZFolderSession.h"

static NSUInteger firstDir(SZFolderSession *s) {
  NSArray<SZFolderItem *> *its = s.items;
  for (NSUInteger i = 0; i < its.count; i++) if (its[i].isDirectory) return i;
  return NSNotFound;
}

int main(int argc, const char **argv) {
  @autoreleasepool {
    if (argc < 2) { printf("usage: test_navloop <archive>\n"); return 2; }
    NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]];

    printf("== A: 单 session 反复进两层/退回 x100 ==\n");
    {
      NSError *e = nil;
      SZFolderSession *s = [SZFolderSession sessionWithFileURL:url error:&e];
      if (!s) { printf("  ✗ open fail\n"); return 1; }
      for (int k = 0; k < 100; k++) {
        NSUInteger d = firstDir(s);
        if (d == NSNotFound) { printf("  (root 无目录，跳过进入)\n"); break; }
        [s enterFolderAtIndex:d error:&e];
        NSUInteger d2 = firstDir(s);
        if (d2 != NSNotFound) [s enterFolderAtIndex:d2 error:&e];
        while (s.canGoToParent) [s enterParentFolder:&e];   // 逐层退回根
        if (s.items.count == 0) { printf("  ✗ root 退回后为空（iter %d）\n", k); return 1; }
      }
      printf("  ✓ 单 session OK, root items=%lu\n", (unsigned long)s.items.count);
    }

    printf("== B: 反复 open→进两层→退回→释放 x50（模拟 FS↔归档反复切换）==\n");
    for (int iter = 0; iter < 50; iter++) {
      @autoreleasepool {
        NSError *e = nil;
        SZFolderSession *s = [SZFolderSession sessionWithFileURL:url error:&e];
        if (!s) { printf("  ✗ open fail at iter %d\n", iter); return 1; }
        NSUInteger d = firstDir(s);
        if (d != NSNotFound) {
          [s enterFolderAtIndex:d error:&e];
          NSUInteger d2 = firstDir(s);
          if (d2 != NSNotFound) [s enterFolderAtIndex:d2 error:&e];
          while (s.canGoToParent) [s enterParentFolder:&e];
        }
        if (s.items.count == 0) { printf("  ✗ empty at iter %d\n", iter); return 1; }
      }
    }
    printf("  ✓ 反复 open/release OK\n");

    printf("== C: 进子目录→删除一项→上级（写操作重写归档后上级）==\n");
    {
      NSError *e = nil;
      NSString *cpy = [NSTemporaryDirectory() stringByAppendingPathComponent:@"navloop_c.7z"];
      [NSFileManager.defaultManager removeItemAtPath:cpy error:nil];
      [NSFileManager.defaultManager copyItemAtPath:url.path toPath:cpy error:nil];
      SZFolderSession *s = [SZFolderSession sessionWithFileURL:[NSURL fileURLWithPath:cpy] error:&e];
      NSUInteger d = firstDir(s);
      if (d != NSNotFound) {
        [s enterFolderAtIndex:d error:&e];
        printf("  进子目录: items=%lu canUpdate=%d\n", (unsigned long)s.items.count, s.canUpdate);
        if (s.canUpdate && s.items.count > 0) {
          [s deleteItemsAtIndexes:[NSIndexSet indexSetWithIndex:0] error:&e];
          printf("  删除后: items=%lu canGoToParent=%d\n", (unsigned long)s.items.count, s.canGoToParent);
          if (s.canGoToParent) {
            BOOL ok = [s enterParentFolder:&e];   // ← 疑似崩溃点
            printf("  上级 ok=%d root items=%lu\n", ok, (unsigned long)s.items.count);
          }
        }
      }
      printf("  ✓ C 完成（未崩）\n");
    }

    printf("DONE 全部通过（未复现崩溃）\n");
    return 0;
  }
}
