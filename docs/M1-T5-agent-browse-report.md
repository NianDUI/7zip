# M1-T5 报告：Agent 导航端到端（链接+运行）

> 目标：把 `docs/M1-T3-agent-gate-report.md` 延后到 M1-T5 的端到端验收落地——验证 Agent 层"归档→文件夹"导航链（`CArchiveFolderManager::OpenFolderFile → CAgent::Open → CProxyArc::Load → CAgentFolder/IFolderFolder → 枚举/下钻/上溯/归档属性`）在 macOS arm64 **可链接、可运行**。这是 `02-core-bridge.md §4.6 SZFolderSession` 的底层路径。
> 结论：**通过。Agent 导航在 macOS 端到端可运行，方案 B 桥接层 SZFolderSession 路径打通。**
> 基线：26.01 @ main。复现：`Mac/poc/build_agent_browse.sh`（一键，缺测试归档自动用 7zz 现造）。

## 方法

把 Agent 全 7 文件（读 5 + 写 2）+ 端到端测试 `Mac/poc/agent_browse.cpp` 编译，链接进 **7zz/Alone2 的 326 个 `.o` 对象集**（内置全格式 handler + UI/Common + Common/Windows 工具，排除 console-only 11 个），产出可执行测试。`agent_browse` 打开磁盘 `.7z`（含子目录 + 中文名），逐层导航并打印属性。

**codecs 模式取舍**：本测试用 **internal codecs**（复用 Alone2 静态全格式，`CCodecs::Load` 走 `g_Arcs` 静态注册表）。理由：Agent 导航逻辑（`OpenFolderFile → IFolderFolder → BindToFolder`）与 codec 来源（internal/external）**正交**——`CCodecs` 抽象了二者。external + `dlopen lib7z.dylib` 的 codec 加载链已由 M0 段 B（`poc_bridge`）独立验证。两条线互补：M0 证 dylib 加载链，M1-T5 证 Agent 导航链。正式 SevenZipKit 走 external，Agent 导航代码与本测试**逐字节相同**。

## 验收证据（实测输出）

```
[1] OpenFolderFile hr=0x00000000  root=非空
[2] 根枚举：src <DIR> attrib=0x41ed8010（040755 UNIX mode + 0x10 DIRECTORY）
[3] BindToFolder(src) → 3 项：sub<DIR> / top.txt / 中文.txt（UTF-8 正确）
[4] 二级下钻 BindToFolder(sub) → 2 项：sub/deep<DIR> / sub/inner.txt
[5] BindToParentFolder 回到上级：项数一致
[6] IGetFolderArcProps→GetArcProp：levels=1 phySize=4395 errorFlags=0x0 warningFlags=0x0
```

覆盖 M1-T5 全部 AC：打开归档、枚举条目、读 `kpidPath/Size/MTime/IsDir/Attrib`、绑定子目录（多层）、上溯父目录、读归档级属性（含错误旗标）。`attrib` 高 16 位 UNIX mode 正确合成（`FILE_ATTRIBUTE_UNIX_EXTENSION`），中文文件名 UTF-8 往返无损。

## 三个重要发现

### 1. vtable 完整性 → 只读浏览也必须链接写路径（修正 M1-T3 盲区）

`CAgent`/`CAgentFolder` **读写一体**：单一类多继承读接口（`IFolderFolder`）+ 写接口（`IFolderOperations`：`Delete/Rename/CreateFolder/CopyFrom...`）。`OpenFolderFile` 内 `new CAgent` 实例化在**链接期**强制要求完整 vtable，即写路径方法符号（`AgentOut.cpp`/`ArchiveFolderOut.cpp` 定义）必须存在。

→ **只读浏览无法"只链接读路径子集"**。M1-T3 报告"写路径留 M3"是**单文件 `.o` 编译层未暴露、链接成可执行才显现的盲区**。M1-T5 已据此把写路径 2 文件的编译补丁前移落实（登记 `upstream-patches.md` P3/P4），运行仍只走读路径。

### 2. Agent 读路径链接闭环触及 M1-T1 / M1-T6 边界

除 Agent 7 文件，端到端链接还揭示 Agent 依赖的非 console-Alone2 符号：

| 缺失符号 | 来源 | 处置 | 正式接管 |
|---|---|---|---|
| `NWindows::NDLL::MyGetModuleFileName` | DLL.cpp（POSIX 下 `_WIN32` only） | `ArchiveFolderOpen::GetIconPath` 的 PE 图标块 `#ifdef _WIN32` 包掉（P2 第 5 处） | M1-T4（UTType 图标） |
| `CWorkDirTempFile`（DLL.cpp/WorkDir.cpp） | 补编 `Windows/DLL.cpp` + `UI/Common/WorkDir.cpp` | 真编译进闭环 | — |
| `NWorkDir::CInfo::Load/Save` | ZipRegistry.cpp（Windows 注册表） | 链接桩 `Load(){SetDefault();}`（POSIX 默认工作目录，写路径不运行） | **M1-T1**（ZipRegistry_mac NSUserDefaults） |
| `CompareFileNames_ForFolderList` | PanelSort.cpp（拖 `ShlObj.h`，不可单独编） | 链接桩 `wcscmp`（M1-T5 不触发 `CompareItems` 排序，行为不影响） | **M1-T6**（PanelModel 从上游提取共享） |

→ **M1-T1（plist 后端）优先级坐实**：它不只是"设置持久化"，更是 Agent 链接闭环的一部分（`WorkDir → NWorkDir::CInfo`）。链接桩见 `Mac/poc/m1t5_link_stubs.cpp`（归属标注清晰）。

### 3. arcFormat 不可传 NULL（API 契约）

`OpenFolderFile` 的 `arcFormat` 透传 `CAgent::Open → ParseOpenTypes`，后者隐式 `UString(arcFormat)`；NULL → `UString(NULL)` 崩溃。**须传空串 `L""`（=自动嗅探所有格式），Windows FM 亦如此**。已写入 `agent_browse.cpp` 注释，桥接层 `SZFolderSession` 封装时须保证非 NULL。

## 对方案的影响

- **架构不变**：lib7z.dylib + SevenZipKit(含 Agent) + AppKit 三层维持。SZFolderSession（`02 §4.6`）底层导航路径已实证可行，其 ObjC 封装可在此之上推进。
- **M1-T3 报告修正**：写路径 2 文件因 vtable 完整性已在 M1（非 M3）落实编译补丁。
- **依赖排序确认**：M1-T1（plist 后端）是 Agent 链接闭环一部分，应优先；M1-T6（PanelModel）接管 `CompareFileNames_ForFolderList` 共享；M1-T4 接管图标。

## 产物

- 上游补丁：`upstream-patches.md` P2 第 5 处 + P3(AgentOut 4) + P4(ArchiveFolderOut 2)，均 `#ifdef _WIN32` 隔离，Windows 行为不变；shim 增 `HMODULE`。
- 新增：`Mac/poc/agent_browse.cpp`（端到端测试，唯一 INITGUID 单元）、`Mac/poc/m1t5_link_stubs.cpp`（链接桩，归属 M1-T1/M1-T6）、`Mac/poc/build_agent_browse.sh`（一键复现）。
