// test_edit.cpp —— M3-T5 验证：归档内增删改（纯 C++，直接用 SZFolderCore 写方法）。
// 每次进程：打开 → 一个操作 → 退出（CommonUpdateOperation 已持久化到磁盘）。外层脚本用 7zz l 验证。
#include "SZFolderCore.h"
#include <cstdio>
#include <string>

static size_t findByName(SZFolderCore &core, const char *name) {
  const auto &items = core.items();
  for (size_t i = 0; i < items.size(); i++)
    if (items[i].name == name) return i;
  return (size_t)-1;
}

int main(int argc, char **argv) {
  if (argc < 3) {
    fprintf(stderr, "usage: test_edit <archive> <list | delete NAME | add FSFILE | mkdir NAME | rename OLD NEW>\n");
    return 2;
  }
  SZFolderCore core;
  const int rc = core.open(argv[1]);
  if (rc != 0) { printf("打开失败 rc=%d\n", rc); return 1; }
  const std::string op = argv[2];
  int r = 0;

  if (op == "list") {
    printf("canUpdate=%d 项数=%zu\n", core.canUpdate() ? 1 : 0, core.items().size());
    for (size_t i = 0; i < core.items().size(); i++)
      printf("  %s%s\n", core.items()[i].name.c_str(), core.items()[i].isDir ? "/" : "");
  } else if (op == "delete" && argc >= 4) {
    size_t i = findByName(core, argv[3]);
    if (i == (size_t)-1) { printf("未找到 %s\n", argv[3]); return 1; }
    r = core.deleteItems(std::vector<size_t>{i});
    printf("delete %s → rc=%d 剩余项数=%zu\n", argv[3], r, core.items().size());
  } else if (op == "add" && argc >= 4) {
    r = core.addFile(argv[3]);
    printf("add %s → rc=%d 项数=%zu\n", argv[3], r, core.items().size());
  } else if (op == "mkdir" && argc >= 4) {
    r = core.createFolder(argv[3]);
    printf("mkdir %s → rc=%d 项数=%zu\n", argv[3], r, core.items().size());
  } else if (op == "rename" && argc >= 5) {
    size_t i = findByName(core, argv[3]);
    if (i == (size_t)-1) { printf("未找到 %s\n", argv[3]); return 1; }
    r = core.renameItem(i, argv[4]);
    printf("rename %s→%s rc=%d\n", argv[3], argv[4], r);
  } else { printf("未知操作\n"); return 2; }

  return r == 0 ? 0 : 1;
}
