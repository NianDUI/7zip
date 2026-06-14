// SZCompressCore.cpp —— 压缩核心（M3-T4 执行链 + M3-T1 基础参数合成）。
// 移植蓝本：7zz Console/UpdateCallbackConsole（回调集，去控制台 IO）+ Common/Update.cpp 的 UpdateArchive()。
// 非 INITGUID 单元（IID 由 SZFolderCore.o 提供）。延续 Pimpl：含 7-Zip 头，公开头不含。
// IUpdateCallbackUI2/IOpenCallbackUI 均为非 COM 虚接口，回调对象可栈分配（UpdateArchive 不 AddRef）。

#include "Common/MyCom.h"
#include "Common/StringConvert.h"
#include "Common/Wildcard.h"

#include "7zip/UI/Common/Update.h"
#include "7zip/UI/Common/UpdateCallback.h"
#include "7zip/UI/Common/ArchiveOpenCallback.h"
#include "7zip/UI/Common/DirItem.h"
#include "7zip/UI/Common/Property.h"
#include "7zip/UI/Agent/Agent.h"            // g_CodecsObj / LoadGlobalCodecs
#include "7zip/Archive/IArchive.h"

#include "SZCompressCore.h"
#include <time.h>

using namespace NWindows;

namespace {

std::string ToUtf8(const wchar_t *w) {
  if (!w) return std::string();
  UString u = w;
  AString a = UnicodeStringToMultiByte(u, CP_UTF8);
  return std::string(a.Ptr(), a.Len());
}
std::string ToUtf8(const FString &f) { return ToUtf8(fs2us(f).Ptr()); }
UString ToUString(const std::string &s) {
  return MultiByteToUnicodeString(AString(s.c_str()), CP_UTF8);
}

void AddProp(CObjectVector<CProperty> &props, const char *name, const UString &value) {
  CProperty p; p.Name = MultiByteToUnicodeString(AString(name), CP_UTF8); p.Value = value; props.Add(p);
}

} // namespace


// ======================== 回调 ========================

class SZUpdateCallback Z7_final:
  public IUpdateCallbackUI2,
  public IOpenCallbackUI
{
  Z7_IFACE_IMP(IUpdateCallbackUI)
  Z7_IFACE_IMP(IDirItemsCallback)
  Z7_IFACE_IMP(IUpdateCallbackUI2)
  Z7_IFACE_IMP(IOpenCallbackUI)

  SZCompressDelegate *_del;
  UString _password;
  bool _passwordDefined;

  bool Break() const {
    if (!_del) return false;
    while (_del->isPaused() && !_del->isCancelled()) {
      struct timespec ts = {0, 100 * 1000 * 1000};
      nanosleep(&ts, NULL);
    }
    return _del->isCancelled();
  }
  HRESULT GetPw(BSTR *password);

public:
  UInt64 OutArcFileSize;

  SZUpdateCallback(SZCompressDelegate *del, bool hasPw, const UString &pw):
      _del(del), _passwordDefined(hasPw), OutArcFileSize(0) { if (hasPw) _password = pw; }
};

