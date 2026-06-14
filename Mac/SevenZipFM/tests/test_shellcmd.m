// test_shellcmd.m —— SZShellCommand 命令模型单测（M5-T2）。URL 往返 / op 映射 / base64url / 启发式。
#import <Foundation/Foundation.h>
#import "SZShellCommand.h"

static int g_fail = 0;
#define CHECK(cond, msg) do { if (cond) printf("  ✓ %s\n", msg); \
  else { printf("  ✗ FAIL: %s\n", msg); g_fail++; } } while (0)

static BOOL roundtrip(SZShellOp op, NSArray<NSString *> *paths, NSArray<NSString *> *methods) {
  SZShellCommand *c = [SZShellCommand commandWithOp:op paths:paths];
  if (methods) c.methods = methods;
  NSURL *u = c.url;
  if (!u) return NO;
  SZShellCommand *d = [SZShellCommand commandFromURL:u];
  if (!d) return NO;
  if (d.op != op) return NO;
  if (![d.paths isEqualToArray:paths]) return NO;
  if (methods && ![d.methods isEqualToArray:methods]) return NO;
  return YES;
}

int main(void) {
  @autoreleasepool {
    printf("== test 1: 各 op URL 往返 ==\n");
    NSArray *ops = @[@(SZShellOpOpen), @(SZShellOpExtract), @(SZShellOpExtractHere),
                     @(SZShellOpExtractToFolder), @(SZShellOpTest), @(SZShellOpCompress),
                     @(SZShellOpCompress7z), @(SZShellOpCompressZip)];
    BOOL allOps = YES;
    for (NSNumber *n in ops)
      if (!roundtrip((SZShellOp)n.integerValue, @[@"/tmp/a.7z"], nil)) allOps = NO;
    CHECK(allOps, "8 个 op 往返一致");

    printf("== test 2: 中文 + 空格 + 多路径往返 ==\n");
    NSArray *paths = @[@"/Users/x/下载/3336-【财务】问题单.7z", @"/tmp/with space/b.zip"];
    CHECK(roundtrip(SZShellOpExtract, paths, nil), "中文/空格/多路径往返");

    printf("== test 3: hash 命令 methods 往返 ==\n");
    CHECK(roundtrip(SZShellOpHash, @[@"/tmp/f.bin"], (@[@"CRC32", @"SHA256"])), "hash methods 往返");

    printf("== test 4: 非法 URL 返回 nil ==\n");
    CHECK([SZShellCommand commandFromURL:[NSURL URLWithString:@"http://x/extract"]] == nil, "错 scheme → nil");
    CHECK([SZShellCommand commandFromURL:[NSURL URLWithString:@"sevenzip://bogus"]] == nil, "错 op → nil");

    printf("== test 5: op ↔ string 映射 ==\n");
    CHECK([[SZShellCommand stringForOp:SZShellOpCompress7z] isEqualToString:@"compress7z"], "op→string");
    CHECK([SZShellCommand opForString:@"extracthere"] == SZShellOpExtractHere, "string→op");
    CHECK([SZShellCommand opForString:@"nope"] == SZShellOpUnknown, "未知→Unknown");

    printf("== test 6: 解压基础名启发式 ==\n");
    CHECK([[SZShellCommand baseNameForArchive:@"/x/archive.7z"] isEqualToString:@"archive"], "archive.7z→archive");
    CHECK([[SZShellCommand baseNameForArchive:@"/x/data.tar.gz"] isEqualToString:@"data.tar"], "data.tar.gz→data.tar");

    printf("== test 7: 压缩基础名启发式 ==\n");
    CHECK([[SZShellCommand archiveBaseNameForPaths:@[@"/x/report.txt"]] isEqualToString:@"report"], "单选去扩展名");
    CHECK(([[SZShellCommand archiveBaseNameForPaths:@[@"/x/proj/a.c", @"/x/proj/b.c"]] isEqualToString:@"proj"]), "多选用父目录名");

    printf("== test 8: URL 实际形态可被 open 解析 ==\n");
    NSURL *u = [[SZShellCommand commandWithOp:SZShellOpHash paths:@[@"/tmp/f"]] url];
    SZShellCommand *back = [SZShellCommand commandFromURL:u];
    CHECK([u.scheme isEqualToString:@"sevenzip"] && [u.host isEqualToString:@"hash"] && back != nil,
          "URL scheme/host 正确且可解码");

    printf("\n%s（失败 %d）\n", g_fail == 0 ? "===== 全部通过 =====" : "===== 有失败 =====", g_fail);
    return g_fail ? 1 : 0;
  }
}
