# 01 总体架构

> 7-Zip 26.01 Windows GUI 一对一移植 macOS · 方案B（核心 dylib + ObjC++ 桥接 + AppKit）
> 本文是【可执行方案】首篇，给出整体架构、进程模型、仓库布局、数据流/线程/错误模型、构建体系与上游同步策略，落到具体文件、命令与接口签名。
> 三层、接口签名细节、对话框/Finder 等价实现、路线图分别见 `02-core-bridge.md`、`03-feature-map-filemanager.md`、`04-feature-map-dialogs-finder.md`、`05-roadmap-execution.md`。
> 引用源码一律 `路径:行号`（相对仓库根 `/Users/lyd/WorkSpace/MyProjects/7zip`）。已验证事实参见五份研究底料 `docs/research/01..05`。

---

## 1. 目标与范围

### 1.1 一对一移植的精确定义

"一对一"指 macOS 版在功能与交互上等价复刻 Windows 7-Zip 的三个 GUI 程序（7zFM / 7zG / Explorer 集成），而非命令行 `7zz`（CLI 已用 Alone2 编译验证，作为引擎自测工具，不在 GUI 范围）。精确边界按研究底料的功能清单逐项对齐：

| 覆盖面 | 数量（底料实测） | 必须 1:1 | 证据 |
|---|---|---|---|
| 7zFM 菜单命令（File/Edit/View/Favorites/Tools/Help） | 6 顶层菜单、约 70 条命令项 + 隐藏命令 | 是 | `01-filemanager-inventory.md` §1.1（resource.rc:33-161） |
| 7zFM 面板级键盘命令 | 全键表（PanelKey.cpp:39-357） | 是 | 同上 §1.2 |
| 7zFM 对话框 | 16 类（About/Browse/Browse2/Combo/Copy/Edit/ListView/Mem/Messages/Overwrite/Password/Progress/Progress2/Split/Link + 6 选项页） | 是（Link 的 Junction/WSL 除外，见 §1.2 不做项） | 同上 §2、§3 |
| 7zFM 选项页 | 6 页（System/Menu/Folders/Editor/Settings/Language） | 是（System/Menu 改 macOS 等价机制） | 同上 §3 |
| 7zFM 面板能力 | 列模型/排序/选择/双面板/地址栏/历史/收藏/状态栏/自动刷新/7 类文件夹实现 | 是 | 同上 §4 |
| 7zG 对话框与操作层 | 压缩 CCompressDialog（+二级 Options）、解压 CExtractDialog、进度 Progress2、覆盖、密码、Hash 结果、内存确认、Benchmark | 是 | `02-gui-dialogs-inventory.md` §2-§8 |
| Explorer 右键命令集 | 主命令 11 项 + Hash 子菜单 13 项 + Open-with 子菜单 | 是（宿主壳换 Finder 扩展/App 内菜单） | `03-explorer-agent.md` §1.2-§1.3 |
| 设置项总量 | 约 60 标量/数组键 + 3 个二进制 blob（Columns/Position/Panels） | 是（迁 UserDefaults/plist） | `05-platform-layer.md` §4 |

引擎能力（全部格式 handler、Rar 解码、AES、汇编优化、哈希）已随 `7zz` 在本机 macOS arm64 验证，并已实测把全格式 bundle（Bundles/Format7zF）零改动编译为 Mach-O dylib，dlopen 端到端压缩/列表/解压 roundtrip 通过（`04-core-dylib.md` §0、§8）。因此移植工作量集中在 UI 层与平台桥接，不触碰引擎算法。

### 1.2 明确不做项（及理由）

| 不做项 | 理由 | 证据 |
|---|---|---|
| Far 插件（UI/Far） | 上游为 Far Manager（Windows 文件管理器）插件，macOS 无宿主；Agent 接口的第二消费者，仅佐证接口稳定性 | `03-explorer-agent.md` §0.2、§2.8 |
| NTFS 备用数据流（ADS）浏览与压缩（AltStreamsFolder、`IDM_ALT_STREAMS`、压缩对话框 AltStreams 复选） | 宿主 FS 枚举/写 ADS 仅 Windows；macOS xattr 语义不同，核心捕获/恢复整体 `#if defined(_WIN32)` | `05-platform-layer.md` §5#7；`01-filemanager-inventory.md` §10 |
| NT 安全描述符（NtSecurity）捕获/恢复、解压"还原安全描述符"复选 | `Z7_USE_SECURITY_CODE` 全程 `#if defined(_WIN32)`，macOS 无对应物 | `05-platform-layer.md` §2.2、§5#7 |
| 网络邻居 NetFolder、`\\.\` 设备卷、`\\?\` 超级路径视图 | WNet/NT 路径语义专属 Windows | `01-filemanager-inventory.md` §4.7、§10 |
| Large memory pages 设置（-slp） | Windows 特权 API；macOS 编译期即 stub，设置页隐藏 | `05-platform-layer.md` §2.2 |
| Link 对话框的 Junction / WSL 链接类型 | macOS 仅 hardlink/symlink（保留这两种） | `01-filemanager-inventory.md` §10 |
| 文件关联与右键集成的"注册表式实现" | 改为 macOS 等价机制（Info.plist `CFBundleDocumentTypes` + LaunchServices + Finder 扩展），功能保留、实现替换 | `05-platform-layer.md` §4.1-G |
| .chm 帮助 | HtmlHelp 专属；改在线/本地网页帮助 | `01-filemanager-inventory.md` §10 |
| 回收站语义直译 | `SHFileOperation` → `NSWorkspace recycleURLs`，功能保留 | `01-filemanager-inventory.md` §10 |

不做项中 ADS/NtSecurity/Net/LargePages/Junction 属"Windows 专属、无等价语义"；文件关联/右键/帮助/回收站属"功能保留、实现重写"。两类在功能清单上均有明确标注，UI 上对无意义复选框做隐藏处理。

---

## 2. 三层架构详图

### 2.1 ASCII 总图

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  SevenZipFM.app  (AppKit 原生应用，可执行文件，Swift + ObjC++ 少量)            │
│  ──────────────────────────────────────────────────────────────────────────  │
│  · NSApplicationMain / AppDelegate（替代 FM.cpp WinMain）                       │
│  · 主窗口：NSSplitView 双面板 + NSToolbar + 地址栏 + 状态栏                     │
│  · 面板：NSTableView/NSOutlineView（替代 SysListView32）                        │
│  · 对话框：NSWindowController / sheet（压缩/解压/进度/覆盖/密码/选项 6 页…）    │
│  · 设置：NSUserDefaults（com.7zip.SevenZipFM）                                 │
│  · Finder 集成：FinderSync App Extension（独立 target，共享 App Group defaults）│
│           │ 仅依赖 SevenZipKit 的 ObjC/Swift API；不直接 #include 任何 7-Zip C++ │
│           ▼                                                                      │
├──────────────────────────────────────────────────────────────────────────────┤
│  SevenZipKit.framework  (Objective-C++ 桥接层，.mm)                            │
│  ──────────────────────────────────────────────────────────────────────────  │
│  · 对 Swift 暴露纯 ObjC API：SZArchive / SZItem / SZTask / SZProgress / 错误域  │
│  · 内部持有 C++：CMyComPtr<IInArchive/IOutArchive>、CCodecs、CAgent/CAgentFolder│
│  · 回调对象（Open/Extract/Update）实现 COM 接口（Z7_IFACES_IMP_UNK_*）          │
│  · 串行 dispatch queue 串行化引擎调用；进度回调 hop 到 main queue                │
│  · NSString↔UString(UTF-8 中转)、NSDate↔FILETIME(1601 纪元)、HRESULT→NSError    │
│  · 复用上游 UI/Common + UI/Agent 纯逻辑（编入本 framework，见 §4.3）            │
│           │ 经 C ABI 工厂调用核心；接口指针在桥接层与引擎间传递（同一运行时）    │
│           ▼                                                                      │
├──────────────────────────────────────────────────────────────────────────────┤
│  lib7z.dylib  (核心动态库 = Bundles/Format7zF，全格式 handler + codec + 加密)   │
│  ──────────────────────────────────────────────────────────────────────────  │
│  · C ABI 工厂：CreateObject / GetNumberOfFormats / GetHandlerProperty2 …（19）  │
│  · 内部 COM 风格 IInArchive/IOutArchive/ICompressCoder…（由 MyWindows.h 模拟）  │
│  · 自包含：仅依赖 libSystem + libc++（otool -L 实测）                           │
│  · 由上游 makefile 零改动产出 Mach-O dylib（make -f cmpl_mac_arm64.mak）        │
└──────────────────────────────────────────────────────────────────────────────┘
```

