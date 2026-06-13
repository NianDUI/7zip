# M2-T1 报告：解压回调链桥接（核心）

> 目标：把 7-Zip 解压本体（`Common/Extract.cpp` 的 `Extract()`，与 7zz `x`/`t` 命令同一函数）桥接到 macOS，并以纯 C++ 抽象 `SZExtractDelegate` 替代 Windows GUI 的 `CExtractCallbackImp + CProgressDialog`，把进度/覆盖询问/密码/内存/错误/结果等回调事件上抛。这是 `05-roadmap-execution.md §3 M2-T1` 的核心，也是整个 M2 解压链的地基。
> 结论：**通过。解压核心在 macOS arm64 可链接、可运行，普通 .7z / .zip / 加密 .7z 解压结果与 7zz CLI 字节级一致。**
> 基线：26.01 @ main。复现：`Mac/SevenZipKit/build_test_extract.sh`（一键，自造普通/加密/zip/损坏样本并与 7zz 对照）。

## 方法

延续 M1 的 Pimpl 三层与 internal-codecs 链接策略（复用 Alone2 的 326 对象集，排除 console-only 11 个；`SZFolderCore.cpp` 仍是唯一 INITGUID 单元）：

| 层 | 文件 | 含 7-Zip 头 | 职责 |
|---|---|---|---|
| 公开纯 C++ 头 | `Mac/SevenZipKit/src/SZExtractCore.h` | 否 | `SZExtractRequest/Result`、`SZExtractDelegate` 抽象、枚举（路径/覆盖模式、覆盖答案）——只用 `std::string/uint64_t/bool` |
| 纯 C++ 核心 | `Mac/SevenZipKit/src/SZExtractCore.cpp` | 是 | `SZExtractCallback`（实现回调接口集）+ `SZExtractCore::run`（组装 `CExtractOptions`/censor 调 `Extract()`） |
| 命令行 driver | `Mac/SevenZipKit/tests/test_extract.cpp` | 否（仅公开头） | 解压到目录 + 打印逐文件事件，供脚本字节对照 |

**回调接口集**（对齐 console `CExtractCallbackConsole`，去控制台 IO，mac 全开 crypto）：
`IProgress` / `IFolderArchiveExtractCallback` / `IExtractCallbackUI`(非COM) / `IOpenCallbackUI`(非COM) / `IFolderArchiveExtractCallback2` / `ICryptoGetTextPassword` / `IArchiveRequestMemoryUseCallback`。
错误文案映射（`SetExtractErrorMessage`：CRC/DataError/UnsupportedMethod/UnexpectedEnd/WrongPassword…）1:1 移植 console 英文常量。

## 验收证据（实测）

```
A) 普通 .7z   SZExtractCore vs 7zz → diff -r 字节级一致；结果 文件=4 目录=3 解压字节=65559 错误=0
B) .zip       SZExtractCore vs 7zz → 字节级一致
C) 加密 .7z   预设密码 pass123 → 解压字节级一致（CryptoGetTextPassword 闭环）
D) 测试模式   testMode 不落盘，逐项 T 标记，无错误
E) 损坏档     截断 200B → OpenResult result=S_FALSE，打开错误=1，非零退出（isOK=false）
```

覆盖 M2-T1 AC：解压单/多条目到目标目录、进度回调不崩、E_ABORT=取消（`isCancelled()` 轮询）；并顺带覆盖 M2-T5 的测试模式与归档级错误聚合基础。中文文件名 UTF-8 往返无损、子目录层级正确还原。

## 三个关键工程点

### 1. COM 回调对象必须堆分配（栈分配 → abort）

`SZExtractCallback` 多继承自 `CMyUnknownImp`，`Release()` 在引用计数归零时 `delete this`。`Extract()` 内部对回调 `AddRef/Release`，若回调是**栈对象**，归零时 `delete` 栈地址 → `Abort trap: 6`。解法同 console（`ecs = new ...`）：`new SZExtractCallback` + `CMyComPtr<IFolderArchiveExtractCallback> keeper` 持一引用，函数末自动 `Release`。这是把 COM 对象传给会持有引用的引擎入口时的硬约束。

### 2. 全选 censor 构造范式

`Extract()` 用 `NWildcard::CCensorNode` 过滤条目。解压整档 = `censor.AddPreItem_Wildcard()`（加 `"*"`）；解压选中项 = 逐条 `AddPreItem_NoWildcard(path)`；统一 `AddPathsToCensor(NWildcard::k_RelatPath)` 后取 `censor.Pairs.Front().Head`（蓝本 `CompressCall2.cpp:200-203`）。`selectedPaths` 已留好接口，供 M2-T6 面板选中项拖出 / M2-T3 对话框选择性解压复用。

### 3. 归档级错误独立计入（修正 isOK 语义）

文件级错误（CRC/DataError，`SetOperationResult`）与归档级打开失败（`OpenResult result≠S_OK`）是两类：损坏档**打开失败**时 `Extract()` 整体仍返回 `S_OK`、文件错误为 0，若只看这两者会把"无法打开"误判为成功。故 `SZExtractResult` 增 `numOpenErrors`，`isOK()` 三者皆为 0 才真。这是 M2-T5「多档案编排错误聚合」的基础口径。

## 边界与后续

- **ObjC 外观 `SZExtractor.mm` 暂未做**：进度回调 hop 主队列、阻塞式询问（覆盖/密码/内存）的 `dispatch_semaphore` 桥接与 ObjC 外观设计强耦合，统一放 **M2-T2/T4** 落地，避免先做外观再为阻塞语义返工。当前 `SZExtractDelegate` 默认实现已给无 GUI 安全缺省（覆盖=Yes、无密码、不取消），命令行与策略对象（M2-T2）可直接用。
- **无上游改动**：M2-T1 全部为 `Mac/` 下新增文件，未触碰 `CPP/`，`upstream-patches.md` 无需追加。
- **Agent 路径解压**（面板选中项经 `CAgentFolder::Extract`）与本 `Common/Extract.cpp` 路径并存，复用同一 `SZExtractCallback`；接 GUI 面板时（M2-T3/T6）落地。

## 产物

- 新增：`Mac/SevenZipKit/src/SZExtractCore.{h,cpp}`、`Mac/SevenZipKit/tests/test_extract.cpp`、`Mac/SevenZipKit/build_test_extract.sh`（一键复现）。
