# 00 总览（方案摘要 · 决策清单 · 阅读指南）

> 7-Zip 26.01 Windows GUI 一对一移植 macOS · 方案 B（核心 dylib + ObjC++ 桥接 + AppKit）
> 本文是六份方案文档（`01`~`05` 设计 + `06` 对抗评审存档）的入口与索引。详细落地见各章；本文只给摘要、决策、阅读路径、工作量/里程碑、Top 风险与开放问题。
> 基线：仓库 main @ `8c63d71`（26.01）。证据格式 `文件:行号`（相对仓库根 `/Users/lyd/WorkSpace/MyProjects/7zip`）。

---

## 1. 方案摘要（一页）

**目标**：在 macOS 13.0+（universal arm64 + x86_64）上**功能与交互等价复刻** Windows 7-Zip 的三个 GUI 程序（7zFM 文件管理器 / 7zG 压缩解压 GUI / Explorer 右键集成），而非命令行 `7zz`。覆盖六菜单约 70 条命令 + 全键表 + 16 类对话框 + 6 选项页 + 面板能力 + 右键命令集 + 约 60 设置键。

**为什么可行**：引擎（全部格式 handler、Rar 解码、AES、汇编优化、哈希）已随 `7zz` 在本机 macOS arm64 编译自测通过，且全格式 bundle（`Bundles/Format7zF`）用 stock makefile **零改动**产出 Mach-O dylib，dlopen 端到端压缩/列表/解压 roundtrip 通过。**工作量集中在 UI 层与平台桥接，不触碰引擎算法。**

**三层架构**：

```
SevenZipFM.app   AppKit 主应用（双面板/菜单/快捷键/对话框/设置/Finder 扩展 target）
      │  只调 SevenZipKit 的 ObjC/Swift API，不直接 include 7-Zip C++ 头
      ▼
SevenZipKit.framework   ObjC++（.mm）桥接层 + 静态编入上游 UI/Common + UI/Agent
      │  线程模型/错误转换/取消/编码时间转换；dylib 边界只走 C 工厂
      ▼
lib7z.dylib   核心动态库 = Format7zF 全格式 handler + codec + 加密（19 个 C ABI 入口）
```

**关键移植转换**：
- **进程内化**：Windows 的 7zFM→7zG 子进程 + `7zMap` 命名共享内存 IPC 不可移植 → 合并为单进程，压缩/解压在 SevenZipKit 串行队列/`NSOperation` 上跑（蓝本 `CompressCall2.cpp`）。
- **崩溃隔离**：进程内化丧失 Windows"独立 7zG 进程"的崩溃隔离 → 对不受信/疑损坏/超大任务走 `SevenZipEngine.xpc` 子进程跑引擎（主线发布即落地）。
- **Finder 集成**：Explorer 右键 shellex → FinderSync App Extension（独立沙箱进程，经 App Group + XPC/URL scheme 唤起主 App 执行）。
- **持久化**：注册表 → NSUserDefaults（域 `com.7zip.SevenZipFM`，与 Finder 扩展经 App Group 共享）。
- **平台替身**：注册表→UserDefaults、`CFindChangeNotification`→FSEvents、Shell 文件关联→LaunchServices/UTType、回收站→`NSWorkspace recycleURLs`、MOTW→`com.apple.quarantine`。

**分发主线**：Developer ID 签名 + 公证（hardened runtime）。App Store/沙盒为可选后续阶段。

---

## 2. 关键决策清单（每条含一句话理由）