### 2.2 各层职责边界

**lib7z.dylib（核心层）**——上游 `CPP/7zip/Bundles/Format7zF` 原样产物（Windows 上即 `7z.dll`）。
- 职责：提供全部格式 handler、编解码器、AES 加密、哈希器，经 19 个 `extern "C"` 工厂导出（`04-core-dylib.md` §1.1）。
- 边界：不含任何 UI、不含设置存储、不调用平台 GUI API；不读注册表（`#ifdef _WIN32` 分支天然不进，§2.7 of `03`）。
- 稳定性约束：与桥接层**必须同一 clang / 同一 C++ 运行时 / 同一 IUnknown 虚析构设置**编译，否则 `LoadCodecs::IsSupportedDll` 的 ABI 闸门会拒载（`04-core-dylib.md` §2.2、§4.1，LoadCodecs.cpp:521-562）。

**SevenZipKit.framework（桥接层）**——新写 ObjC++（`.mm`），是本项目工程量集中点之一。
- 职责：把 COM 风格 C++ 引擎封装为 Swift 友好的 ObjC API；承载线程模型（串行队列 + 主线程派发）、错误转换（HRESULT→NSError）、取消语义、字符串/时间编码转换。
- 复用：把上游 **UI/Common**（OpenArchive/Extract/Update/LoadCodecs/ArchiveExtractCallback/UpdateCallback/HashCalc 等，已随 7zz 验证）与 **UI/Agent**（归档文件夹化）整包编入本 framework，作为"业务逻辑底座"；ObjC++ 层只在其上做薄包装与回调桥接。
- 边界：不含 AppKit 视图代码（不 `import AppKit` 做控件）；进度/错误/询问以回调 block 或 delegate 形式上抛，由 App 层决定 UI 呈现。

**SevenZipFM.app（应用层）**——AppKit 为主，表单型界面可嵌 SwiftUI。
- 职责：全部窗口/视图/菜单/快捷键/拖放/设置 UI；进程入口（`NSApplicationMain`）；Finder 扩展 target。
- 边界：只调用 SevenZipKit 的 ObjC/Swift API，**不直接 include 7-Zip C++ 头**（防止 COM/wchar_t 语义污染 Swift 侧，也保证桥接边界单一）。

### 2.3 Agent 层归属：桥接层（SevenZipKit）

Agent（`UI/Agent`，12 文件/约 5.1k 行）把 `IInArchive` 适配成"归档文件夹"`IFolderFolder`，提供导航/属性/增删改的统一事务流程（`03-explorer-agent.md` §2）。归属决策与理由：

- **归入桥接层 SevenZipKit，而非核心 dylib。** 理由：
  1. Agent 是面板（FileManager）的数据模型适配层，本质是 UI 侧逻辑而非引擎；Windows 上 Agent 静态链入 `7zFM.exe`，**不进 7z.dll**（`03-explorer-agent.md` §0.2，FM.mak:94-101）。把 Agent 放进 dylib 会越过其本职边界。
  2. Agent 7 个 `.cpp` 已确认在 POSIX 下可编译复用，"仅 1.5 处需动手"（删一处只服务注释代码的 `RegistryUtils.h` include；ArchiveFolderOpen.cpp 的图标/扩展表机制重写）（`03-explorer-agent.md` §3.1）。
  3. Agent 多继承 14 个 COM 接口（Agent.h:51-66）、内部 `throw int`（AgentProxy.cpp:184）——这些指针/异常**必须留在桥接层一侧的同一运行时内**，不跨 dylib 的 C ABI 边界传递（dylib 边界仅走 C 工厂 `CreateObject`）（`03-explorer-agent.md` §5#6）。
- **结论**：dylib 边界 = C 风格 `CreateObject` 工厂；Agent + UI/Common + ObjC++ 包装同属 SevenZipKit，编进同一 framework 二进制，彼此用 C++ 接口指针直连。

---

## 3. 进程模型

### 3.1 Windows 现状

Windows 上 7zFM 与 7zG 是两个独立进程：7zFM（文件管理器）通过 `Call7zGui` 用 `CreateProcess` 启动 **`7zG.exe`** 子进程执行压缩/解压/测试/基准（`05-platform-layer.md` §6，CompressCall.cpp:33,73-96）。文件清单不走命令行参数，而是写入**命名共享内存** `7zMap<rand>` + **命名事件** `7zEvent<rand>`，参数形如 `-i#7zMapNNN:size:7zEventNNN`，内容为 UTF-16/wchar NUL 分隔串（CompressCall.cpp:136,148-182）。Explorer 右键同样走"7zG 子进程 + FileMapping IPC"（`03-explorer-agent.md` §1.4）。

关键约束：该 IPC 协议（`ParseMapWithPaths`、`CFileMapping`、`CEventSetEnd`）整段在 `#ifdef _WIN32` 内，非 Windows 落入 `throw "not implemented"`（ArchiveCommandLine.cpp:620-622,634；FileMapping.h 无 POSIX 分支）。即"7zFM→7zG 子进程"模型在 macOS **不可直接移植**。

### 3.2 macOS 决策：主程序进程内化；Finder 扩展独立进程 + XPC

