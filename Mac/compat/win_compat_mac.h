// win_compat_mac.h —— UI/Agent 等上层代码在 POSIX(macOS) 编译所需的 Win32 宏/类型补充。
// 用法：clang++ -include <此文件>（预包含）。仅补「纯宏/类型别名」这类零侵入项；
// 成员访问类的移植（CFileInfo.Attrib→GetWinAttrib() 等）见 docs/M1-T3-agent-gate-report.md。
#pragma once
#ifndef _WIN32

#include "Common/MyWindows.h"   // DWORD / UInt64 等基础类型（已含 POSIX 定义）

// Windows 文件属性「无效值」哨兵。Agent.h:253 Is_Attrib_ReadOnly 用其判定属性是否已取。
#ifndef INVALID_FILE_ATTRIBUTES
#define INVALID_FILE_ATTRIBUTES ((DWORD)0xFFFFFFFF)
#endif

// 个别上层代码用了 Windows 拼写 UINT64（UpdateCallbackAgent.cpp）。7-Zip 自有类型为 UInt64。
typedef UInt64 UINT64;

#endif // !_WIN32
