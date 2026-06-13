# 上游源码改动登记（可重放补丁）

> 落实 01-architecture.md D12「上游隔离」：为 macOS 移植对上游 7-Zip 源码（`CPP/`、`C/`、`Asm/`）的每一处改动登记于此，便于官方发新版（如 26.02）整包覆盖后**重放**。
> 原则：改动一律用 `#ifdef _WIN32 … #else … #endif` 包裹，**Windows 分支字节不变**，仅新增非 Windows 分支；能放进 `Mac/` 新文件的绝不改上游。
> 基线：26.01 @ `8c63d71`。

## 索引

| # | 文件 | 处数 | 里程碑 | 性质 |
|---|------|------|--------|------|
| P1 | `CPP/7zip/UI/Agent/Agent.cpp` | 3 | M1-T3 | Windows-only 字段裸访问 → POSIX 等价 |
| P2 | `CPP/7zip/UI/Agent/ArchiveFolderOpen.cpp` | 5 | M1-T3/T4/T5 | 图标资源加载（纯 Win）→ POSIX 空 stub |
| P3 | `CPP/7zip/UI/Agent/AgentOut.cpp` | 4 | M1-T5 | 写路径 Windows-only 字段/类型 → POSIX 等价（vtable 完整性，见下） |
| P4 | `CPP/7zip/UI/Agent/ArchiveFolderOut.cpp` | 2 | M1-T5 | 写路径 CDirEntry/SetFileAttrib → POSIX 等价 |

> 另有零侵入预包含 shim `Mac/compat/win_compat_mac.h`（不改上游，`-include` 注入）：补 `INVALID_FILE_ATTRIBUTES` 宏、`UINT64` 类型别名、`HMODULE` 类型别名（与 `Windows/DLL.h:9` 一致；internal codecs 编译时 LoadCodecs.h 不引 DLL.h 致 `Agent.h:335 CCodecIcons::LoadIcons(HMODULE)` 缺类型，补此即可，external 模式无影响）。

> **移植副本**（非改上游：mac 侧同源复制上游纯函数，因其宿主文件不可单独编译；升版须核对来源）：
>
> | mac 文件 | 上游来源 | 原因 | 升版核对点 |
> |---|---|---|---|
> | `Mac/SevenZipKit/src/SZNaturalCompare.cpp` | `PanelSort.cpp:14` `CompareFileNames_ForFolderList` | 宿主 `PanelSort.cpp` 经 `Panel.h` 拖 `ShlObj.h`，macOS 不可单编 | `PanelSort.cpp:14-51` |
>
> 逐行同源副本，C++ 符号名一致：一份满足 Agent.o(`CAgentFolder::CompareItems`) 链接 + `SZFolderCore` 排序，与 7zFM 自然排序 1:1（M1-T6，替换 M1-T5 的 wcscmp 桩）。

> **为何写路径（P3/P4）在 M1（只读浏览）就需要落实**：`CAgent`/`CAgentFolder` 读写一体（单一类多继承读 `IFolderFolder` + 写 `IFolderOperations` 全部虚方法）。`OpenFolderFile` 内 `new CAgent` 实例化在**链接期**强制要求完整 vtable，即写路径方法符号（`AgentOut.cpp`/`ArchiveFolderOut.cpp` 定义）必须存在。故只读浏览无法"只链接读路径子集"——这是 M1-T3 报告"写路径留 M3"在单文件 `.o` 编译层未暴露、链接成可执行才显现的盲区。M1-T5 已据此把写路径 2 文件的编译补丁前移落实（运行仍只走读路径）。

---

## P1 · Agent.cpp（3 处，M1-T3）

读路径（CAgent::Open / 打开归档读属性）对 `CFileInfo` 的 Windows-only 成员裸访问，POSIX 分支改用跨平台访问器：

| 位置（26.01 行号） | 原 | POSIX 分支 |
|---|---|---|
| ~L1499 | `&& !NName::IsAltStreamPrefixWithColon(path)` | `#ifdef _WIN32` 包裹（mac 无 NTFS 备用数据流，恒非 alt-stream） |
| ~L1623 | `_attrib = fi.Attrib; _isDeviceFile = fi.IsDevice;` | `_attrib = fi.GetWinAttrib(); _isDeviceFile = false;`（FileFind.h:132 从 st_mode 合成） |
| ~L1670 | `arc.MTime.Def = !fi.IsDevice;` | `arc.MTime.Def = true;`（POSIX 普通文件无设备概念） |