**决策一：7zFM 与 7zG 合并为单进程（进程内化）。**
- 7zG 的压缩/解压/基准本质是"在工作线程上跑 UI/Common 的 `UpdateArchive()`/`Extract()`/`Bench()` + 进度窗"。上游已存在进程内等价实现 `CompressCall2.cpp`（`#ifndef Z7_EXTERNAL_CODECS` 时编译，直接调 UpdateGUI/ExtractGUI/HashCalcGUI/Benchmark，`02-gui-dialogs-inventory.md` §9）——这正是 macOS 单体形态的范本。
- 在 macOS：压缩/解压由 SevenZipKit 在串行队列/`NSOperation` 上承载，进度对话框是 App 内的 `NSWindowController`（窗口而非子进程）。删除 `CompressCall` 的进程派生路径与 `7zMap` 协议。
- 理由：消除不可移植的命名共享内存 IPC；统一进度/错误/取消的线程语义；避免双进程的格式发现、设置同步、生命周期协调成本。

**决策二：Finder 集成走独立 App Extension 进程，经 App Group + URL scheme / XPC 与主 App 通信。**
- FinderSync 扩展是 macOS 规定的独立进程，沙箱、生命周期与主 App 不同（`03-explorer-agent.md` §5#2）。扩展只承担"在 Finder 上下文菜单显示命令 + 收集选中文件 URL"，实际压缩/解压**唤起主 App** 执行（用 URL scheme 打开主 App 并传入操作 + 文件列表，或 `NSXPCConnection`）。
- 扩展与主 App 共享设置经 **App Group 的 NSUserDefaults**（菜单项开关 flags 等，`05-platform-layer.md` §4.2）。
- 理由：彻底绕开 `7zMap` 命名共享内存（沙箱扩展不可用）；把"重逻辑"集中在主 App，扩展保持轻量以满足 Finder 扩展的资源约束。

**决策三：可选 helper 进程留作后续（沙箱/权限分离）。** 若 App Store 沙箱阶段需要权限分离，可引入 XPC helper（传 `[String]` 而非共享内存），但主线分发（Developer ID）不需要，列为 `05-roadmap-execution.md` 的可选阶段。

### 3.3 模块目录发现（进程内化的配套改动）

`LoadCodecs` 把主库名硬编码为 `kMainDll = "7z.so"`（非 Windows 分支，LoadCodecs.cpp:72-77，本机已 `sed` 核实），搜索根目录 = `GetModuleDirPrefix()`，POSIX 实现靠 `Set_ModuleDirPrefix_From_ProgArg0(argv[0])` 注入（ArchiveCommandLine.cpp:1880-1886）。AppKit 应用无 `argv[0]` 注入习惯，必须在启动时显式设置为 `NSBundle.mainBundle` 的 Frameworks 目录（`04-core-dylib.md` §3.3；`05-platform-layer.md` §6）。

- 决策（与 `02-core-bridge.md` §1.2 统一为准）：**产物文件名定为 `lib7z.dylib`**（符合 macOS 习惯/对外品牌），放在 `SevenZipFM.app/Contents/Frameworks/`（与 SevenZipKit.framework 同级或其内），并在同目录建**兼容符号链接 `7z.so → lib7z.dylib`**（构建脚本一行 `ln -sf`）。这样桥接层 dlopen 绝对路径 `lib7z.dylib`、而复用 LoadCodecs（`kMainDll="7z.so"` 硬编码）的 FM 路径命中软链，两条消费路径都零改动。启动时调用一个 macOS 版 `GetModuleDirPrefix`（基于 `_NSGetExecutablePath`/`NSBundle`）。详细补丁点见 `05-roadmap-execution.md`（M0-T3）。
- 备选：若不愿带符号链接，改 `LoadCodecs.cpp:72-77` 一行为 `lib7z.dylib`（侵入一行，已记入开放问题取舍）。

### 3.4 进程内化的崩溃隔离代价与缓解（决策项）

进程内化（§3.2 决策一）消除了不可移植的 `7zMap` IPC，但**丧失了 Windows 上"右键→独立 7zG.exe"的崩溃隔离**：Windows 上解压损坏归档触发的崩溃只死子进程、FM 主体存活；进程内化后，引擎解析恶意/损坏归档触发的崩溃（解码器越界、CRC 绕过后的 UB、§5.1 的 `throw int` 穿越路径）会直接 take down 整个 `SevenZipFM.app`，丢失用户双面板状态/未完操作。`05-roadmap-execution.md` §9.2 测试集已承认要喂"损坏归档（CRC错/截断/头损坏/部分损坏）/路径穿越"样本，即攻击面已知存在。本节把缓解从开放问题升为明确决策：

**决策四：对"不受信/疑损坏/超大"任务走 XPC 子进程跑引擎（崩溃隔离 + 可被杀）。** 判据（命中任一即走子进程，写进 M2/M5 验收）：
1. **来源不受信**：归档带 `com.apple.quarantine`（下载/邮件/AirDrop 来源）。
2. **疑损坏命中**：Open 阶段返回 `NonOpen_ErrorInfo` 或 CRC/头校验告警（`OpenArchive.cpp` 的错误信息），后续解压改走子进程重试。
3. **超大任务**：归档体积 `>50 GB` 或条目数 `>100k`（与 §5.4 内存预算同阈值），无论来源都隔离，避免一次崩溃丢全部状态。

子进程为 `SevenZipEngine.xpc`（XPC service，复用 SevenZipKit 引擎逻辑，经 `NSXPCConnection` 传 `[String]` 路径 + 选项，不用共享内存），崩溃/超时由主 App `invalidationHandler`/`interruptionHandler` 捕获并向用户报"该归档处理异常"而非整体退出；进度/取消经 XPC 协议透传（与 §6 线程模型同构，回调跨进程改 message 往返）。不命中判据的常规任务仍进程内执行（保持轻量、低延迟）。

> 与 §3.2 决策三的区别：决策三的 XPC helper 是为"App Store 沙箱权限分离"的可选阶段；决策四的 XPC service 是为**崩溃隔离**，属主线发布（Developer ID）的明确决策，M2/M5 落地。

**配套（发布闸门）**：CI 必须用 libFuzzer/ASan 对 dylib 喂损坏归档语料做 fuzz（§8.3 步骤 3），作为发布闸门；风险登记册补一条"损坏归档崩溃主进程"（概率中/影响高，缓解=XPC 隔离 + fuzz 闸门 + 子进程资源上限）。

---

## 4. 仓库布局

### 4.1 隔离原则

最小侵入上游源码，便于跟随官方升版（26.02…）。所有新增代码集中到顶层 **`Mac/`** 目录，与上游 `C/`、`CPP/`、`DOC/` 等并列；对上游树的改动收敛为"少数可枚举的补丁点"，并以 `Mac/patches/` 记录。

