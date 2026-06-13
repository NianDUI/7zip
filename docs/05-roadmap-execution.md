# 05 路线图与执行计划

> 7-Zip Windows GUI 一对一移植 macOS（方案B：核心 dylib + ObjC++ 桥接 + AppKit）的落地执行章。
> 本章把前四章（见 `01-architecture.md` / `02-core-bridge.md` / `03-feature-map-filemanager.md` / `04-feature-map-dialogs-finder.md`）的设计结论拆解为可照着开工的里程碑、任务、验收标准、风险与测试合规清单。
> 基线：仓库 main @ 8c63d71（26.01）。证据格式 `文件路径:行号`（相对仓库根 `/Users/lyd/WorkSpace/MyProjects/7zip`）。
> 估算单位：人日（1 人日 = 1 个熟练 C++/ObjC++/AppKit 工程师 1 个工作日）。所有估算为净开发，不含评审与等待。

---

## 0. 执行总览

### 0.1 三层目标产物（与设计公约一致）

| 层 | 产物 | 形态 | 来源 |
|---|---|---|---|
| 核心库 | `lib7z.dylib`（+ 兼容软链 `7z.so → lib7z.dylib`，命名已定案见 `02-core-bridge.md` §1.2 / `01-architecture.md` §3.3，落地见 §1 M0-T3） | Mach-O DYLIB，COM 风格 C 导出（19 个 C ABI 入口） | `CPP/7zip/Bundles/Format7zF` 现有 makefile 直接产出，已本机实测通过（见 `02-core-bridge.md`） |
| 桥接层 | `SevenZipKit.framework` | Objective-C++，对 Swift/ObjC 暴露归档浏览/解压/压缩/哈希 API | 新写；内部链接 UI/Common + UI/Agent（POSIX 可编译子集） |
| 应用 | `SevenZipFM.app` | AppKit 为主，含 7zFM 全功能 + 7zG 全对话框 + Finder 扩展 | 新写 UI 壳，复用 PanelModel/命令模型/Agent 逻辑 |

目标：macOS 13.0+，universal（arm64 + x86_64），Developer ID 签名 + 公证为分发主线。

### 0.2 里程碑链（粗粒度）

```
M0 dylib PoC + 桥接骨架       —— 证明加载链、ABI、universal、签名闭环
M1 桥接层 + 只读浏览           —— SevenZipKit 列表/属性 API + 单面板只读浏览；【出口 gate：列表/内存性能基线 M1-T9】
M2 解压全功能                  —— 解压/测试/密码/覆盖/进度/Finder 拖出，对照 7zz；【出口 gate：解压吞吐 + 主线程响应性 M2-T9】
M3 压缩全功能                  —— 压缩对话框 1:1 + 更新/分卷/SFX 取舍 + 归档内增删改
M4 7zFM 完整 1:1              —— 双面板/菜单/快捷键/选项 6 页/工具/历史收藏，行为对齐 Windows 版
M5 Finder 集成与打磨发布       —— Finder 扩展、文件关联、并发资源仲裁 + 性能收尾、公证发布、上游同步 SOP 落地
```

每个里程碑都以"可演示且可回归"为出口标准；M2 起每个里程碑都附带样本归档回归集（见 §4.2）。**M1、M2 额外设性能出口 gate**（列表/内存基线、解压吞吐/响应性），不达标不进下一里程碑——性能验收不再全部推迟到 M5（见 §3 R-PERF、§9.4）。

### 0.3 关键路径与并行性

