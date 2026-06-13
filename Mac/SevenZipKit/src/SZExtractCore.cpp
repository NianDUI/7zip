// SZExtractCore.cpp —— 解压核心实现（M2-T1）。
// 移植蓝本：7zz CPP/7zip/UI/Console/ExtractCallbackConsole.cpp 的回调集，去掉控制台 IO（CStdOutStream/
// CPercentPrinter），把每个回调事件转发到纯 C++ 抽象 SZExtractDelegate；解压本体调 Common/Extract.cpp 的
// Extract()（与 7zz x/t 命令同一函数，故输出可与 7zz 字节对照，见 M2-T8）。
// 非 INITGUID 单元：全部 7-Zip IID 由 SZFolderCore.cpp（唯一含 MyInitGuid.h 者）在链接期提供。
// 延续 Pimpl：本文件含 7-Zip 头，公开头 SZExtractCore.h 不含（BOOL 隔离）。

#include "Common/MyCom.h"
#include "Common/StringConvert.h"
#include "Common/Wildcard.h"
#include "Windows/PropVariant.h"

#include "7zip/Archive/IArchive.h"
#include "7zip/UI/Common/OpenArchive.h"
#include "7zip/UI/Common/Extract.h"
#include "7zip/UI/Agent/Agent.h"            // g_CodecsObj / LoadGlobalCodecs

#include "SZExtractCore.h"

using namespace NWindows;

namespace {

// —— 类型转换 helpers（与 SZFolderCore 同源约定：UTF-8 ↔ UString、FILETIME → unix 秒）——
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
UString ToUString(const std::string &s) {
  return MultiByteToUnicodeString(AString(s.c_str()), CP_UTF8);
}
double FiletimeToUnix(const FILETIME &ft) {
  unsigned long long t = ((unsigned long long)ft.dwHighDateTime << 32) | ft.dwLowDateTime;
  const unsigned long long kEpochDiff = 116444736000000000ULL; // 1601→1970 的 100ns 数
  if (t == 0 || t < kEpochDiff) return -1;
  return (double)(t - kEpochDiff) / 10000000.0;
}

// 错误码 → 文案（移植 SetExtractErrorMessage，ExtractCallbackConsole.cpp:418-463 的英文常量，1:1）。
const char *OpResultText(Int32 opRes, Int32 encrypted) {
  using namespace NArchive::NExtract;
  switch (opRes) {
    case NOperationResult::kUnsupportedMethod: return "Unsupported Method";
    case NOperationResult::kCRCError:          return encrypted ? "CRC Failed in encrypted file. Wrong password?" : "CRC Failed";
    case NOperationResult::kDataError:         return encrypted ? "Data Error in encrypted file. Wrong password?" : "Data Error";
    case NOperationResult::kUnavailable:       return "Unavailable data";
    case NOperationResult::kUnexpectedEnd:     return "Unexpected end of data";
    case NOperationResult::kDataAfterEnd:      return "There are some data after the end of the payload data";
    case NOperationResult::kIsNotArc:          return "Is not archive";
    case NOperationResult::kHeadersError:      return "Headers Error";
    case NOperationResult::kWrongPassword:     return "Wrong password";
    default:                                   return NULL;
  }
}

} // namespace


// ======================== 回调实现 ========================
// 接口集对齐 console CExtractCallbackConsole（去 SFX/crypto 条件编译，mac 全开）：
//   IProgress / IFolderArchiveExtractCallback / IExtractCallbackUI(非COM) / IOpenCallbackUI(非COM)
//   / IFolderArchiveExtractCallback2 / ICryptoGetTextPassword / IArchiveRequestMemoryUseCallback

