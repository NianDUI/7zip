// SZHashCore.cpp —— 哈希核心实现（M5）。
// 移植蓝本：HashCalc.cpp 的 HashCalc() 顶层函数 + HashCon.cpp 的结果读取（k_HashCalc_Index_Current/DataSum）。
// 非 INITGUID 单元：7-Zip IID 由 SZFolderCore.cpp（唯一含 MyInitGuid.h 者）在链接期提供。
// 延续 Pimpl：本文件含 7-Zip 头，公开头 SZHashCore.h 不含（BOOL 隔离）。
#include "Common/MyCom.h"
#include "Common/StringConvert.h"
#include "Common/Wildcard.h"

#include "7zip/UI/Common/HashCalc.h"
#include "7zip/UI/Common/EnumDirItems.h"   // CDirItemsStat（回调签名用到）

#include "SZHashCore.h"

using namespace NWindows;

namespace {

// —— 类型转换 helpers（与 SZExtractCore 同源约定）——
std::string ToUtf8(const wchar_t *w) {
  if (!w) return std::string();
  UString u = w;
  AString a = UnicodeStringToMultiByte(u, CP_UTF8);
  return std::string(a.Ptr(), a.Len());
}
std::string ToUtf8(const UString &u) {
  AString a = UnicodeStringToMultiByte(u, CP_UTF8);
  return std::string(a.Ptr(), a.Len());
}
std::string ToUtf8(const AString &a) {
  return std::string(a.Ptr(), a.Len());
}
std::string FsToUtf8(const FString &p) {
  return ToUtf8(fs2us(p));
}
UString ToUString(const std::string &s) {
  return MultiByteToUnicodeString(AString(s.c_str()), CP_UTF8);
}

// WriteToString 输出缓冲（对齐 HashCon.cpp k_DigestStringSize）。
const unsigned kDigestStrSize = k_HashCalc_DigestSize_Max * 2 + k_HashCalc_ExtraSize * 2 + 16;

// 读某 group（Current/DataSum）的每算法哈希字符串，组装到 out。
void ReadHashes(const CObjectVector<CHasherState> &hashers, unsigned groupIndex,
                std::vector<SZHashPair> &out) {
  out.clear();
  FOR_VECTOR (i, hashers) {
    const CHasherState &h = hashers[i];
    char buf[kDigestStrSize + 4];
    buf[0] = 0;
    h.WriteToString(groupIndex, buf);
    SZHashPair p;
    p.method = ToUtf8(h.Name);
    p.hex = buf;
    out.push_back(p);
  }
}

} // namespace


// ======================== 回调实现 ========================
// IHashCallbackUI（含 IDirItemsCallback）是 7-Zip 纯虚接口（非 COM，无 AddRef/Release/QI），直接继承实现。
class SZHashCallback Z7_final : public IHashCallbackUI {
  SZHashDelegate *del_;
  SZHashResult &res_;
  std::string curName_;     // GetStream 记录的当前文件显示路径
  bool curIsDir_ = false;
public:
  SZHashCallback(SZHashDelegate *del, SZHashResult &res) : del_(del), res_(res) {}

  HRESULT CheckBreak2() { return (del_ && del_->isCancelled()) ? E_ABORT : S_OK; }

  // —— IDirItemsCallback ——
  HRESULT ScanError(const FString &path, DWORD systemError) Z7_override {
    if (del_) del_->onScanError(FsToUtf8(path), "scan error");
    return S_OK;   // 扫描错误不中断枚举
  }
  HRESULT ScanProgress(const CDirItemsStat & /*st*/, const FString & /*path*/, bool /*isDir*/) Z7_override {
    return CheckBreak2();
  }