| # | 决策 | 一句话理由 | 出处 |
|---|---|---|---|
| D1 | 方案 B：核心 dylib + ObjC++ 桥接 + AppKit | 引擎已实测可 dylib 化复用，UI 层用原生 AppKit 最贴合 mac 交互 | 01 §2 |
| D2 | dylib 边界只走 C 风格 `CreateObject` 工厂 + COM 接口指针，不跨边界传 C++ 异常 | `RTLD_LOCAL` 装载 + 非原子引用计数下，跨边界 C++ 异常/对象生命周期是 UB | 01 §2.3、02 §6 |
| D3 | dylib 文件名 = `lib7z.dylib` + 兼容软链 `7z.so → lib7z.dylib` | 产物用品牌名，软链让复用 `LoadCodecs`（`kMainDll="7z.so"`）的 FM 路径零改动命中 | 02 §1.2、01 §3.3 |
| D4 | Agent 层（7 .cpp）编入桥接层 framework，不进 dylib | Agent 是 UI 侧数据模型适配层、内部 `throw int`，须留在桥接层同一运行时 | 01 §2.3、02 §3 |
| D5 | 7zFM 与 7zG 合并为单进程（进程内化） | 消除不可移植的 `7zMap` 命名共享内存 IPC，统一进度/取消/错误线程语义 | 01 §3.2、04 §0 |
| D6 | 不受信/疑损坏/超大任务走 XPC 子进程跑引擎（崩溃隔离） | 进程内化后损坏归档崩溃会 take down 整个 App，须隔离 + fuzz 闸门 | 01 §3.4 |
| D7 | 进度走 pull（拉取）模型：引擎回调只原子写共享结构，200ms main-queue 定时器合并送达 | 对齐 Windows `kTimerElapse=200`；引擎每秒数千次回调若每次 `dispatch_async` 会 UI 卡顿 | 02 §7.2 |
| D8 | 引擎调用串行化：每会话对象一个私有串行 `dispatch_queue` | 同一 IInArchive 禁并发 + 非原子引用计数，对象生命周期须单线程化 | 02 §7.1 |
| D9 | 阻塞式回调（密码/覆盖/卷/内存）用信号量 + 主线程 sheet 桥接 | 协议本身同步阻塞，回调线程须等用户应答；`dispatch_sync(main)` 会死锁故用信号量 | 02 §7.3 |
| D10 | HRESULT→NSError 单一错误域 `com.7zip.SevenZipKit`，保留原始码 | 便于诊断回溯；`E_ABORT`=用户取消，取消靠返回码驱动不靠异常 | 01 §7、02 §4.0 |
| D11 | UI/Common、UI/Agent 由 xcode 工程直接引用上游路径源文件编译 | 随上游升版自动跟进，多数升版只需重放少量补丁 | 01 §4.1 |
| D12 | 全部 macOS 新增物隔离到顶层 `Mac/`，上游改动登记为可重放补丁 | 最小侵入上游、便于跟随官方升版（整包覆盖 + 人造 vendor 分支 SOP） | 01 §4、05 §11 |
| D13 | 大归档懒加载：峰值常驻 ≤ 600 MB / 100 万条目、每条目均摊 ≤ 512 字节 | 字符串/对象被 proxy 树 + 桥接 + ObjC 多层放大，须懒加载收敛并设可验收预算 | 01 §5.4、03 §5.6 |
| D14 | 性能验收前移：M1-T9、M2-T9 设里程碑出口 gate，不达标本里程碑内回炉 | 内存/延迟敏感的核心数据结构若推迟到 M5 验收，不达标返工面极大 | 05 §0.2、§3、§9.4 |
| D15 | 文件关联用 Info.plist 静态声明，系统公共类型一律 Viewer/Alternate，安装不静默抢占 | `Editor/Owner` 会改变用户既有双击行为（如 zip 不再用归档实用工具），属侵入副作用 | 04 §3.1 |
| D16 | Finder 右键主选 FinderSync Extension（+ App Intents 补、Services 兜底） | 唯一能在 Finder 提供动态、可级联、按选中内容显隐菜单的机制，最接近一对一 | 04 §3.2 |
| D17 | dylib 与 framework 都动态链接同一份系统 libc++，dylib 不导出任何 C++ 符号 | 两份 libc++ 会令跨边界虚调用/分配释放静默 UB；进 CI 硬闸门 | 01 §8.1.1 |
| D18 | 一对一基线与分期/裁剪登记表（05 §0.4）为唯一权威判定口径 | 凡注册表键/菜单已登记的一对一项不得以"开放问题"悄悄降级，须分类 + 验收硬标准 + 产品签字 | 05 §0.4 |

---

## 3. 六份文档阅读指南