- **关键路径**：M0 → M1（桥接 ABI 与 PanelModel 抽取）→ M2（解压回调链 + 阻塞式 UI 桥接）→ M3（压缩参数模型）→ M4（FM 壳）。M5 的 Finder 扩展可在 M2 完成后并行起步。
- **可提前并行**：ZipRegistry 的 plist 后端（M1 起即阻塞多处，应作为 M1 第一批）、Lang/*.txt 本地化体系移植（任意时刻可做）、样本归档测试集准备（M0 即可启动）。
- **B 计划触发点**：M1 末尾对 Agent 层 POSIX 可编译性做一次硬验证（见 §3 风险 R-AGENT），若失败立即切到 B 计划（桥接层不复用 Agent，改用 IInArchive 直驱），影响 M1-M2 排期。

### 0.4 一对一基线与分期/裁剪登记表（验收硬标准）

> **目的（回应功能完整性审查）**：凡注册表键/菜单项已登记的"一对一"功能，**不得以"开放问题/建议后置"形式悄悄降级而无验收硬标准**。本表是唯一权威登记：每个"分期/后置/裁剪"项必须明确归为下列两类之一，并给目标版本或裁剪理由；属一对一硬基线的项是否允许分期，须**产品签字**后写入对应里程碑验收清单。各 OQ 详述见对应 feature-map 文档，本表为汇总判定口径。
>
> 分类定义：
> - **【分期】= 一对一范围内但分期实现**：最终必须补齐，给出目标版本（如 v1.1）；首版交付"最小一对一基线"，分期部分进"已知分期缺口"清单。
> - **【裁剪】= 明确裁剪**：给替代方案或砍除理由（多为 Windows 专属无 mac 等价语义，见 `01-architecture.md` §1.2 不做项）。

| 项（登记来源） | 分类 | 最小一对一基线（首版必达） | 分期目标版本 / 裁剪理由 | 验收落点 | 需产品签字 |
|---|---|---|---|---|---|
| 四视图模式 Large/Small Icons/List/Details（View 菜单 IDM_700-703，resource.rc:97-100 / Panel.cpp:871-892；OQ-3） | **分期** | M4：Details + Large Icons 两档可用、行为对齐 Windows | v1.1：补 List + Small Icons（四档齐全 + Cmd+1..4 全映射 + ListMode 持久化） | M4 出口 + v1.1 出口 | **是**（"一对一硬标准是否允许 View 菜单项分期"；若否则四档全进 M4，+≈3 人日） |
| 备选选择模式 _mySelectMode / AlternativeSelection（Settings 页键，App.cpp:98-108；OQ-5） | **分期** | M4：标准多选 + 保留 `FM.AlternativeSelection` 键（可持久化） | v1.1：勾选后 FAR 式 Ins/Shift/方向标记选择生效 | M4 出口 + v1.1 出口 | **是**（默认分期；若产品认定可裁剪须给替代=键保留但 UI 隐藏并提示，记为范围变更） |
| 列配置持久化格式（FM\Columns blob，OQ-1） | 实现细节（非分期/非裁剪） | M4：列显隐/宽度/排序键持久化（结构化 plist，弃 blob） | 功能首版即全交付；blob 导入兼容列为增强 | M4-T4 | 否（工程定，不涉一对一降级） |
| CVirtFileSystem 内存优化（小文件入内存阈值，OQ-4） | **分期** | M4：归档内打开/编辑回写功能可用（首版可一律落盘临时文件） | 后续版本：补内存优化（性能项，非功能项） | M4-T7 | 否（性能优化，功能不降级） |
| Cmd+V 粘贴文件进归档（OQ-6） | **裁剪**（超出一对一） | — | Windows EditPaste 为空实现，mac 不做即与 Windows 一致；启用属增强 | — | 否 |
| ShowSystemMenu 系统 Shell 菜单注入（OQ-7） | **裁剪 + 替代** | 设置键保留 | mac 无 IShellFolder/IContextMenu；替代="右键含'在访达中显示'"开关（§1.8） | M4-T2 | 是（键语义改写 vs 移除） |
| 地址栏面包屑分段展示（OQ-8） | **分期**（已定案自建 `SZAddressBar`） | M4：可编辑地址栏 + 历史/固定项可用（首版降级可接受纯 NSComboBox 无分段） | v1.1：面包屑分段展示态 | M4-T10 | 否（已定案，降级标注为已知 UX 缺口） |
| Return 键二义 Open vs Rename（OQ-2） | 已定案=Open（一对一） | Return=Open，Rename 走 F2 / Cmd+Return | — | M4-T3 | 是（仅当产品要贴 Finder 改 Return=Rename 时为范围变更） |
| SFX 自解压（OQ-Q3/05、04 §6） | **裁剪**（含决策项） | 压缩对话框 SFX 复选隐藏 | mac 无 PE `7z.sfx` 模块；是否生成 .exe SFX 供 Windows 用户为决策项 Q3 | M3-T6 | 是（Q3） |
| Email/分享系列（MAPI，04 §3.5、Q4） | **裁剪 + 替代** | — | mac 无 MAPI；替代 NSSharingService，v1 可裁剪 | M5-T2 | 是（Q4） |
| ADS/NtSecurity/Net/LargePages/Junction-WSL（`01-architecture.md` §1.2） | **裁剪** | UI 上隐藏无意义复选/菜单项 | Windows 专属、无 mac 等价语义（理由见 01 §1.2 不做项表） | 各里程碑 | 否（已定不做） |

> **"已知分期缺口"清单**：上表所有【分期】项构成首版发布说明的"已知分期缺口"小节（标注"一对一范围内、目标版本 vX 补齐"），评审据此判定首版是否达到"最小一对一基线"。**【分期】项中标"需产品签字=是"者，未签字前按"最小一对一基线必须全进首版"从严执行**（即四视图四档、AlternativeSelection FAR 交互默认进 M4），避免以"建议"留白导致评审无法判定完整性。

---

## 1. 里程碑 M0：dylib PoC 与构建/签名闭环

**目标**：把"核心引擎可在 macOS 以 dylib 形态加载并完成 roundtrip"从实测脚本固化为可重复的工程构建；建立 universal + 签名 + 公证的完整管线骨架；产出桥接层最小可调用入口。出口：一条命令产出已签名的 universal `lib7z.dylib`，一个最小 XCTest 用例 dlopen 它并完成压缩/解压 roundtrip。

| # | 任务 | 涉及文件/模块 | 前置依赖 | 验收标准 | 估算 |
|---|---|---|---|---|---|
| M0-T1 | 固化 dylib 构建脚本：arm64 + x64 两切片 + `lipo` 合 universal | `CPP/7zip/Bundles/Format7zF/makefile.gcc`、`CPP/7zip/cmpl_mac_arm64.mak`、新增 `cmpl_mac_x64.mak` 调用（已存在 `var_mac_x64.mak`） | 无 | `make` 产出 `b/m_arm64/7z.so` 与 `b/m_x64/7z.so`，`lipo -create` 出 universal，`lipo -info` 显示两架构；`file` 判定 Mach-O DYLIB | 1.5 |
| M0-T2 | 链接加固片段：`-install_name @rpath/...`、`-exported_symbols_list`（仅 19 个 C 入口，见 `02-core-bridge.md` §1）、`-compatibility_version/-current_version`、可选 `-dead_strip` | 新增 `CPP/7zip/var_mac_arm64_dylib.mak` 或挂 `LDFLAGS_STATIC_3`（`CPP/7zip/7zip_gcc.mak:88` 为零侵入挂接点）；新增 `exports7z.txt` | M0-T1 | `nm -gU` 仅导出 19 个带下划线前缀的 C 符号（`_CreateObject` 等）；`otool -D` install_name 为 `@rpath/...` | 1.5 |
| M0-T3 | 命名决策落地（已定案=`lib7z.dylib` + 兼容软链 `7z.so → lib7z.dylib`，见 `02-core-bridge.md` §1.2）：产物 `lib7z.dylib`，构建脚本 `ln -sf lib7z.dylib 7z.so` 建软链使复用 `LoadCodecs.cpp:72-77` 的 `kMainDll="7z.so"` 路径零改动命中；备选（不带软链）才改 `kMainDll` 一行 | `CPP/7zip/UI/Common/LoadCodecs.cpp:72-77`、构建脚本 | M0-T1 | `lib7z.dylib` + `7z.so` 软链均在 Frameworks 内；桥接层 dlopen `lib7z.dylib` 与 LoadCodecs 经软链加载均通过 | 0.5 |
| M0-T4 | 签名 + 公证管线骨架：`codesign --options runtime`、`notarytool submit`、`stapler` | 新增 `scripts/sign_notarize.sh`；Developer ID 证书（开放问题 Q1） | M0-T2 | hardened runtime 下签名 dylib 可被另一进程 dlopen；公证流程跑通一次（可用占位 app） | 2 |
| M0-T5 | SevenZipKit.framework 骨架 target：Xcode 工程 + 一个 ObjC++ 文件 dlopen dylib，封 `CreateObject`/`Open`/`GetNumberOfItems` | 新增 `SevenZipKit/`（`.mm`）；引擎自带编译源码集（见 `02-core-bridge.md` §3.5：MyWindows/FileStreams/PropVariant/MyString/StringConvert/UTFConvert/DLL/Alloc/TimeUtils 等） | M0-T2 | framework 编译通过并链接进 XCTest target | 2.5 |
| M0-T6 | M0 验收 XCTest：bundle 内定位 dylib（`GetModuleDirPrefix` 走 NSBundle.Frameworks，见 `05-platform-layer.md` §6）→ 压缩 2 文件成 .7z → 列表 → 解压 → 断言一致 | M0-T5 + 新增 `GetModuleDirPrefix` 的 NSBundle 实现（替代 `ArchiveCommandLine.cpp:1875-1900` 的 argv[0] 方案） | M0-T5 | XCTest 绿；CI（开放问题 Q2）可跑 | 2 |

**M0 小计：10 人日。**

> M0 输出的"引擎自带编译源码集 + NSBundle 版 GetModuleDirPrefix + plist 后端接口位"是后续所有里程碑的地基。`GetModuleDirPrefix` 必须在桥接层早期调用，否则 LoadCodecs 回落 `./` 找不到 dylib（`05-platform-layer.md` §3.3、风险表）。

---

## 2. 里程碑 M1：桥接层 API 与只读浏览

**目标**：SevenZipKit 暴露归档浏览（列表/属性/导航/嵌套归档）与文件系统浏览的只读 API；AppKit 单面板能浏览 .7z/.zip/.rar 等归档与本地目录（NSTableView/NSOutlineView）；完成 PanelModel 抽取与 ZipRegistry→plist 后端；**对 Agent 层 POSIX 可编译性做硬验证**（B 计划闸门）。出口：双击归档在 app 内打开并逐层浏览，列排序/选择可用，设置可持久化；**性能 gate（M1-T9）：万级条目列表滚动 60fps + 100 万条目内存峰值基线达标 + CI 性能回归基线建立**，不达标不进 M2。

| # | 任务 | 涉及文件/模块 | 前置依赖 | 验收标准 | 估算 |
|---|---|---|---|---|---|
| M1-T1 | **ZipRegistry plist 后端**（阻塞级，优先）：保留 `NExtract::CInfo/NCompression::CInfo/NWorkDir::CInfo/CContextMenuInfo` 接口，`.cpp` 重写为 NSUserDefaults（域 `com.7zip.SevenZipFM`），含 `RecurseDeleteKey`=按前缀删 | 新写 `ZipRegistry_mac.mm`（替 `UI/Common/ZipRegistry.cpp`）；键映射表见 `05-platform-layer.md` §4.2 | M0 | 6 个文件（grep `HKEY_` 实测）调用方零改动编译链接通过；CBoolPair 三态（键不存在=未定义）语义保留 | 5 |
| M1-T2 | **Registry CKey 适配**（可选过渡层）：把 `HKEY_CURRENT_USER + "Software/7-Zip/..."` 键路径转 defaults 前缀，使 ViewSettings/ZipRegistry 先零改动跑通 | 新写 `Registry_mac.mm`（替 `CPP/Windows/Registry.cpp`） | M0 | ViewSettings.cpp 二进制 blob（Position/Panels/Columns）能读写（NSData 映射） | 2 |
| M1-T3 | **Agent 7 个 .cpp POSIX 编译验证**（B 计划闸门）：把 Agent.o/AgentProxy.o/AgentOut.o/ArchiveFolder.o/ArchiveFolderOut.o/ArchiveFolderOpen.o/UpdateCallbackAgent.o 加入桥接 target | `CPP/7zip/UI/Agent/*`；规则已存在 `7zip_gcc.mak:933-945`；处理 ArchiveFolderOpen 的 `g_hInstance/MyLoadString`（`03-explorer-agent.md` §3.1） | M0 | 7 个 .o 编译链接通过；`CArchiveFolderManager::OpenFolderFile` 能打开归档返回 IFolderFolder。**失败则触发 §3 R-AGENT B 计划** | 4 |
| M1-T4 | **CCodecIcons / 扩展名图标表去 Win 化**：`ArchiveFolderOpen.cpp:13-80` 读 PE 资源 ID=100 的"ext:iconIndex"表 → 改静态表/plist；`GetIconPath` → UTType/AssetCatalog | `CPP/7zip/UI/Agent/ArchiveFolderOpen.cpp`、`FilePlugins.cpp` | M1-T3 | 各格式扩展名→图标映射可用，不依赖 PE 资源 | 3 |
| M1-T5 | **SevenZipKit 浏览 API**：`SZArchive`（持 `CMyComPtr<IInArchive>` + 串行 dispatch queue，见 `02-core-bridge.md` §6）、`SZItem`（属性懒取）、嵌套归档导航；NSString↔UString 经 UTF-8、NSDate↔FILETIME 经 TimeUtils（保留 wReserved 精度字段） | 新写 framework 头与实现；所有权协议见 `02-core-bridge.md` §2.4 | M1-T3 | XCTest 打开归档枚举条目、读 kpidPath/Size/MTime/IsDir/Attrib、绑定子目录、读归档级属性（含错误旗标） | 6 |
| M1-T6 | **PanelModel 抽取**：`_folder/_parentFolders/_selectedStatusVector/_columns/_sortID/_flatMode` + BindToPath/排序比较器/选择集（`03-feature-map-filemanager.md` §4.2-4.4 对应 PanelSort/PanelSelect/PanelItems 逻辑部分） | 复用 `UI/FileManager/Panel*.cpp` 纯逻辑部分；剥离 ListView 调用点 | M1-T5 | 排序（目录恒在文件前、Size 首次降序等）、列持久化、选择集逻辑通过单测 | 5 |
| M1-T7 | **AppKit 单面板只读壳**：NSTableView（view-based 虚拟模式，dataSource = PanelModel）、多列 sortDescriptors、地址栏面包屑、状态栏（4 格信息）、系统图标（NSWorkspace iconForFile）；目录监视抽象 IDirWatcher + FSEvents 实现（替 `CFindChangeNotification`，FSFolder.h:141 类型成员，见 `05-platform-layer.md` §5.10） | 新写 AppKit；`RootFolder.cpp` 非 Win 分支（Computer→"/"）、FSFolder 枚举/属性（已有 ifdef） | M1-T6 | 浏览本地目录与归档，列点击排序、双击进目录、Backspace 上级、Enter 打开归档；1s 自动刷新 | 8 |
| M1-T8 | NFC/NFD 规范化桥接（无现成代码，新增）：入档 NFC、磁盘比较双向规范化（`05-platform-layer.md` §5.3） | 新增桥接工具；影响更新/覆盖检测与 wildcard | M1-T5 | 含变音符/中文/韩文 NFD 磁盘名与 NFC 档内名比较不失配（专项用例） | 3 |
| M1-T9 | **列表性能 gate（M1 出口闸门，前移自原 M5-T6）**：用 §9.2 大条目数样本（10 万 + 100 万条目）测 NSTableView 虚拟模式 + PanelModel + proxy 树构建：归档打开延迟、滚动帧率、内存峰值；建立 §9.4 性能 CI 回归基线（基线在 M1 末确立，非 M5）。**不达标即在 M1 内回炉 SZItem 懒取/PanelModel 数据结构，不带病进 M2** | §9.4 指标；§9.2 大条目数样本；`SZItem` 属性懒取策略（M1-T5）、PanelModel（M1-T6） | M1-T7 | 万级条目列表滚动 ≥ 60fps 不掉帧；100 万条目内存峰值记录基线且无失控增长；归档打开延迟达 §9.4 达标线；基线写入 CI 性能回归（阈值告警） | 3 |

**M1 小计：39 人日。**

> **M1 出口闸门（gate）**：除功能出口外，M1-T9 的列表性能基线（帧率 + 内存峰值 + 打开延迟）必须达 §9.4 达标线方可进 M2。**理由**：万级条目虚拟化（M1-T7）与 `SZItem` 一次性/懒取属性模型（M1-T5）是内存/延迟敏感的核心数据结构，若推迟到 M5 才验收，不达标将回炉 M1-M2 核心结构、返工面极大（见 §3 R-PERF）。

---

## 3. 里程碑 M2：解压全功能

**目标**：解压/测试全链路对齐 7zz 与 Windows 7zG 行为：路径模式/覆盖模式/密码/分卷/内存限额/进度/错误聚合；阻塞式回调（密码/覆盖/内存）经信号量桥接主线程对话框；Finder 拖出（file promise 延迟解压）。出口：对照样本归档回归集（§4.2）解压结果与 7zz 字节一致，全部对话框 1:1；**性能 gate（M2-T9）：解压吞吐 ≥ 7zz 90% + 进度刷新期间主线程响应性达标**，不达标不进 M3。

| # | 任务 | 涉及文件/模块 | 前置依赖 | 验收标准 | 估算 |
|---|---|---|---|---|---|
| M2-T1 | **解压回调链桥接**：`CArchiveExtractCallback`（已随 7zz 验证，A 类）+ `CExtractCallbackImp` 等价物；进度回调跨线程 hop 主队列（实证进度可发生在 worker 线程，见 `02-core-bridge.md` §5）；回调内禁止重入同一 archive | `UI/Common/Extract.cpp/ArchiveExtractCallback.cpp`；回调时序见 `02-core-bridge.md` §4.2 | M1 | 解压单/多条目到目标目录，进度刷新不崩；E_ABORT=用户取消静默 | 5 |
| M2-T2 | **阻塞式子对话框桥接**（高风险，见 §3 R5）：密码（CryptoGetTextPassword）、覆盖（AskOverwrite）、内存限额（IArchiveRequestMemoryUseCallback）回调里 `dispatch` 主线程对话框 + `dispatch_semaphore` 回传，保持"工作线程阻塞等答案"语义 | `FileManager/ExtractCallback.cpp:201-232`（覆盖）、密码框、`MemDialog`；阻塞协议本质同步（`02-core-bridge.md` §5） | M2-T1 | 加密归档弹密码框、目标存在弹覆盖框（Yes/No/All/AutoRename/Cancel 全档）、超限弹内存框；无死锁（压测 100 次） | 6 |
| M2-T3 | **解压对话框 CExtractDialog 1:1**：目标目录（历史≤16）、路径模式（Full/No/Abs，**无 Relative**）、覆盖模式（Ask/Overwrite/Skip/Rename/RenameExisting）、ElimDup、密码、SplitDest 子目录名；字段→`CExtractOptions` 映射 | `UI/GUI/ExtractDialog.cpp`（`04-feature-map-dialogs-finder.md` §3）；NtSecurity 复选隐藏（mac 无意义） | M2-T2 | 控件与映射逐项对齐；注册表偏好双源合并（命令行 vs plist）保留 | 4 |
| M2-T4 | **主进度对话框 ProgressDialog2 1:1**：9 项统计（Elapsed/Remaining/Files/Errors/Total/Speed/Processed/Packed/Ratio）+ 状态行 + 文件名 + 进度条 + 错误列表；Background（→thread QoS，不降整个 app，见 §3 R6）、Pause（暂停计时结转）、Cancel（先暂停再确认）；CProgressSync 经 NSTimer 拉取 | `FileManager/ProgressDialog2.cpp`（`04-feature-map-dialogs-finder.md` §4） | M2-T1 | 统计值、暂停/后台/取消行为、错误聚合、标题百分比对齐；ITaskbarList3→NSProgress 暴露 dock | 6 |
| M2-T5 | **多档案解压编排 + 测试模式**：`Extract()` 统计/跳过/错误聚合；测试模式（testMode）"There are no errors"结果；OpenResult 诊断文案（无法打开/加密/偏移） | `UI/Common/Extract.cpp`、`UpdateCallbackGUI.cpp` 文案表 | M2-T1 | 多归档批量解压；损坏归档报 DataError/CRC/UnexpectedEnd 等正确文案 | 3 |
| M2-T6 | **Finder 拖出（延迟解压）**：归档源拖出用 `NSFilePromiseProvider`（映射"延迟解压"语义，替 OLE HDROP + 7zE 临时目录，`03-feature-map-filemanager.md` §6 拖拽源、§9.3） | 新写 AppKit 拖拽源；`CAgentFolder::Extract`（Agent.cpp:1456-1567） | M2-T1 | 从归档拖文件到 Finder 触发解压并落盘正确 | 4 |
| M2-T7 | **quarantine 写入**：GUI 解压网络来源档案写 `com.apple.quarantine`（对应 Windows WriteZoneIdExtract，`05-platform-layer.md` §5.8；新增桥接工作项） | 新增桥接；`qtn_file_*` 或 NSURL quarantinePropertiesKey | M2-T1 | 解压可执行文件带 quarantine，Gatekeeper 行为符合预期 | 2 |
| M2-T8 | M2 回归：样本归档集（§4.2）解压对照 7zz | §4.2 样本集 + §4 测试框架 | M2-T1..T7 | 全格式/加密/分卷解压字节级一致；路径穿越样本被净化（`ExtractingFilePath` 的 Correct_FsPath，A 类） | 3 |
| M2-T9 | **解压吞吐 + 主线程响应性 gate（M2 出口闸门，前移自原 M5-T6）**：用 §9.2 大 7z/zip（LZMA2）样本测解压吞吐对照本机 7zz CLI；进度刷新（CProgressSync NSTimer 拉取，M2-T4）期间主线程响应性（UI 不卡顿）；NSString↔UString 转换热点 profile。**不达标即在 M2 内修桥接转换/进度刷新模型，不带病进 M3** | §9.4 指标；§9.2 大样本；进度刷新模型（M2-T4）、回调链桥接（M2-T1） | M2-T1..T4 | 解压吞吐 ≥ 7zz CLI 的 90%；进度刷新期间主线程无可感卡顿（无掉帧/无 spinner）；转换热点已 profile，无明显瓶颈；纳入 M1 末建立的 CI 性能回归 | 3 |

**M2 小计：36 人日。**

> **M2 出口闸门（gate）**：除功能出口外，M2-T9 的解压吞吐（≥7zz 90%）与进度刷新期间主线程响应性必须达标方可进 M3。**理由**：进度回调模型（M2-T1/T4）与桥接转换热点在 M2 即固化，推迟到 M5 验收将回炉回调链与进度刷新结构（见 §3 R-PERF）。

---

## 4. 里程碑 M3：压缩全功能

**目标**：压缩对话框（含二级选项对话框）1:1，全部 auto 档/内存估算算法平移；更新/分卷/SFX 取舍；归档内增删改（Agent 更新事务）。出口：压缩参数与 Windows 7zG 产出等价，归档内 CRUD 可用。

| # | 任务 | 涉及文件/模块 | 前置依赖 | 验收标准 | 估算 |
|---|---|---|---|---|---|
| M3-T1 | **ParamsModel 抽取**（纯算法，无 UI）：g_Formats 能力表、所有 auto 档（LZMA/LZMA2 字典/Order/Solid 块/线程上限/MemUse 档位）、内存估算 `GetMemoryUsage_*`、SetOutProperties 属性合成 | `UI/GUI/CompressDialog.cpp:271-356`（能力表）、`:1859-3068`（算法）、`UpdateGUI.cpp` 映射表（`04-feature-map-dialogs-finder.md` §2.3/2.6） | M1 | 给定格式/等级/方法，模型输出的字典/线程/内存档位与 Windows 版逐项一致（对照单测） | 6 |
| M3-T2 | **压缩对话框 CCompressDialog 1:1**：档案名/格式/等级/方法/字典/Order/Solid/线程/内存/分卷/参数/更新模式/路径模式/SFX/密码/加密算法/加密文件名；CBN_SELCHANGE 联动矩阵照表回放（`04-feature-map-dialogs-finder.md` §2.3） | `UI/GUI/CompressDialog.cpp`（3821 行）；BrowseDialog→NSSavePanel allowedContentTypes + 格式过滤器（§3 R11） | M3-T1 | 全控件 + 联动链 1:1；OnOK 校验顺序（密码 ASCII/长度/一致/内存超限/路径/分卷确认）保留 | 8 |
| M3-T3 | **二级选项对话框 COptionsDialog**：NTFS 组（按 Supported 显隐，mac 隐藏 NtSecurity/AltStreams）、PreserveATime、时间精度 Combo + 4 组 set 复选对（MTime/CTime/ATime/ZTime，CBoolBox 双复选模型） | `CompressDialog.cpp:3397-3816`；SymLinks/HardLinks 在 POSIX 原生支持，暴露开关 | M3-T2 | 时间组写回 CFormatOptions；tar GNU/POSIX、zip 精度限制保留 | 3 |
| M3-T4 | **压缩/更新执行链桥接**：`UpdateArchive()`（A 类）+ `CUpdateCallbackGUI`/`CUpdateCallbackGUI2` 等价物；进度/密码（ShowAskPasswordDialog）/扫描错误回调 | `UI/Common/Update.cpp`、`UI/GUI/UpdateGUI.cpp/UpdateCallbackGUI.cpp` | M3-T1, M2-T4 | 压缩多文件成各格式归档；更新模式 Add/Update/Fresh/Sync 正确 | 5 |
| M3-T5 | **归档内增删改（Agent 更新事务）**：`CommonUpdateOperation`（临时文件 + SFX 头拷贝 + CTailOutStream + MoveToOriginal + ReOpen 恢复位置）；Delete/Rename/CreateFolder/Comment(zip)/CopyFrom/CopyFromFile；MoveArc 中断协议（延迟 E_ABORT 防损档，见 §3 R-MOVEARC） | `UI/Agent/ArchiveFolderOut.cpp/AgentOut.cpp`（`03-explorer-agent.md` §2.6）；WorkDir 逻辑（B 类，依赖 plist 后端） | M3-T4, M1-T1 | 归档内增删改改名注释回写正确；CanUpdate 判定（多层嵌套/尾部垃圾/只读=禁用）如实呈现禁用态 | 5 |
| M3-T6 | **分卷拆分/合并 + SFX 取舍**：Split（卷大小序列、≥100 卷确认）/Combine（自动探测 .001 序列）；SFX 决策（mac 上 .exe SFX 无意义，开放问题 Q3） | `FileManager/PanelSplitFile.cpp`；SFX `UpdateGUI.cpp:516-565` | M3-T4 | 分卷压缩/合并 roundtrip；SFX 取舍写入文档 | 3 |
| M3-T7 | M3 回归：压缩产出对照 + 归档内 CRUD 回归 | §4.2 样本集 | M3-T1..T6 | 同参数压缩产出可被 7zz 解压且与 Windows 版属性一致；CRUD 后归档完整 | 3 |

**M3 小计：33 人日。**

---

## 5. 里程碑 M4：7zFM 完整 1:1

**目标**：7zFM 全部菜单/对话框/快捷键/双面板/选项 6 页/内嵌工具/历史收藏，行为对齐 Windows 版。出口：FM 全功能可用，菜单命令与快捷键逐条对照通过。

| # | 任务 | 涉及文件/模块 | 前置依赖 | 验收标准 | 估算 |
|---|---|---|---|---|---|
| M4-T1 | **双面板布局 + 主窗骨架**：NSSplitView 两面板、F9 切换、Tab 焦点、窗口标题=焦点面板路径、状态保存/恢复（NSWindow setFrameAutosaveName） | `FileManager/FM.cpp/App.cpp`（`03-feature-map-filemanager.md` §0.1/§4.5） | M1-T7 | 双面板/F9/Tab/标题/启动恢复路径对齐 | 5 |
| M4-T2 | **菜单系统 1:1**：File/Edit/View/Favorites/Tools/Help 全部命令 ID→动作映射（NSMenu）；动态 File 菜单（按上下文重建）、CRC 子菜单、时间戳精度子菜单（5 级+UTC）、Favorites 动态书签 | `FileManager/MyLoadMenu.cpp`、resource.rc 菜单（`03-feature-map-filemanager.md` §1.1） | M4-T1 | 全菜单项逐条对照（§4 UI 自动化清单） | 6 |
| M4-T3 | **快捷键全表**：菜单加速键 + 面板级键盘命令（PanelKey.cpp 全表）；Win VK 键→macOS keyEquivalent 表驱动映射（含 Alt/Ctrl/Shift 组合、小键盘 +-*、Alt+数字书签） | `FileManager/PanelKey.cpp:39-357`（`03-feature-map-filemanager.md` §1.2） | M4-T2 | 快捷键逐条对照表通过；冲突项（如 Ctrl+A vs macOS 习惯）决策记录 | 5 |
| M4-T4 | **选择/排序/列模型 UI 化**：标准多选（M4 交付）+ 保留 `FM.AlternativeSelection` 设置键（FAR 式交互分期至 v1.1，见 `03-feature-map-filemanager.md` OQ-5）；列头拖动重排、列显示菜单、列持久化（弃二进制 blob 改结构化 plist 或 NSTableView autosave，定案见 OQ-1） | PanelSelect/PanelSort/PanelItems UI 壳；PanelModel（M1-T6） | M4-T1 | 标准多选 + 排序 + 列配置对齐；`AlternativeSelection` 键持久化（FAR 交互留 v1.1） | 5 |
| M4-T5 | **选项对话框 6 页**：System（文件关联→LaunchServices/UTType，C 类重设计）、7-Zip/Menu（→Finder 扩展开关）、Folders（工作目录）、Editor（外部程序）、Settings（9 项，LargePages 隐藏）、Language（扫 Lang/*.txt）；NSTabViewController/Preferences 窗口 | `FileManager/OptionsDialog.cpp` + 6 个 Page（`03-feature-map-filemanager.md` §3） | M4-T2, M1-T1 | 6 页设置读写 plist；语言切换立即生效 | 6 |
| M4-T6 | **文件操作 UI 化**：删除（→NSWorkspace recycleURLs，永久删除分支）、重命名（NSTableView 就地编辑）、新建文件/文件夹、Copy/Move（F5/F6，4 条路径：FS↔FS/归档↔FS/FS→归档/归档→归档经临时目录）、CopyDialog | PanelOperations/PanelCopy（`03-feature-map-filemanager.md` §6.2） | M4-T1, M3-T5 | 4 条复制路径 + 删除/重命名/新建对齐；"Cannot copy onto itself"防护 | 6 |
| M4-T7 | **"在归档内编辑并回写"**：解压单项到临时（小文件入内存 CVirtFileSystem）→ 启动关联程序 → 监视退出/变更（NSRunningApplication/KVO + 文件变更 dispatch source，替 Toolhelp32 进程快照）→ 询问回写 → CopyFromFile | `FileManager/PanelItemOpen.cpp:1110-1780`（`03-feature-map-filemanager.md` §6.2/§9.5） | M4-T6 | 编辑外部程序后回写归档；嵌套归档返回上级时检测回写 | 5 |
| M4-T8 | **面板内拖放（源+目标）**：NSDraggingSource/Destination + NSFilePromiseProvider；FS↔FS、归档↔FS、压入归档（CompressDropFiles）、右键拖出菜单；私有粘贴板类型替代 `7-Zip::SetTargetFolder/Transfer` 协商 | `FileManager/PanelDrag.cpp`（3006 行，C 类全重写，§8 矩阵） | M4-T6 | 面板↔面板、面板↔Finder 拖放各路径正确；错误集合弹 MessagesDialog | 6 |
| M4-T9 | **内嵌工具**：哈希计算（PanelCrc，FS 多文件流式 + 归档内 CopyTo 到哈希器，结果 CListViewDialog）、属性窗口（逐层归档属性 + rawProps 十六进制）、归档注释、链接创建（mac 仅 hardlink/symlink，砍 Junction/WSL）、临时文件清理、文件夹历史/收藏 | PanelCrc/PanelMenu/LinkDialog/BrowseDialog2（`03-feature-map-filemanager.md` §7） | M4-T2 | 各工具对齐；不支持项（Junction/WSL）UI 移除 | 6 |
| M4-T10 | **地址栏面包屑 + 根视图**：ComboBoxEx 等价（逐级目录 + Documents/Computer/卷列表，砍 Network）；Computer→/Volumes（NSFileManager mountedVolumeURLs，替 FSDrives）；AltStreamsFolder/NetFolder 移除 | PanelFolderChange/RootFolder/FSDrives（`03-feature-map-filemanager.md` §4.6/§4.7、§10） | M4-T1 | 面包屑导航、卷列表、混合路径解析（FS+归档内+嵌套）对齐 | 5 |
| M4-T11 | **本地化体系移植**：Lang/*.txt（92 语言可直接随 .app Resources）+ 内置英文 fallback 表（替 ResourceString .rc fallback，`05-platform-layer.md` §7）；LangString 机制保留 | `Common/Lang.cpp`、`FileManager/LangUtils.cpp` | M4-T2 | 切换语言菜单/对话框文本更新；无 .rc 时 fallback 不空 | 4 |
| M4-T12 | M4 回归：菜单/快捷键/操作全量对照 Windows 版 | §4 UI 自动化 | M4-T1..T11 | 对照清单全过 | 4 |

**M4 小计：63 人日。**

---

## 6. 里程碑 M5：Finder 集成与打磨发布

**目标**：Finder 扩展（右键命令 + 拖放）、文件关联、性能调优、签名公证发布、上游同步 SOP 落地。出口：可分发的已公证 .app，性能达标，合规清单全绿。

| # | 任务 | 涉及文件/模块 | 前置依赖 | 验收标准 | 估算 |
|---|---|---|---|---|---|
| M5-T1 | **命令模型抽取**（纯逻辑，FM 与 Finder 扩展共享）：命令枚举/Verb/扩展名启发式（kExtractExcludeExtensions ~120 后缀、GetSubFolderNameForExtract、CreateArchiveName）；剥离 Explorer 16 项截断协议 | `UI/Explorer/ContextMenu.cpp` 业务规则部分（`03-explorer-agent.md` §1.2-1.3/§1.9） | M4 | 命令决策层无 UI 依赖，单测覆盖 | 4 |
| M5-T2 | **Finder 扩展（FinderSync）**：右键菜单（Open/Extract/ExtractHere/ExtractTo/Test/Compress/CompressTo7z/CompressToZip/CRC 子菜单）+ 目录/卷拖放；`FIFinderSyncController` + `menuForMenuKind` | 新写 extension target；命令模型（M5-T1）；与主 app 经 XPC/URL scheme 通信（替 7zG 子进程 + 7zMap IPC，`03-explorer-agent.md` §1.9、§5.2） | M5-T1, M3 | Finder 右键全命令可用；Email 系列首版裁剪（MAPI 无对应，开放问题 Q4） | 8 |
| M5-T3 | **文件关联（LaunchServices/UTType）**：Info.plist `CFBundleDocumentTypes`/`UTImportedTypeDeclarations` 声明 + `LSSetDefaultRoleHandlerForContentType` 动态设默认（替 Software\Classes 注册表，`05-platform-layer.md` §4.1-G） | Info.plist + 桥接；扩展名/图标数据（M1-T4） | M4-T5 | 双击归档用本 app 打开；System 设置页可设默认 | 4 |
| M5-T4 | **进程内化收尾 + per-operation context + 全局资源仲裁**：(a) 去 CompressCall 的 7zG 子进程路径（蓝本 CompressCall2.cpp）；进程级全局（g_HWND/g_DisableUserQuestions/g_ExternalCodecs/语言单例）改 per-operation context，避免并发踩踏（§3 R6）；(b) **新增进程级任务调度/限流器**（`SZTaskScheduler` 单例 + `NSOperationQueue`/信号量）：控制并发引擎任务数（默认按核数/RAM 动态），避免每任务无约束起 mt 导致线程超订；(c) **mt 与字典内存全局收敛**：跨任务总线程 ≤ 物理核数、总字典内存 ≤ RAM 上限，各 SZCompressor/SZExtractor 的 threadCount 经调度器分配而非各自透传默认（=核数） | `UI/Common/CompressCall2.cpp` 蓝本（`04-feature-map-dialogs-finder.md` §11.2-11.3）；threadCount/mt 透传点（`02-core-bridge.md` §6 / `:523`）；MtCoder/LzFindMt 自起 pthread（底料04 §5） | M3, M4 | 同进程并发多操作不互相污染；后台按钮=thread QoS；**并发 N 任务时总活跃引擎线程 ≤ 物理核数、总字典内存 ≤ RAM 仲裁上限**（用「2 压缩+1 解压」验证不超订/不触顶，对照 M5-T6 与 §9.4 并发基准） | 5 |
| M5-T5 | **基准测试 GUI**（CBenchmarkDialog）：字典/线程/遍数 Combo、压缩/解压成绩、CPU 信息；进程内化（替 7zG b 子进程） | `UI/GUI/BenchmarkDialog.cpp`（`04-feature-map-dialogs-finder.md` §8） | M3-T1 | Benchmark 对齐，成绩与 7zz CLI 同量级 | 3 |
| M5-T6 | **性能收尾调优**（基线已在 M1-T9/M2-T9 建立，此处为全链路收口而非首次验收）：对照 7zz CLI 与 Windows 7zFM（§9.4 基准）；压缩吞吐/哈希吞吐补测；ARM64 汇编路径（LzmaDecOpt.S）/SHA/AES HW intrinsics 已在 dylib；桥接层 NSString↔UString 转换热点收尾优化；**并发资源仲裁基准**（§9.4 新增「2 压缩+1 解压」并发场景，对照 R6 资源调度器，见 M5-T4） | 全链路；并发调度器（M5-T4） | M4 | 压缩/哈希吞吐 ≥ §9.4 达标线；并发「2 压缩+1 解压」总内存峰值不触顶、系统不卡顿；M1/M2 早期基线无回退 | 4 |
| M5-T7 | **签名/公证/分发**：universal app（dylib + framework + extension 全签名，hardened runtime）；entitlements；notarytool + stapler | M0-T4 管线扩展 | M5-T1..T6 | Developer ID 签名 + 公证通过；`spctl -a` 通过 | 3 |
| M5-T8 | **合规执行清单落实**（§10 全部，硬交付物）：LGPL（动态链接 dylib + 三文件许可 License.txt/copying.txt/unRarLicense.txt 随包 + **静态进 framework 的 LGPL .o/.a + 重链接命令**，§10.1）、unRAR（含付费分发决策 D-RAR + `DISABLE_RAR` 切片，§10.2）、BSD 三组件署名（LZFSE/ZSTD/XXH64，§10.3）、商标命名（产品名/图标/Bundle ID 自有域名/about 三项声明，§10.4） | `DOC/License.txt`+`DOC/copying.txt`+`DOC/unRarLicense.txt` 随包；LGPL 目标文件归档 + 重链接脚本；`DISABLE_RAR` 开关；自有域名替换 `com.7zip.*` | M5-T7 | §10.1#2 三文件 `diff` 一致；交付 .o/.a + 命令能重链接出可加载 framework；付费版无 RAR handler 或附书面许可；about 框三项声明 + 三类许可入口可打开；Bundle ID/域名为自有域 | 5 |
| M5-T9 | **上游同步 SOP 文档化 + 首次演练**（§11）：整包覆盖式 + 人造 vendor 分支建立 | 本章 §11 | M5 | `vendor-upstream` 纯上游分支建立并提交一版；对 26.01→下一版（或上一版回放）做一次整包覆盖合并 + diff 演练；`Mac/` 隔离层不参与覆盖验证通过 | 2 |

**M5 小计：38 人日。**

---

## 7. 工作量汇总与人力配置

### 7.1 总工作量

| 里程碑 | 内容 | 人日 |
|---|---|---|
| M0 | dylib PoC + 构建/签名闭环 | 10 |
| M1 | 桥接层 + 只读浏览（含 M1-T9 列表性能 gate） | 39 |
| M2 | 解压全功能（含 M2-T9 吞吐/响应性 gate） | 36 |
| M3 | 压缩全功能 | 33 |
| M4 | 7zFM 完整 1:1 | 63 |
| M5 | Finder 集成与打磨发布 | 38 |
| **净开发小计** | | **219** |
| 缓冲（评审/返工/集成/CI，按 30%） | | 66 |
| **总计（含缓冲）** | | **≈285 人日** |

> M4 是单一最大块（FM 壳的逐控件 1:1），且强依赖 M1-M3 的模型层；建议 M4 内部按"双面板/菜单+快捷键/操作/工具/选项页"五条线切分以便并行。

### 7.2 人力配置建议

**单人节奏（1 名全栈 C++/ObjC++/AppKit 工程师）**

- 串行执行，285 人日 ≈ **13-15 个月**（按每月 20 工作日）。
- 排序建议：M0→M1（先做 ZipRegistry plist 后端 + Agent 闸门，闸门失败立即评估 B 计划）→ M2→M3→M4→M5。
- 风险：M4 体量大、易疲劳返工；建议在 M2 末尾插入一次完整回归冻结点，避免后期发现底层桥接缺陷大面积返工。

**双人节奏（建议）**

- **工程师 A（核心/桥接）**：M0 全部、M1 的 T1/T2/T3/T5/T6/T8、M2 的回调链与编排、M3 的 ParamsModel 与执行链、M5 的进程内化/性能/签名。
- **工程师 B（AppKit/UI）**：M1 的 T4/T7、M2 的对话框与进度窗/拖出、M3 的对话框、M4 大部、M5 的 Finder 扩展/文件关联。
- 交接面 = SevenZipKit 头文件（M1 早期冻结接口草案，见 `02-core-bridge.md`）。两人并行 + 接口先行，日历周期 ≈ **7-8 个月**（含集成对齐开销，并行效率按 0.85 折算）。
- 关键同步点：M1-T3 Agent 闸门（共同决策 B 计划）、M2-T2 阻塞式桥接（接口契约）、每里程碑回归冻结。

---

## 8. 风险登记册

概率/影响：高/中/低。触发信号 = 应当立即升级处置的可观测现象。

| ID | 风险 | 概率 | 影响 | 缓解 | 触发信号 |
|---|---|---|---|---|---|
| R-AGENT | **Agent 层 POSIX 移植失败**（ArchiveFolderOpen 的 g_hInstance/MyLoadString、ZipRegistry 链接、CCodecIcons 资源依赖编不过或行为不符） | 中 | 高 | **B 计划**：桥接层不复用 Agent 的 IFolderFolder 适配，改为 SevenZipKit 直接驱动 `IInArchive`（CreateObject→Open→GetProperty→Extract，见 `02-core-bridge.md` §4），自建轻量目录树（参考 CProxyArc 算法但用 ObjC++ 重写）。代价：归档内增删改事务（CommonUpdateOperation）需在桥接层重写 ≈ +10 人日。闸门设在 M1-T3，越早越省 | M1-T3 中 7 个 .o 任一编译/链接失败且 2 人日内无法 stub 通过；或 CommonUpdateOperation 回写损档 |
| R-WCHAR | **wchar_t/编码坑**：mac wchar_t=4 字节，UString 实为 UTF-32；任何把 UString 当 UTF-16 用（NSString 直转/memcpy）的桥接代码在非 BMP 字符出错；BSTR 二进制 blob（kClassID/kSignature）按宽字符串处理越界 | 中 | 中 | 统一经 UTFConvert（UTF-8 中转），列为代码评审强制检查项；二进制 BSTR 一律用 `SysStringByteLen`（`02-core-bridge.md` §2.3/风险表）；专项 emoji/CJK 扩展区文件名用例 | 含 U+1xxxx 字符的归档条目名乱码/截断；GUID 属性读取崩溃 |
| R-NFD | **NFC/NFD 规范化缺失**（全仓无现成处理），档内 NFC 名 vs 磁盘 NFD 名比较失配（更新/覆盖检测、wildcard） | 中 | 中 | M1-T8 桥接层统一规范化（入档 NFC，比较双向规范化）；专项测试集（中文/韩文/带变音符） | HFS+ 卷上更新归档时同名文件被重复添加；覆盖检测漏判 |
| R-PERF | **性能不达标**：桥接层 NSString↔UString 转换热点、列表万级条目卡顿、未走 ARM64 汇编/HW intrinsics | 中 | 中 | dylib 已含 LzmaDecOpt.S + SHA/AES intrinsics（`02-core-bridge.md` §3.1）；列表 NSTableView 虚拟模式；§9.4 基准对照 7zz；转换缓存。**关键缓解：M1-T9 与 M2-T9 各设一个 perf gate**——列表/内存基线在 M1 末（M1-T9）验收并建 CI 回归，解压吞吐 + 主线程响应性在 M2 末（M2-T9）验收，不达标即在本里程碑内回炉，避免推迟到 M5 才证伪导致回炉 M1-M2 核心结构（概率由"低"上调"中"，因无早期基准即无法判断概率低） | 解压/压缩吞吐 < 7zz CLI 的 90%；万条目列表滚动掉帧；M1-T9/M2-T9 基线不达标 |
| R5 | **阻塞式回调死锁**：密码/覆盖/内存回调在工作线程经信号量等主线程对话框，易引入死锁（主线程也在等工作线程） | 中 | 高 | 桥接层统一同步回调注入点（block + dispatch_semaphore）；回调内绝不重入同一 archive（持锁=死锁，`02-core-bridge.md` §5）；压测 | 加密/覆盖场景偶发卡死；进度窗无响应 |
| R6 | **进程内化共享态污染 + 并发资源超订**：(a) g_HWND/g_DisableUserQuestions/语言单例/cwd/后台优先级变全局，并发多操作互相踩踏；(b) 各任务无约束起 mt（默认=核数）→ N 任务 ×mt 线程超订；N 份高等级 LZMA2 字典内存（可达数百 MB/任务）叠加 → 总内存触顶，无全局并发上限/无内存仲裁 | 中 | 中 | per-operation context；后台按钮改 thread QoS（QOS_CLASS_BACKGROUND）；输出目录显式传参；**M5-T4 进程级 `SZTaskScheduler` 限流器控制并发引擎任务数（按核数/RAM 动态），mt 与字典内存全局收敛（总线程 ≤ 物理核、总字典内存 ≤ RAM 上限）**；§9.4 「2 压缩+1 解压」并发基准验证（`04-feature-map-dialogs-finder.md` §11.3） | 同时两个压缩任务进度错乱；一个任务取消影响另一个；**并发任务总内存触顶/系统卡顿/总线程数 > 物理核** |
| R-MOVEARC | **归档内更新回写损档**：MoveToOriginal 跨卷移动/权限/quarantine 传播、MoveArc 中断协议（延迟 E_ABORT）未保真 | 中 | 高 | 中断协议在 UI 桥接保真；APFS/沙箱/TCC 下验证跨卷移动；更新前后 CRC 校验（`03-explorer-agent.md` §5.5） | 更新归档后原档损坏/丢失；取消更新留下半成品 |
| R-COM-ABI | **COM 模拟跨 dylib ABI**：IUnknown 虚析构设置须双侧一致，缺 GetModuleProp 的库在 POSIX 被拒载；跨界 C++ 异常=UB | 低 | 高 | 双侧同仓同设置编译；保留 GetModuleProp 导出；dylib 边界走 C 风格 CreateObject 工厂；桥接回调全 catch-all（`02-core-bridge.md` §2.2/风险表） | LoadCodecs 报模块不兼容；回调抛异常进引擎崩溃 |
| R-FINDER | **Finder 集成模型差异**：FinderSync 沙箱/生命周期/菜单粒度与 IContextMenu 完全不同；与主 app 通信需 XPC | 中 | 中 | M2 后并行起步 M5-T2 留足验证时间；命令模型（M5-T1）先抽出；XPC 替代共享内存（`03-explorer-agent.md` §5.2） | FinderSync 菜单不显示/沙箱拒绝 XPC；扩展进程崩溃 |
| R-NONATOMIC | **非原子引用计数**：AddRef/Release 默认裸 ++/--，跨线程 Release 同一对象 UAF | 低 | 高 | 对象生命周期单线程化（串行 dispatch queue）；或定义 `Z7_COM_USE_ATOMIC` 并补 Interlocked 实现（需双侧重编，`02-core-bridge.md` §5/风险表） | 多线程下偶发崩溃/UAF（ASan 命中） |
| R-RAR | **unRAR 许可**：Format7zF 默认含 Rar 解码，unRAR 许可限制再分发/商店；**第 3 条禁止未经书面许可对含 unRAR 的分发收费**（`DOC/unRarLicense.txt:21-23`），与付费/商店付费分发冲突 | 低 | 中 | `DISABLE_RAR=1` 开关现成（`Arc_gcc.mak:200-205`）；分发评估与付费决策 D-RAR 见 §10.2；许可文本随包；**付费分发默认无 RAR 切片或取 Roshal 书面许可** | 法务/商店审核要求移除 RAR；**产品确定付费/商店付费分发且仍含 RAR handler**（触发 D-RAR 决策） |
| R-SCHEDULE | **M4 体量导致排期滑坡**（63 人日单块） | 中 | 中 | 五条线切分并行；M2 末插回归冻结点；接口先行减少返工 | M4 任一线超估算 30% |

---

## 9. 测试策略

### 9.1 桥接层单测（XCTest 调 SevenZipKit）

- **覆盖面**：SevenZipKit 公开 API 全部方法——打开/列表/属性读取（各 VT 类型：BSTR/UI4/UI8/FILETIME/BOOL，含二进制 blob）、嵌套导航、解压（含 testMode）、压缩（各格式各等级）、哈希、归档内 CRUD、密码/覆盖/取消回调。
- **回调正确性**：用 mock 回调断言时序（GetStream→PrepareOperation→SetOperationResult，见 `02-core-bridge.md` §4.2）、E_ABORT=取消、进度 hop 主队列、阻塞回调信号量配平。
- **内存/并发**：AddressSanitizer + ThreadSanitizer 跑全套；断言 BSTR/PROPVARIANT 用 SysFreeString/VariantClear 配对（不 free）；同一 IInArchive 串行约束验证。
- **编码**：UString↔NSString 往返（CJK/emoji/变音符/NFD-NFC）；FILETIME↔NSDate 保留 wReserved 精度往返。
- **目标**：核心 API 行覆盖 ≥ 80%，所有回调路径有用例。

### 9.2 样本归档对照测试集（与 7zz / Windows 版行为对照）

测试框架：对每个样本，分别用（a）SevenZipKit、（b）本机 `7zz`（已验证基准）、（c）若可得，Windows 7-Zip 26.01 预生成的期望输出，三方对照解压结果字节级 diff 与属性对照。需准备的样本类型：

| 类别 | 样本内容 | 验证点 |
|---|---|---|
| 多格式 | 7z/zip/rar/tar/gz/bz2/xz/wim/cab/iso/各嵌套组合（tar.gz/tar.xz/.7z 内含 .zip） | 全格式打开/列表/解压一致；嵌套逐层浏览 |
| 加密 | 7z 头加密 + 数据加密、zip ZipCrypto、zip AES-256、各错误密码 | 密码回调、错误密码报错、加密文件名 |
| 分卷 | .7z.001.. 、.zip.001.. 、.part01.rar.. 、合并探测 | 多卷打开/解压/合并；卷回调 |
| 大条目数 | 单归档 10 万 / 100 万条目（深目录树 + 平铺） | 列表虚拟化性能、proxy 树构建、内存占用 |
| 损坏归档 | CRC 错、截断（UnexpectedEnd）、头损坏、错误签名、部分损坏（可恢复 vs 不可恢复） | 错误文案（DataError/CRC/UnsupportedMethod）、不崩溃、错误聚合 |
| 路径穿越 | 含 `../`、绝对路径、`..\\`、超长路径、保留名（CON/PRN 等）、含 `\` 字符的档内名、含 `:` 的名 | 落盘路径被净化（Correct_FsPath），不写出沙箱外 |
| 文件系统语义 | 符号链接、硬链接、POSIX 权限（attrib 高 16 位）、纳秒时间戳、NFD/NFC 文件名 | 链接/权限/时间戳往返；NFD 比较不失配 |
| 边缘卷 | HFS+（秒级 mtime）、APFS case-sensitive 卷 | 已知限制文档化、不误判 |

样本集纳入仓库（小样本）或脚本生成（大条目数/分卷），CI 每次跑核心子集、夜间跑全集。

### 9.3 UI 自动化（XCUITest）范围

- **菜单/快捷键对照**：脚本遍历 File/Edit/View/Favorites/Tools/Help 全部命令项与 PanelKey 快捷键，断言触发正确动作（对照 `03-feature-map-filemanager.md` §1 表）。
- **对话框 1:1**：压缩/解压/进度/覆盖/密码/内存/分卷/链接/选项 6 页——断言控件存在、联动（如 CompressDialog 的 CBN_SELCHANGE 矩阵）、OnOK 校验。
- **核心用户流**：打开归档→浏览→解压；选文件→压缩→产出；归档内重命名/删除→回写；双面板 F5/F6 复制；拖放（面板↔面板、面板↔Finder）。
- **不强求 100% UI 自动化**：拖放/Finder 扩展部分以手动测试用例清单 + 关键路径 XCUITest 结合。

### 9.4 性能基准（对照 7zz 与 Windows 7zFM）

| 指标 | 基准 | 达标线 | 首次验收里程碑 |
|---|---|---|---|
| 解压吞吐（大 7z/zip，LZMA2） | 本机 7zz CLI | ≥ 7zz 的 90%（同 dylib 引擎，差距应仅在 IO/桥接） | **M2-T9（gate）** |
| 进度刷新期间主线程响应性 | — | 无可感卡顿（无掉帧/无 spinner） | **M2-T9（gate）** |
| 列表滚动 | — | 万条目滚动 60fps 不掉帧 | **M1-T9（gate）** |
| 归档打开延迟（万级条目） | Windows 7zFM（若可对照） | 同量级（≤ 2×） | **M1-T9（gate）** |
| 内存峰值（100 万条目） | — | 记录基线，无失控增长 | **M1-T9（gate）** |
| 压缩吞吐（各等级） | 本机 7zz CLI | ≥ 7zz 的 90% | M5-T6 |
| 哈希吞吐 | 7zz CLI | ≥ 7zz 的 95% | M5-T6 |
| **并发资源（2 压缩+1 解压）** | — | 总活跃引擎线程 ≤ 物理核数；总字典内存 ≤ RAM 仲裁上限；总内存峰值不触顶、系统不卡顿 | M5-T6（依赖 M5-T4 调度器） |

> **性能验收前移（不再全部挂在 M5）**：解压吞吐 + 列表/内存基线是内存/延迟敏感核心结构的出口闸门，**CI 性能回归基线在 M1 末（M1-T9）建立，而非 M5 收尾**；M1-T9、M2-T9 为里程碑出口 gate，不达标即在本里程碑内回炉对应数据结构（SZItem 懒取 / PanelModel / 进度回调链），避免带病累积到 M5 再大面积返工（见 §3 R-PERF）。M5-T6 仅做压缩/哈希补测、并发基准与收尾调优。

基准脚本固定样本 + 多次取中位数；arm64 与 x86_64（Rosetta/原生）分别测；纳入 CI 性能回归（阈值告警，基线自 M1 末起维护）。并发基准须包含「同时 2 个压缩 + 1 个解压」场景，记录总线程数、总字典内存、总内存峰值，验证 M5-T4 的全局仲裁生效。

---

## 10. 合规执行清单

> 本章合规项分两类：**硬交付物**（M5-T8 验收闸门，缺一不可发布）与**决策项**（需在 M5-T8 前由产品/法务在给定工程选项中三选一/二选一定案，非"待法务确认"的开放挂起）。下文逐项给出可验收的硬约束，不再以"建议/若需"弱化。

### 10.1 LGPL 义务逐条落实（含静态进 framework 的 §6 重链接义务）

7-Zip 多数代码为 LGPL 2.1（部分 BSD/公有领域，unRAR 另有限制条款）。关键事实（决定合规边界）：本方案不仅动态链接 `lib7z.dylib`，**SevenZipKit.framework 还把上游 UI/Common 与 UI/Agent（均为 LGPL）整包静态编入自身二进制**（见 `01-architecture.md:71`、`:93`，`02-core-bridge.md:217`）。因此 framework 自身落入 LGPL 派生作品范畴，仅靠 dylib 的动态链接（下文#1）覆盖不了静态进 framework 的那部分，**必须按 LGPL 2.1 §6 提供可重链接材料**。须落实：

1. **核心引擎动态链接（已满足设计）**：`lib7z.dylib` 以独立动态库形态分发，app 与 framework 经 dlopen 调用，不静态内联进闭源部分——满足 LGPL "允许用户替换库" 的核心要求。验收：`otool -L SevenZipFM.app/Contents/MacOS/SevenZipFM` 显示对 dylib 的动态引用，用户替换同 ABI 的自编 dylib 后仍加载。
2. **随包许可文本（三文件齐全，缺一不可）**：在 .app `Contents/Resources/licenses/` 放置以下三个文件，且字节与仓库 `DOC/` 一致（不得只搬 License.txt）：
   - `License.txt`——7-Zip 许可与各文件归属（原 `DOC/License.txt`，**注意它本身不含 LGPL 正文**，只给出获取链接）。
   - `copying.txt`——**LGPL 2.1 全文**（原 `DOC/copying.txt`，502 行，第 1-2 行即 "GNU LESSER GENERAL PUBLIC LICENSE Version 2.1"）。这是"随分发提供本许可副本"义务的正文来源。
   - `unRarLicense.txt`——unRAR 许可原文（原 `DOC/unRarLicense.txt`，含收费限制第 3 条，见 §10.2）。
   "关于"对话框提供入口打开三者。验收：`SevenZipFM.app/Contents/Resources/licenses/` 下存在以上三文件，且 `diff` 对 `DOC/License.txt`、`DOC/copying.txt`、`DOC/unRarLicense.txt` 均无差异；"关于"框三个入口均可打开。
3. **静态进 framework 的 LGPL 代码重链接材料（§6 硬交付物，非"若需"）**：因 UI/Common、UI/Agent 的目标码被静态编入 SevenZipKit.framework，按 LGPL 2.1 §6 必须随分发或在官网提供"用户能用自改的 LGPL 源码重链接出等价 framework"的完整材料：
   - (a) framework 内**全部 LGPL 目标文件**（UI/Common 的 OpenArchive.o/Extract.o/Update.o/LoadCodecs.o/ArchiveExtractCallback.o/UpdateCallback.o/HashCalc.o 等 + UI/Agent 的 7 个 .o：Agent.o/AgentProxy.o/AgentOut.o/ArchiveFolder.o/ArchiveFolderOut.o/ArchiveFolderOpen.o/UpdateCallbackAgent.o）的归档（`.a` 或 `.o` 集）；
   - (b) 非 LGPL 部分（桥接 ObjC++ 层）的目标码或可链接库；
   - (c) 完整的 `ld`/`clang` 重链接命令与链接脚本，使用户改动 LGPL 源后能重新编出可加载的 `SevenZipKit.framework`。
   验收：照交付的 .o/.a + 提供的链接命令，能重链接出一个可被 `SevenZipFM.app` 正常 dlopen/加载的 `SevenZipKit.framework`（替换后 app 启动并完成一次 roundtrip）。
4. **dylib 构建可重现说明**：随分发或在官网提供说明文档：(a) `lib7z.dylib` 的源码/对象清单（Format7zF），(b) 用 `cmpl_mac_arm64.mak`/`cmpl_mac_x64.mak` 重建 dylib 的命令，(c) 用户可用自编 dylib 替换分发版。验收：照说明能重建出 universal dylib 并替换运行。
5. **源码可获取与版权保留**：提供本移植对 7-Zip 源码的修改（mak 片段、平台桥接 `*_mac.mm`、`docs/upstream-patches.md` 登记项）的获取途径；保留所有原始版权声明（含引擎内 Igor Pavlov 版权，见 §10.3 about 框硬验收）。

### 10.2 unRAR 条款（含付费/收费分发限制）

- Format7zF 默认含 Rar 解码。`DOC/unRarLicense.txt` 实测含两条对本移植有约束的条款：
  - **第 2 条（禁止重建 RAR 算法）**：unRAR 源码不得用于重建 RAR 压缩算法；分发须在文档/源码注释中声明"代码不得用于开发兼容 RAR(WinRAR) 的归档器"。
  - **第 3 条（收费/付费分发限制）**：`No person or company may charge a fee for the distribution of unRAR without written permission from the copyright holder.`（`DOC/unRarLicense.txt:21-23`）——即对"含 unRAR 代码的产品收费分发"需 Roshal 书面许可。注意 7-Zip 主 `License.txt` 采纳的 "unRAR license restriction" 仅复述第 2 条（重建算法），但 §10.1#2 要求随包 `unRarLicense.txt` 原文，第 3 条即在其中，付费分发时与商业意图直接冲突，须法务判定该条对"RAR 解码代码"的适用范围（unRAR 工具 vs 内嵌解码代码）。
- 处置（硬约束）：
  - (a) 若保留 RAR 解压，随包 `unRarLicense.txt` 原文，且不得宣称可"创建 RAR"。
  - (b) **决策项 D-RAR（M5-T8 前定案）**：产品是否付费/商店付费分发？
    - 免费分发 → 可保留 RAR handler（仍随包 unRAR license）。
    - 付费/商店付费分发 → 须取得 Roshal 书面许可，**或**默认对所有付费/商店渠道用 `DISABLE_RAR=1`（`Arc_gcc.mak:200-205,283-296,311-317`）产出无 RAR 的 dylib 切片。
  - (c) App Store/严格沙盒场景一律用 `DISABLE_RAR=1`。
- 验收：含 RAR 版本随包 unRAR license 原文；**付费版确认不含 RAR handler**（`GetNumberOfFormats`/格式枚举不含 rar），或随附 Roshal 书面许可副本；商店版同上。

### 10.3 第三方 BSD 组件署名（随 lib7z.dylib 进入分发二进制）

`DOC/License.txt:11-13` 明确 `lib7z.dylib` 内含三处 BSD 许可代码，均随二进制再分发，BSD 第 2 条要求"二进制形式再分发须在文档/随附材料中重现版权声明与许可条款"：

| 组件 | 文件 | 许可 | 版权行（须重现） |
|---|---|---|---|
| LZFSE 解码 | `CPP/7zip/Compress/LzfseDecoder.cpp` | BSD 3-clause | `Copyright (c) 2015-2016, Apple Inc.` + `Copyright (c) 2023-2026 Igor Pavlov.` |
| ZSTD 解码 | `C/ZstdDec.c` | BSD 3-clause | `Copyright (c) Facebook, Inc.` + `Copyright (c) 2023-2026 Igor Pavlov.` |
| XXH64 哈希 | `C/Xxh64.c` | BSD 2-clause | `Copyright (c) 2012-2021 Yann Collet.` + `Copyright (c) 2023-2026 Igor Pavlov.` |

> XXH64 是用户可见功能（GUI 哈希子菜单，`03-`/`04-` feature-map），其代码确进二进制。

- 处置（硬约束）：随包许可材料中重现上述三组版权行 + 各自 BSD 许可正文。最省做法：直接随包的 `DOC/License.txt`（已含 BSD-3 与 BSD-2 全文，第 45-131 行）即满足"重现条款"，但 about 框/Resources 须能让用户看到这三组署名。
- 验收：about 框或 `Contents/Resources/licenses/` 内可见 LZFSE(BSD-3, Apple)、ZSTD(BSD-3, Facebook)、XXH64(BSD-2, Yann Collet) 三组版权行与许可正文（随包 `License.txt` 已覆盖即可）。

### 10.4 商标与命名（M5-T8 硬交付物，非建议）

- "7-Zip" 是 Igor Pavlov 的项目名/标识。本移植**不得**命名为"7-Zip for Mac"或使用官方 logo，以免暗示官方出品或背书。
- **M5-T8 交付物（非建议、不推迟到 Q6）**——以下四项须在 M5-T8 定案并验收：
  1. **最终用户产品名**：面向用户的独立第三方移植名（`SevenZipFM` 仅作内部 target 名，不作产品名）。
  2. **产品图标**：自有图标，不复用 7-Zip 官方 logo。
  3. **Bundle ID 与内部域名**：用自有域名反写。**当前文档全套把 UserDefaults 域 / 错误域硬编码为 `com.7zip.SevenZipFM`、`com.7zip.SevenZipKit`（`01-architecture.md:59`/`:312`、`05-roadmap-execution.md` M1-T1）含 `7zip` 暗示商标**——M5-T8 须评估改为自有域名反写（如 `<自有域>.SevenZipFM`），并同步改 M1-T1 的 NSUserDefaults 域与 SZErrorDomain 字符串（一处定义、全局引用，改动成本低，建议 M1 即用占位自有域以免后期大面积替换）。
  4. **about 框非官方声明文案**：明确"基于 7-Zip 引擎的独立 macOS 移植，非 Igor Pavlov / 7-zip.org 官方出品"。
- **about 框硬验收（三项同时展示）**：
  1. 产品为第三方移植、非官方出品的声明；
  2. `基于 7-Zip，Copyright (C) 1999-2026 Igor Pavlov`（LGPL/BSD 均要求保留版权声明，引擎源码含此版权）；
  3. LGPL（copying.txt）/ unRAR / BSD（LZFSE·ZSTD·XXH64）许可入口，均可打开对应正文。

### 10.5 签名/公证具体命令步骤

**entitlements 文件最小键集**（两个文件，被步骤 3/4 引用）：

`SevenZipFM.entitlements`（主 app）——
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <!-- 与 Finder 扩展共享 defaults/IPC，App Group 须与 appex 一致 -->
  <key>com.apple.security.application-groups</key>
  <array><string>group.<自有域>.SevenZipFM</string></array>
  <!-- 仅 Developer ID + hardened runtime 主线（非沙盒）。dlopen 同 Team 签名的 lib7z.dylib/7z.so
       在 hardened runtime 下无需额外 entitlement（同签名、同 Team；见 04 §3.4/§7），故不加
       disable-library-validation；若将来需加载第三方未签名 .so 才设
       com.apple.security.cs.disable-library-validation -->
</dict></plist>
```

`FinderExt.entitlements`（FinderSync appex）——
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.application-groups</key>
  <array><string>group.<自有域>.SevenZipFM</string></array>
</dict></plist>
```
> App Group ID（`group.<自有域>.SevenZipFM`）主 app 与 appex 必须一致，是二者共享 UserDefaults/通信的前提（`01-architecture.md:60`）。沙盒版（开放问题 Q7）才需 `com.apple.security.app-sandbox` + security-scoped bookmark 相关键，本主线不加。

```sh
# 1) 引擎 dylib（universal，加固链接见 M0-T2）
codesign --force --timestamp --options runtime \
  --sign "Developer ID Application: <NAME> (<TEAMID>)" \
  SevenZipFM.app/Contents/Frameworks/lib7z.dylib
# 注：7z.so 是指向 lib7z.dylib 的符号链接（02 §1.2，ln -sf）。codesign 不单独签符号链接，
#     它随 .app 封装签名/公证；干净机内对该 symlink 做 dlopen 必须成功（见验收）。

# 2) SevenZipKit.framework
codesign --force --timestamp --options runtime \
  --sign "Developer ID Application: <NAME> (<TEAMID>)" \
  SevenZipFM.app/Contents/Frameworks/SevenZipKit.framework

# 3) Finder 扩展（appex，带 entitlements）
codesign --force --timestamp --options runtime \
  --entitlements FinderExt.entitlements \
  --sign "Developer ID Application: <NAME> (<TEAMID>)" \
  SevenZipFM.app/Contents/PlugIns/FinderExt.appex

# 4) 主 app（最后签，--deep 不推荐，逐项签）
codesign --force --timestamp --options runtime \
  --entitlements SevenZipFM.entitlements \
  --sign "Developer ID Application: <NAME> (<TEAMID>)" \
  SevenZipFM.app

# 5) 校验签名
codesign --verify --deep --strict --verbose=2 SevenZipFM.app
codesign -d --entitlements - SevenZipFM.app/Contents/PlugIns/FinderExt.appex  # 确认 App Group 已写入
spctl -a -vvv -t exec SevenZipFM.app   # 公证前会显示 rejected（正常）

# 6) 打包并公证（notarytool，需 App Store Connect API key 或 app-specific password）
ditto -c -k --keepParent SevenZipFM.app SevenZipFM.zip
xcrun notarytool submit SevenZipFM.zip \
  --keychain-profile "AC_NOTARY" --wait

# 7) 装订票据到 .app（注意：dylib/appex 无法单独 staple，staple 主 .app；符号链接随 .app 一并被票据覆盖）
xcrun stapler staple SevenZipFM.app
xcrun stapler validate SevenZipFM.app
spctl -a -vvv -t exec SevenZipFM.app   # 现应 accepted

# 8) 制作分发 DMG，再对 DMG 签名 + 公证 + staple
hdiutil create -volname "SevenZipFM" -srcfolder SevenZipFM.app \
  -ov -format UDZO SevenZipFM.dmg
codesign --force --timestamp --options runtime \
  --sign "Developer ID Application: <NAME> (<TEAMID>)" SevenZipFM.dmg
ditto -c -k SevenZipFM.dmg SevenZipFM-dmg.zip   # notarytool 收 .dmg 也可直传 .dmg
xcrun notarytool submit SevenZipFM.dmg \
  --keychain-profile "AC_NOTARY" --wait
xcrun stapler staple SevenZipFM.dmg
spctl -a -vvv -t open --context context:primary-signature SevenZipFM.dmg  # DMG 用 -t open
```

验收：
- `spctl -a -t exec` 对 .app accepted；`spctl -a -t open` 对 .dmg accepted；干净机器双击可运行无 Gatekeeper 拦截。
- `spctl -a -vvv` 对 `FinderExt.appex` 单独 accepted（`spctl -a -vvv -t exec SevenZipFM.app/Contents/PlugIns/FinderExt.appex`）。
- **干净机内**（从未信任过本 Team 的机器）：`SevenZipFM.app/Contents/Frameworks/7z.so` 符号链接随 .app staple 后，桥接层/LoadCodecs 对它 `dlopen` 成功（验证 symlink 在签名/公证后仍可加载，不被 Gatekeeper 拦）。
- `codesign -d --entitlements -` 显示主 app 与 appex 的 App Group 一致。

---

### 10.6 GitHub 源码托管 checklist（public / private 区分）

> 适用场景：把本仓库（含 `Mac/` 新增代码）push 到 GitHub。这是**源码托管**，与 §10.1–10.5 的**二进制 .app 分发**是不同分发形态——源码托管的合规显著更轻（源码公开本身就满足"提供源码"义务）。
> 事实澄清：7-Zip **无官方 GitHub 仓库**（Igor Pavlov 仅在 7-zip.org 发布源码包），GitHub 上的 7-Zip 仓库均为第三方镜像；许可证看代码本身的 LGPL/BSD/unRAR 条款，与托管在谁的 GitHub 无关。

**Private 仓库（仅本人 / 授权协作者可见）**：不构成对公众分发，仍属**自用**，LGPL/BSD/unRAR 义务均不触发。**无强制项**；保留原 `DOC/` 许可文件是零成本好习惯。

**Public 仓库（任何人可 clone）= 源码分发，触发义务，但多数已被"源码公开"本身满足**：

| # | 硬约束 | 验收 |
|---|---|---|
| 1 | 保留原许可与版权（fork 自带，**勿删**）：`DOC/License.txt`、`DOC/copying.txt`(LGPL-2.1 全文)、`DOC/unRarLicense.txt`，及所有源码文件头 `Copyright (C) Igor Pavlov` 行 | git 中三文件存在且与上游一致；文件头版权未被改动 |
| 2 | `Mac/` 新增代码（SevenZipKit/SevenZipFM/桥接 mak）声明许可：因 include 7-Zip 头并静态编入 LGPL 的 UI/Common+Agent，属 **LGPL 派生作品** → 用 `LGPL-2.1-or-later`（或兼容）开源 | `Mac/LICENSE` 存在；各 `.mm/.swift/.h` 文件头带 SPDX 标识 |
| 3 | 顶层"非官方"声明 README：注明"基于 Igor Pavlov 的 7-Zip 的独立第三方 macOS 移植，非官方、无背书"，不使用官方 logo（呼应 §10.4 商标） | `Mac/README.md`（或仓库根 README）含该声明 |
| 4 | unRAR 声明：README/NOTICE 注明"**不用于重建 RAR 压缩算法**"（unRAR 第 2 条）。源码托管不收费即不触发 §10.2 第 3 条收费限制 | README 含 unRAR 声明 |
| 5 | 若在 GitHub **Releases 放编译好的 .app/.dmg** → 回到 §10.1–10.5 全套（随包许可、§6 重链接材料、签名公证、BSD 署名）。**仅托管源码、不发二进制则不触发** | 视是否发布二进制而定 |

**自用提示**：目标若始终是自用，**private 仓库即可，本节全部可跳过**；仅当决定 public 时按上面 5 条做（成本极低，主要是"别删原文件 + 给 Mac/ 代码加 LICENSE + 写非官方 README"）。

---

## 11. 上游同步 SOP（官方新版本发布时的合入流程）

7-Zip 由 Igor Pavlov 不定期发布新版（如 26.01→26.02→27.00）。本移植的核心策略：**引擎层零改动复用上游，改动收敛在 mak 片段 + 平台桥接 .mm + AppKit 壳**，使上游同步成本最小。

### 11.1 改动隔离原则（让同步可行）

- 对上游 C/C++ 源码的修改**尽量为零**；必需的改动（如 `kMainDll` 改名、SecurityUtils 补 `_WIN32` guard）集中登记在 `docs/upstream-patches.md`（每条含文件:行号 + 原因 + diff）。
- 新增文件用独立命名（`*_mac.mm`、`var_mac_*_dylib.mak`、`exports7z.txt`），不覆盖上游文件。
- 桥接层（SevenZipKit）与 AppKit 壳完全是新增代码，与上游解耦。

### 11.2 合入流程

> **现实约束（决定 SOP 形态）**：官方 7-Zip 以 `.tar.xz` 整包发布，**无公开 git 历史、无可三方合并的 upstream vendor 分支**；本仓库 `origin` 为镜像（`NianDUI/7zip`），git log 实测每版是一次整包提交（`8c63d71`=26.01、`839151e`=26.00、`5e96a82`=25.01，无逐文件演进历史）。因此**不能假设存在可直接三方合并的共同祖先**，须用"整包覆盖式 + 人造上游分支"SOP：

1. **拉取并固化"纯上游"基线（人造 vendor 历史，提供三方合并的 base）**：
   - 解压官方新版 `.tar.xz` 到 vendor 临时树（如 `/tmp/7zip-<ver>/`）。
   - 在本地维护一个**纯上游分支**（如 `vendor-upstream`，只含官方源码、不含本移植任何 `*_mac.mm`/mak 片段/`Mac/` 隔离层）：每出新版，把官方整包**覆盖**该分支工作树后 `git commit`（这条 commit 即"人造上游历史"的一环），形成可作为三方合并 base 的连续提交链。
   - **`Mac/` 隔离层（本移植新增的平台桥接、AppKit 壳、mak 片段、`*_mac.mm`、`exports7z.txt`、`docs/`）不参与覆盖**，始终只存在于主分支。
2. **三方合并到主分支**：主分支 `git merge vendor-upstream`（以上一版 `vendor-upstream` commit 为共同祖先做三方合并）。因隔离层与上游文件不重叠，冲突仅出现在"被本移植 patch 过的上游文件"（`docs/upstream-patches.md` 登记项）。
3. **无 git / 镜像不同步时的退路**：若无法维护 git 上游分支（如只拿到 `.tar.xz`），改用"逐目录 diff + 补丁重放"：对上一版 vendor 树与新版 vendor 树做 `diff -ruN`，按 §11.2 步骤 4 的范围分级人工采纳，再对登记的 patch 用 `patch`/手工重放。
4. **diff 范围分级**（按对本移植的影响）：
   - **引擎层**（`C/`、`CPP/7zip/Archive`、`CPP/7zip/Compress`、`CPP/7zip/Crypto`、`CPP/Common`、`CPP/Windows` 的 POSIX 分支）：直接采纳；重新跑 dylib 构建 + roundtrip 实测（M0-T6 的 XCTest）。
   - **导出 ABI**（`Archive2.def`、`DllExports2.cpp`、`CodecExports.cpp`、`ArchiveExports.cpp`）：检查 19 个 C 入口签名/数量、`GetModuleProp(kVersion)` 是否变化、新增/删除格式或方法（`GetNumberOfFormats/Methods`）。ABI 变更须同步 `exports7z.txt` 与桥接层。
   - **UI/Common + UI/Agent**（本移植复用的逻辑层）：逐文件 diff，关注接口结构变化（`IFolder.h`、`ZipRegistry.h` 的 CInfo 结构、回调接口）；若结构变化需同步 plist 后端与桥接。
   - **UI/FileManager + UI/GUI + UI/Explorer**（对照 1:1 的功能源）：diff 用于发现**新增/变更的菜单项/对话框控件/默认值/快捷键/设置键**，逐条更新 AppKit 壳与对照清单（`03-`/`04-` feature-map 文档同步修订）。
   - **被本移植 patch 过的文件**（`docs/upstream-patches.md` 登记项）：重新应用 patch，解决冲突。
5. **回归清单**（每次同步必跑）：
   - [ ] dylib 构建通过（arm64 + x64 + lipo）；`nm -gU` 仅 19 个 C 符号；`GetModuleProp(kVersion)` 更新。
   - [ ] M0-T6 dlopen roundtrip XCTest 绿。
   - [ ] 桥接层单测全过（§9.1）；ASan/TSan 干净。
   - [ ] 样本归档对照测试集核心子集 + 新版若新增格式则补样本（§9.2）。
   - [ ] UI 自动化菜单/快捷键/对话框对照（§9.3）；用 diff 发现的新增功能逐条补测。
   - [ ] 性能基准无回退（§9.4）。
   - [ ] 合规：新版若改 License/新增第三方组件（含 BSD 组件清单变化），更新随包许可文本与三文件齐全性（§10.1#2、§10.3）。
   - [ ] 签名 + 公证流程跑通（§10.5）。
6. **功能差异处置**：上游新增功能（新格式、新对话框选项、新快捷键）按本章里程碑模板补任务卡，纳入下个迭代；Windows 专属新功能（如新的 NTFS/Shell 特性）评估是否有 mac 等价物或裁剪（参照 `05-platform-layer.md` §2 裁剪原则、`01-filemanager-inventory.md` §10）。
7. **文档同步**：更新本章基线版本号、`docs/upstream-patches.md`、feature-map 文档的行号引用（行号会随上游版本漂移，回归时校正）。

### 11.3 同步成本预估

- 补丁版（如 26.01→26.02，引擎小修）：≈ 2-3 人日（diff + 回归 + 签名）。
- 次版本（如 26→27，可能含新格式/UI 变更）：≈ 5-10 人日（视 UI/Common 接口与 FM/GUI 功能变更面）。

---

## 12. 开放问题

> 以下为无法仅凭源码定案、需产品/法务/基础设施决策的问题，已在本章相关任务中标注。

1. **Q1 — Developer ID 证书/Apple 开发者账号归属**：签名公证需要的 Developer ID Application 证书与 App Store Connect API key 由谁提供、团队 ID 是什么。阻塞 M0-T4。
2. **Q2 — CI 基础设施**：是否有 macOS CI（自建 mac runner / 云 mac），universal 构建 + 公证是否在 CI 内执行还是手动放行。影响 M0-T6 及全程回归自动化。
3. **Q3 — SFX 取舍**：Windows 的 .exe 自解压在 mac 无直接等价物；是否提供（a）完全移除 SFX、（b）生成 .exe SFX 供 Windows 用户、（c）研究 mac 可执行 SFX（复杂度高）。影响 M3-T6 与压缩对话框 SFX 控件去留。
4. **Q4 — Email 命令族**：Compress→Email（Windows 走 MAPI）在 mac 用 NSSharingService 重做还是首版裁剪。影响 M5-T2 Finder 扩展命令集。
5. **Q5 — LGPL §6 合规路径选型（工程决策，非"是否需要"）**：SevenZipKit.framework 静态编入 LGPL 代码（UI/Common、UI/Agent）已使其落入派生作品范畴，按 LGPL 2.1 §6 必须落地三条合规路径之一——(a) 随包提供这些 LGPL .o/.a + 链接命令使用户能重链接出等价 framework（§10.1#3 已采纳为默认硬交付物）；(b) 把 UI/Common·UI/Agent 也拆成独立 dylib 动态链接；(c) 整体开源 SevenZipKit。M5-T8 须在三者中定案落地，**不以"法务确认"为由推迟到发布之后**。当前默认 (a)。
6. **Q6 — 产品最终命名与商标（M5-T8 交付物，非推迟项）**：面向用户的产品名、图标、Bundle ID/内部域名（自有域名反写，替换现有 `com.7zip.*`）、about 非官方声明文案，已在 §10.4 列为 M5-T8 硬交付物与验收项；此处仅留"由谁拍板命名"的归属决策，工程约束已闭环。
7. **Q7 — App Store/沙盒的优先级**：设计公约定分发主线为 Developer ID + 公证，App Store/沙盒为可选后续。若需同步做沙盒版，Finder 扩展 XPC、security-scoped bookmark、entitlements 会额外增加约 15-20 人日，需确认是否纳入首版范围。
8. **Q8 — 与 Windows 7-Zip 的逐项对照基准来源**：§9.2 的"Windows 版期望输出"是否可获得一台 Windows + 7-Zip 26.01 生成对照样本，还是仅以本机 7zz CLI 为基准（7zz 与 7zFM 在 GUI 默认值/路径处理上可能有细微差异）。影响对照测试的精度。
