// test_compress.cpp —— M3-T4/T1 验证 driver（纯 C++，仅 SZCompressCore.h）。
// 压缩输入到归档；roundtrip（7zz 解压回来对照）由外层 build_test_compress.sh 完成。
// 用法：test_compress <out-archive> <input...> [-l N] [-p PASS] [-f fmt] [-he] [-mt N]
#include "SZCompressCore.h"
#include <cstdio>
#include <cstdlib>
#include <string>

class PrintDel : public SZCompressDelegate {
public:
  void onFileStart(const std::string &name) override { printf("  + %s\n", name.c_str()); }
  void onScanError(const std::string &p, const std::string &m) override { printf("  ERR %s: %s\n", p.c_str(), m.c_str()); }
};

int main(int argc, char **argv) {
  if (argc < 3) { fprintf(stderr, "usage: test_compress <out-archive> <input...> [-l N] [-p PASS] [-f fmt] [-he] [-mt N]\n"); return 2; }
  SZCompressRequest req;
  req.archivePath = argv[1];
  for (int i = 2; i < argc; i++) {
    std::string a = argv[i];
    if (a == "-l" && i + 1 < argc) req.level = atoi(argv[++i]);
    else if (a == "-p" && i + 1 < argc) { req.hasPassword = true; req.password = argv[++i]; }
    else if (a == "-f" && i + 1 < argc) req.format = argv[++i];
    else if (a == "-mt" && i + 1 < argc) req.threads = atoi(argv[++i]);
    else if (a == "-v" && i + 1 < argc) req.volumeSize = strtoull(argv[++i], nullptr, 10);
    else if (a == "-he") req.encryptHeader = true;
    else req.inputPaths.push_back(a);
  }
  PrintDel del;
  printf("压缩 %zu 项 → %s (level=%d%s)\n", req.inputPaths.size(), req.archivePath.c_str(),
         req.level, req.hasPassword ? " 加密" : "");
  SZCompressResult r = SZCompressCore::run(req, &del);
  printf("结果 hr=%d  归档大小=%llu\n", r.hresult, (unsigned long long)r.outArchiveSize);
  if (!r.errorMessage.empty()) printf("error: %s\n", r.errorMessage.c_str());
  return r.isOK() ? 0 : 1;
}
