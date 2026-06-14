// SZFolderCore.cpp —— 纯 C++ 桥接核心实现（唯一 INITGUID 单元；不含 ObjC，故可安全 include 7-Zip 头）。
// 包装 CArchiveFolderManager → CAgent → CAgentFolder/IFolderFolder 的只读导航（M1-T5）。

#include "Common/MyInitGuid.h"            // 唯一 INITGUID 单元：实体化全部 7-Zip IID
#include "Common/MyCom.h"
#include "Common/StringConvert.h"
#include "Windows/PropVariant.h"
#include "7zip/Common/FileStreams.h"       // CInFileStream
#include "7zip/UI/FileManager/IFolder.h"   // IFolderFolder/IFolderManager/IFolderArcProps...
#include "7zip/UI/Agent/Agent.h"           // CArchiveFolderManager

#include "SZFolderCore.h"
#include <vector>
#include <algorithm>

using namespace NWindows;

// 自然排序（SZNaturalCompare.cpp，同源移植 PanelSort.cpp:14）。wchar 版供预转键排序（M1-T9 优化）。
extern int CompareFileNames_ForFolderList(const wchar_t *s1, const wchar_t *s2);

namespace {

std::string ExtOf(const std::string &name) {
  const size_t p = name.find_last_of('.');
  return (p == std::string::npos) ? std::string() : name.substr(p);
}

// UString(UTF-32 wchar) → std::string(UTF-8)。经 7-Zip 的 UnicodeStringToMultiByte(CP_UTF8)。
std::string ToUtf8(const wchar_t *w) {
  if (!w) return std::string();
  UString u = w;
  AString a = UnicodeStringToMultiByte(u, CP_UTF8);
  return std::string(a.Ptr(), a.Len());
}

double FiletimeToUnix(const FILETIME &ft) {
  unsigned long long t = ((unsigned long long)ft.dwHighDateTime << 32) | ft.dwLowDateTime;
  const unsigned long long kEpochDiff = 116444736000000000ULL; // 1601→1970 的 100ns 数
  if (t == 0 || t < kEpochDiff) return -1;
  return (double)(t - kEpochDiff) / 10000000.0;
}

unsigned long long PropU64(const PROPVARIANT &p) {
  switch (p.vt) {
    case VT_UI8: return (unsigned long long)p.uhVal.QuadPart;
    case VT_UI4: return p.ulVal;
    case VT_UI2: return p.uiVal;
    default:     return 0;
  }
}

UString ToUString(const std::string &s) {
  return MultiByteToUnicodeString(AString(s.c_str()), CP_UTF8);
}

} // namespace

struct SZFolderCore::Impl {
  CMyComPtr<IInStream>                   stream;
  CMyComPtr<IFolderManager>             mgr;
  CMyComPtr<IFolderFolder>             folder;
  std::vector<CMyComPtr<IFolderFolder>> parents;
  std::vector<std::string>             pathStack;
  std::vector<SZCoreItem>              items;
  SZSortKey sortKey_   = SZSortKey::Name;   // 默认按名升序（7zFM 初始）
  bool      ascending_ = true;