原则：
1. **新增不混入**：ObjC++/Swift/xcodeproj/脚本全部在 `Mac/` 下，不散落进 `CPP/7zip/UI`。
2. **改动可枚举**：必须改上游的点（如 FM.cpp 的 `_WIN32` guard、可选的 `kMainDll` 重命名）集中登记，单独成 patch，升版时可重放/复核（清单见 `05-roadmap-execution.md`）。
3. **构建挂接零侵入优先**：dylib 的链接定制走上游已有的 `LDFLAGS_STATIC_3` 变量（已被 `7zip_gcc.mak:88` 纳入链接参数，是零侵入挂接点，`04-core-dylib.md` §3.4）或新增独立 `var_mac_*_dylib.mak`，不改 bundle 的 makefile 主体。
4. **上游纯逻辑直接引用**：UI/Common、UI/Agent 的 `.cpp` 由 xcode 工程**直接引用上游路径源文件**编译进 SevenZipKit（不复制），从而随上游升版自动跟进。

### 4.2 目录树建议

```
/ (仓库根)
├── C/                         # 上游 C 引擎（不动）
├── CPP/                       # 上游 C++（引擎/UI/平台层，仅少数登记补丁点）
│   └── 7zip/
│       ├── Bundles/Format7zF/ # → lib7z.dylib 来源（make 构建，不改主 makefile）
│       ├── UI/Common/         # 桥接层直接引用编译（纯逻辑）
│       ├── UI/Agent/          # 桥接层直接引用编译（归档文件夹化）
│       └── ...
├── DOC/
├── docs/                      # 本移植方案文档（01..05 + research/）
└── Mac/                                     # ★ 全部 macOS 新增物，顶层隔离
    ├── SevenZipKit/                         # ObjC++ 桥接 framework 源码
    │   ├── include/SevenZipKit/             # 对外公开 ObjC 头（umbrella header）
    │   │   ├── SevenZipKit.h
    │   │   ├── SZArchive.h  SZItem.h  SZTask.h  SZError.h  SZProgress.h
    │   ├── src/                             # .mm 实现（持有 C++，不暴露给 App）
    │   │   ├── SZArchive.mm  SZOpenCallback.mm  SZExtractCallback.mm
    │   │   ├── SZUpdateCallback.mm  SZCodecs.mm  SZConvert.mm（编码/时间）
    │   │   ├── SZError.mm（HRESULT→NSError）  SZFolderModel.mm（Agent 包装）
    │   └── platform/                        # 上游平台层的 mac 替身实现
    │       ├── Registry_mac.mm              # NRegistry::CKey → NSUserDefaults 适配
    │       ├── ModuleDir_mac.mm             # GetModuleDirPrefix(NSBundle)
    │       └── DirWatcher_mac.mm            # CFindChangeNotification → FSEvents
    ├── SevenZipFM/                          # AppKit 主应用
    │   ├── App/                             # AppDelegate / MainMenu / 入口
    │   ├── Panel/                           # 双面板/列模型/排序/选择（NSTableView）
    │   ├── Dialogs/                         # 压缩/解压/进度/覆盖/密码/选项 6 页…
    │   ├── Finder/                          # FinderSync App Extension target
    │   └── Resources/                       # Assets/Lang(*.txt 直接复用)/Info.plist
    ├── scripts/                             # 构建/产线/CI 脚本
    │   ├── build_dylib.sh                   # make arm64+x64 → lipo → 签名
    │   ├── build_app.sh                     # xcodebuild framework+app
    │   ├── package.sh                       # 公证 + DMG
    │   └── exports7z.txt                    # dylib 导出符号收敛清单（19 个 C 入口）
    ├── patches/                             # 登记的上游改动（可重放）
    │   └── 0001-fm-win32-guards.patch ...
    └── SevenZip.xcodeproj  (或 SevenZip.xcworkspace)
        # 三 target：SevenZipKit(framework) / SevenZipFM(app) / SevenZipFMFinder(extension)
        # dylib 由外部 make 产出，作为 prebuilt 依赖 + Copy Files 阶段嵌入
```

xcode 工程组织：一个 workspace/project，三个 target——framework、app、Finder 扩展。dylib 不在 xcode 内编译（由 `scripts/build_dylib.sh` 的 make 产出），以"预构建产物 + Run Script 校验 + Copy Files 嵌入"方式接入（构建体系详见 §8）。

---

## 5. 数据流

### 5.1 打开归档 → Agent → 面板渲染（完整时序）

对应 Windows 链路 `Panel::OpenAsArc → CArchiveFolderManager::OpenFolderFile → CAgent::Open → CProxyArc::Load → CAgentFolder`（`03-explorer-agent.md` §2.5、§4）。macOS 时序：

```
[App 主线程]                [SevenZipKit 串行队列]              [lib7z.dylib]
用户双击/拖入归档
  └─ SZArchive open: 调用 ─────►│ （异步：立即返回，进度/取消句柄上抛 App）
                                │ LoadGlobalCodecs（首次）
                                │   └─ CCodecs::Load → 静态 g_Arcs 或 dlopen 7z.so ──► 枚举格式/codec
                                │ new CArchiveFolderManager
                                │ IFolderManager::OpenFolderFile
                                │   └─ CAgent::Open(openCallback=SZOpenCallback) ★必传
                                │        ├─ CArchiveLink::Open(COpenOptions)
                                │        │    └─ IInArchive::Open(stream, SZOpenCallback) ──► 探测+读目录
                                │        │         · SetTotal/SetCompleted → 进度 hop main（§6.3 节流）
                                │        │         · 每次回调检 isCancelled → 命中 return E_ABORT
                                │        │         · 加密头 → SZOpenCallback 经信号量
                                │        │           回主线程弹密码 sheet（§6 阻塞回调）
                                │        └─ BindToRootFolder → ReadItems
                                │             └─ CProxyArc(2)::Load(GetArc, IProgress) ──► 切层建树
                                │                  · SetTotal(numItems)/逐 0x10000 项 SetCompleted
                                │                  · 检 isCancelled → return E_ABORT（中断建树）
                                │ 列模型：GetNumberOfProperties/GetPropertyInfo
                                │ 行数据：按需 GetProperty（§5.4 懒加载，不在 open 内全读）
  ◄───── 完成 block（SZArchive(rootFolder, 列定义) 或 NSError(Cancelled)）
刷新 NSTableView（main queue）
```

