# 上游源码改动登记（可重放补丁）

> 落实 01-architecture.md D12「上游隔离」：为 macOS 移植对上游 7-Zip 源码（`CPP/`、`C/`、`Asm/`）的每一处改动登记于此，便于官方发新版（如 26.02）整包覆盖后**重放**。
> 原则：改动一律用 `#ifdef _WIN32 … #else … #endif` 包裹，**Windows 分支字节不变**，仅新增非 Windows 分支；能放进 `Mac/` 新文件的绝不改上游。
> 基线：26.01 @ `8c63d71`。

## 索引

| # | 文件 | 处数 | 里程碑 | 性质 |
|---|------|------|--------|------|
| P1 | `CPP/7zip/UI/Agent/Agent.cpp` | 3 | M1-T3 | Windows-only 字段裸访问 → POSIX 等价 |
| P2 | `CPP/7zip/UI/Agent/ArchiveFolderOpen.cpp` | 4 | M1-T3/T4 | 图标资源加载（纯 Win）→ POSIX 空 stub |

> 另有零侵入预包含 shim `Mac/compat/win_compat_mac.h`（不改上游，`-include` 注入）：补 `INVALID_FILE_ATTRIBUTES` 宏、`UINT64` 类型别名。

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

重放要点：M1-T4 完成 UTType 图标后，此 stub 的 `#else` 分支由真实实现替换（届时更新本条）。

---

## 待登记（M3 写路径，已查明修法，尚未改）

`AgentOut.cpp`、`ArchiveFolderOut.cpp` 是归档更新（写）路径，M1 只读不编译它们。M3 实施时按下表改并登记：

| 文件:行 | 错误 | 修法 |
|---|---|---|
| AgentOut.cpp:228 | `IsAltStreamPrefixWithColon` | `#ifdef _WIN32` 包条件，POSIX 恒 normalize |
| AgentOut.cpp:240 | `item.IsAltStream = true` | `#ifdef _WIN32` 包裹 |
| AgentOut.cpp:510 | `di.Attrib = FILE_ATTRIBUTE_DIRECTORY` | `di.SetAsDir();`（FileFind.h:135 跨平台） |
| AgentOut.cpp:521 | `di.CTime=di.ATime=di.MTime=ft`（FILETIME→CFiTime 无重载） | `#ifdef _WIN32` 直赋；POSIX 用 FILETIME→CFiTime 转换 |
| ArchiveFolderOut.cpp:46 | `CDirEntry::IsDir()` 不存在 | `enumerator.DirEntry_IsDir(fileInfo, false)`（FileFind.h:311） |
| ArchiveFolderOut.cpp:60 | `SetFileAttrib` 未声明 | `#ifdef _WIN32` 包裹（POSIX 删 readonly 目录无需先清属性） |
