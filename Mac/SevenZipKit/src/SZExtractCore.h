// SZExtractCore.h —— 纯 C++ 解压核心（M2-T1）。
// 存在理由：与 SZFolderCore 同样的 BOOL 隔离——本头只暴露 std/标量类型，不含任何 7-Zip 头，
// 故可被 ObjC++（SZExtractor.mm）与纯 C++ 测试同时 include。实现端 SZExtractCore.cpp 才含 7-Zip 头。
// 蓝本：7zz CPP/7zip/UI/Console/ExtractCallbackConsole.{h,cpp} + Common/Extract.cpp 的 Extract() 入口。
#pragma once
#include <string>
#include <vector>
#include <cstdint>

// 路径模式（对齐 NExtract::NPathMode）。自用裁剪：CurPaths / NoPathsAlt 不在 GUI 暴露。
enum class SZPathMode { FullPaths = 0, NoPaths, AbsPaths };

// 覆盖模式（对齐 NExtract::NOverwriteMode）。
enum class SZOverwriteMode { Ask = 0, Overwrite, Skip, Rename, RenameExisting };

// 覆盖询问答案（对齐 IFileExtractCallback.h NOverwriteAnswer）。
enum class SZOverwriteAnswer { Yes = 0, YesToAll, No, NoToAll, AutoRename, Cancel };

// 解压事件回调（抽象类）。语义同步：工作线程直接调用，阻塞式询问（覆盖/密码/内存）就地等返回值。
// ObjC 层（SZExtractor.mm）经 dispatch_semaphore 把询问 hop 主线程对话框再回传，保持"工作线程阻塞等答案"。
// 默认实现给出无 GUI 时的安全缺省（取消=false、覆盖=Yes、无密码），便于命令行测试与策略对象（M2-T2）。
class SZExtractDelegate {
public:
  virtual ~SZExtractDelegate() {}

  // —— 进度（可能在 worker 线程被调用，见 02-core-bridge.md §5）——
  virtual void onTotalBytes(uint64_t total) {}
  virtual void onProgressBytes(uint64_t completed) {}

  // —— 文件级 ——
  // isTest=true 表示测试模式（askExtractMode==kTest）。
  virtual void onFileStart(const std::string &name, bool isDir, bool isTest) {}
  // opResult: 0=OK（对齐 NOperationResult::kOK），非 0 见 SZExtractCore.cpp 错误文案映射。
  virtual void onFileDone(const std::string &name, int opResult, bool encrypted) {}
  virtual void onMessageError(const std::string &message) {}

  // —— 归档级（多档案编排，M2-T5）——
  // hresult: 0=打开成功；diagnostic: 打开/解压失败时的诊断文案（无法打开/加密/偏移）。
  virtual void onArchiveResult(const std::string &arcPath, int hresult, const std::string &diagnostic) {}

  // —— 阻塞式询问（M2-T2）——
  virtual SZOverwriteAnswer askOverwrite(
      const std::string &existPath, uint64_t existSize, double existMTime,
      const std::string &newPath,   uint64_t newSize,   double newMTime) { return SZOverwriteAnswer::Yes; }
  // 返回 true 并填 password；false=用户取消解压。
  virtual bool getPassword(std::string &password) { return false; }
  // 内存超限：返回 true=放行继续；false=跳过该档/中止。
  virtual bool askKeepGoingOnMemory(uint64_t requiredBytes, uint64_t allowedBytes) { return true; }

  // 取消标志（对齐 CheckBreak2 → E_ABORT）。worker 线程高频轮询，须线程安全。
  virtual bool isCancelled() { return false; }
};

// 一次解压请求。一个请求可含多个归档（多档案批量编排）。
struct SZExtractRequest {
  std::vector<std::string> archivePaths;   // 归档文件 FS 路径（UTF-8），≥1
  std::string outputDir;                   // 目标目录（UTF-8）；testMode 时忽略
  SZPathMode pathMode = SZPathMode::FullPaths;
  SZOverwriteMode overwriteMode = SZOverwriteMode::Ask;
  bool testMode = false;                    // 测试模式（不落盘，校验完整性）
  bool elimDup = false;                     // ElimDup（消除重复路径）
  bool hasPassword = false;                 // 预设密码（来自对话框/命令行）
  std::string password;
  std::vector<std::string> selectedPaths;   // 档内相对路径白名单；空=全选（解压整档）
};

// 解压结果统计（聚合 CDecompressStat + 错误计数）。
struct SZExtractResult {
  int hresult = 0;                          // 整体 HRESULT：0=S_OK，<0 引擎错误，E_ABORT=用户取消
  uint64_t numArchives = 0;
  uint64_t numFiles = 0;
  uint64_t numFolders = 0;
  uint64_t unpackSize = 0;
  uint64_t numFileErrors = 0;               // 文件级错误数（CRC/DataError…）
  uint64_t numOpenErrors = 0;               // 归档级打开失败数（无法识别/损坏头）
  std::string errorMessage;                 // 聚合错误文案
  bool isOK() const { return hresult == 0 && numFileErrors == 0 && numOpenErrors == 0; }
};

class SZExtractCore {
public:
  // 同步执行解压（调用方负责放在后台线程；del 可为 nullptr=全用安全缺省）。
  static SZExtractResult run(const SZExtractRequest &req, SZExtractDelegate *del);
};
