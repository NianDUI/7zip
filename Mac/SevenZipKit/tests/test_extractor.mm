// test_extractor.mm —— M2-T2 验证：SZArchiveExtractor 异步解压 + 阻塞式询问（覆盖/密码）经信号量主队列往返。
// 纯 ObjC，仅依赖 SevenZipKit 公开头。每用例独立跑主 runloop，让后台 worker 的 dispatch_async(main)
// 弹询问能执行、completion 能回来（验证「工作线程阻塞等主线程答复」机制不死锁）。
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import "SevenZipKit/SZArchiveExtractor.h"

static int g_fail = 0;

@interface Mock : NSObject <SZArchiveExtractDelegate>
@property (nonatomic) NSInteger overwriteAsks;
@property (nonatomic) NSInteger passwordAsks;
@property (nonatomic) NSInteger fileStarts;
@property (nonatomic) SZOverwriteResponse overwriteReply;
@property (nonatomic, copy) NSString *passwordReply;
@end

@implementation Mock
- (void)extractor:(SZArchiveExtractor *)e willStartFile:(NSString *)n isDirectory:(BOOL)d { _fileStarts++; }
- (void)extractor:(SZArchiveExtractor *)e didFailFile:(NSString *)n message:(NSString *)m {
  printf("    [fail] %s : %s\n", n.UTF8String, m.UTF8String);
}
- (SZOverwriteResponse)extractor:(SZArchiveExtractor *)e
            askOverwriteExisting:(NSString *)ep existSize:(uint64_t)es existDate:(NSDate *)ed
                         withNew:(NSString *)np newSize:(uint64_t)ns newDate:(NSDate *)nd {
  _overwriteAsks++;
  if (![NSThread isMainThread]) { printf("    ✗ askOverwrite 不在主线程！\n"); g_fail++; }
  return _overwriteReply;
}
- (NSString *)extractorAskPassword:(SZArchiveExtractor *)e {
  _passwordAsks++;
  if (![NSThread isMainThread]) { printf("    ✗ askPassword 不在主线程！\n"); g_fail++; }
  return _passwordReply;
}
@end