// —— IUpdateCallbackUI ——
HRESULT SZUpdateCallback::WriteSfx(const wchar_t *, UInt64) { return S_OK; }
HRESULT SZUpdateCallback::SetTotal(UInt64 size) { if (_del) _del->onTotalBytes(size); return Break() ? E_ABORT : S_OK; }
HRESULT SZUpdateCallback::SetCompleted(const UInt64 *v) { if (_del && v) _del->onProgressBytes(*v); return Break() ? E_ABORT : S_OK; }
HRESULT SZUpdateCallback::SetRatioInfo(const UInt64 *, const UInt64 *) { return S_OK; }
HRESULT SZUpdateCallback::CheckBreak() { return Break() ? E_ABORT : S_OK; }
HRESULT SZUpdateCallback::SetNumItems(const CArcToDoStat &) { return S_OK; }
HRESULT SZUpdateCallback::GetStream(const wchar_t *name, bool /*isDir*/, bool /*isAnti*/, UInt32 /*mode*/) {
  if (_del && name) _del->onFileStart(ToUtf8(name));
  return Break() ? E_ABORT : S_OK;
}
HRESULT SZUpdateCallback::OpenFileError(const FString &path, DWORD systemError) {
  if (_del) _del->onScanError(ToUtf8(path), "open file error");
  (void)systemError; return S_OK;
}
HRESULT SZUpdateCallback::ReadingFileError(const FString &path, DWORD systemError) {
  if (_del) _del->onScanError(ToUtf8(path), "reading file error");
  (void)systemError; return S_OK;
}
HRESULT SZUpdateCallback::SetOperationResult(Int32 /*opRes*/) { return S_OK; }
HRESULT SZUpdateCallback::ReportExtractResult(Int32 /*opRes*/, Int32 /*enc*/, const wchar_t *) { return S_OK; }
HRESULT SZUpdateCallback::ReportUpdateOperation(UInt32 /*op*/, const wchar_t *, bool) { return S_OK; }

HRESULT SZUpdateCallback::GetPw(BSTR *password) {
  *password = NULL;
  return StringToBstr(_password.Ptr(), password);
}
HRESULT SZUpdateCallback::CryptoGetTextPassword2(Int32 *passwordIsDefined, BSTR *password) {
  *password = NULL;
  if (!_passwordDefined && _del) {
    std::string pw;
    if (_del->getPassword(pw)) { _password = ToUString(pw); _passwordDefined = true; }
  }
  *passwordIsDefined = _passwordDefined ? 1 : 0;
  return StringToBstr(_password.Ptr(), password);
}
HRESULT SZUpdateCallback::CryptoGetTextPassword(BSTR *password) { return GetPw(password); }
HRESULT SZUpdateCallback::ShowDeleteFile(const wchar_t *, bool) { return S_OK; }

// —— IDirItemsCallback ——
HRESULT SZUpdateCallback::ScanError(const FString &path, DWORD systemError) {
  if (_del) _del->onScanError(ToUtf8(path), "scan error");
  (void)systemError; return S_OK;
}
HRESULT SZUpdateCallback::ScanProgress(const CDirItemsStat & /*st*/, const FString &path, bool /*isDir*/) {
  if (_del) _del->onScanProgress(ToUtf8(path));
  return Break() ? E_ABORT : S_OK;
}

// —— IUpdateCallbackUI2 ——
HRESULT SZUpdateCallback::OpenResult(const CCodecs *, const CArchiveLink &, const wchar_t *, HRESULT) { return S_OK; }
HRESULT SZUpdateCallback::StartScanning() { return S_OK; }
HRESULT SZUpdateCallback::FinishScanning(const CDirItemsStat &) { return S_OK; }
HRESULT SZUpdateCallback::StartOpenArchive(const wchar_t *) { return S_OK; }
HRESULT SZUpdateCallback::StartArchive(const wchar_t *, bool) { return S_OK; }
HRESULT SZUpdateCallback::FinishArchive(const CFinishArchiveStat &st) { OutArcFileSize = st.OutArcFileSize; return S_OK; }
HRESULT SZUpdateCallback::DeletingAfterArchiving(const FString &, bool) { return S_OK; }
HRESULT SZUpdateCallback::FinishDeletingAfterArchiving() { return S_OK; }
HRESULT SZUpdateCallback::MoveArc_Start(const wchar_t *, const wchar_t *, UInt64, Int32) { return S_OK; }
HRESULT SZUpdateCallback::MoveArc_Progress(UInt64, UInt64) { return Break() ? E_ABORT : S_OK; }
HRESULT SZUpdateCallback::MoveArc_Finish() { return S_OK; }