class SZExtractCallback Z7_final:
  public IFolderArchiveExtractCallback,
  public IExtractCallbackUI,        // 非 COM（v23.00 起不含 IFolderArchiveExtractCallback）
  public IOpenCallbackUI,           // 非 COM
  public IFolderArchiveExtractCallback2,
  public ICryptoGetTextPassword,
  public IArchiveRequestMemoryUseCallback,
  public CMyUnknownImp
{
  Z7_COM_QI_BEGIN2(IFolderArchiveExtractCallback)
  Z7_COM_QI_ENTRY(IFolderArchiveExtractCallback2)
  Z7_COM_QI_ENTRY(ICryptoGetTextPassword)
  Z7_COM_QI_ENTRY(IArchiveRequestMemoryUseCallback)
  Z7_COM_QI_END
  Z7_COM_ADDREF_RELEASE

  Z7_IFACE_COM7_IMP(IProgress)
  Z7_IFACE_COM7_IMP(IFolderArchiveExtractCallback)
  Z7_IFACE_IMP(IExtractCallbackUI)
  Z7_IFACE_IMP(IOpenCallbackUI)
  Z7_IFACE_COM7_IMP(IFolderArchiveExtractCallback2)
  Z7_IFACE_COM7_IMP(ICryptoGetTextPassword)
  Z7_IFACE_COM7_IMP(IArchiveRequestMemoryUseCallback)

  SZExtractDelegate *_del;
  UString _currentArchivePath;
  UString _currentName;
  UString _password;
  bool _passwordDefined;

  bool Break() const { return _del && _del->isCancelled(); }
  HRESULT GetPasswordImpl(BSTR *password);

public:
  UInt64 NumFileErrors;
  UInt64 NumOpenErrors;

  SZExtractCallback(SZExtractDelegate *del):
      _del(del), _passwordDefined(false), NumFileErrors(0), NumOpenErrors(0) {}

  void SetPasswordPreset(const UString &pw) { _password = pw; _passwordDefined = true; }
};


// —— IProgress ——
Z7_COM7F_IMF(SZExtractCallback::SetTotal(UInt64 size)) {
  if (_del) _del->onTotalBytes(size);
  return Break() ? E_ABORT : S_OK;
}
Z7_COM7F_IMF(SZExtractCallback::SetCompleted(const UInt64 *completeValue)) {
  if (_del && completeValue) _del->onProgressBytes(*completeValue);
  return Break() ? E_ABORT : S_OK;
}

// —— IFolderArchiveExtractCallback ——
Z7_COM7F_IMF(SZExtractCallback::AskOverwrite(
    const wchar_t *existName, const FILETIME *existTime, const UInt64 *existSize,
    const wchar_t *newName, const FILETIME *newTime, const UInt64 *newSize,
    Int32 *answer))
{
  if (Break()) return E_ABORT;
  SZOverwriteAnswer a = SZOverwriteAnswer::Yes;
  if (_del)
    a = _del->askOverwrite(
        ToUtf8(existName), existSize ? *existSize : 0, existTime ? FiletimeToUnix(*existTime) : -1,
        ToUtf8(newName),   newSize  ? *newSize  : 0, newTime  ? FiletimeToUnix(*newTime)  : -1);
  switch (a) {
    case SZOverwriteAnswer::Yes:        *answer = NOverwriteAnswer::kYes;      break;
    case SZOverwriteAnswer::YesToAll:   *answer = NOverwriteAnswer::kYesToAll; break;
    case SZOverwriteAnswer::No:         *answer = NOverwriteAnswer::kNo;       break;
    case SZOverwriteAnswer::NoToAll:    *answer = NOverwriteAnswer::kNoToAll;  break;
    case SZOverwriteAnswer::AutoRename: *answer = NOverwriteAnswer::kAutoRename; break;
    case SZOverwriteAnswer::Cancel:     return E_ABORT;
  }
  return S_OK;
}

Z7_COM7F_IMF(SZExtractCallback::PrepareOperation(const wchar_t *name, Int32 isFolder, Int32 askExtractMode, const UInt64 *position)) {
  UNUSED_VAR(position)
  _currentName = name ? name : L"";
  if (_del) {
    const bool isTest = (askExtractMode == NArchive::NExtract::NAskMode::kTest);
    _del->onFileStart(ToUtf8(_currentName), isFolder != 0, isTest);
  }
  return Break() ? E_ABORT : S_OK;
}

Z7_COM7F_IMF(SZExtractCallback::MessageError(const wchar_t *message)) {
  NumFileErrors++;
  if (_del) _del->onMessageError(ToUtf8(message));
  return Break() ? E_ABORT : S_OK;
}

Z7_COM7F_IMF(SZExtractCallback::SetOperationResult(Int32 opRes, Int32 encrypted)) {
  if (opRes != NArchive::NExtract::NOperationResult::kOK)
    NumFileErrors++;
  if (_del) _del->onFileDone(ToUtf8(_currentName), (int)opRes, encrypted != 0);
  return Break() ? E_ABORT : S_OK;
}

// —— IFolderArchiveExtractCallback2 ——
Z7_COM7F_IMF(SZExtractCallback::ReportExtractResult(Int32 opRes, Int32 encrypted, const wchar_t *name)) {
  if (opRes != NArchive::NExtract::NOperationResult::kOK) {
    _currentName = name ? name : L"";
    return SetOperationResult(opRes, encrypted);
  }
  return Break() ? E_ABORT : S_OK;
}