int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc < 4) { fprintf(stderr, "usage: test_extractor <plain.7z> <enc.7z> <outdir>\n"); return 2; }
    NSString *plain = @(argv[1]), *enc = @(argv[2]), *outdir = @(argv[3]);

    // —— 用例 1：普通异步解压（completion 回主队列）——
    printf("== 用例1：异步解压 ==\n");
    {
      SZArchiveExtractor *ex = [SZArchiveExtractor new];
      SZArchiveExtractOptions *o = [SZArchiveExtractOptions new];
      o.outputDirectory = [outdir stringByAppendingPathComponent:@"c1"];
      o.overwriteMode = SZExtractOverwriteModeOverwrite;
      Mock *m = [Mock new];
      [ex extractArchive:plain options:o delegate:m
              completion:^(BOOL ok, uint64_t nf, uint64_t nfe, uint64_t noe, NSString *em) {
        if (![NSThread isMainThread]) { printf("  ✗ completion 不在主线程\n"); g_fail++; }
        printf("  ok=%d 文件=%llu willStart 回调=%ld\n", ok, (unsigned long long)nf, (long)m.fileStarts);
        if (ok && m.fileStarts > 0) printf("  ✓ 异步解压 + 进度回调\n"); else { g_fail++; printf("  ✗ 失败\n"); }
        CFRunLoopStop(CFRunLoopGetMain());
      }];
      CFRunLoopRun();
    }

    // —— 用例 2：覆盖询问（先填充目标，再 Ask 模式触发 askOverwrite）——
    printf("== 用例2：覆盖询问（阻塞式，主线程往返）==\n");
    {
      NSString *dir = [outdir stringByAppendingPathComponent:@"c2"];
      SZArchiveExtractor *ex0 = [SZArchiveExtractor new];
      SZArchiveExtractOptions *o0 = [SZArchiveExtractOptions new];
      o0.outputDirectory = dir; o0.overwriteMode = SZExtractOverwriteModeOverwrite;
      [ex0 extractArchive:plain options:o0 delegate:nil
               completion:^(BOOL ok, uint64_t a, uint64_t b, uint64_t c, NSString *e) { CFRunLoopStop(CFRunLoopGetMain()); }];
      CFRunLoopRun();

      SZArchiveExtractor *ex = [SZArchiveExtractor new];
      SZArchiveExtractOptions *o = [SZArchiveExtractOptions new];
      o.outputDirectory = dir; o.overwriteMode = SZExtractOverwriteModeAsk;
      Mock *m = [Mock new]; m.overwriteReply = SZOverwriteResponseYesToAll;
      [ex extractArchive:plain options:o delegate:m
              completion:^(BOOL ok, uint64_t nf, uint64_t nfe, uint64_t noe, NSString *em) {
        printf("  覆盖询问次数=%ld ok=%d\n", (long)m.overwriteAsks, ok);
        if (m.overwriteAsks > 0 && ok) printf("  ✓ 覆盖询问触发，信号量往返无死锁\n");
        else { g_fail++; printf("  ✗ 覆盖询问未触发或失败\n"); }
        CFRunLoopStop(CFRunLoopGetMain());
      }];
      CFRunLoopRun();
    }

    // —— 用例 3：密码询问（加密档无预设密码 → 触发 extractorAskPassword）——
    printf("== 用例3：密码询问（阻塞式）==\n");
    {
      SZArchiveExtractor *ex = [SZArchiveExtractor new];
      SZArchiveExtractOptions *o = [SZArchiveExtractOptions new];
      o.outputDirectory = [outdir stringByAppendingPathComponent:@"c3"];
      o.overwriteMode = SZExtractOverwriteModeOverwrite;
      Mock *m = [Mock new]; m.passwordReply = @"pass123";
      [ex extractArchive:enc options:o delegate:m
              completion:^(BOOL ok, uint64_t nf, uint64_t nfe, uint64_t noe, NSString *em) {
        printf("  密码询问次数=%ld ok=%d 文件=%llu\n", (long)m.passwordAsks, ok, (unsigned long long)nf);
        if (m.passwordAsks > 0 && ok) printf("  ✓ 密码询问触发，解压成功\n");
        else { g_fail++; printf("  ✗ 密码询问未触发或失败\n"); }
        CFRunLoopStop(CFRunLoopGetMain());
      }];
      CFRunLoopRun();
    }

    // —— 用例 4：密码取消（delegate 返回 nil → 解压中止）——
    printf("== 用例4：密码取消（返回 nil）==\n");
    {
      SZArchiveExtractor *ex = [SZArchiveExtractor new];
      SZArchiveExtractOptions *o = [SZArchiveExtractOptions new];
      o.outputDirectory = [outdir stringByAppendingPathComponent:@"c4"];
      o.overwriteMode = SZExtractOverwriteModeOverwrite;
      Mock *m = [Mock new]; m.passwordReply = nil;  // 取消
      [ex extractArchive:enc options:o delegate:m
              completion:^(BOOL ok, uint64_t nf, uint64_t nfe, uint64_t noe, NSString *em) {
        printf("  密码询问次数=%ld ok=%d\n", (long)m.passwordAsks, ok);
        if (m.passwordAsks > 0 && !ok) printf("  ✓ 取消密码 → 解压不成功（预期）\n");
        else { g_fail++; printf("  ✗ 取消语义错误\n"); }
        CFRunLoopStop(CFRunLoopGetMain());
      }];
      CFRunLoopRun();
    }

    // —— 用例 5：阻塞询问压测（100 次覆盖往返，坐实 R5 无死锁）——
    printf("== 用例5：阻塞询问压测（100 次覆盖往返，验证无死锁）==\n");
    {
      NSString *dir = [outdir stringByAppendingPathComponent:@"c5"];
      // 先填充目标，使后续每次都触发覆盖询问
      SZArchiveExtractor *exFill = [SZArchiveExtractor new];
      SZArchiveExtractOptions *of = [SZArchiveExtractOptions new];
      of.outputDirectory = dir; of.overwriteMode = SZExtractOverwriteModeOverwrite;
      [exFill extractArchive:plain options:of delegate:nil
                  completion:^(BOOL ok, uint64_t a, uint64_t b, uint64_t c, NSString *e) { CFRunLoopStop(CFRunLoopGetMain()); }];
      CFRunLoopRun();

      SZArchiveExtractor *ex = [SZArchiveExtractor new];
      Mock *m = [Mock new]; m.overwriteReply = SZOverwriteResponseYesToAll;
      __block int i = 0;
      __block void (^next)(void);
      next = ^{
        if (i >= 100) {
          printf("  完成 100 次，覆盖询问累计=%ld\n", (long)m.overwriteAsks);
          if (m.overwriteAsks >= 100) printf("  ✓ 100 次阻塞往返无死锁\n");
          else { g_fail++; printf("  ✗ 询问次数异常\n"); }
          next = nil;  // 断递归 block 自引用
          CFRunLoopStop(CFRunLoopGetMain());
          return;
        }
        i++;
        SZArchiveExtractOptions *o = [SZArchiveExtractOptions new];
        o.outputDirectory = dir; o.overwriteMode = SZExtractOverwriteModeAsk;
        [ex extractArchive:plain options:o delegate:m
                completion:^(BOOL ok, uint64_t nf, uint64_t nfe, uint64_t noe, NSString *em) { next(); }];
      };
      next();
      CFRunLoopRun();
    }

    printf(g_fail ? "\n✗ %d 个用例失败\n" : "\n✓ 全部用例通过\n", g_fail);
    return g_fail ? 1 : 0;
  }
}