重放要点：官方若重构 `CFileInfoBase`，确认 `GetWinAttrib()` 仍存在（FileFind.h `#else` 分支）。

## P2 · ArchiveFolderOpen.cpp（4 处，M1-T3/T4）

`CCodecIcons::LoadIcons` 从 PE 资源（ID=100 的 ext:iconIndex 表）加载图标，纯 Windows（依赖 `g_hInstance`/`MyLoadString`/`ResourceString.h`，POSIX 均无）。POSIX 下整体 stub，图标映射改由 SevenZipKit 用 UTType/Asset Catalog 提供（M1-T4）：

| 位置 | 改动 |
|---|---|
| L9 `#include ResourceString.h` | `#ifdef _WIN32` 包裹 |
| L13 `extern HINSTANCE g_hInstance` + `kIconTypesResId` | `#ifdef _WIN32` 包裹 |
| `LoadIcons` 函数体 | `#ifdef _WIN32` 原逻辑 `#else (void)m;`（IconPairs 留空） |
| L78 `InternalIcons.LoadIcons(g_hInstance)` | `#else InternalIcons.LoadIcons(NULL);` |
| `GetIconPath` 内 `InternalIcons.FindIconIndex`+`MyGetModuleFileName(path)` 块（M1-T5 补） | `#ifdef _WIN32` 包裹 PE 模块图标路径块，`#else (void)ext;`。POSIX 无 `MyGetModuleFileName`（DLL.cpp 该函数 `_WIN32` only，POSIX 用 argv[0] 定位），且 `InternalIcons` 在 POSIX 恒空，本块死代码 |

重放要点：M1-T4 完成 UTType 图标后，此 stub 的 `#else` 分支由真实实现替换（届时更新本条）。

---

## P3 · AgentOut.cpp（4 处，M1-T5 已落实）

写路径（归档更新/新建文件夹）对 `CDirItem`(继承 `CFileInfoBase`) 的 Windows-only 成员/类型裸访问。M1-T5 因 vtable 完整性（见上）已落实：

| 位置（26.01 行号） | 原 | POSIX 分支 |
|---|---|---|
| ~L228 | `if (!NName::IsAltStreamPrefixWithColon(...)) NormalizeDirPathPrefix(...)` | `#ifdef _WIN32` 原逻辑；`#else` 直接 `NormalizeDirPathPrefix`（mac 无 NTFS alt-stream） |
| ~L240 | `item.IsAltStream = true` | `#ifdef _WIN32` 包裹（POSIX `CFileInfoBase` 无 `IsAltStream` 成员，且此分支 mac 不可达） |
| ~L510 | `di.Attrib = FILE_ATTRIBUTE_DIRECTORY` | `di.SetAsDir();`（FileFind.h:107/135 跨平台访问器，Windows 等价 `Attrib=FILE_ATTRIBUTE_DIRECTORY`） |
| ~L521 | `di.CTime = di.ATime = di.MTime = ft`（ft 为 FILETIME；POSIX `CFiTime=timespec` 无 FILETIME 赋值重载） | `#ifdef _WIN32` 直赋；`#else` 全局 `FILETIME_To_timespec(ft, di.CTime); di.ATime = di.MTime = di.CTime;` |

重放要点：`FILETIME_To_timespec` 是**全局函数**（非 `NWindows::NTime` 成员，TimeUtils.h POSIX 分支在 namespace 块之前）。

## P4 · ArchiveFolderOut.cpp（2 处，M1-T5 已落实）

写路径（删除空文件夹及子树）：

| 位置（26.01 行号） | 原 | POSIX 分支 |
|---|---|---|
| ~L46 | `if (fileInfo.IsDir())`（`CDirEntry` POSIX 无无参 `IsDir()`，symlink 的 d_type 需 stat 才定） | `#ifdef _WIN32` 原逻辑；`#else if (enumerator.DirEntry_IsDir(fileInfo, false))`（FileFind.h:311） |
| ~L60 | `if (!SetFileAttrib(path, 0)) return false;`（POSIX 无 `SetFileAttrib`） | `#ifdef _WIN32` 包裹（POSIX 删只读目录权限取决于父目录，无需先清自身属性） |
