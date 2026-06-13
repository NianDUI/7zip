// SZNormalize.h —— Unicode NFC/NFD 规范化桥接（05-platform-layer §5.3 / M1-T8）。
//
// 背景：macOS HFS+/APFS 磁盘文件名多为 NFD（分解形式），归档内名多为 NFC（预组合形式）。
// 同一文件名在两种形式下字节不同，直接比较会失配，影响：更新检测、覆盖判定、wildcard 匹配。
// 全仓库无任何 Unicode 规范化处理，故新增本桥接。纯 C++（CFStringNormalize），不暴露 ObjC。
#pragma once
#include "Common/MyString.h"   // UString

namespace SZNorm {
  /// 入档统一 NFC（写归档时对磁盘名规范化，与 Windows/多数归档一致）。
  UString ToNFC(const UString &s);
  /// 转 NFD（如需与磁盘原始形式对齐时用）。
  UString ToNFD(const UString &s);

  /// 文件名等价比较（双向规范化到 NFC 后比较）：NFD 磁盘名 vs NFC 档内名不失配。
  bool NamesEqual(const UString &a, const UString &b);
  /// 文件名规范化后比较（<0/0/>0），用于排序/查找的稳定比较。
  int  NamesCompare(const UString &a, const UString &b);
}