  void applySort() {
    const SZSortKey key = sortKey_;
    const bool asc = ascending_;
    const size_t n = items.size();
    if (n < 2) return;

    // M1-T9 优化：预转 name → UString（O(n)），避免在 O(n log n) 次比较里反复 UTF-8→UString 转换。
    std::vector<UString> nameKeys(n);
    for (size_t i = 0; i < n; i++)
      nameKeys[i] = MultiByteToUnicodeString(AString(items[i].name.c_str()), CP_UTF8);
    std::vector<UString> extKeys;
    if (key == SZSortKey::Type) {
      extKeys.resize(n);
      for (size_t i = 0; i < n; i++)
        extKeys[i] = MultiByteToUnicodeString(AString(ExtOf(items[i].name).c_str()), CP_UTF8);
    }

    // 排序索引（目录恒在文件前不受方向影响 PanelSort:190；同类按 key+方向；主键相等二级按 Name；
    // 仍相等 stable_sort 保持 LoadItems 原序）。
    std::vector<size_t> idx(n);
    for (size_t i = 0; i < n; i++) idx[i] = i;
    std::stable_sort(idx.begin(), idx.end(), [&](size_t a, size_t b) -> bool {
      const SZCoreItem &ia = items[a], &ib = items[b];
      if (ia.isDir != ib.isDir) return ia.isDir;
      if (key == SZSortKey::None) return false;
      int r = 0;
      switch (key) {
        case SZSortKey::Name:   r = CompareFileNames_ForFolderList(nameKeys[a].Ptr(), nameKeys[b].Ptr()); break;
        case SZSortKey::Size:   r = (ia.size  < ib.size)  ? -1 : (ia.size  > ib.size)  ? 1 : 0; break;
        case SZSortKey::MTime:  r = (ia.mtime < ib.mtime) ? -1 : (ia.mtime > ib.mtime) ? 1 : 0; break;
        case SZSortKey::Attrib: r = (ia.attrib < ib.attrib) ? -1 : (ia.attrib > ib.attrib) ? 1 : 0; break;
        case SZSortKey::Type:   r = CompareFileNames_ForFolderList(extKeys[a].Ptr(), extKeys[b].Ptr()); break;
        case SZSortKey::None:   return false;
      }
      if (r == 0 && key != SZSortKey::Name)
        r = CompareFileNames_ForFolderList(nameKeys[a].Ptr(), nameKeys[b].Ptr());  // 二级 Name
      if (r == 0) return false;
      return asc ? (r < 0) : (r > 0);
    });

    // 按 idx 原地重排（new[i]=old[idx[i]]），省一份 items 副本（M1-T9 控峰值）。
    std::vector<char> done(n, 0);
    for (size_t i = 0; i < n; i++) {
      if (done[i]) continue;
      size_t j = i;
      SZCoreItem tmp = std::move(items[i]);
      for (;;) {
        done[j] = 1;
        const size_t src = idx[j];
        if (src == i) { items[j] = std::move(tmp); break; }
        items[j] = std::move(items[src]);
        j = src;
      }
    }
  }

  void reload() {
    items.clear();
    if (!folder) return;
    folder->LoadItems();
    UInt32 n = 0;
    folder->GetNumberOfItems(&n);
    items.reserve(n);
    for (UInt32 i = 0; i < n; i++) {
      NCOM::CPropVariant path, name, isDir, size, mtime, attrib, crc;
      folder->GetProperty(i, kpidPath,   &path);
      folder->GetProperty(i, kpidName,   &name);
      folder->GetProperty(i, kpidIsDir,  &isDir);
      folder->GetProperty(i, kpidSize,   &size);
      folder->GetProperty(i, kpidMTime,  &mtime);
      folder->GetProperty(i, kpidAttrib, &attrib);
      folder->GetProperty(i, kpidCRC,    &crc);
      SZCoreItem it;
      it.path   = (path.vt == VT_BSTR) ? ToUtf8(path.bstrVal) : std::string();
      it.name   = (name.vt == VT_BSTR) ? ToUtf8(name.bstrVal) : std::string();
      if (it.name.empty()) {
        size_t slash = it.path.find_last_of('/');
        it.name = (slash == std::string::npos) ? it.path : it.path.substr(slash + 1);
      }
      it.isDir  = (isDir.vt == VT_BOOL && isDir.boolVal != VARIANT_FALSE);
      it.size   = PropU64(size);
      it.attrib = (uint32_t)PropU64(attrib);
      it.mtime  = (mtime.vt == VT_FILETIME) ? FiletimeToUnix(mtime.filetime) : -1;
      it.hasCrc = (crc.vt == VT_UI4);
      it.crc    = (crc.vt == VT_UI4) ? crc.ulVal : 0;
      it.folderIndex = i;
      items.push_back(std::move(it));
    }
    applySort();   // 保持当前排序（导航后亦然）
  }

  unsigned long long arcProp(PROPID propID) {
    if (!folder) return 0;
    CMyComPtr<IGetFolderArcProps> getter;
    folder.QueryInterface(IID_IGetFolderArcProps, &getter);
    if (!getter) return 0;
    CMyComPtr<IFolderArcProps> props;
    if (getter->GetFolderArcProps(&props) != S_OK || !props) return 0;
    UInt32 levels = 0;
    props->GetArcNumLevels(&levels);
    if (levels == 0) return 0;
    NCOM::CPropVariant v;
    props->GetArcProp(0, propID, &v);
    return PropU64(v);
  }
};

