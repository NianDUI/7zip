// SZNaturalCompare.cpp —— 文件名自然排序（与 Windows 7zFM 1:1）。
//
// 上游 CompareFileNames_ForFolderList 定义在 PanelSort.cpp:14，但该 .cpp 经 Panel.h 拖入 ShlObj.h，
// 在 macOS 不可单独编译。故此处提供**同源副本**（逐行移植 PanelSort.cpp:14-51），一份两用：
//   1. C++ 符号 CompareFileNames_ForFolderList(const wchar_t*, const wchar_t*)
//      —— 满足 Agent.o(CAgentFolder::CompareItems) 链接（替换 M1-T5 的 wcscmp 桩）。
//   2. SZNaturalCompareUTF8(const char*, const char*)
//      —— 供 SZFolderCore 对 UTF-8 名排序（内部转 UString 调上面），与 7zFM 同算法。
//
// 升版核对点：PanelSort.cpp:14。登记于 docs/upstream-patches.md（移植副本）。

#include "Common/MyString.h"        // MyCharUpper
#include "Common/StringConvert.h"   // MultiByteToUnicodeString / CP_UTF8

int CompareFileNames_ForFolderList(const wchar_t *s1, const wchar_t *s2)
{
  for (;;)
  {
    wchar_t c1 = *s1;
    wchar_t c2 = *s2;
    if ((c1 >= '0' && c1 <= '9') &&
        (c2 >= '0' && c2 <= '9'))
    {
      for (; *s1 == '0'; s1++);
      for (; *s2 == '0'; s2++);
      size_t len1 = 0;
      size_t len2 = 0;
      for (; (s1[len1] >= '0' && s1[len1] <= '9'); len1++);
      for (; (s2[len2] >= '0' && s2[len2] <= '9'); len2++);
      if (len1 < len2) return -1;
      if (len1 > len2) return 1;
      for (; len1 > 0; s1++, s2++, len1--)
      {
        if (*s1 == *s2) continue;
        return (*s1 < *s2) ? -1 : 1;
      }
      c1 = *s1;
      c2 = *s2;
    }
    s1++;
    s2++;
    if (c1 != c2)
    {
      wchar_t u1 = MyCharUpper(c1);
      wchar_t u2 = MyCharUpper(c2);
      if (u1 < u2) return -1;
      if (u1 > u2) return 1;
    }
    if (c1 == 0) return 0;
  }
}

// UTF-8 包装：转 UString（UTF-32）后用上面的自然排序，保证与 7zFM 1:1（含 MyCharUpper 大小写折叠）。
int SZNaturalCompareUTF8(const char *a, const char *b)
{
  const UString ua = MultiByteToUnicodeString(AString(a), CP_UTF8);
  const UString ub = MultiByteToUnicodeString(AString(b), CP_UTF8);
  return CompareFileNames_ForFolderList(ua.Ptr(), ub.Ptr());
}
