// SZHashCore.h —— 纯 C++ 哈希核心（M5：CRC/SHA 校验和）。
// 蓝本：7zz CPP/7zip/UI/Common/HashCalc.{h,cpp}（HashCalc() 顶层函数）+ Console/HashCon.cpp 的结果读取。
// 与 SZExtractCore/SZCompressCore 同构：调 UI/Common 顶层函数 HashCalc()，实现纯 C++ 回调把事件转发到
// 抽象 SZHashDelegate。internal-codecs-only（Alone2 未定义 Z7_EXTERNAL_CODECS），故 HashCalc 零 codecs 参数。
// BOOL 隔离：本头只暴露 std/标量，不含任何 7-Zip 头，可被 ObjC++ 与纯 C++ 测试同时 include。
#pragma once
#include <string>
#include <vector>
#include <cstdint>

// 单个算法的一对结果：method=注册名（"CRC32"/"SHA256"…），hex=大写十六进制（小算法为反转字节序的数值，
// 与 7zz h 输出一致，见 HashHexToString）。
struct SZHashPair {
  std::string method;
  std::string hex;
};

// 单个文件（或目录项）的哈希结果。
struct SZHashFileResult {
  std::string path;                 // 显示用相对路径（UTF-8）
  uint64_t size = 0;
  bool isDir = false;
  std::vector<SZHashPair> hashes;   // 与 request.methods 同序；目录项可能为空
};

// 一次哈希请求。
struct SZHashRequest {
  std::vector<std::string> paths;    // 输入 FS 路径（文件或目录，UTF-8），≥1
  std::vector<std::string> methods;  // 算法注册名，顺序保留；空=默认 {"CRC32"}
};

// 哈希事件回调（抽象类）。语义同步：工作线程直接调用。ObjC 外观把进度/结果 hop 主队列。
// 默认实现为安全空缺省，便于命令行测试。
class SZHashDelegate {
public:
  virtual ~SZHashDelegate() {}
  virtual void onTotalBytes(uint64_t total) {}
  virtual void onProgressBytes(uint64_t completed) {}
  // 每个文件哈希完成即回调（供 UI 流式刷新列表）。
  virtual void onFileResult(const SZHashFileResult &r) {}
  // 扫描/打开错误（不中断，累计 NumErrors）。
  virtual void onScanError(const std::string &path, const std::string &message) {}
  // 取消标志（worker 高频轮询，须线程安全）。
  virtual bool isCancelled() { return false; }
};

// 哈希结果统计（聚合 CHashBundle 计数 + 数据总和）。
struct SZHashResult {
  int hresult = 0;                                 // 0=S_OK，<0 引擎错误，E_ABORT=取消
  uint64_t numFiles = 0;
  uint64_t numDirs = 0;
  uint64_t numErrors = 0;
  uint64_t totalSize = 0;
  std::vector<SZHashPair> dataSum;                 // 数据总和（所有文件内容拼接的哈希，对齐 7zz "for data"）
  std::string errorMessage;
  bool isOK() const { return hresult == 0 && numErrors == 0; }
};

class SZHashCore {
public:
  // 同步执行（调用方负责放后台线程；del 可为 nullptr=全用安全缺省）。
  static SZHashResult run(const SZHashRequest &req, SZHashDelegate *del);

  // 支持的算法注册名（与 7zz i 的 Hashers 段一致，按 GUI 展示常用序）。供 UI 构建多选。
  static std::vector<std::string> supportedMethods();
};
