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

// 自然排序（SZNaturalCompare.cpp，同源移植 PanelSort.cpp:14）
extern int SZNaturalCompareUTF8(const char *a, const char *b);

namespace {

std::string ExtOf(const std::string &name) {
  const size_t p = name.find_last_of('.');
  return (p == std::string::npos) ? std::string() : name.substr(p);
}

// 同类（都目录/都文件）项的列比较：主键相等时二级按 Name（对齐 CompareItems 的 fallback to kpidName）。
int CmpByKey(const SZCoreItem &a, const SZCoreItem &b, SZSortKey key) {
  int r = 0;
  switch (key) {
    case SZSortKey::Name:   return SZNaturalCompareUTF8(a.name.c_str(), b.name.c_str());
    case SZSortKey::Size:   r = (a.size  < b.size)  ? -1 : (a.size  > b.size)  ? 1 : 0; break;
    case SZSortKey::MTime:  r = (a.mtime < b.mtime) ? -1 : (a.mtime > b.mtime) ? 1 : 0; break;
    case SZSortKey::Attrib: r = (a.attrib < b.attrib) ? -1 : (a.attrib > b.attrib) ? 1 : 0; break;
    case SZSortKey::Type:   r = SZNaturalCompareUTF8(ExtOf(a.name).c_str(), ExtOf(b.name).c_str()); break;
    case SZSortKey::None:   return 0;
  }
  if (r != 0) return r;
  return SZNaturalCompareUTF8(a.name.c_str(), b.name.c_str());  // 二级 Name
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
    // 目录恒在文件前（不受升降序影响，PanelSort CompareItems:190）；
    // 同类按 key+方向；主键相等 stable_sort 保持 LoadItems 原序（PanelSort 兜底）。
    std::stable_sort(items.begin(), items.end(),
        [key, asc](const SZCoreItem &a, const SZCoreItem &b) -> bool {
          if (a.isDir != b.isDir) return a.isDir;       // 目录在前
          if (key == SZSortKey::None) return false;
          const int r = CmpByKey(a, b, key);
          if (r == 0) return false;
          return asc ? (r < 0) : (r > 0);
        });
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