| 文档 | 主题 | 读它当你要… | 关键锚点 |
|---|---|---|---|
| `01-architecture.md` | 总体架构、进程模型、仓库布局、数据流/线程/错误模型、构建体系、上游同步 | 建立全局心智模型、定边界与目录、理解为什么进程内化 + XPC 隔离 | §1 范围与不做项；§2 三层；§3 进程模型；§4 布局；§5 数据流；§6 线程；§8 构建 |
| `02-core-bridge.md` | lib7z.dylib 构建 + 19 个 C ABI + Agent 处置 + SevenZipKit ObjC API + 类型/内存/线程/取消 | 写桥接层代码、做 dylib 构建、查 PROPVARIANT/FILETIME/BSTR 转换、ABI 闸门 | §1 构建；§2 ABI；§3 Agent；§4 API 草案；§5 类型映射；§6 所有权；§7 线程取消；§8 M0 PoC |
| `03-feature-map-filemanager.md` | 7zFM 逐功能映射：六菜单/键表/13 专属对话框/设置 6 页/快捷键/特殊语义 | 实现 FM 壳、查某菜单命令/快捷键/对话框的 mac 落点与行为差异 | §1 主映射表；§2 对话框；§3 设置；§4 快捷键；§5 特殊语义；§6 工作量；§7 开放问题 |
| `04-feature-map-dialogs-finder.md` | 7zG 对话框（压缩/解压/覆盖/密码/进度/内存/Hash/基准）逐控件 + Finder 集成 + UTType | 实现压缩/解压对话框联动、进度窗、FinderSync、文件关联 | §1 压缩对话框；§2 解压/覆盖/密码/进度；§3 Finder 集成；§4 UTType；§5 能力差异；§6 取舍 |
| `05-roadmap-execution.md` | 里程碑/任务/验收/工作量/风险/测试/合规/上游 SOP | 排期、估工、查某任务验收标准、风险缓解、合规交付物 | §0.4 分期/裁剪登记表；§1-6 M0-M5；§7 工作量；§8 风险；§9 测试；§10 合规；§11 SOP |
| `06-adversarial-review-record.md` | 5 角色对抗评审存档：findings 全表 + 裁决 + 处置结果 + 遗留开放问题 | 了解每条设计结论被如何证伪/修正、查某 finding 落地到哪、看遗留待定项 | §1 方法；§2 裁决；§3 findings 全表；§4 遗留开放问题（O 系列 + Q 系列） |

**推荐路径**：新人 → `01`（全局）→ `02`（桥接核心，技术含量最高）→ `03`/`04`（功能映射，按你负责的子系统选）→ `05`（排期与验收）。评审/PM → `00`（本文）→ `05 §0.4` + `06`（决策与遗留）。

> 命名约定提示：各文档中 `01-filemanager-inventory.md`、`02-gui-dialogs-inventory.md`、`03-explorer-agent.md`、`04-core-dylib.md`、`05-platform-layer.md` 指 `docs/research/` 下的**研究底料**（已验证事实来源），与本套 `01`~`06` 方案文档是不同集合，引用时按"底料/research"理解。

---

## 4. 工作量与里程碑摘要

### 4.1 里程碑链

```
M0 dylib PoC + 桥接骨架      —— 加载链/ABI/universal/签名闭环
M1 桥接层 + 只读浏览         —— SevenZipKit 列表/属性 API + 单面板只读；出口 gate=列表/内存性能基线
M2 解压全功能                —— 解压/测试/密码/覆盖/进度/Finder 拖出；出口 gate=解压吞吐 + 主线程响应性
M3 压缩全功能                —— 压缩对话框 1:1 + 更新/分卷/SFX 取舍 + 归档内增删改
M4 7zFM 完整 1:1            —— 双面板/菜单/快捷键/选项 6 页/工具/历史收藏
M5 Finder 集成与打磨发布     —— Finder 扩展/文件关联/并发资源仲裁/性能收尾/公证发布/上游 SOP
```

### 4.2 工作量汇总（人日，净开发口径）

| 里程碑 | 内容 | 人日 |
|---|---|---|
| M0 | dylib PoC + 构建/签名闭环 | 10 |
| M1 | 桥接层 + 只读浏览（含 M1-T9 列表性能 gate） | 39 |
| M2 | 解压全功能（含 M2-T9 吞吐/响应性 gate） | 36 |
| M3 | 压缩全功能 | 33 |
| M4 | 7zFM 完整 1:1（单一最大块） | 63 |
| M5 | Finder 集成与打磨发布 | 38 |
| **净开发小计** | | **219** |
| 缓冲（评审/返工/集成/CI，30%） | | 66 |
| **总计（含缓冲）** | | **≈285 人日** |

**日历周期**：单人串行 ≈ 13-15 个月；双人（核心/桥接 + AppKit/UI，接口先行）≈ 7-8 个月。关键路径 M0→M1→M2→M3→M4；M5 Finder 扩展可在 M2 后并行。**B 计划闸门**在 M1-T3（Agent POSIX 可编译性硬验证，失败则桥接层改 IInArchive 直驱，≈ +10 人日）。

---

## 5. 风险 Top 5

> 全表见 `05 §8`（概率/影响：高/中/低）。下列为对发布影响最大者。

