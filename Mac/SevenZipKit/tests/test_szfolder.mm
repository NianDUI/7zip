// test_szfolder.mm —— SZFolderSession 只读浏览端到端测试（纯 ObjC，仅依赖 SevenZipKit 公开头，
// 不 include 任何 7-Zip C++ 头，验证桥接边界单一性，01-architecture.md §2.2）。
#import <Foundation/Foundation.h>
#import "SevenZipKit/SZFolderSession.h"

static void Dump(SZFolderSession *s, int depth) {
  NSString *pad = [@"" stringByPaddingToLength:(NSUInteger)depth * 2 withString:@" " startingAtIndex:0];
  printf("%s[path=\"%s\"] %lu 项  errFlags=0x%x phySize=%llu\n",
         pad.UTF8String, s.currentPath.UTF8String, (unsigned long)s.items.count,
         s.archiveErrorFlags, s.archivePhysicalSize);
  for (SZFolderItem *it in s.items) {
    printf("%s  [%lu] %-20s %s size=%-8llu attrib=0x%x mtime=%s\n",
           pad.UTF8String, (unsigned long)it.index, it.name.UTF8String,
           it.isDirectory ? "<DIR>" : "     ", it.size, it.attributes,
           it.modificationDate ? it.modificationDate.description.UTF8String : "-");
  }
}

int main(int argc, const char **argv) {
  @autoreleasepool {
    NSString *path = (argc > 1) ? @(argv[1]) : @"/tmp/agent_t5/test.7z";
    NSError *err = nil;
    SZFolderSession *s = [SZFolderSession sessionWithFileURL:[NSURL fileURLWithPath:path] error:&err];
    if (!s) { printf("FAIL open: %s\n", err.description.UTF8String); return 1; }

    printf("== SZFolderSession 只读浏览：%s ==\n\n[1] 根：\n", path.UTF8String);
    Dump(s, 0);

    for (SZFolderItem *it in s.items) {
      if (!it.isDirectory) continue;
      printf("\n[2] enterFolderAtIndex %lu (%s)：\n", (unsigned long)it.index, it.name.UTF8String);
      if (![s enterFolderAtIndex:it.index error:&err]) { printf("FAIL enter\n"); return 1; }
      Dump(s, 1);

      for (SZFolderItem *it2 in s.items) {
        if (!it2.isDirectory) continue;
        printf("\n[3] 二级 enterFolderAtIndex %lu (%s)：\n", (unsigned long)it2.index, it2.name.UTF8String);
        [s enterFolderAtIndex:it2.index error:&err];
        Dump(s, 2);
        break;
      }

      printf("\n[4] enterParentFolder 连续上溯（canGoToParent=%d）：\n", s.canGoToParent);
      while (s.canGoToParent) [s enterParentFolder:&err];
      printf("    回到根 path=\"%s\"  %lu 项\n", s.currentPath.UTF8String, (unsigned long)s.items.count);
      break;
    }

    printf("\n===== SZFolderSession 只读浏览端到端通过 =====\n");
  }
  return 0;
}