SZFolderCore::SZFolderCore() : _p(new Impl) {}
SZFolderCore::~SZFolderCore() { delete _p; }

std::vector<std::string> SZFolderCore::ArchiveExtensions() {
  // 来源 = 格式 handler 表 g_CodecsObj->Formats[*].Exts（非 Windows PE 图标资源表）。
  // CArchiveFolderManager::GetExtensions 走 CCodecIcons 图标表，POSIX 下被 stub 留空（M1-T4），故直接查格式表。
  std::vector<std::string> out;
  if (LoadGlobalCodecs() != S_OK || !g_CodecsObj) return out;
  FOR_VECTOR (i, g_CodecsObj->Formats) {
    const CArcInfoEx &ai = g_CodecsObj->Formats[i];
    FOR_VECTOR (j, ai.Exts)
      if (!ai.Exts[j].Ext.IsEmpty())
        out.push_back(ToUtf8(ai.Exts[j].Ext.Ptr()));
  }
  return out;
}

int SZFolderCore::open(const char *fsPath) {
  CInFileStream *fileSpec = new CInFileStream;
  _p->stream = fileSpec;
  if (!fileSpec->Open(fsPath)) return 1;
  _p->mgr = new CArchiveFolderManager;
  const UString arcPathW = GetUnicodeString(AString(fsPath));
  CMyComPtr<IFolderFolder> root;
  // arcFormat 必须空串 L""（自动嗅探），不可 NULL（M1-T5 报告发现 3）
  const HRESULT hr = _p->mgr->OpenFolderFile(_p->stream, arcPathW.Ptr(), L"", &root, NULL);
  if (hr != S_OK || !root) return (hr == S_FALSE) ? 2 : (int)hr;
  _p->folder = root;
  _p->reload();
  return 0;
}

const std::vector<SZCoreItem> &SZFolderCore::items() const { return _p->items; }
std::string SZFolderCore::currentPath() const { return _p->pathStack.empty() ? std::string() : _p->pathStack.back(); }
bool SZFolderCore::canGoToParent() const { return !_p->parents.empty(); }

bool SZFolderCore::enterFolderAtIndex(size_t index) {
  if (index >= _p->items.size() || !_p->items[index].isDir) return false;
  CMyComPtr<IFolderFolder> sub;
  if (_p->folder->BindToFolder((UInt32)index, &sub) != S_OK || !sub) return false;
  _p->parents.push_back(_p->folder);
  _p->pathStack.push_back(_p->items[index].path);
  _p->folder = sub;
  _p->reload();
  return true;
}

bool SZFolderCore::enterParentFolder() {
  if (_p->parents.empty()) return false;
  _p->folder = _p->parents.back();
  _p->parents.pop_back();
  _p->pathStack.pop_back();
  _p->reload();
  return true;
}

void SZFolderCore::setFlatMode(bool flat) {
  if (!_p->folder) return;
  CMyComPtr<IFolderSetFlatMode> fm;
  _p->folder.QueryInterface(IID_IFolderSetFlatMode, &fm);
  if (fm) { fm->SetFlatMode(flat ? 1 : 0); _p->reload(); }
}

void SZFolderCore::setSort(SZSortKey key, bool ascending) {
  _p->sortKey_ = key;
  _p->ascending_ = ascending;
  _p->applySort();
}
SZSortKey SZFolderCore::sortKey() const { return _p->sortKey_; }
bool SZFolderCore::sortAscending() const { return _p->ascending_; }

uint32_t SZFolderCore::archiveErrorFlags()   { return (uint32_t)_p->arcProp(kpidErrorFlags); }
uint64_t SZFolderCore::archivePhysicalSize() { return _p->arcProp(kpidPhySize); }

// ======================== 写操作（M3-T5 归档内增删改）========================