| ID | 风险 | 概率/影响 | 核心缓解 |
|---|---|---|---|
| R-AGENT | Agent 层 POSIX 移植失败（g_hInstance/MyLoadString、ZipRegistry 链接、CCodecIcons 资源） | 中 / 高 | B 计划：桥接层 IInArchive 直驱 + 自建轻量目录树；闸门设 M1-T3 越早越省（CommonUpdateOperation 重写 ≈ +10 人日） |
| R5 阻塞式回调死锁 | 密码/覆盖/内存回调在工作线程经信号量等主线程对话框，易死锁 | 中 / 高 | 统一同步回调注入点（block + `dispatch_semaphore`）；回调内绝不重入同一 archive；压测 100 次 |
| R-MOVEARC | 归档内更新回写损档（MoveToOriginal 跨卷/权限/quarantine、MoveArc 延迟 E_ABORT 未保真） | 中 / 高 | 中断协议在桥接保真；APFS/沙箱/TCC 下验证跨卷移动；更新前后 CRC 校验 |
| R-PERF | 性能不达标（NSString↔UString 转换热点、万级条目列表卡顿、未走汇编/HW intrinsics） | 中 / 中 | dylib 已含 LzmaDecOpt.S + SHA/AES intrinsics；列表虚拟化 + 惰性物化；**M1-T9/M2-T9 各设 perf gate**，不达标本里程碑回炉 |
| R6 进程内化共享态污染 + 并发资源超订 | 全局态并发踩踏；N 任务 ×mt 线程超订、N 份字典内存叠加触顶 | 中 / 中 | per-operation context；后台改 thread QoS；M5-T4 `SZTaskScheduler` 全局限流（总线程 ≤ 物理核、总字典内存 ≤ RAM 上限） |

> 次级但需盯：R-WCHAR（mac wchar_t=4B/UTF-32 编码坑）、R-NFD（NFC/NFD 失配）、R-COM-ABI（IUnknown 虚析构双侧一致 + GetModuleProp 闸门）、R-RAR（unRAR 收费分发限制）、R-FINDER（FinderSync 沙箱/生命周期/卷注册）、R-SCHEDULE（M4 体量 63 人日单块）。

---

## 6. 开放问题清单

> 完整登记见 `06 §4`（O-01~O-30 + Q1~Q8）与各章末"开放问题"。下列按性质分组给状态。

**已定案/已分类（不再悬置，仅留签字或取舍）**：
- **dylib 命名（O-01）**：= `lib7z.dylib` + 软链 `7z.so`（01 §3.3 / 02 §1.2 统一）。
- **列配置格式 OQ-1（O-16）**：= 首版即结构化 plist（弃 blob，05 §4.2 为准），属实现细节非功能降级。
- **四视图模式 OQ-3（O-18）**：【分期·一对一范围内】M4 = Details+Large Icons、List/Small 目标 v1.1；**需产品签字**是否允许 View 菜单项分期，未签字前从严四档全进 M4。
- **备选选择模式 OQ-5（O-20）**：【分期·一对一范围内】M4 = 标准多选 + 保留 `AlternativeSelection` 键、FAR 交互 v1.1；**需产品签字**分期 vs 裁剪。
- **Return 键二义 OQ-2（O-17）**：默认 Return=Open（一对一）；仅当产品贴 Finder 改 Rename 时为范围变更。
- **地址栏控件 OQ-8（O-23）**：已定案自建 `SZAddressBar`（面包屑分段展示态可分期至 v1.1，工作量 L）。
- **崩溃隔离 XPC（O-26）**：已升为明确决策（不受信/疑损坏/>50GB 或 >100k 文件走子进程）。

**待产品/UX 决策（功能范围/裁剪）**：SFX 形态（Q3/O-27）、Email 命令族（Q4/O-28）、Cmd+V 粘贴文件进归档（O-21）、ShowSystemMenu 语义（O-22）、CVirtFileSystem 内存优化是否移植（O-19）、本地化体系 Lang/*.txt vs NSLocalizedString（O-24）、操作中心汇总面板（O-25）、QuickLook 扩展（O-29）、AppleScript .sdef（O-30）。

**待工程/实测定案（构建/桥接/平台）**：EXPORTS_LIST 相对路径解析（O-03）、exported_symbols_list × dead_strip 交互（O-04，M0 由 AC-1 闭环）、x64 切片汇编（O-05）、SetCodecs(NULL) 卸载链路（O-06）、引用计数原子化（O-07）、NFC/NFD 规范化落点（O-08/O-09）、FILETIME 精度字段保真（O-10）、Finder↔主 App 通信机制（O-11）、quarantine API 与三档映射（O-13/O-14）、FinderSync 兜底降级（O-15）。

**待法务/基础设施（Q 系列）**：Developer ID 证书归属（Q1）、macOS CI（Q2）、LGPL §6 重链接路径选型（Q5，默认随包 .o/.a + 链接命令）、产品命名与商标（Q6，M5-T8 交付物）、App Store/沙盒优先级（Q7，+15-20 人日）、Windows 逐项对照基准来源（Q8）。