// —— IOpenCallbackUI（更新现有归档时打开旧档）——
HRESULT SZUpdateCallback::Open_CheckBreak() { return Break() ? E_ABORT : S_OK; }
HRESULT SZUpdateCallback::Open_SetTotal(const UInt64 *, const UInt64 *) { return Break() ? E_ABORT : S_OK; }
HRESULT SZUpdateCallback::Open_SetCompleted(const UInt64 *, const UInt64 *) { return Break() ? E_ABORT : S_OK; }
HRESULT SZUpdateCallback::Open_Finished() { return S_OK; }
HRESULT SZUpdateCallback::Open_CryptoGetTextPassword(BSTR *password) { return GetPw(password); }


// ======================== 入口 ========================

SZCompressResult SZCompressCore::run(const SZCompressRequest &req, SZCompressDelegate *del) {
  SZCompressResult res;
  if (LoadGlobalCodecs() != S_OK || !g_CodecsObj || req.inputPaths.empty() || req.archivePath.empty()) {
    res.hresult = (int)E_FAIL;
    res.errorMessage = "codecs load failed or no input/output";
    return res;
  }

  const UString arcPath = ToUString(req.archivePath);

  // 是否 7z（决定 solid/he 等 7z 专有属性是否下发，避免对 zip/tar 报错）
  bool is7z = (req.format == "7z");
  if (req.format.empty()) {
    const size_t dot = req.archivePath.find_last_of('.');
    is7z = (dot != std::string::npos && req.archivePath.substr(dot) == ".7z");
  }

  CUpdateOptions options;
  options.SetActionCommand_Add();   // Add 动作（新建/追加）

  // 显式格式（否则 UpdateArchive 内部按扩展名 FindFormatForArchiveName 推断）
  if (!req.format.empty()) {
    const int fi = g_CodecsObj->FindFormatForArchiveType(ToUString(req.format));
    if (fi >= 0) { options.MethodMode.Type.FormatIndex = fi; options.MethodMode.Type_Defined = true; }
  }

  // —— 参数合成（CProperty 列表，对齐 7-Zip -m 开关名）——
  CObjectVector<CProperty> &P = options.MethodMode.Properties;
  AddProp(P, "x", ToUString(std::to_string(req.level)));        // 等级
  if (!req.method.empty()) AddProp(P, "0", ToUString(req.method));         // 主方法
  if (req.dictSize)        AddProp(P, "d", ToUString(std::to_string(req.dictSize) + "b"));
  if (req.threads > 0)     AddProp(P, "mt", ToUString(std::to_string(req.threads)));
  if (is7z) {
    AddProp(P, "s", req.solid ? UString("on") : UString("off"));          // 固实
    if (req.encryptHeader) AddProp(P, "he", UString("on"));               // 加密文件名
  }
  for (size_t i = 0; i < req.extraProperties.size(); i++) {               // 额外属性透传
    const std::string &kv = req.extraProperties[i];
    const size_t eq = kv.find('=');
    if (eq == std::string::npos) AddProp(P, kv.c_str(), UString());
    else { std::string n = kv.substr(0, eq); AddProp(P, n.c_str(), ToUString(kv.substr(eq + 1))); }
  }

  // 输入文件 censor（每个磁盘路径 AddPreItem_NoWildcard）
  NWildcard::CCensor censor;
  for (size_t i = 0; i < req.inputPaths.size(); i++)
    censor.AddPreItem_NoWildcard(ToUString(req.inputPaths[i]));
  censor.AddPathsToCensor(NWildcard::k_RelatPath);

  CObjectVector<COpenType> types;   // 空（格式经 MethodMode.Type 或 arcPath 扩展名）
  CUpdateErrorInfo errorInfo;
  SZUpdateCallback cb(del, req.hasPassword, ToUString(req.password));

  const HRESULT hr = UpdateArchive(
      g_CodecsObj, types, arcPath, censor, options, errorInfo,
      &cb,   // openCallback (IOpenCallbackUI)
      &cb,   // callback     (IUpdateCallbackUI2)
      true); // needSetPath

  res.hresult = (int)hr;
  res.outArchiveSize = cb.OutArcFileSize;
  if (errorInfo.ThereIsError() && !errorInfo.Message.IsEmpty())
    res.errorMessage = std::string(errorInfo.Message.Ptr(), errorInfo.Message.Len());
  return res;
}
