# M1-T3 闸门报告：Agent 层 POSIX 可编译性（B 计划闸门）

> 目标：验证 7-Zip 的 Agent 层（把 `IInArchive` 适配成可导航 `IFolderFolder` 的数据模型层）能否在 macOS/clang 下编译复用。**这是方案 B 的最大技术不确定性**——若不可行，需触发 R-AGENT B 计划（桥接层改 `IInArchive` 直驱 + 自建目录树，+10 人日）。
> 结论：**可移植，不触发 B 计划。方案 B 架构维持不变。**

## 方法

单独用 mac arm64 clang 标志编译 Agent 7 个 `.cpp`（`-include Mac/compat/win_compat_mac.h`），逐错定位、查源码确认 POSIX 语义、打最小 `#ifdef _WIN32` 补丁，迭代至读路径全绿。

## 关键发现

1. **`AgentProxy.cpp`（最核心的代理树逻辑）零改动直接编译通过**，`ArchiveFolder.cpp`（IFolderFolder 读导航）也仅靠 shim 即通过——Agent 层的导航核心本就 POSIX-clean。
2. 全部障碍是**有限的 Windows-only 边角依赖**，两类：
   - **A 类·宏/类型**（INVALID_FILE_ATTRIBUTES、UINT64）→ 零侵入 shim 头解决，不改上游。
   - **B 类·Windows-only 成员裸访问**（CFileInfo.Attrib/IsDevice、CDirItem.IsAltStream、NTFS alt-stream、PE 图标资源）→ 上游已用 `#ifdef _WIN32` 正确排除这些成员，仅 Agent 代码未加保护（因从未在 POSIX 编过）。逐处加 `#ifdef` + POSIX 等价即可。
3. **读/写路径可分离**（决定 M1 范围）：M1 只读浏览只需读路径，写路径留 M3。
   > ⚠ **M1-T5 修正**：此结论仅在"单文件 `.o` 编译"层成立。链接成可执行时，`CAgent`/`CAgentFolder` 读写一体的 vtable 强制要求写路径符号存在（`new CAgent` 实例化），故 `AgentOut.cpp`/`ArchiveFolderOut.cpp` 的编译补丁已在 **M1-T5 前移落实**（非 M3），运行仍只走读路径。详见 `docs/M1-T5-agent-browse-report.md` 发现 1 与 `upstream-patches.md` P3/P4。

| 文件 | 路径 | M1 状态 |
|---|---|---|
| Agent.cpp | 读（Open+属性） | ✅ 改 3 处后通过 |
| AgentProxy.cpp | 读（代理树） | ✅ 零改动通过 |
| ArchiveFolder.cpp | 读（导航） | ✅ shim 后通过 |
| ArchiveFolderOpen.cpp | 读（OpenFolderFile 入口） | ✅ 图标 stub 后通过 |
| UpdateCallbackAgent.cpp | 回调 | ✅ shim 后通过 |
| AgentOut.cpp | 写（更新） | ✅ M1-T5 已落实（4 处，vtable 完整性前移；见 P3） |
| ArchiveFolderOut.cpp | 写（删除/属性） | ✅ M1-T5 已落实（2 处；见 P4） |

## 验收

- **AC（编译）**：M1 读路径 5 文件全部编译出 `.o`（实测，见 `Mac/poc/verify_agent.sh`）。✅
- **AC（链接/运行 `OpenFolderFile` 返回 IFolderFolder）**：延后到 M1-T5——届时 SevenZipKit 的 `SZFolderSession` 会真实调用 `CArchiveFolderManager::OpenFolderFile`，在那里做端到端验收（打开 .7z → 绑定根目录 → 枚举条目）。

## 改动

- 上游补丁登记：`docs/upstream-patches.md`（Agent.cpp 3 处 + ArchiveFolderOpen.cpp 4 处，均 `#ifdef _WIN32` 隔离，Windows 行为不变）。
- 新增 shim：`Mac/compat/win_compat_mac.h`（零侵入预包含）。
- 复现脚本：`Mac/poc/verify_agent.sh`。

## 对方案的影响

- **架构不变**：继续 lib7z.dylib + SevenZipKit(含 Agent) + AppKit 三层。
- **工作量确认**：Agent 移植 = 有限补丁（远小于 B 计划重写），文档 M1-T3 估 4 人日合理甚至偏宽。
- **解除阻塞**：M1-T5（SevenZipKit 浏览 API）可基于已编译通过的 Agent 读路径推进。