要点：
- **打开归档是可取消、可报进度的异步操作（硬约束，写进 M1 验收）。** 双击 10 万/100 万条目归档时，整段（`IInArchive::Open` 头解析 + proxy 树构建）都在 SevenZipKit 串行队列上跑，必须全程可报进度、可注入 `E_ABORT`：
  1. **Open 阶段**：给 `CAgent::Open` 传入实现 `IArchiveOpenCallback` 的 `SZOpenCallback`（接 `isCancelled`→`E_ABORT`、`SetCompleted`→进度）。底层 `OpenArchive.cpp:1599` 的 `archive->Open(stream, maxCheckStartPosition, openCallback)` 已透传该回调；solid/加密头大归档头解析可达数秒（`OpenArchive.cpp:1958/2227/3115` 走 `op.callback->SetTotal`），靠此回调报进度并响应取消。
  2. **proxy 树构建阶段**：`CProxyArc::Load` 本就支持进度（`AgentProxy.cpp:250` `SetTotal(numItems)`、`:263` 逐 `0x10000` 项 `SetCompleted`），但 `CAgent::ReadItems` 当前向两处 `Load` 传 NULL（`Agent.cpp:1770-1771` `_proxy2->Load(GetArc(), NULL)` / `_proxy->Load(GetArc(), NULL)`），导致整段不可中断、不报进度。**登记为上游补丁点**（`Mac/patches/`，见 `05-roadmap-execution.md`）：给 `CAgent` 增一个 `SetOpenProgress(IProgress*)`/`ReadItems(IProgress*)` 入口，把桥接层的真实 `IProgress`（同一回调对象）传给两处 `Load`；patch 边界清晰（仅这两行 + 一个成员/形参），升版可重放。
  3. **若不愿改上游**（B 计划）：桥接层自建轻量目录树替代 proxy（仅持 path/isDir/index 的扁平数组 + 父子索引），构建循环自带 `SetCompleted`/`isCancelled` 检查；此时 proxy 树不参与 FM 面板（仅在需要 `CAgentFolder` 增删改事务时按需懒建）。取舍记入开放问题。
- 列 = 当前 `IFolderFolder` 报告的属性集 + rawProps，`kpidIsDir` 不作列（`01-filemanager-inventory.md` §4.2）。桥接层把 PROPVARIANT 转 ObjC 值（NSString/NSNumber/NSDate），App 层只渲染。
- 名字内存由 proxy 持有裸指针，`LoadItems/ReOpen` 后失效（`03-explorer-agent.md` §5#8）——桥接层在每次 LoadItems 后**立即拷出 NSString**，不让 App 层持有引擎裸指针。
- 开档失败但有 `NonOpen_ErrorInfo` 时仍返回 folder 以展示错误属性（ArchiveFolderOpen.cpp:107-115），桥接层将其映射为"可浏览但带错误"的 SZArchive 状态。

### 5.2 压缩任务流

对应 7zG 的压缩流水线（`02-gui-dialogs-inventory.md` §2.6、§10）：

```
用户在压缩 sheet 确认（NCompressDialog::CInfo 等价的 SZCompressOptions）
  └─ SZTask compress: 派发到串行队列上的 NSOperation
       └─ UpdateGUI 等价：CInfo → CUpdateOptions → SetOutProperties → 属性名/值对
            └─ UpdateArchive()（UI/Common/Update.cpp）
                 ├─ EnumerateItems（censor 扫描源文件）
                 ├─ GetUpdatePairInfoList / UpdateProduce（配对+动作）
                 ├─ IOutArchive::UpdateItems(outStream, n, CArchiveUpdateCallback) ──► 引擎压缩
                 │     · 进度 SetTotal/SetCompleted（可能在 worker 线程，§6）
                 │     · 密码 CryptoGetTextPassword2 → 信号量回主线程弹密码 sheet
                 └─ 分卷/SFX/MoveArc（如适用）
  进度回调 hop main queue → 更新 SZProgress → 进度窗 NSProgressIndicator
  完成/取消 → 完成 block（NSError? + 统计）
```

字段→7z 属性的完整映射表（Level→"x"、Method→"0"/"m"、Dict→"d"、Solid→"s"、Threads→"mt"、加密→"em"/"he" 等）在 `02-gui-dialogs-inventory.md` §2.6，桥接层 `SZCompressOptions` 逐字段对齐，落点为 `ISetProperties::SetProperties`。

### 5.3 解压任务流

```
用户在解压 sheet 确认（NExtract::CInfo 等价的 SZExtractOptions）
  └─ SZTask extract: NSOperation on 串行队列
       └─ ExtractGUI 等价 → Extract()（UI/Common/Extract.cpp）
            └─ CArchiveLink::Open_Strict ─创建→ COpenCallbackImp
               IInArchive::Extract(realIndices, testMode, CArchiveExtractCallback) ──► 引擎解压
                 · 覆盖冲突 → AskOverwrite → 信号量回主线程弹覆盖 sheet
                 · 密码 → CryptoGetTextPassword → 密码 sheet
                 · 内存超限 → IArchiveRequestMemoryUseCallback → 内存确认 sheet
                 · 解压网络来源档 → 写 com.apple.quarantine（替代 Windows ZoneId，新增桥接工作项）
  进度/错误 hop main queue；错误聚合进 Messages 列表（NSTableView）
```

归档内提取（面板内 CopyTo）走 `IFolderOperations::CopyTo → CAgentFolder::Extract`（`03-explorer-agent.md` §2.5）。

### 5.4 大归档内存预算与懒加载（100 万条目）

字符串/对象被多层放大，必须给出可验收的内存预算并以懒加载收敛：

**放大来源（实测）**：
- proxy 树：每条目一个 `CProxyFile`（`const wchar_t* Name + NameLen + NeedDeleteName`，`AgentProxy.h:8-16`）外加 `CObjectVector<CProxyDir>`。macOS 上 `wchar_t=4B` 且零拷贝名优化被禁用（`AgentProxy.cpp:274` 的 `#if defined(MY_CPU_LE) && defined(_WIN32)`，POSIX 走 BSTR 复制慢路径，`02-core-bridge.md:224`），即每个名字是一份 UTF-32 堆拷贝。
- 桥接层若 eager 全读：每条目一个 `SZArchiveEntry` NSObject，创建时一次性把 path/name/size/3 个 NSDate/crc/attrib 等十余属性读出并 boxing（`02-core-bridge.md:443`）——100 万条目即 100 万个 NSObject + 十余倍的 NSNumber/NSDate boxing，叠加引擎 BSTR→proxy wchar_t→NSString 三份字符串。

**预算与约束（验收项，写进 M1/性能基线）**：
- **峰值常驻 ≤ 600 MB / 100 万条目**（含 proxy 树 + 桥接元数据 + 当前可见窗口的 ObjC 快照）；**每条目均摊 ≤ 512 字节**（不含可见窗口内临时 ObjC 对象）。超阈即视为回归失败（替换 `05-roadmap-execution.md` §9.4『记录基线，无失控增长』的无数字表述）。
- **桥接层默认走懒加载**：`SZArchive.entries` 不 eager 建数组，FM 面板用 `enumerateEntriesUsingBlock:` / `entryAtIndex:`（`02-core-bridge.md:415-419`）按需取。`SZArchiveEntry` 改为 **lazy**——属性在 `valueForPropID:`/getter 首次访问时才 `GetProperty` 读出并缓存，不在创建时 eager 全读；不可见行不 boxing 任何 NSNumber/NSDate。`02-core-bridge.md` §4.3 的"创建时一次性读出"措辞据此改为"按需读出"（登记为 02 同步修订点）。
- **不双份持有全量字符串**：proxy 树（UTF-32 裸指针）是唯一全量名字常驻者；`SZArchiveEntry` 的 path/name 在懒加载命中时即时从 proxy 拷出 NSString 并随 entry 释放回收，不与 proxy 同时各持一份 100 万级全量副本。

