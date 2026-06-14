// test_hash.mm —— SZHashCore 核心回归（M5）。
// 验证：单文件多算法（CRC32 大写 / SHA256 小写，对照标准值）、目录递归计数、空文件、取消、数据总和。
// 纯 C++（经 .mm 编译，但不含 7-Zip 头；SZHashCore.h 是纯 std 公开头）。
#include "SZHashCore.h"
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>
#include <fstream>

static int g_fail = 0;
#define CHECK(cond, msg) do { if (cond) printf("  ✓ %s\n", msg); \
  else { printf("  ✗ FAIL: %s\n", msg); g_fail++; } } while (0)

struct CollectDelegate : public SZHashDelegate {
  std::vector<SZHashFileResult> files;
  uint64_t total = 0, completed = 0;
  std::vector<std::string> errors;
  bool cancel = false;
  void onTotalBytes(uint64_t t) override { total = t; }
  void onProgressBytes(uint64_t c) override { completed = c; }
  void onFileResult(const SZHashFileResult &r) override { files.push_back(r); }
  void onScanError(const std::string &p, const std::string &m) override { errors.push_back(p + ": " + m); }
  bool isCancelled() override { return cancel; }
};

static std::string hexOf(const SZHashFileResult &r, const std::string &method) {
  for (size_t i = 0; i < r.hashes.size(); i++)
    if (r.hashes[i].method == method) return r.hashes[i].hex;
  return "";
}
static std::string sumOf(const SZHashResult &res, const std::string &method) {
  for (size_t i = 0; i < res.dataSum.size(); i++)
    if (res.dataSum[i].method == method) return res.dataSum[i].hex;
  return "";
}
static void writeFile(const char *path, const std::string &content) {
  std::ofstream f(path, std::ios::binary);
  f.write(content.data(), (std::streamsize)content.size());
}

int main() {
  const char *D = "/tmp/szhash_test";
  system("rm -rf /tmp/szhash_test && mkdir -p /tmp/szhash_test/sub");
  writeFile("/tmp/szhash_test/hello.txt", "hello");        // 5 bytes，无换行
  writeFile("/tmp/szhash_test/empty.txt", "");             // 空文件
  writeFile("/tmp/szhash_test/sub/inner.bin", "inner-data");

  // 标准值（"hello"）：CRC32=3610A686（≤8 字节 → 大写反序数值）；SHA256（>8 字节 → 小写原序）。
  const std::string kCRC = "3610A686";
  const std::string kSHA = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824";

  printf("== test 1: 单文件 CRC32 + SHA256（\"hello\"，对照标准值）==\n");
  {
    SZHashRequest req;
    req.paths.push_back("/tmp/szhash_test/hello.txt");
    req.methods.push_back("CRC32");
    req.methods.push_back("SHA256");
    CollectDelegate del;
    SZHashResult res = SZHashCore::run(req, &del);
    CHECK(res.hresult == 0, "hresult == 0");
    CHECK(del.files.size() == 1, "1 个文件结果");
    if (!del.files.empty()) {
      CHECK(del.files[0].size == 5, "size == 5");
      CHECK(hexOf(del.files[0], "CRC32") == kCRC, "CRC32 == 3610A686（大写）");
      CHECK(hexOf(del.files[0], "SHA256") == kSHA, "SHA256 匹配标准值（小写）");
    }
    CHECK(res.numFiles == 1, "numFiles == 1");
    CHECK(sumOf(res, "CRC32") == kCRC, "dataSum CRC32 == 单文件值");
    CHECK(del.total == 5 && del.completed >= 5, "进度回调 total/completed 正确");
  }

  printf("== test 2: 目录递归（传目录，3 文件计数）==\n");
  {
    SZHashRequest req;
    req.paths.push_back(D);
    req.methods.push_back("CRC32");
    CollectDelegate del;
    SZHashResult res = SZHashCore::run(req, &del);
    CHECK(res.hresult == 0, "hresult == 0");
    CHECK(res.numFiles == 3, "numFiles == 3（hello/empty/sub/inner）");
    CHECK(del.files.size() == 3, "3 个文件结果回调");
    CHECK(res.errorMessage.empty(), "无错误文案");
  }

  printf("== test 3: 空文件 CRC32 == 00000000 ==\n");
  {
    SZHashRequest req;
    req.paths.push_back("/tmp/szhash_test/empty.txt");
    req.methods.push_back("CRC32");
    CollectDelegate del;
    SZHashResult res = SZHashCore::run(req, &del);
    CHECK(res.hresult == 0, "hresult == 0");
    CHECK(!del.files.empty() && del.files[0].size == 0, "size == 0");
    CHECK(!del.files.empty() && hexOf(del.files[0], "CRC32") == "00000000", "空文件 CRC32 == 00000000");
  }

  printf("== test 4: 取消（isCancelled → E_ABORT）==\n");
  {
    SZHashRequest req;
    req.paths.push_back(D);
    req.methods.push_back("SHA256");
    CollectDelegate del; del.cancel = true;
    SZHashResult res = SZHashCore::run(req, &del);
    CHECK(res.hresult != 0, "取消后 hresult != 0（E_ABORT）");
  }

  printf("== test 5: supportedMethods 非空且含 CRC32/SHA256 ==\n");
  {
    std::vector<std::string> m = SZHashCore::supportedMethods();
    bool hasCRC = false, hasSHA = false;
    for (size_t i = 0; i < m.size(); i++) { if (m[i] == "CRC32") hasCRC = true; if (m[i] == "SHA256") hasSHA = true; }
    CHECK(m.size() >= 5, "支持算法数 >= 5");
    CHECK(hasCRC && hasSHA, "含 CRC32 与 SHA256");
  }

  printf("\n%s（失败 %d）\n", g_fail == 0 ? "===== 全部通过 =====" : "===== 有失败 =====", g_fail);
  return g_fail ? 1 : 0;
}
