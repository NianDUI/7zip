// test_hash_bridge.m —— SZHashCalculator ObjC 桥接端到端（M5）。
// 验证 dispatch 后台队列 + completion block + 主 runloop 这条真实路径（app 实际走它）产出正确哈希。
#import <Foundation/Foundation.h>
#import "SevenZipKit/SZHashCalculator.h"

int main(void) {
  @autoreleasepool {
    system("rm -rf /tmp/szhb && mkdir -p /tmp/szhb/sub && printf hello > /tmp/szhb/hello.txt"
           " && printf inner-data > /tmp/szhb/sub/inner.bin");
    __block int rc = 2;
    SZHashCalculator *c = [SZHashCalculator new];
    [c calculateForPaths:@[@"/tmp/szhb"]
                 methods:@[SZHashMethodCRC32, SZHashMethodSHA256]
                delegate:nil
              completion:^(SZHashSummary *sum) {
      NSString *crc = nil, *sha = nil;
      for (SZHashItem *it in sum.items)
        if ([it.path containsString:@"hello"]) { crc = [it hashForMethod:@"CRC32"]; sha = [it hashForMethod:@"SHA256"]; }
      BOOL ok = sum.ok && sum.numFiles == 2 && sum.items.count == 2 &&
                [crc isEqualToString:@"3610A686"] &&
                [sha isEqualToString:@"2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"] &&
                // DataSum 与 7zz "for data" 行字节一致（多文件含 extra 后缀，1:1 锁定）
                [sum.dataSum[@"CRC32"] isEqualToString:@"EB4B4DB7-00000000"];
      printf("  桥接 ok=%d numFiles=%llu items=%lu\n  hello CRC32=%s\n  hello SHA256=%s\n  dataSum CRC32=%s\n",
             ok, (unsigned long long)sum.numFiles, (unsigned long)sum.items.count,
             crc.UTF8String, sha.UTF8String, [sum.dataSum[@"CRC32"] UTF8String]);
      rc = ok ? 0 : 1;
      CFRunLoopStop(CFRunLoopGetMain());
    }];
    CFRunLoopRun();
    printf("%s\n", rc == 0 ? "===== 桥接端到端通过 =====" : "===== 桥接端到端失败 =====");
    return rc;
  }
}