---

## 6. 线程模型

源码已实证的硬约束（`04-core-dylib.md` §5；`03-explorer-agent.md` §5#6）驱动以下规则：

### 6.1 任务队列与引擎调用串行化

- **每个 SZArchive 持有一个串行 `dispatch_queue`**，所有引擎调用（Open/GetProperty/Extract/UpdateItems）在该队列排队执行。理由：官方注释明确"同一 IInArchive 对象禁止从不同线程并发调用"（IArchive.h:305-308）。
- 并行任务（如同时浏览 + 解压）用**多个 IInArchive 实例**（各自独立 IInStream），不共享同一对象。面板预览走 `IInArchiveGetStream` 的单独实例。
- 引用计数默认非原子（`++/--`，`Z7_COM_USE_ATOMIC` 全仓未定义，`MyCom.h:380-386` 实证 AddRef/Release 为裸 `++/--`；`04-core-dylib.md` §2.2）——**对象生命周期收敛到其所属串行队列**，禁止跨线程 AddRef/Release 同一对象（否则 UAF）。
- **派发到 main queue 的 block 一律 `__weak` 捕获桥接对象（硬规则）。** §6.2/§6.3 的进度与 completion 都 `dispatch_async(main)`；若 block 强捕获 `self`（ObjC 包装对象）并在 main 线程析构，其成员 `CMyComPtr<IInArchive>` 析构会在 **main 线程对引擎对象做非原子 Release**，而该引擎对象可能仍被串行队列上的调用栈持有——正是本条禁止的跨线程 Release。规则：(a) main queue block 对桥接 ObjC 对象用 `__weak self`，进入 block 后 `strongify` 仅用于读 UI 状态，不触发底层 Release；(b) **桥接 ObjC 对象的 `dealloc`（即 `CMyComPtr` 成员析构 → 引擎 `Release`）必须发生在该对象所属串行队列上**——实现方式：在 `dealloc` 里把持有引擎指针的成员转移后 `dispatch_async` 回私有串行队列释放（或保证最后一个强引用必在私有队列释放），杜绝引擎 `Release` 跨线程。这是 `04-core-dylib.md` §7 风险表已点名、本设计在此落地的约束。

### 6.2 核心回调线程

- **进度回调可能发生在引擎 worker 线程上**（实证：ZIP 多线程压缩中 `CoderThread→WaitAndCode` 直接调 `Progress->SetCompleted`，持锁串行但非主线程，`04-core-dylib.md` §5、ZipUpdate.cpp:289-408）。
- 桥接层的进度回调实现必须：(a) **统一 hop 到 main queue** 再更新 UI（`dispatch_async(main)`，弱引用防环）；(b) **回调内绝不重入同一 archive 对象**（持锁重入=死锁/未定义）。
- 引擎默认含 MT 对象（LzFindMt/MtCoder/MtDec…），会按 `mt` 参数自起 pthread（`04-core-dylib.md` §5），桥接层不感知这些内部线程，只在边界处约束。

### 6.3 UI 主线程派发规则

| 事件来源 | 发生线程 | 派发规则 |
|---|---|---|
| 引擎进度（SetTotal/SetCompleted/Ratio） | 可能 worker 线程 | hop main queue，节流（如 200ms，对齐 Windows `kTimerElapse`） |
| 解压条目回调（GetStream/SetOperationResult） | 串行队列（串行保证） | 状态更新 hop main queue |
| **阻塞式询问**（密码/覆盖/卷请求/内存限额） | 引擎调用线程（同步阻塞） | semaphore 桥接：回调线程 `dispatch_sync` 不可（会死锁），改用 `dispatch_semaphore` + `dispatch_async(main)` 弹 sheet，用户应答后 signal 解阻塞 |
| 完成/错误 | 串行队列 | 完成 block hop main queue |

密码/覆盖/卷/内存回调是**同步阻塞**协议（IPassword.h:16-51 协议本身同步，Windows GUI 即如此）——回调线程必须同步等待用户输入完成。桥接层用信号量把"回调线程阻塞 + 主线程弹 sheet"配对，给队列加忙碌标记（`04-core-dylib.md` §6、§7）。

---

## 7. 错误处理

### 7.1 HRESULT → NSError 错误域设计

引擎统一以 `HRESULT`（`= LONG = INT32`）返回，`SUCCEEDED(hr) = hr>=0`（`04-core-dylib.md` §2.1）。桥接层定义单一错误域并保留原始码：

```objc
// SZError.h（草案）
extern NSErrorDomain const SZErrorDomain;        // @"com.7zip.SevenZipKit"

typedef NS_ERROR_ENUM(SZErrorDomain, SZErrorCode) {
    SZErrorOK              = 0,        // S_OK
    SZErrorFalse           = 1,        // S_FALSE（非该格式/无更多数据，非失败）
    SZErrorCancelled       = -2147467260, // E_ABORT 0x80004004 → 用户取消
    SZErrorOutOfMemory     = -2147024882, // E_OUTOFMEMORY 0x8007000E
    SZErrorInvalidArg      = -2147024809, // E_INVALIDARG 0x80070057
    SZErrorNotImpl         = -2147467263, // E_NOTIMPL
    SZErrorFail            = -2147467259, // E_FAIL
    SZErrorWrongPassword,                 // 业务码（解压 opRes 解码）
    SZErrorDataError,                     // CRC/数据错误（NExtract::NOperationResult）
    SZErrorUnsupportedMethod,
    // …映射 ExtractRes.h 的 IDS_EXTRACT_MSG_* 全集
};

// userInfo:
//   NSLocalizedDescriptionKey      ← 本地化串（复用 Lang/*.txt 或内置英文表）
//   @"SZUnderlyingHRESULT"         ← NSNumber(int32) 原始 HRESULT
//   @"SZItemPath"                  ← 出错条目路径（如适用）
```