// —— ICryptoGetTextPassword / IOpenCallbackUI 密码（共用）——
HRESULT SZExtractCallback::GetPasswordImpl(BSTR *password) {
  if (!_passwordDefined) {
    std::string pw;
    if (_del && _del->getPassword(pw)) {
      _password = ToUString(pw);
      _passwordDefined = true;
    } else {
      return E_ABORT; // 用户取消
    }
  }
  *password = NULL;
  return StringToBstr(_password.Ptr(), password);
}
Z7_COM7F_IMF(SZExtractCallback::CryptoGetTextPassword(BSTR *password)) {
  return GetPasswordImpl(password);
}

// —— IArchiveRequestMemoryUseCallback（移植 console RequestMemoryUse 简化版）——
Z7_COM7F_IMF(SZExtractCallback::RequestMemoryUse(
    UInt32 flags, UInt32 indexType, UInt32 index, const wchar_t *path,
    UInt64 requiredSize, UInt64 *allowedSize, UInt32 *answerFlags))
{
  UNUSED_VAR(indexType) UNUSED_VAR(index) UNUSED_VAR(path)
  if (flags & NRequestMemoryUseFlags::k_IsReport) {
    // 仅报告，无需用户决策
    return S_OK;
  }
  bool keepGoing = true;
  if (_del)
    keepGoing = _del->askKeepGoingOnMemory(requiredSize, allowedSize ? *allowedSize : 0);
  if (answerFlags) {
    if (keepGoing) {
      *answerFlags = NRequestMemoryAnswerFlags::k_Allow;
      if (allowedSize && *allowedSize < requiredSize) *allowedSize = requiredSize;
    } else {
      *answerFlags = (flags & NRequestMemoryUseFlags::k_SkipArc_IsExpected)
          ? NRequestMemoryAnswerFlags::k_SkipArc
          : NRequestMemoryAnswerFlags::k_Stop;
    }
  }
  return S_OK;
}

// —— IExtractCallbackUI（非 COM）——
HRESULT SZExtractCallback::BeforeOpen(const wchar_t *name, bool testMode) {
  UNUSED_VAR(testMode)
  _currentArchivePath = name ? name : L"";
  return Break() ? E_ABORT : S_OK;
}
HRESULT SZExtractCallback::OpenResult(const CCodecs *codecs, const CArchiveLink &arcLink, const wchar_t *name, HRESULT result) {
  UNUSED_VAR(codecs) UNUSED_VAR(arcLink)
  std::string diag;
  if (result != S_OK) {
    NumOpenErrors++;
    diag = (result == S_FALSE) ? "Cannot open the file as archive" : "Open error";
  }
  if (_del) _del->onArchiveResult(ToUtf8(name), (int)result, diag);
  return S_OK;
}
HRESULT SZExtractCallback::ThereAreNoFiles() { return S_OK; }
HRESULT SZExtractCallback::ExtractResult(HRESULT result) {
  if (result == E_ABORT) return result;   // 用户取消 → 中止后续档案
  return S_OK;                            // 其他错误已逐条记录，继续批量（多档案编排，M2-T5）
}
HRESULT SZExtractCallback::SetPassword(const UString &password) {
  _password = password;
  _passwordDefined = true;
  return S_OK;
}

// —— IOpenCallbackUI（非 COM）——
HRESULT SZExtractCallback::Open_CheckBreak()                                  { return Break() ? E_ABORT : S_OK; }
HRESULT SZExtractCallback::Open_SetTotal(const UInt64 *, const UInt64 *)      { return Break() ? E_ABORT : S_OK; }
HRESULT SZExtractCallback::Open_SetCompleted(const UInt64 *, const UInt64 *)  { return Break() ? E_ABORT : S_OK; }
HRESULT SZExtractCallback::Open_Finished()                                    { return S_OK; }
HRESULT SZExtractCallback::Open_CryptoGetTextPassword(BSTR *password)         { return GetPasswordImpl(password); }


// ======================== 入口：组装 CExtractOptions + censor 并调 Extract() ========================
namespace {

NExtract::NPathMode::EEnum MapPathMode(SZPathMode m) {
  switch (m) {
    case SZPathMode::NoPaths:  return NExtract::NPathMode::kNoPaths;
    case SZPathMode::AbsPaths: return NExtract::NPathMode::kAbsPaths;
    case SZPathMode::FullPaths:
    default:                   return NExtract::NPathMode::kFullPaths;
  }
}
NExtract::NOverwriteMode::EEnum MapOverwriteMode(SZOverwriteMode m) {
  switch (m) {
    case SZOverwriteMode::Overwrite:      return NExtract::NOverwriteMode::kOverwrite;
    case SZOverwriteMode::Skip:           return NExtract::NOverwriteMode::kSkip;
    case SZOverwriteMode::Rename:         return NExtract::NOverwriteMode::kRename;
    case SZOverwriteMode::RenameExisting: return NExtract::NOverwriteMode::kRenameExisting;
    case SZOverwriteMode::Ask:
    default:                              return NExtract::NOverwriteMode::kAsk;
  }
}

} // namespace

