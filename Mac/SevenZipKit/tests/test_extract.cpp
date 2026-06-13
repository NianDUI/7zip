// test_extract.cpp —— M2-T1 验证 driver（纯 C++，仅依赖 SZExtractCore.h）。
// 解压归档到目录并打印逐文件事件；字节级对照 7zz 由外层 build_test_extract.sh 完成。
// 用法：test_extract <archive> <outdir> [-t] [-p PASS]
#include "SZExtractCore.h"
#include <cstdio>
#include <cstdint>
#include <string>

namespace {
unsigned long long U(uint64_t v) { return (unsigned long long)v; }
}

class PrintDelegate : public SZExtractDelegate {
public:
  std::string preset;
  bool hasPw = false;
  bool cancelled = false;

  void onTotalBytes(uint64_t t) override { (void)t; }
  void onProgressBytes(uint64_t c) override { (void)c; }
  void onFileStart(const std::string &name, bool isDir, bool isTest) override {
    printf("  %s %s%s\n", isTest ? "T" : "-", name.c_str(), isDir ? "/" : "");
  }
  void onFileDone(const std::string &name, int op, bool enc) override {
    if (op != 0) printf("  ! 错误码=%d encrypted=%d  %s\n", op, enc ? 1 : 0, name.c_str());
  }
  void onMessageError(const std::string &m) override { printf("  ERROR: %s\n", m.c_str()); }
  void onArchiveResult(const std::string &a, int hr, const std::string &diag) override {
    printf("[arc] %s  hr=%d  %s\n", a.c_str(), hr, diag.c_str());
  }
  bool getPassword(std::string &pw) override {
    if (hasPw) { pw = preset; return true; }
    return false;
  }
  bool isCancelled() override { return cancelled; }
};

int main(int argc, char **argv) {
  if (argc < 3) {
    fprintf(stderr, "usage: test_extract <archive> <outdir> [-t] [-p PASS]\n");
    return 2;
  }
  SZExtractRequest req;
  req.archivePaths.push_back(argv[1]);
  req.outputDir = argv[2];
  req.overwriteMode = SZOverwriteMode::Overwrite;  // 测试：直接覆盖，避免交互

  PrintDelegate del;
  for (int i = 3; i < argc; i++) {
    std::string a = argv[i];
    if (a == "-t") req.testMode = true;
    else if (a == "-p" && i + 1 < argc) {
      req.hasPassword = true; req.password = argv[++i];
      del.hasPw = true; del.preset = req.password;
    }
  }

  printf("解压 %s → %s%s\n", argv[1], argv[2], req.testMode ? "  (测试模式)" : "");
  SZExtractResult r = SZExtractCore::run(req, &del);
  printf("结果 hr=%d  档案=%llu 文件=%llu 目录=%llu 解压字节=%llu 文件错误=%llu 打开错误=%llu\n",
         r.hresult, U(r.numArchives), U(r.numFiles), U(r.numFolders), U(r.unpackSize),
         U(r.numFileErrors), U(r.numOpenErrors));
  if (!r.errorMessage.empty()) printf("errorMessage: %s\n", r.errorMessage.c_str());
  return r.isOK() ? 0 : 1;
}
