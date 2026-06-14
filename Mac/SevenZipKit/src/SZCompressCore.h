// SZCompressCore.h —— 纯 C++ 压缩核心（M3-T4 执行链 + M3-T1 基础参数合成）。
// 同 SZExtractCore 的 BOOL 隔离：本头只暴露 std/标量，不含 7-Zip 头。
// 蓝本：7zz Console/UpdateCallbackConsole + Common/Update.cpp 的 UpdateArchive()。
#pragma once
#include <string>
#include <vector>
#include <cstdint>

// 压缩事件回调（同步语义，工作线程直接调用）。
class SZCompressDelegate {
public:
  virtual ~SZCompressDelegate() {}
  virtual void onTotalBytes(uint64_t total) {}
  virtual void onProgressBytes(uint64_t completed) {}
  virtual void onScanProgress(const std::string &path) {}     // 扫描输入阶段
  virtual void onFileStart(const std::string &name) {}        // 写入某文件
  virtual void onScanError(const std::string &path, const std::string &message) {}
  // 加密：返回 true 并填 password；false=不加密/取消。
  virtual bool getPassword(std::string &password) { return false; }
  virtual bool isCancelled() { return false; }
  virtual bool isPaused() { return false; }
};

// 一次压缩请求（基础参数；完整 auto 档算法 M3-T1 细化）。
struct SZCompressRequest {
  std::string archivePath;                  // 输出归档 FS 路径（扩展名决定格式，除非 format 指定）
  std::string format;                       // "7z"/"zip"/"tar"/... 空=按扩展名推断
  std::vector<std::string> inputPaths;      // 输入文件/目录 FS 路径（≥1）
  int level = 5;                            // 压缩等级 0(仅存储)–9(极限)
  std::string method;                       // 主方法名（如 "LZMA2"）；空=格式默认
  uint64_t dictSize = 0;                    // 字典大小（字节）；0=等级默认
  int threads = 0;                         // 线程数；0=引擎默认
  bool solid = true;                       // 固实压缩（7z）
  bool hasPassword = false;
  std::string password;
  bool encryptHeader = false;              // 加密文件名（7z -mhe=on）
  uint64_t volumeSize = 0;                 // 分卷大小（字节）；0=不分卷（→ .001/.002…）
  std::vector<std::string> extraProperties; // 额外 "name=value" 属性（透传，覆盖以上）
};

struct SZCompressResult {
  int hresult = 0;                          // 0=S_OK
  uint64_t outArchiveSize = 0;              // 产出归档字节数（FinishArchive）
  std::string errorMessage;
  bool isOK() const { return hresult == 0; }
};

class SZCompressCore {
public:
  // 同步执行（调用方放后台线程；del 可空）。
  static SZCompressResult run(const SZCompressRequest &req, SZCompressDelegate *del);
};
