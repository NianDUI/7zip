// perf_test.cpp —— M1-T9 列表性能 gate：压测 SZFolderCore 的快照模型在大条目数下的
// 打开延迟 / 内存峰值 / 排序耗时，对照 01-architecture.md §5.4 内存预算判定是否需改懒加载。
#include "SZFolderCore.h"
#include <cstdio>
#include <sys/resource.h>
#include <mach/mach_time.h>
#include <mach/mach.h>
#include <mach/task.h>

static double NowMs() {
  static mach_timebase_info_data_t tb;
  if (tb.denom == 0) mach_timebase_info(&tb);
  return (double)mach_absolute_time() * tb.numer / tb.denom / 1e6;
}

// 峰值常驻（单调不降）：getrusage ru_maxrss（macOS 单位为字节）
static long MaxRssBytes() {
  struct rusage r; getrusage(RUSAGE_SELF, &r); return r.ru_maxrss;
}

// 当前物理内存占用（可随释放回落）：TASK_VM_INFO.phys_footprint
static long FootprintBytes() {
  task_vm_info_data_t info; mach_msg_type_number_t cnt = TASK_VM_INFO_COUNT;
  if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &cnt) != KERN_SUCCESS) return 0;
  return (long)info.phys_footprint;
}

int main(int argc, char **argv) {
  const char *path = (argc > 1) ? argv[1] : "/tmp/szperf/flat100000.7z";
  const long rss0 = MaxRssBytes();

  const double t0 = NowMs();
  SZFolderCore core;
  const int rc = core.open(path);          // 含 IInArchive::Open + proxy 树（全条目）+ 根层快照
  if (rc != 0) { printf("open fail rc=%d (%s)\n", rc, path); return 1; }
  // 下钻到内容层（造的归档为 flatN/ 单目录包裹大量条目）：测"打开→看见大列表"的总延迟
  unsigned depth = 0;
  while (core.items().size() == 1 && core.items()[0].isDir && depth < 8) { core.enterFolderAtIndex(0); depth++; }
  const double t1 = NowMs();

  const size_t n = core.items().size();
  const long footResident = FootprintBytes();   // 常驻快照（排序前）

  const double t2 = NowMs(); core.setSort(SZSortKey::Size,  false); const double t3 = NowMs();
  const double t4 = NowMs(); core.setSort(SZSortKey::Name,  true);  const double t5 = NowMs();

  const long footAfterSort = FootprintBytes();   // 排序后常驻（临时键已释放，应≈快照）
  const long rssPeak = MaxRssBytes();            // 峰值（含排序瞬时键）

  const double openMs = t1 - t0, sizeSortMs = t3 - t2, nameSortMs = t5 - t4;
  const double residentPerItem = n ? (double)(footResident - rss0) / (double)n : 0;

  // §5.4：峰值常驻≤600MB/100万；每条目均摊≤512B（针对常驻，不含排序瞬时键）
  const bool okPeak = rssPeak <= 600L * 1048576;
  const bool okPerItem = residentPerItem <= 512.0;

  printf("== M1-T9 perf：%s ==\n", path);
  printf("  条目数(当前层)  : %zu\n", n);
  printf("  打开延迟        : %8.1f ms  (Open+proxy 树+快照+默认排序)\n", openMs);
  printf("  Size 排序       : %8.1f ms\n", sizeSortMs);
  printf("  Name 自然排序   : %8.1f ms  (预转键 O(n))\n", nameSortMs);
  printf("  常驻(快照)      : %8.1f MB  (均摊 %.0f 字节/条目)\n", footResident / 1048576.0, residentPerItem);
  printf("  常驻(排序后)    : %8.1f MB  (临时键已释放)\n", footAfterSort / 1048576.0);
  printf("  峰值 maxrss     : %8.1f MB  (含排序瞬时键)\n", rssPeak / 1048576.0);
  printf("  §5.4 判定       : 峰值≤600MB[%s] & 常驻均摊≤512B[%s]\n",
         okPeak ? "✓" : "✗", okPerItem ? "✓" : "✗");
  return (okPeak && okPerItem) ? 0 : 2;
}
