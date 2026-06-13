// SZFolderCore.h —— 纯 C++ 桥接核心（不含 ObjC，不暴露任何 7-Zip 头）。
// 存在理由：7-Zip 的 MyWindows.h `typedef int BOOL` 与 ObjC `typedef bool BOOL` 冲突，
// 故把所有 7-Zip C++ 交互隔离到本纯 C++ 层；SZFolderSession.mm 仅在其上做 ObjC 值转换
// （Pimpl 隔离，对齐 01-architecture.md §2.2 桥接边界单一）。仅用标准类型暴露数据。
#pragma once
#include <string>
#include <vector>
#include <cstdint>
#include <cstddef>

struct SZCoreItem {
  std::string path;        // UTF-8 档内相对路径（kpidPath）
  std::string name;        // UTF-8 末级名（kpidName / path 末段）
  bool        isDir  = false;
  uint64_t    size   = 0;
  double      mtime  = -1;  // 距 1970 的秒；<0 表示无（kpidMTime）
  uint32_t    attrib = 0;   // kpidAttrib
  bool        hasCrc = false;
  uint32_t    crc    = 0;
};

/// 排序键（对齐 7zFM 列）。默认方向：Size/MTime 降序、其余升序（PanelSort.cpp:264-272）。
enum class SZSortKey { None, Name, Size, MTime, Type, Attrib };

class SZFolderCore {
public:
  SZFolderCore();
  ~SZFolderCore();
  SZFolderCore(const SZFolderCore &) = delete;
  SZFolderCore &operator=(const SZFolderCore &) = delete;

  /// 打开归档并绑定根。返回 0 成功；1=无法打开文件；2=非归档(S_FALSE)；否则原始 HRESULT(<0)。
  int open(const char *fsPath);

  const std::vector<SZCoreItem> &items() const;
  std::string currentPath() const;
  bool canGoToParent() const;

  bool enterFolderAtIndex(size_t index);   // BindToFolder
  bool enterParentFolder();                // BindToParentFolder
  void setFlatMode(bool flat);             // IFolderSetFlatMode

  /// 排序当前层 items（目录恒在文件前、不分升降序；同类按 key+方向，主键相等二级按 Name；
  /// 对齐 PanelSort.cpp CompareItems）。导航后保持当前排序。
  void setSort(SZSortKey key, bool ascending);
  SZSortKey sortKey() const;
  bool sortAscending() const;

  uint32_t archiveErrorFlags();            // kpidErrorFlags（第 0 层）
  uint64_t archivePhysicalSize();          // kpidPhySize

private:
  struct Impl;
  Impl *_p;
};