namespace {
// 最小更新进度回调（COM 堆分配；写操作同步完成，本桥接暂不透传进度/密码）。
class SZUpdateProgress Z7_final:
  public IFolderArchiveUpdateCallback,
  public CMyUnknownImp
{
  Z7_COM_QI_BEGIN2(IFolderArchiveUpdateCallback)
  Z7_COM_QI_END
  Z7_COM_ADDREF_RELEASE
  Z7_IFACE_COM7_IMP(IProgress)
  Z7_IFACE_COM7_IMP(IFolderArchiveUpdateCallback)
};
Z7_COM7F_IMF(SZUpdateProgress::SetTotal(UInt64)) { return S_OK; }
Z7_COM7F_IMF(SZUpdateProgress::SetCompleted(const UInt64 *)) { return S_OK; }
Z7_COM7F_IMF(SZUpdateProgress::CompressOperation(const wchar_t *)) { return S_OK; }
Z7_COM7F_IMF(SZUpdateProgress::DeleteOperation(const wchar_t *)) { return S_OK; }
Z7_COM7F_IMF(SZUpdateProgress::OperationResult(Int32)) { return S_OK; }
Z7_COM7F_IMF(SZUpdateProgress::UpdateErrorMessage(const wchar_t *)) { return S_OK; }
Z7_COM7F_IMF(SZUpdateProgress::SetNumFiles(UInt64)) { return S_OK; }

IFolderOperations *GetOps(IFolderFolder *folder) {
  IFolderOperations *ops = NULL;
  if (folder) folder->QueryInterface(IID_IFolderOperations, (void **)&ops);
  return ops;
}
} // namespace

bool SZFolderCore::canUpdate() {
  CMyComPtr<IFolderOperations> ops = GetOps(_p->folder);
  return ops != NULL;
}

int SZFolderCore::deleteItems(const std::vector<size_t> &coreIndices) {
  CMyComPtr<IFolderOperations> ops = GetOps(_p->folder);
  if (!ops) return -1;
  CRecordVector<UInt32> idx;
  for (size_t i = 0; i < coreIndices.size(); i++) {
    const size_t ci = coreIndices[i];
    if (ci < _p->items.size()) idx.Add(_p->items[ci].folderIndex);
  }
  if (idx.IsEmpty()) return 0;
  CMyComPtr<IProgress> prog = new SZUpdateProgress();
  const HRESULT hr = ops->Delete(&idx[0], idx.Size(), prog);
  if (hr != S_OK) return (int)hr;
  _p->reload();
  return 0;
}

int SZFolderCore::createFolder(const std::string &name) {
  CMyComPtr<IFolderOperations> ops = GetOps(_p->folder);
  if (!ops) return -1;
  CMyComPtr<IProgress> prog = new SZUpdateProgress();
  const HRESULT hr = ops->CreateFolder(ToUString(name).Ptr(), prog);
  if (hr != S_OK) return (int)hr;
  _p->reload();
  return 0;
}

int SZFolderCore::renameItem(size_t coreIndex, const std::string &newName) {
  if (coreIndex >= _p->items.size()) return -1;
  CMyComPtr<IFolderOperations> ops = GetOps(_p->folder);
  if (!ops) return -1;
  CMyComPtr<IProgress> prog = new SZUpdateProgress();
  const HRESULT hr = ops->Rename(_p->items[coreIndex].folderIndex, ToUString(newName).Ptr(), prog);
  if (hr != S_OK) return (int)hr;
  _p->reload();
  return 0;
}

int SZFolderCore::addFile(const std::string &fsPath) {
  CMyComPtr<IFolderOperations> ops = GetOps(_p->folder);
  if (!ops) return -1;
  std::string dir, name;
  const size_t slash = fsPath.find_last_of('/');
  if (slash == std::string::npos) { dir = "."; name = fsPath; }
  else { dir = fsPath.substr(0, slash); name = fsPath.substr(slash + 1); }
  const UString dirU = ToUString(dir);
  const UString nameU = ToUString(name);
  const wchar_t *items[1] = { nameU.Ptr() };
  CMyComPtr<IProgress> prog = new SZUpdateProgress();
  const HRESULT hr = ops->CopyFrom(0, dirU.Ptr(), items, 1, prog);
  if (hr != S_OK) return (int)hr;
  _p->reload();
  return 0;
}