规则：
- `code` 直接采用 `HRESULT` 数值（保留原值，便于诊断与回溯）；业务级错误（密码错/CRC/不支持方法）用 `NExtract::NOperationResult` 与 `ExtractRes.h` 的 `IDS_EXTRACT_MSG_*` 解码为补充码（`02-gui-dialogs-inventory.md` §7）。
- 本地化串复用上游 `LangString` 体系（Lang/*.txt 可随 .app 分发，本地化"基本免费移植"，`05-platform-layer.md` §7）；无 .txt 时 fallback 到内置英文表（替代 .rc 资源）。
- `errno` 类错误经 `HRESULT_FROM_WIN32(errno)`（POSIX 自定义 FACILITY_ERRNO=0x800，`04-core-dylib.md` §2.1）原样保留。

### 7.2 取消语义贯穿三层

`E_ABORT`（0x80004004）是引擎规定的"用户取消"语义（`04-core-dylib.md` §2.1、§6）。取消的传递路径：

```
[App 层] 用户点进度窗 Cancel
   │  SZTask.cancel  →  设置 SZProgress.isCancelled 标志（原子）
   ▼
[桥接层] 回调对象的 IProgress::SetCompleted / 各 askXxx 检查 isCancelled
   │  命中则 return E_ABORT（不抛 C++ 异常穿越 C ABI）
   ▼
[核心层] 引擎收到 E_ABORT → 中止当前操作，逐层 return 失败
   ▼
[桥接层] 顶层 Extract()/UpdateArchive() 返回 E_ABORT
   │  COM_TRY 边界：catch-all 转 HRESULT（C++/ObjC 异常不穿出 C ABI）
   ▼
[App 层] 完成 block 收到 NSError(SZErrorCancelled) → 静默关窗（非错误弹框）
```

要点：
- 取消标志由 App 设置、桥接层回调读取并转成 `E_ABORT` 返回值（**返回码驱动，不靠异常**）。
- 桥接层所有回调方法 **catch-all**（C++ 与 ObjC 异常都拦截）转 HRESULT——客户端回调抛异常进引擎无人保护，是 UB（`04-core-dylib.md` §2.2、§6）。
- 归档内更新的 `MoveArc_*` 协议会**刻意延迟 E_ABORT**以保护回写完整性（ArchiveFolderOut.cpp:192-233），桥接层必须保真该延迟语义，否则可能损档（`03-explorer-agent.md` §5#5）。

---

## 8. 构建体系

### 8.1 总体：make（dylib）+ xcodebuild（framework/app）组合

两套构建产线，由 `Mac/scripts/` 编排：

1. **lib7z.dylib 走上游 make**（已实测可用，`04-core-dylib.md` §3.2、§8）。每架构切片独立 make，再 `lipo` 合并：
```sh
# Mac/scripts/build_dylib.sh（要点）
cd CPP/7zip/Bundles/Format7zF
make -f ../../cmpl_mac_arm64.mak -j8        # → b/m_arm64/7z.so  (已验证零改动通过)
make -f ../../cmpl_mac_x64.mak  -j8        # → b/m_x64/7z.so
lipo -create b/m_arm64/7z.so b/m_x64/7z.so -output "$OUT/7z.so"  # universal
# 链接定制（经 LDFLAGS_STATIC_3 或独立 var_mac_*_dylib.mak，§3.4 of 04）：
#   -Wl,-install_name,@rpath/7z.so
#   -Wl,-exported_symbols_list,Mac/scripts/exports7z.txt   （收敛到 19 个 _C 入口）
#   -Wl,-compatibility_version,1 -Wl,-current_version,26.01
#   -Wl,-dead_strip
codesign --force --options runtime --sign "$DEV_ID" "$OUT/7z.so"
```

2. **SevenZipKit.framework + SevenZipFM.app + Finder 扩展走 xcodebuild**。SevenZipKit 直接引用上游 UI/Common、UI/Agent 源 + Mac/SevenZipKit 的 `.mm`；dylib 以预构建产物嵌入：
```sh
# Mac/scripts/build_app.sh（要点）
xcodebuild -workspace Mac/SevenZip.xcworkspace -scheme SevenZipFM \
  -configuration Release \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  MACOSX_DEPLOYMENT_TARGET=13.0 \
  CODE_SIGN_IDENTITY="$DEV_ID" -allowProvisioningUpdates
# Copy Files 阶段把 7z.so + SevenZipKit.framework 放入 .app/Contents/Frameworks/
# rpath：@loader_path/../Frameworks（保证 dylib 可被找到）
```

### 8.1.1 C++ 运行时 / ABI 边界的可校验约束（硬闸门）

dylib 经 `RTLD_LOCAL|RTLD_NOW` 装载（`DLL.cpp:148-153` 实证），7z.so 内部符号不进全局符号表——这恰好支持"dylib 边界只走 19 个 C 工厂"（决策正确，§2.3）。但 `RTLD_LOCAL` 下，**若 dylib 与 framework 各自静态嵌入一份 libc++**，则跨边界的 `IUnknown` 虚调用、typeinfo/vtable、`operator new`/`delete`、PROPVARIANT/BSTR 的分配释放会因两份运行时不一致而静默 UB。§2.2"同一 clang / 同一 C++ 运行时"的硬约束据此落为可校验项，全部进 CI 闸门：

1. **两侧都动态链接同一份系统 libc++**：`otool -L "$OUT/7z.so"` 与 `otool -L SevenZipKit.framework/SevenZipKit` 必须**都列出 `/usr/lib/libc++.1.dylib`**（系统共享库），且**都不得**出现静态嵌入的 libc++ 符号。构建侧禁用 `-static-libstdc++`/静态 libc++ 嵌入；CI 断言两者依赖路径一致。
2. **dylib 不导出任何 C++ 符号**：`nm -gU "$OUT/7z.so"` 的导出表必须**恰好等于** `Mac/scripts/exports7z.txt` 的 19 个 `_C` 入口（无 mangled C++ 符号、无 `operator new`/typeinfo 泄漏）。导出表与清单 diff 非空即构建失败（与 §8.3 CI 步骤 1 合并执行）。
3. **PROPVARIANT/BSTR 跨边界的分配释放归属固定一侧**：跨 C ABI 传递的 `BSTR`/`PROPVARIANT` 一律用 `MyWindows` 提供的 `SysAllocString`/`SysFreeString`/`VariantClear`（不用裸 `malloc`/`free`），且这些符号**固定来自桥接层一侧**（dylib 不导出它们）——即"谁分配谁释放"收敛到 framework 内同一运行时，避免跨 `RTLD_LOCAL` 边界配对。桥接层 `SZConvert.mm` 的 PROPVARIANT 读取在 framework 侧完成后只把转换后的 ObjC 值（已脱离 PROPVARIANT）上抛 App。

> 校验脚本固化在 `build_dylib.sh`（步骤 1/2）与 `build_app.sh` 后置 Run Script（步骤 1），任一不满足 CI 即红。

### 8.2 universal binary 产线

- 目标：macOS 13.0+，universal（arm64 + x86_64）。
- dylib：两架构 make 切片 + `lipo`（§8.1）。x64 切片用 `var_mac_x64.mak`（`04-core-dylib.md` §3.1）。
- framework/app：xcodebuild `ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO`。
- 校验：构建后 `lipo -info` 确认双架构；`otool -l` 确认 `LC_BUILD_VERSION` minos=13.0。

### 8.3 最小 CI 流程

```
[CI on macOS runner]
1. build_dylib.sh         → 产出 universal 7z.so + 校验：
                            · file/lipo 双架构
                            · nm -gU 导出表 == exports7z.txt 的 19 个 C 入口（无 C++ 符号，§8.1.1#2）
                            · otool -L 含 /usr/lib/libc++.1.dylib、无静态 libc++（§8.1.1#1）
2. dylib 冒烟测试          → 复用 Client7z roundtrip（dlopen+压缩+列表+解压+diff，04 §8）
3. libFuzzer/ASan fuzz     → 对 dylib 喂损坏归档语料（CRC错/截断/头损坏/路径穿越，05 §9.2 样本集）
                            作为发布闸门：无 crash/无 ASan 报错才放行（§3.4）
4. build_app.sh           → xcodebuild framework + app + extension
                            · 后置 Run Script：otool -L framework 校验同一 libc++（§8.1.1#1）
5. 单元测试               → SevenZipKit 的 XCTest（打开/压缩/解压/取消/错误域/编码转换）
                            · 含"打开 10 万条目归档过程中取消 1s 内返回 SZErrorCancelled"（§5.1）
6. codesign 验证          → codesign --verify --deep --strict
7. （release 分支）package.sh → 公证 + stapler + DMG
```

CI 最小集合先保证"dylib 可构建可加载 + framework 可链接 + 核心桥接单测通过"；**fuzz（步骤 3）为发布闸门，非可选**（进程内化后损坏归档崩溃直接打进主 App，见 §3.4）。UI 自动化测试列为后续（详见 `05-roadmap-execution.md`）。

### 8.4 签名与分发

- 主线：Developer ID 签名 + 公证（hardened runtime；hardened runtime 下 dlopen 同签名 dylib 无障碍，`04-core-dylib.md` §3.4、§7）。dylib、framework、app、extension 均需签名。
- App Store/沙盒列为可选后续阶段（涉及 entitlements、security-scoped bookmark、Rar/unRAR 许可评估，记入 `05-roadmap-execution.md`）。

---

## 9. 上游同步策略（SOP 概要）

官方出新版（如 26.02）时的升级 SOP 概要（详细步骤、补丁清单、回归用例在 `05-roadmap-execution.md`）：

1. **合并上游源码**：把官方 26.02 的 `C/`、`CPP/` 覆盖/合并进仓库；`Mac/` 不受影响（隔离原则，§4.1）。
2. **重放登记补丁**：依次重放 `Mac/patches/` 下登记的上游改动（FM/UI 公共 cpp 的 `_WIN32` guard、可选 `kMainDll` 重命名等），解决冲突。补丁应尽量小且边界清晰，便于在新版重放。
3. **重建 dylib 并核对 ABI**：`build_dylib.sh` 重新产出；用运行时探测核对 `GetModuleProp(kVersion)` 是否变为新版本号、`kInterfaceType`（虚析构约定）是否仍为 0（ABI 闸门，`04-core-dylib.md` §4.1）。若 IUnknown 虚析构设置在新版变化，桥接层须同步重编（双侧一致是硬约束，§2.2）。
4. **核对导出与接口**：`nm -gU` 确认 19 个 C 入口仍在；diff `IArchive.h`/`ICoder.h`/`PropID.h` 看是否新增 PROPID/接口/VT 类型（影响桥接的属性映射）。
5. **回归**：CI 全流程 + dylib roundtrip 冒烟 + SevenZipKit 单测；UI 手工回归一对一清单的关键路径。
6. **版本号更新**：同步 `-Wl,-current_version` 与 app 版本。

由于 UI/Common、UI/Agent 是**直接引用上游路径源文件**编译（§4.1 原则 4），多数升版只需重放少量补丁 + 重建，不需重抄逻辑。桥接层与 App 层因只依赖稳定的 IFolder/IInArchive 接口契约，受上游内部实现变动影响小。

---

## 10. 开放问题

以下问题无法仅从源码定案，需在评审或实测中决断：

1. **dylib 文件名 `7z.so` vs `lib7z.dylib`**：**已定案（§3.3，与 `02-core-bridge.md` §1.2 一致）= `lib7z.dylib` + 兼容软链 `7z.so → lib7z.dylib`**——产物用 `lib7z.dylib`（符合 macOS 习惯/品牌），软链让复用 `LoadCodecs`（`kMainDll` 硬编码 `7z.so`，LoadCodecs.cpp:72-77）的路径零改动命中。残留待定的仅"是否带软链 vs 改一行上游 `kMainDll`"的取舍（默认带软链，见 §3.3 备选）。
2. **dylib 装载方式：dlopen（外置）vs 静态链接全格式进 framework**：研究底料指出 macOS 上"静态链接全部格式（同 7zz）最稳、已验证"，单 dylib 方案需补模块路径发现与 `.so` 后缀验证（`03-explorer-agent.md` §2.7、§5#10）。方案B 名义为"核心 dylib"，但是否在桥接层退化为静态链接以降低加载链复杂度，需评审拍板（影响 §4.2 布局与 §8 产线）。
3. **Finder 集成的通信机制：URL scheme 唤起主 App vs NSXPCConnection**：两者都能绕开 `7zMap`，但在沙箱权限、App Group 文件访问、用户体验（是否切换到主 App）上不同，需在 Finder 扩展原型阶段实测确定（§3.2 决策二）。
4. **沙箱权限分离 helper 的引入时机**：进程内化是默认决策；"崩溃隔离用 XPC 子进程"已升为明确决策（§3.4 决策四，主线发布即落地）。剩余待定的是 §3.2 决策三的"App Store 沙箱权限分离 helper"——其引入时机需与路线图的沙箱阶段协调（与决策四的崩溃隔离 XPC service 可否合用一个进程，待原型评估）。
5. **NFC/NFD 规范化策略**：全仓库无任何 Unicode 规范化处理，档内名（多为 NFC）与磁盘名（HFS+ 强制 NFD、Finder 多输入 NFD）比较会失配，需新写桥接代码（`05-platform-layer.md` §5#3）。入档统一 NFC、比较时双向规范化是建议方向，但具体落点（桥接层哪一处、是否影响 wildcard）需专项设计与测试集验证——此为新增工作项而非现成代码。
6. **quarantine 写入的具体 API 与时机**：解压网络来源档需写 `com.apple.quarantine`（替代 Windows WriteZoneIdExtract），用 `qtn_file_*` 还是 `NSURL quarantinePropertiesKey`、对可执行文件/全部文件的策略，需结合 Gatekeeper 预期实测（`05-platform-layer.md` §5#8）。
7. **引用计数原子化取舍**：默认 `++/--` 非原子；若桥接层确有跨线程共享对象的需求，需定义 `Z7_COM_USE_ATOMIC` 并补 `InterlockedIncrement/Decrement` 实现并双侧重编（`04-core-dylib.md` §2.2、§7）。本文默认"对象生命周期单线程化"规避之（§6.1），但若性能/架构演进需要共享，此开关的代价需评估。