SZExtractResult SZExtractCore::run(const SZExtractRequest &req, SZExtractDelegate *del) {
  SZExtractResult res;

  if (LoadGlobalCodecs() != S_OK || !g_CodecsObj || req.archivePaths.empty()) {
    res.hresult = (int)E_FAIL;
    res.errorMessage = "codecs load failed or no archive";
    return res;
  }

  // COM 对象必须堆分配：Extract() 内部会 AddRef/Release，引用归零时 CMyUnknownImp::Release 会 delete this。
  // 栈分配会在归零时对栈对象 delete → abort（console 版同理用 new）。keeper 持一引用，函数末自动释放。
  SZExtractCallback *cb = new SZExtractCallback(del);
  CMyComPtr<IFolderArchiveExtractCallback> keeper(cb);
  if (req.hasPassword)
    cb->SetPasswordPreset(ToUString(req.password));

  // 目标目录（末尾补路径分隔符；testMode 时忽略）
  FString outDir;
  if (!req.testMode) {
    outDir = us2fs(ToUString(req.outputDir));
    if (!outDir.IsEmpty() && outDir.Back() != FCHAR_PATH_SEPARATOR)
      outDir.Add_PathSepar();
  }

  CExtractOptions options;
  options.PathMode = MapPathMode(req.pathMode);
  options.PathMode_Force = true;
  options.OverwriteMode = MapOverwriteMode(req.overwriteMode);
  options.OverwriteMode_Force = true;
  options.TestMode = req.testMode;
  options.OutputDir = outDir;
  options.OutDirMode = NExtractOutDirMode::k_Direct;   // OutputDir 即字面目录
  options.ElimDup.Val = req.elimDup;
  options.ElimDup.Def = true;

  // 选择哪些条目：白名单非空→逐条精确匹配；否则 "*" 全选（解压整档）。
  NWildcard::CCensor censor;
  if (req.selectedPaths.empty())
    censor.AddPreItem_Wildcard();
  else
    for (size_t i = 0; i < req.selectedPaths.size(); i++)
      censor.AddPreItem_NoWildcard(ToUString(req.selectedPaths[i]));
  censor.AddPathsToCensor(NWildcard::k_RelatPath);

  // 归档路径向量（path 与 full 同值；full 仅用于 OutDirMode 的归档名拼接，此处 k_Direct 不依赖）
  UStringVector arcPaths, arcPathsFull;
  for (size_t i = 0; i < req.archivePaths.size(); i++) {
    UString u = ToUString(req.archivePaths[i]);
    arcPaths.Add(u);
    arcPathsFull.Add(u);
  }

  CObjectVector<COpenType> types;   // 空 = 自动识别格式
  CIntVector excludedFormats;       // 空
  UString errorMessage;
  CDecompressStat stat;
  stat.Clear();

  const HRESULT hr = Extract(
      g_CodecsObj, types, excludedFormats,
      arcPaths, arcPathsFull,
      censor.Pairs.Front().Head, options,
      cb,    // openCallback   (IOpenCallbackUI)
      cb,    // extractCallback (IExtractCallbackUI)
      cb,    // faeCallback    (IFolderArchiveExtractCallback)
      NULL,  // hash
      errorMessage, stat);

  res.hresult     = (int)hr;
  res.numArchives = stat.NumArchives;
  res.numFiles    = stat.NumFiles;
  res.numFolders  = stat.NumFolders;
  res.unpackSize  = stat.UnpackSize;
  res.numFileErrors = cb->NumFileErrors;
  res.numOpenErrors = cb->NumOpenErrors;
  res.errorMessage  = ToUtf8(errorMessage);
  return res;
}

std::string SZExtractErrorText(int opResult, bool encrypted) {
  if (opResult == NArchive::NExtract::NOperationResult::kOK) return std::string();
  const char *s = OpResultText((Int32)opResult, encrypted ? 1 : 0);
  if (s) return std::string(s);
  return std::string("Error #") + std::to_string(opResult);
}