  // —— IHashCallbackUI ——
  HRESULT StartScanning() Z7_override { return S_OK; }
  HRESULT FinishScanning(const CDirItemsStat & /*st*/) Z7_override { return S_OK; }
  HRESULT SetNumFiles(UInt64 /*numFiles*/) Z7_override { return S_OK; }
  HRESULT SetTotal(UInt64 size) Z7_override {
    res_.totalSize = size;
    if (del_) del_->onTotalBytes(size);
    return S_OK;
  }
  HRESULT SetCompleted(const UInt64 *completeValue) Z7_override {
    if (completeValue && del_) del_->onProgressBytes(*completeValue);
    return CheckBreak2();
  }
  HRESULT CheckBreak() Z7_override { return CheckBreak2(); }
  HRESULT BeforeFirstFile(const CHashBundle & /*hb*/) Z7_override { return S_OK; }

  HRESULT GetStream(const wchar_t *name, bool isFolder) Z7_override {
    curName_ = ToUtf8(name);
    curIsDir_ = isFolder;
    return S_OK;
  }

  HRESULT OpenFileError(const FString &path, DWORD /*systemError*/) Z7_override {
    if (del_) del_->onScanError(FsToUtf8(path), "open error");
    return S_FALSE;   // 必须 S_FALSE：HashCalc 内 `if (res != S_FALSE) return res` 才会 continue 下一文件
  }

  HRESULT SetOperationResult(UInt64 fileSize, const CHashBundle &hb, bool showHash) Z7_override {
    // 仅文件项回调（目录无哈希价值；"算文件校验和"语义只列文件）。numDirs 仍在 AfterLastFile 统计。
    if (del_ && !curIsDir_) {
      SZHashFileResult r;
      r.path = curName_;
      r.size = fileSize;
      r.isDir = false;
      if (showHash)
        ReadHashes(hb.Hashers, k_HashCalc_Index_Current, r.hashes);
      del_->onFileResult(r);
    }
    return CheckBreak2();
  }

  HRESULT AfterLastFile(CHashBundle &hb) Z7_override {
    res_.numFiles = hb.NumFiles;
    res_.numDirs = hb.NumDirs;
    res_.numErrors = hb.NumErrors;
    // 数据总和（所有文件内容拼接的哈希，对齐 7zz "for data:" 行）
    ReadHashes(hb.Hashers, k_HashCalc_Index_DataSum, res_.dataSum);
    return S_OK;
  }
};


// ======================== 入口 ========================
SZHashResult SZHashCore::run(const SZHashRequest &req, SZHashDelegate *del) {
  SZHashResult res;
  if (req.paths.empty()) {
    res.hresult = (int)E_INVALIDARG;
    res.errorMessage = "no input paths";
    return res;
  }

  // 输入文件 censor（每磁盘路径 AddPreItem_NoWildcard，对齐 SZCompressCore）。
  NWildcard::CCensor censor;
  for (size_t i = 0; i < req.paths.size(); i++)
    censor.AddPreItem_NoWildcard(ToUString(req.paths[i]));
  censor.AddPathsToCensor(NWildcard::k_RelatPath);

  CHashOptions options;
  if (req.methods.empty()) {
    options.Methods.Add(UString("CRC32"));
  } else {
    for (size_t i = 0; i < req.methods.size(); i++)
      options.Methods.Add(ToUString(req.methods[i]));
  }
  options.PathMode = NWildcard::k_RelatPath;

  SZHashCallback cb(del, res);
  AString errorInfo;
  const HRESULT hr = HashCalc(censor, options, errorInfo, &cb);

  res.hresult = (int)hr;
  if (!errorInfo.IsEmpty())
    res.errorMessage = ToUtf8(errorInfo);
  return res;
}

std::vector<std::string> SZHashCore::supportedMethods() {
  // 与 7zz i 的 Hashers 段一致；按 GUI 展示常用序（CRC 在前，SHA 系，再哈希家族）。
  return {
    "CRC32", "CRC64",
    "SHA1", "SHA256", "SHA384", "SHA512", "SHA3-256",
    "BLAKE2sp", "XXH64", "MD5",
  };
}
