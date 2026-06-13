# 06 对抗评审存档记录

> 7-Zip Windows GUI 一对一移植 macOS（方案B：核心 dylib + ObjC++ 桥接 + AppKit）设计文档（`01`~`05`）的对抗式评审存档。
> 本记录固化：评审组成与方法、各角色裁决、findings 全表与处置结果、遗留开放问题。
> 处置结果（采纳/驳回）来自修订人对各文档的实际改动返回值。
> 基线：仓库 main @ 8c63d71（26.01）。证据格式 `文件路径:行号`（相对仓库根 `/Users/lyd/WorkSpace/MyProjects/7zip`）。

---

## 1. 评审组成与方法

### 1.1 评审方法

本轮采用 **5 角色对抗式评审**。每个角色以独立、对抗（adversarial）的立场审视全部 5 份设计文档，目标是主动证伪设计结论而非确认。评审遵循以下硬规则：

- **证据强制**：每条 finding 必须给出可核验的现场证据，证据格式为 `文件路径:行号`（指向上游 7-Zip 源码或本方案文档的具体行），禁止凭印象断言。
- **严重度分级**：`blocker`（阻塞发布/必返工）> `major`（重大缺陷，需修正）> `minor`（次要瑕疵，宜修正）。
- **可执行建议**：每条 finding 必须附带可落地的修订建议（recommendation），指向具体章节与可验收改法。
- **裁决（verdict）三档**：`通过` / `有条件通过`（须修正 major 及以上后放行）/ `需重大修改`（存在 blocker 或系统性缺陷）。
- **处置闭环**：findings 交由修订人逐条处置，处置结果分 `采纳`（已改入对应文档）或 `驳回`（附理由）；驳回但有争议者、以及起草阶段未定案的开放问题，统一沉淀到第 4 节遗留清单。

### 1.2 评审组成（5 角色）

| # | 角色 | 关注边界 | 主要审视文档 |
|---|---|---|---|
| 1 | 内核桥接专家（C++/COM/ABI） | COM 接口语义、ABI 闸门、dlopen/符号、异常边界、密码/时间编码 | `02`、`01` |
| 2 | macOS 平台架构师 | 沙箱/Hardened Runtime、FinderSync 能力边界、书签生命周期、UTType/关联、控件选型、libc++ 一致性 | `03`、`04`、`01` |
| 3 | 功能完整性审查官 | 一对一覆盖（对话框/菜单/命令全集）、分期降级是否越界、源码清单核对 | `03`、`04`、全局 |
| 4 | 性能与稳定性工程师 | 进度模型、大归档打开、内存预算、崩溃隔离、取消清理、并发资源仲裁 | `02`、`01`、`05` |
| 5 | 合规与发布审查官 | LGPL §6 重链接、随包许可、unRAR/BSD 署名、商标命名、签名公证、上游同步 SOP | `05` |

---

## 2. 各角色裁决一览

| # | 角色 | 裁决（verdict） | findings 计数（blocker / major / minor） |
|---|---|---|---|
| 1 | 内核桥接专家（C++/COM/ABI） | **有条件通过** | 0 / 3 / 6 |
| 2 | macOS 平台架构师 | **有条件通过** | 2 / 7 / 2 |
| 3 | 功能完整性审查官 | **有条件通过** | 0 / 3 / 4 |
| 4 | 性能与稳定性工程师 | **需重大修改** | 2 / 6 / 1 |
| 5 | 合规与发布审查官 | **需重大修改** | 2 / 4 / 1 |
| — | **合计** | — | **6 / 23 / 14（共 43 条）** |

综合结论：2 个角色给出 `需重大修改`（性能与稳定性、合规与发布），3 个角色 `有条件通过`。全部 6 条 blocker + 23 条 major + 14 条 minor 均已交付修订人处置。

---

## 3. findings 全表（含处置结果）

> 处置结果列：`采纳` = 已改入对应文档；`驳回` = 未改，附理由。本轮全部 43 条 findings 经修订人处置后均为 **采纳**（无驳回）。证据与建议为评审原文留档。

### 3.1 角色一 · 内核桥接专家（C++/COM/ABI）

| # | severity | 文档 | 标题 | 证据 | 建议 | 处置结果 |
|---|---|---|---|---|---|---|
| 1-1 | major | 02-core-bridge.md | 预览路径 `dataForEntryAtIndex` 对 7z/zip 主格式不可用——`IInArchiveGetStream` 仅容器型 handler 实现 | §4.2 把 `dataForEntryAtIndex:` 与 §7.1『预览走独立 SZArchive 实例（QI IInArchiveGetStream）』作为 FM 预览干净路径。但 `IInArchiveGetStream`（IArchive.h:268-270，`GetStream(UInt32 index, ISequentialInStream**)`）仅由 CHandlerCont 基类（HandlerCont.h:28-42）及容器型 handler 实现——`grep -rln IInArchiveGetStream CPP/7zip/Archive` 命中 tar/iso/fat/ntfs/squashfs/dmg/xar/cpio，而 7z/、Zip/ 返回空。7z（含 solid）与 zip handler 不实现该接口，QI 返回 E_NOINTERFACE；文档无降级方案，且误称『随机读』（接口实际只产出前向只读 ISequentialInStream）。 | (1) QI 失败时退化为对单条目 index 调 `archive->Extract(&idx,1,0,memCallback)` 写内存/临时流（QuickLook 走此路径，对应 OQ-4）；(2) 修正语义为『顺序读，非随机读』；solid 7z 取单文件触发整段 solid block 解码，需在内存阈值策略量化（联动 04 预览设计）。 | **采纳** |
| 1-2 | major | 02-core-bridge.md | `SZLibrary` dlopen 路径用 `NSBundle subdirectory:"../Frameworks"` 是不可靠 API 用法 | §4.1 写 `dlopen([NSBundle.mainBundle URLForResource:@"lib7z" withExtension:@"dylib" subdirectory:@"../Frameworks"].path …)`。subdirectory 参数是相对 Resources 的子路径查找，`..` 上跳属未定义/不稳定行为（常返回 nil）。框架 dylib 正规定位为 `privateFrameworksURL` 或 `[NSBundle bundleForClass:].executablePath`。返回 nil 后 dlopen(NULL) 崩或加载失败。 | 改为 `NSURL *fw = NSBundle.mainBundle.privateFrameworksURL; NSURL *dylib = [fw URLByAppendingPathComponent:@"lib7z.dylib"];` 取 .path 传 dlopen；01 §3.3 的 GetModuleDirPrefix(NSBundle) 用同一基址，保证桥接 dlopen 与 LoadCodecs 复用路径（7z.so 软链）落同一目录。 | **采纳** |
| 1-3 | major | 02-core-bridge.md | 密码回调示例 `*password = StringToBstr(pw)` 签名错误，编译失败且掩盖 NSString→UTF-32 转换缺口 | §7.3/§6.2 写 `*password = StringToBstr(pw);`（pw 为 NSString*）。`CPP/Common/MyCom.h:184`：`StringToBstr(LPCOLESTR src, BSTR *bstr)` 返回 HRESULT、入参 LPCOLESTR（macOS 下 UTF-32），非 NSString。赋值方向反了且跳过 NSString→UTF-8→ConvertUTF8ToUnicode 必经一步。IPassword.h:16-24 明确 BSTR 由回调方分配、引擎 SysFreeString 释放，分配必须真实发生。 | 改为 `UString us; ConvertUTF8ToUnicode(AString([pw UTF8String]), us); BSTR b=NULL; if (StringToBstr(us.Ptr(), &b)!=S_OK) return E_OUTOFMEMORY; *password=b; return S_OK;`；§5.1 反向编码统一引用此片段，避免 NSString 直传 wchar_t* 接口的宽度陷阱。 | **采纳** |
| 1-4 | minor | 02-core-bridge.md | ABI 闸门校验硬编码 `ulVal != 0`，未与桥接层自身 `k_IUnknown_VirtDestructor_ThisModule` 对齐 | §6.1 写 `v.ulVal != k_IUnknown_VirtDestructor_No`（==0）。上游 `LoadCodecs.cpp:521-560`(IsSupportedDll) 判据是 `flags != k_IUnknown_VirtDestructor_ThisModule`——期望值取自消费者自身编译期常量；非 _WIN32 缺 GetModuleProp 时默认假定 _Yes(=1)。钉死 0 只在『SevenZipKit 也以默认编译』成立，一旦开 Z7_USE_VIRTUAL_DESTRUCTOR_IN_IUNKNOWN 会误判。 | 把校验改为比较 `v.ulVal` 与桥接层自身 `NModuleInterfaceType::k_IUnknown_VirtDestructor_ThisModule`（编译期常量），双侧设置同步变化时闸门自动正确。 | **采纳** |
| 1-5 | minor | 02-core-bridge.md | 19 个导出符号清单核对通过，但 `nm -gU`『≈19』的强收敛与 dead_strip 交互仍是未验证假设 | Archive2.def(15 个 PRIVATE 导出)与 DllExports2.cpp 一致——SetClientVersion/SetProperty 在 DllExports2.cpp:138-155 被注释不导出，故 19=15+4 清单正确。但 §8.2 AC-1 写 `nm -gU 仅 ≈19`，dylib 内含 libc++ 模板实例、RTTI、operator new/delete 等 weak external，收敛后是否仍 global 可见、4041→19 是否精确未实测（§9 开放问题 #2 也承认）。『≈』不可量化。 | M0 实跑后把 AC-1 改成精确断言：`nm -gU \| grep -c ' T '` == 19 且逐一比对符号名集合（与 exports7z.txt 一致），跑 dlopen+CreateObject+roundtrip 确认无运行时 dlsym 失败，『≈』替换为确定值。 | **采纳** |
| 1-6 | minor | 02-core-bridge.md | FILETIME 换算把 `kUnixTimeOffset` 当源码字面量 11644473600，实际为编译期表达式 | §5.2 注释 `kUnixTimeOffset = 11644473600 秒，TimeUtils.cpp:22`。实际 TimeUtils.cpp:22-23 是 `(UInt64)60*60*24*(89 + 365*(kUnixTimeStartYear - kFileTimeStartYear))` 计算式（值确等于 11644473600）。文档建议复用 TimeUtils.h:94-105 互转，但 §5.2 又贴手写 double 算术（/1e7 浮点丢 100ns 精度）。 | 删除手写 double 示例，直接引用 TimeUtils.cpp:160-183 整数互转（FileTimeToUnixTime/UnixTimeToFileTime），桥接层只在最外层转 NSTimeInterval，避免换算环节用 double 丢精度。 | **采纳** |
| 1-7 | minor | 01-architecture.md | §6.1『跨线程 AddRef/Release=UAF』正确，但 §5/§6 进度+completion hop main 本身就跨线程触碰桥接对象 | 04 §5(MyCom.h:345-392) 实证 Z7_COM_USE_ATOMIC 全仓未定义、AddRef/Release 为裸 ++/--；§6.1 据此要求生命周期单线程。但 §6.2/§6.3 进度与 completion 都 `dispatch_async(main)` 派发 block，block 捕获 self 与 CMyComPtr 成员。block 在 main 析构 ObjC 包装对象时其成员 CMyComPtr<IInArchive> 在 main 对引擎做非原子 Release，而引擎对象可能仍被串行队列调用栈持有——正是 §6.1 禁止的跨线程 Release。 | 在 §6.1/§6.2 补硬规则：派发 main 的 block 对桥接对象一律 __weak 捕获；桥接 ObjC 对象 dealloc（CMyComPtr 析构→引擎 Release）必须发生在所属串行队列（dealloc 内 dispatch_sync 回私有队列释放，或保证最后强引用在私有队列释放）。 | **采纳** |
| 1-8 | minor | 02-core-bridge.md | `SZFolderSession` 跨串行队列调用 Agent，而 Agent 内部 `throw int` 的传播边界未在 API 契约层固定 | 01 §2.3 与 02 §3.1 正确论证 Agent 的 `throw int`(AgentProxy.cpp:184 `throw 20120228`)、多继承 15 接口(Agent.h:53-66)必须留同一运行时不跨 C ABI。但 §4.6 把 CAgent 调用包进私有串行 dispatch_queue 的 block，`throw int` 逸出 block 进入 libdispatch 的 C 帧是 UB（libdispatch 不保证跨 block C++ 异常透传）。§6.3 catch-all 只示范回调方法，未覆盖『dispatch block 内调用 Agent 顶层方法』。 | 在 §4.6 明确：dispatch block 内对 CAgent/CAgentFolder 的调用必须用 `try{...}catch(...){转 HRESULT/NSError}` 整体包裹，确保 throw int 不逸出 block 进 libdispatch；加入 §6.3 异常边界规则，与回调 catch-all 并列为两类必守边界。 | **采纳** |

### 3.2 角色二 · macOS 平台架构师

| # | severity | 文档 | 标题 | 证据 | 建议 | 处置结果 |
|---|---|---|---|---|---|---|
| 2-1 | **blocker** | 04-feature-map-dialogs-finder.md | FinderSync 右键菜单真实能力边界被高估：菜单仅在『被监控目录』内出现，全盘监控不可靠且有体验/性能后果 | §3.2 写『监视目录（或全盘 directoryURLs）』，§5 #2 列为『换法做、能力足够』。但 `menu(for:)`/`selectedItemURLs()` 仅当浏览/选中项位于 setDirectoryURLs: 注册子树内时才被调用。设『/』名义全盘，但 (a) 对根注册每次目录切换都唤醒扩展，Apple 不鼓励；(b) 外接/网络/可移动卷挂载需动态重注册；(c) 沙箱拿不到注册目录外 URL。Windows IContextMenu 对任意选中项即时可用，非 1:1。 | 把『全盘 directoryURLs』升级为必须正面处理的设计约束：明确 setDirectoryURLs:[file:///] 代价与替代（按卷动态注册 + mountedVolumeURLs 监听重注册）；给『扩展未被调用』可观测验收；§5 #2 结论改为『能力受限、需配合卷挂载监听』（关系 OQ-9 降级）。 | **采纳** |
| 2-2 | **blocker** | 03-feature-map-filemanager.md | 归档内『就地编辑回写』在沙箱/security-scoped bookmark 下生命周期未设计：监视跨分钟级，回写时书签可能已失效 | §5.1 临时文件落 `<容器>/Caches/7zO<rand>/`（正确），但回写目标是原归档。原档经 NSOpenPanel/拖入获得，访问权依赖 security-scoped bookmark。监视流程持续数分钟到数小时，若仅用瞬时 startAccessing 未持久化书签保活，回写阶段 copyFromFile: 对原档无写权限会失败/损档。MoveArc 的 MoveToOriginal 跨目录 replace 需父目录写权限，而书签只授单文件。05 §5#5 已点出但 03 未纳入步骤/验收。 | §5.1 增书签生命周期：打开归档即对原档父目录申请并持久化书签（或非沙箱主线标注仅 App Store 阶段需要）；监视全程持有 startAccessing 至回写完成；MoveToOriginal 验证 replaceItemAtURL 对书签授予父目录是否成立。验收补『原档位于 ~/Downloads 之外任意位置回写成功』。 | **采纳** |
| 2-3 | major | 04-feature-map-dialogs-finder.md | Hardened Runtime / App Sandbox 下 dlopen 自带 dylib 的约束被『无障碍』带过，遗漏 Library Validation 与扩展沙箱条件 | 01 §8.4 与底料 04-core-dylib.md:183 称『hardened runtime 下 dlopen 同签名 dylib 无障碍』，只在『同 Team ID 签名 + 主 App 进程』成立。遗漏：(1) Hardened Runtime 默认开 Library Validation 要求 7z.so 与加载方同 Team ID，build_dylib.sh 的 codesign 隐含未显式校验；(2) FinderSync 强沙箱进程若 dlopen 引擎需 disable-library-validation 或同签名；(3) App Sandbox 阶段 dlopen 仅允许 bundle 内路径，与 §3.3 GetModuleDirPrefix 改 NSBundle 决策耦合但未交叉说明。 | 在 01 §8.4 或 04 新增小节：dylib 与所有可执行体同 Developer ID Team 签名是硬前提（CI 加 codesign --verify --strict 校验 Team ID 一致）；列 App Sandbox 阶段 entitlements（library-validation、files.user-selected.read-write、App Group）；确认扩展进程永不 dlopen 引擎（写死为约束）。 | **采纳** |
| 2-4 | major | 03-feature-map-filemanager.md | NSPathControl 作为面包屑地址栏在『可编辑+自定义下拉历史+固定项』需求下能力不足，OQ-8 两选项都没验证可行性 | §6 与 OQ-8 把地址栏定为『NSPathControl 或可编辑 NSComboBox+自绘下拉』。NSPathControl 是只读面包屑，无 setEditable、无法路径段就地输入、菜单定制有限。Windows ComboBoxEx 是『可编辑文本框+路径栈下拉+固定项』三合一(PanelFolderChange.cpp:627-801)。NSPathControl 做不到可编辑，NSComboBox 做不到面包屑分段，两候选各缺一半，实际须自绘复合控件，工作量被低估为 M。 | OQ-8 明确结论倾向：自建复合控件（NSTextField 编辑态 + 自绘面包屑展示态切换 + NSPopover 下拉），NSPathControl 仅纯展示降级。工作量上调，或首版接受『纯可编辑 NSComboBox（无面包屑分段）』并标注已知 UX 缺口。不要把可行性悬置为原型问题。 | **采纳** |
| 2-5 | major | 03-feature-map-filemanager.md | 10 万行虚拟化只在视图层提 NSTableView，但 Agent/Proxy 一次性全量建树+全量 NSString 拷出，内存与首屏延迟未评估 | §5.1 称『LoadItems 后立即拷出 NSString』；03-explorer-agent.md §2.4 证实 CProxyArc::Load 遍历 GetNumberOfItems 全量建树、CalculateSizes 递归聚合。NSTableView 虚拟化的是 cell 视图，但数据源背后 _items 是当前目录全量数组，且桥接预先把 kpidPath 等 PROPVARIANT→NSString。对 10 万项归档，LoadItems 时刻全量 GetProperty+NSString 化是同步阻塞，卡住完成 block。文档把虚拟化等同 NSTableView 选型，未区分视图虚拟化与模型全量物化。 | §5.1 或工作量表补『大目录策略』：桥接属性按需惰性读取（仅 objectValueForTableColumn:row: 被调时 GetProperty 该行该列并缓存），非一次性全量物化；PanelModel _items 仅持轻量索引。加验收：打开 10 万项首屏 < N 秒、滚动不卡。 | **采纳** |
| 2-6 | major | 03-feature-map-filemanager.md | Return 键默认绑定 Rename(OQ-2) 直接违反『一对一』硬标准：7zFM 的 Enter=打开是核心交互 | §4 与 OQ-2 决议『焦点单项+无修饰 Return=Rename，Cmd+↓=Open』。但纲领(01 §1.1)是『功能与交互上等价复刻』。Windows 7zFM 的 Enter=OpenSelectedItems(true)(App.h:121，进入归档/打开)，Rename 是 F2。把无修饰 Return 改判 Rename 是把最高频交互从默认键挪走，属交互语义偏离，与『一对一』直接冲突。文档自承冲突却默认选偏离侧。 | 按一对一原则默认 Return=Open(与 Windows 一致)，Rename 用 F2 / Cmd+Return / 单击已选项延时进入编辑(Finder 式但不抢 Return)。把『贴 Finder 还是贴 Windows』作为产品决策显式上抛，但默认值应站一对一侧。UX 评审须先于实现拍板。 | **采纳** |
| 2-7 | major | 04-feature-map-dialogs-finder.md | 拖出归档用 NSFilePromiseProvider 方向正确，但『FinderSync 不处理拖放』与『主面板 NSFilePromise』混述，且 promise 回调同步解压大文件阻塞拖放会话 | §3.3 与 03 §5.3 把延迟解压寄于 NSFilePromiseProvider。未处理：(1)§5 #3/#4 已承认 FinderSync 无拖放释放点回调，从 Finder 右键拖出在 mac 不存在，拖出只发生在主面板，但 04 §3.3 把拖放与 Dock/FinderSync 混述易误读；(2)writePromiseToURL: 回调在 operationQueue，若是主队列或解压大档，Finder 拖放完成长时间转圈无进度，NSFilePromise 无内建进度 UI。 | 04 §3.3 明确：Finder 内不提供归档项拖出（只有主 App 面板提供）；为 delegate 指定独立后台 operationQueue（operationQueueForFilePromiseProvider:），解压期通过主 App SZProgress 窗显示进度；大文件取消路径与 §5.3 验收对齐（取消后清理部分写入文件）。 | **采纳** |
| 2-8 | major | 01-architecture.md | dylib 跨边界传 COM 接口指针的架构假设，与 DLL.cpp 实测 dlopen 用 RTLD_LOCAL 存在一致性风险，需显式约束符号可见性 | §2.3 决策『dylib 边界=C 风格 CreateObject 工厂，Agent+UI/Common+ObjC++ 同 framework 用 C++ 接口指针直连』。实测 DLL.cpp:148-149 dlopen 用 RTLD_LOCAL\|RTLD_NOW，意味 7z.so 内部符号不进全局符号表（支持决策，正确），但也意味桥接层与 dylib 各自链接的 libc++/typeinfo/vtable/operator new 若非同一份共享 libc++，跨边界虚调用与 PROPVARIANT/BSTR 的 malloc/free 配对 UB。§2.2 提『同一 clang/同一 C++ 运行时』是硬约束但未落可校验项。 | 01 §8 或 02 增可校验约束：dylib 与 framework 都动态链接系统 /usr/lib/libc++.1.dylib（otool -L 校验同一 libc++ 而非各自静态嵌入）；CI 加 nm 校验 7z.so 不导出 C++ 符号（只 19 个 _C 入口）；PROPVARIANT/BSTR 跨边界分配释放用 SysAllocString/VariantClear(MyWindows 提供)而非裸 malloc/free，符号来源侧固定。 | **采纳** |
| 2-9 | minor | 04-feature-map-dialogs-finder.md | Info.plist 把 60+ 格式全部声明为 CFBundleDocumentTypes 并设默认处理器，会抢占常见类型(zip/dmg/iso)，LSHandlerRank 策略仅对部分给 Alternate | §3.1 表把 zip 标 Editor、7z 用 LSHandlerRank=Owner、rar 用 Alternate，注释『Viewer 类用 Alternate 避免抢占』。但 zip/tar/gz/dmg/iso 等系统已有默认 App 的类型若声明 Editor/Owner，安装后改变既有双击行为（zip 双击不再用归档实用工具而进 7-Zip 面板），侵入性副作用。Windows 关联是用户逐项勾选才生效，mac 的 Info.plist 静态声明+Owner 是安装即声明。 | §3.1 明确：除 org.7-zip.* 私有类型外，所有系统已有公共类型(zip/tar/gz/bz2/dmg/iso/xar) 的 CFBundleTypeRole 一律 Viewer + LSHandlerRank=Alternate(或 None)，绝不 Owner；『设为默认应用』交给 FM 设置页 LSSetDefaultRoleHandlerForContentType 运行期按勾选执行。安装时不静默抢占任何系统默认。 | **采纳** |

### 3.3 角色三 · 功能完整性审查官

| # | severity | 文档 | 标题 | 证据 | 建议 | 处置结果 |
|---|---|---|---|---|---|---|
| 3-1 | major | 03-feature-map-filemanager.md | MessagesDialog（IDD_MESSAGES）与简易 ProgressDialog（IDD_PROGRESS）两个对话框在 03/04 全文均未映射，违反对话框全覆盖承诺 | 底料 01 §2 对话框全清单含 14 个。03 §2.2 仅映射 10 个专属 + 指向 04 的 6 个共享。MessagesDialog 落夹缝：MessagesDialog.cpp 被 PanelDrag.cpp:1788 用于拖放结束错误聚合弹窗；简易 ProgressDialog.cpp（区别于 ProgressDialog2.cpp）被 PanelCopy.cpp:347 使用。04 §2.4 仅映射 ProgressDialog2 内嵌错误列表(IDL_PROGRESS_MESSAGES)，非独立弹出的 MessagesDialog。两 .cpp/.h/.rc 在 FileManager/ 下真实存在且被链接。 | 在 04 §2.6 或 03 §2 增补：(1) 简易 ProgressDialog（仅进度条+Cancel）→ SZ 进度窗体系下『无统计的轻量进度』变体（或确认并入 SZProgressWindowController 并说明合并）；(2) MessagesDialog → 操作结束后批量错误列表窗（NSTableView+Close+Cmd+C），明确与 ProgressDialog2 内嵌错误列表触发差异。 | **采纳** |
| 3-2 | major | 04-feature-map-dialogs-finder.md | §3.1 UTType 声明把 docx/xlsx/epub/jar/apk/ipa 等系统已知类型当作 7-Zip 私有 UTExportedTypeDeclarations，会与系统/Office 既有 UTType 冲突 | 已核实 ZipRegister.cpp:20 注册扩展含 jar/docx/xlsx/epub/ipa/apk/appx。§3.1 末尾只规定公共 UTType 用 Imported、私有用 Exported，遗漏 docx/xlsx(org.openxmlformats.*)、epub(org.idpf.epub-container)、jar(com.sun.java-archive)、apk/ipa（公认类型）。声明为 org.7-zip.* Exported 属重复声明系统已拥有 UTType，按 Apple 规则引发归属冲突/图标与默认应用行为不确定。 | §3.1 细化：对 docx/xlsx/odt/ods/epub/jar/apk/ipa（本质 zip 但系统/第三方已声明专属 UTType）一律 conform 既有系统 UTType(Imported)，不新建 Exported；仅对真正无系统 UTType 的私有格式建 Exported。§4.1 构建期工具加『扩展名→是否系统已注册 UTType』查表(UTTypeReferenceWithFilenameExtension)。 | **采纳** |
| 3-3 | minor | 03-feature-map-filemanager.md | §2 SplitDialog 卷大小预置清单与源码不符：写 1457664/FAT4G，实际为 CD/DVD/BD 档且 1457664 软盘项已被注释禁用 | SplitUtils.cpp:60-73 实际为 10M/100M/1000M/650M-CD/700M-CD/4092M-FAT/4480M-DVD/8128M-DVD DL/23040M-BD，『1457664 - 3.5" floppy』在 :72 被注释。03 §2 写『预置 1457664/FAT4G 等』——1457664 在 26.01 已非预置，且漏列 CD/700M/DVD/DVD DL/BD。 | §2 SplitDialog 预置示例改为与 SplitUtils.cpp:60-73 一致档位，删 1457664 软盘引用，避免移植者照搬错误清单。 | **采纳** |
| 3-4 | major | 全局 | 多处一对一功能被以『开放问题/首版可分期』悄悄降级，超出可裁剪范围且无验收硬标准 | OQ-3(03 §1.3)：四视图 Large/Small Icons/List/Details(resource.rc:97-100 / Panel.cpp:871-892 真实四档)『建议首版 Details+Icons 两种，List/Small 后置』——核心 View 菜单功能砍半。OQ-5：备选选择模式 _mySelectMode(App.cpp:98-108 真实存在)『后置或砍』。OQ-1：FM\Columns blob『首版可保留 blob 直搬』与 05 §4.2『建议弃 blob』矛盾未定。均属注册表/菜单已登记的一对一项，以开放问题留白且无最小一对一基线判定。 | 每个『分期/后置』项补一行：是『一对一范围内但分期实现（需 vN 补齐，给目标版本）』还是『明确裁剪（给替代/砍除理由）』。四视图与备选选择模式属一对一功能，不能仅『建议』留白——需产品对『一对一硬标准是否允许分期』拍板并写入验收清单。 | **采纳**（落地：新增 `05-roadmap-execution.md` §0.4『一对一基线与分期/裁剪登记表』作为唯一权威判定口径，逐项归为【分期/目标版本】或【裁剪/理由】并标注"需产品签字"；OQ-1/3/5 各补分类与验收硬标准，四视图四档与 AlternativeSelection 定为【分期·一对一范围内】且未签字前从严按全进 M4；OQ-1 列配置定案弃 blob 改结构化 plist，消除 03/05 表述冲突） |
| 3-5 | minor | 03-feature-map-filemanager.md | §1.1 Properties 行将 FS 项『系统属性』笼统描述为『改为弹自绘属性窗』，与 Windows 实际双路径不符 | PanelMenu.cpp:172-180：Properties() 先 QI(IID_IGetFolderArcProps)，若无（纯 FS 文件夹）则 InvokeSystemCommand("properties") 调系统 Shell 属性对话框并 return；只有归档文件夹（实现 IGetFolderArcProps）才走自绘 CListViewDialog。03 §1.1 把『FS 走系统对话框、归档走自绘窗』两路径混为一谈——Windows 下 FS 项从不显示自绘窗。 | §1.1 Properties 改为：归档/归档内项 → SZPropertiesWindow（自绘，IGetFolderArcProps 路径）；FS 项 → 因 mac 无 Shell properties 动词，新建基于 NSURL resourceValuesForKeys 的 FS 属性窗（明确这是行为新增而非平移）。 | **采纳** |
| 3-6 | minor | 04-feature-map-dialogs-finder.md | §3.2 FinderSync 命令全集与 03 §1.1 CRC 子菜单措辞不一致，且哈希命令应核对为完整 13 项 | ContextMenu.cpp:294-308 的 g_HashCommands[] 共 13 项(含 kHash_All `*`、kHash_Generate_SHA256『SHA-256 -> file.sha256』、kHash_TestArc『Checksum : Test』)。04 §3.2 列出 13 项，但 03 §1.1 CRC 子菜单只列 10 算法+`*`(与 FM File 菜单 resource.rc:56-69 一致，FM 菜单确无 Generate/TestArc)。两章各自正确但口径不同，未交叉说明 FM File 菜单 vs FinderSync 右键的哈希差异。 | 03 §1.8 或 04 §3.2 加交叉注解：FM File→CRC = 10 算法+`*`(resource.rc:56-69)，FinderSync/右键 = 多出『SHA-256 -> file.sha256』与『Checksum : Test』(g_HashCommands 13 项)，命令模型同源呈现集合不同，避免移植遗漏 FinderSync 两项扩展哈希。 | **采纳** |
| 3-7 | minor | 04-feature-map-dialogs-finder.md | §2.6 内存确认/Hash结果/测试结果三项与 §2.5 SZProgressSink 挂接描述偏薄，缺 CMemDialog 的『记住本次/改限额』控件级映射 | 底料 01 §2 与 02 §5/§7 指出 CMemDialog（MemDialog.cpp）含『允许/跳过 + 改限额(GB spin) + 记住本次操作』单选组与 Continue/Cancel，由 IArchiveRequestMemoryUseCallback 触发，落 NExtract::Save_LimitGB。04 §2.6 仅写『→ NSAlert，经 askMemoryUse: 阻塞问询』，把含 GB 步进+三态单选+记住开关的对话框压缩为一句 NSAlert，丢失『改限额写回 MemLimit』与『记住本次操作』两个有状态控件。 | §2.6 内存确认升级为独立 sheet（非 NSAlert）：NSStepper+NSTextField（改 GB 限额写回 Extraction.MemLimit）、『允许/跳过』单选、『记住本次操作』勾选、Continue/Cancel；askMemoryUse: 返回结构携带新限额值而非仅 yes/no，与 MemDialog.cpp 控件一一对应。 | **采纳** |

### 3.4 角色四 · 性能与稳定性工程师

| # | severity | 文档 | 标题 | 证据 | 建议 | 处置结果 |
|---|---|---|---|---|---|---|
| 4-1 | **blocker** | 02-core-bridge.md | 进度回调采用每回调 dispatch_async(main) 的 push 模型，与 Windows 已验证的 200ms 拉取模型相悖，必造成主线程派发风暴 | 上游 GUI 是 pull 模型：回调 SetCompleted/SetRatioInfo 只在临界区写 CProgressSync(ProgressDialog2.h:32-105，_cs 保护)，UI 由 200ms WM_TIMER 拉取(ProgressDialog2.cpp:33 kTimerElapse=200、:422 SetTimer)，回调从不触碰 UI。本方案是 push：SZProgressDelegate szTaskDidProgress 注明『已 hop 主线程可直接刷 UI』(02:621)，骨架在 SetCompleted 内直接 dispatch_async(main)(02:724-726)。LZMA2 大文件每块回调一次可达每秒数千次，逐次派发堆积上万 block。01 §6.3 仅顺带提『节流』，未落进 02 桥接契约。 | 把进度改为 pull 模型作为硬契约：回调仅原子写共享结构(completedBytes/inSize/outSize/curFilePath，os_unfair_lock 或 atomic)，绝不 dispatch_async；由桥接层 main-queue 重复 dispatch_source_timer(200ms，对齐 kTimerElapse)周期读取并单次回调 UI。SZProgressDelegate 文档明确『回调按节流间隔批量送达』。 | **采纳** |
| 4-2 | **blocker** | 01-architecture.md | 大归档(10万+条目)打开链路无进度、无取消：CAgent::ReadItems 向 proxy Load 传 NULL，proxy 树构建不可中断且不报进度 | §5.1 打开时序图把 Open→ReadItems→CProxyArc::Load 画成直线无进度/取消。实际 CAgent::ReadItems 调 _proxy->Load(GetArc(), NULL) 与 _proxy2->Load(GetArc(), NULL)，progress 实参均 NULL(Agent.cpp:1770-1771)。CProxyArc::Load 本支持进度(AgentProxy.cpp:250 SetTotal、:263 SetCompleted)，传 NULL 后失效。叠加 IInArchive::Open 头解析(OpenArchive.cpp:374/:1192)。结论：双击打开 10 万条目时串行队列上是无进度、无 E_ABORT 注入点的阻塞操作。 | 打开归档必须可取消、可报进度并写进 M1 验收：(1) 给 Open 传实现 IArchiveOpenCallback 的回调接 isCancelled→E_ABORT；(2) 改 CAgent::ReadItems 把真实 IProgress 传给 proxy Load（登记上游补丁点），或 B 计划自建轻量树自带取消检查。M1-T5/T7 加『打开 10 万条目过程中点取消 1s 内返回 SZErrorCancelled』。 | **采纳** |
| 4-3 | major | 05-roadmap-execution.md | 性能基准只在 M5 才验收，全部桥接/列表/内存设计直到项目末期才被证伪，返工风险极高 | 性能达标线(解压/压缩≥7zz 90%、万条目 60fps、100 万条目内存基线)全挂 M5-T6(05:152)与 §9.4(CI 性能回归也是收尾)。而内存/延迟敏感设计早在 M1(SZArchiveEntry eager 读全属性 02:443、PanelModel 万级虚拟化)与 M2(进度回调模型)就固化。把硬验收推到 211 人日最后里程碑，意味桥接热点/列表内存不达标需回炉 M1-M2 核心数据结构。R-PERF 评『概率低』与此不符。 | 性能验收前移并设里程碑出口闸门：M1 出口加『万级条目列表加载+滚动基线（内存峰值+帧率）』，M2 出口加『解压吞吐≥7zz 90% + 进度刷新期间主线程响应性』。性能 CI 基线 M1 末建立而非 M5。R-PERF 概率上调『中』，缓解补『M1/M2 各设一个 perf gate』。 | **采纳** |
| 4-4 | major | 01-architecture.md | 100 万条目内存预算缺失：proxy 树 + 桥接层 SZArchiveEntry 双份常驻对象，无数字、无验收阈值 | 内存双份放大却无预算。底层 CProxyArc 每条目 CProxyFile(const wchar_t* Name，AgentProxy.h:8-16)+CObjectVector<CProxyDir>；mac 上 wchar_t=4B 且零拷贝名优化被禁(02:224，AgentProxy.cpp:274 限 MY_CPU_LE&&_WIN32，POSIX 走 BSTR 复制)，每名字一份 UTF-32 堆拷贝。桥接 SZArchiveEntry 创建时一次性把十余属性读出转 ObjC(02:443)。01:232 还要求每次 LoadItems 立即拷出 NSString。三份字符串拷贝 + 100 万 NSObject 各带 NSNumber/NSDate boxing。05 §9.4 只写『记录基线』无 MB 数无上限。 | 给出 100 万条目内存上限预算（峰值≤X MB、每条目≤Y 字节）作为验收项。entries 默认走 enumerateEntriesUsingBlock 懒加载/分页，SZArchiveEntry 按需读属性（valueForPropID 时再取，非创建时 eager 全读）。明确 proxy 树与桥接快照不应同时各持一份全量字符串。 | **采纳** |
| 4-5 | major | 01-architecture.md | 进程内化丧失崩溃隔离，损坏归档 fuzz 面直接打进主 App，方案无任何缓解（沙箱化/子进程/资源上限） | §3.2 决策把 7zFM/7zG 合并单进程消除 7zMap IPC，但未评估代价：Windows 右键独立 7zG 解压损坏归档崩溃只死子进程，FM 存活；进程内化后引擎解析恶意/损坏归档触发崩溃（解码越界、throw int 穿越）直接 take down SevenZipFM.app。05 §9.2 承认要喂损坏归档/路径穿越样本(05:237-238)，即已知攻击面，但 R-COM-ABI/R-AGENT 未把『损坏归档崩溃主进程』列风险，全文无 ASan-in-production/子进程隔离/资源上限。 | 明确进程内化隔离代价并给缓解：(1) 对『不受信来源/损坏检测命中/超大任务』走 XPC 子进程跑引擎（崩溃隔离+可杀），从开放问题升 M2/M5 决策项给阈值判据；(2) CI 用 libFuzzer/ASan 对 dylib 喂损坏归档语料做 fuzz 作发布闸门；(3) 风险登记册补『损坏归档崩溃主进程』(概率中/影响高)。 | **采纳** |
| 4-6 | major | 02-core-bridge.md | 取消语义全链路未闭环：abort 后的临时文件/半成品清理无设计，仅依赖引擎默认行为且与延迟 E_ABORT 语义冲突 | §7.4 取消链路图止于『completion(SZErrorCancelled)→主线程』(02:784)，UI『静默关窗』(01:355)，但磁盘半成品清理未提。源码清理有条件：解压 abort 删当前临时(ArchiveExtractCallback.cpp:1265/:1274/:2575/:1369)，但已落盘前序文件不回滚；归档更新路径相反——MoveToOriginal 阶段 E_ABORT 被刻意延迟防损档(02:787、ArchiveFolderOut.cpp:192-233)。方案未说明取消后目标目录部分文件由谁清理，也未定义更新写回中途取消后 CWorkDirTempFile 归属。 | 补全取消清理契约并验收：(1) 明确解压取消后『已完成文件保留 vs 全部回滚』策略（对齐 Windows 7zG 或显式偏离）；(2) 归档更新取消后 CWorkDirTempFile 清理责任落桥接层 finally；(3) M2 加『取消后目标/临时目录无残留，原归档完好(CRC 校验)』，纳入 R5/R-MOVEARC 触发信号。 | **采纳** |
| 4-7 | major | 05-roadmap-execution.md | 多任务并行(同时压缩+解压)的资源策略缺失：mt 线程数、内存、QoS 在并发下超订，无全局协调 | 01 §6.1/05 R6 只解决对象生命周期单线程与 per-operation context 防全局态污染，无跨任务资源预算。每个 SZCompressor/SZExtractor 各持串行队列并把 threadCount/mt 透传引擎(02:523)，引擎按 mt 自起 pthread。用户同跑 2 压缩+1 解压时 3×mt(默认核数) 达 3 倍物理核线程超订 + 3 份字典内存(高等级 LZMA2 数百 MB/任务)叠加，无全局上限/内存仲裁。05-T4 只一句『必要时串行化』，§9.4 基准全单任务。 | 定义全局任务调度与资源仲裁：(1) 进程级 NSOperationQueue/限流器控制并发引擎任务数(按核数/内存动态)；(2) 并发时 mt 与字典内存全局收敛(总线程≤物理核、总字典≤RAM 上限)；(3) §9.4 补『2 压缩+1 解压并发吞吐与内存峰值』基准，R6 触发信号补『并发任务总内存触顶/系统卡顿』。 | **采纳** |
| 4-8 | minor | 02-core-bridge.md | dataForEntryAtIndex 预览 API 把单条目整读进 NSData，无大小阈值/流式回退，大文件预览即 OOM | SZArchive 预览 API 自陈『返回 NSData(小文件)或写入 outputStream』(02:425-426)，但签名只返回 NSData(02:426)，无阈值参数、无 outputStream 重载、无大小上限。FM 预览/QuickLook 若对归档内 4GB 文件调用会把整段解压塞进内存。对照归档内编辑路径上游本有内存阈值保护(PanelItemOpen.cpp:1590-1603 g_RAM_Size>>max(层数+1,8))，预览 API 反而丢了保护。 | 预览 API 增大小阈值与流式回退：超阈值(参考 g_RAM_Size 算法)时返回写入 NSURL/outputStream 的临时文件而非 NSData，或提供 dataForEntryAtIndex:maxBytes: 显式上限并对超限返回错误，避免大条目预览 OOM。 | **采纳** |

### 3.5 角色五 · 合规与发布审查官

| # | severity | 文档 | 标题 | 证据 | 建议 | 处置结果 |
|---|---|---|---|---|---|---|
| 5-1 | **blocker** | 05-roadmap-execution.md | LGPL §6 重链接义务被『若需』弱化并甩进开放问题 Q5，桥接层静态链接 LGPL 代码边界认定缺失——是发布前硬义务非待裁决项 | 01:17/:91-93 明确 SevenZipKit『内部链接 UI/Common + UI/Agent』『整包编入本 framework』；02:217 把 Agent 7 个 .o『编入 framework』。这些文件按 License.txt 规则全是 LGPL。05 §10.1#3(:274) 用『若 app 静态链接 LGPL…须额外提供对象文件或源码』，:277 又用『（若需）对象文件归档可供下载』弱化，Q5(:382) 定性『需法务确认』。LGPL 2.1 §6 对静态链接要求分发方提供可重链接材料（目标文件+链接脚本）或用共享库机制——是确定的发布前置义务，dylib 动态链接覆盖不了静态进 framework 那部分。 | M5-T8 把『提供 SevenZipKit 内所有 LGPL 目标文件(UI/Common、UI/Agent 的 .o)+链接脚本，使用户能用自改 LGPL 代码重链接出等价 framework』列强制交付物(非『若需』)，验收：提供的 .o + ld 调用能重链接出可加载 framework。Q5 从『是否需要』改为『按 §6 哪种合规路径落地（提供 .o 重链接 / UI·Agent 拆独立 dylib 动态链接 / 整体开源 SevenZipKit）』三选一工程决策。 | **采纳** |
| 5-2 | **blocker** | 05-roadmap-execution.md | 随包许可清单只点名 License.txt，遗漏仓库内已存在的 LGPL 全文 copying.txt，且 License.txt 本身不含 LGPL 正文 | 实测 DOC/copying.txt 第 1-2 行即『GNU LESSER GENERAL PUBLIC LICENSE Version 2.1』——完整正文已在仓库内。但 DOC/License.txt 对 LGPL 只写『可从 gnu.org 获取副本』(不含正文)。05 §10.1#2(:273) 随包清单写『完整 License.txt + LGPL 全文 + 各第三方许可』，但『LGPL 全文』来源未指向 copying.txt，全文 grep 仅 DOC/copying.txt 命中。若照字面只搬 License.txt(:273/:282 多处只点名它)，分发包将缺 LGPL 正文，违反『随分发提供本许可副本』。 | §10.1#2 明确逐一点名：DOC/License.txt（7-Zip 许可与归属）+ DOC/copying.txt（LGPL 2.1 全文）+ DOC/unRarLicense.txt（unRAR 原文），三者缺一不可；验收改为『.app/Contents/Resources/ 下存在以上三文件且字节与 DOC/ 一致』。 | **采纳** |
| 5-3 | major | 05-roadmap-execution.md | unRAR 条款只覆盖『禁止重建 RAR 算法』，遗漏 unRarLicense.txt 第 3 条『未经书面许可不得对 unRAR 分发收费』对付费/商业发布的影响 | 实测 DOC/unRarLicense.txt 第 3 条：『No person or company may charge a fee for the distribution of unRAR without written permission.』05 §10.2(:281-283) 只处置『不得宣称创建 RAR』与『商店用 DISABLE_RAR』，对『含 RAR 时若产品收费/付费分发』只字未提。§10.1#2 要求随包 unRarLicense.txt 原文(第 3 条即在其中)，一旦付费分发且含 RAR handler，第 3 条与商业意图直接冲突，需法务判定适用范围。 | §10.2 增决策项：明确产品是否付费分发；若付费且保留 RAR，须取得 Roshal 书面许可或默认对所有付费/商店渠道用 DISABLE_RAR=1 出无 RAR 切片。把『付费分发 × 含 RAR』列入风险登记册 R-RAR 触发信号，验收加『付费版确认不含 RAR handler』。 | **采纳** |
| 5-4 | major | 05-roadmap-execution.md | 上游同步 SOP 假设存在可三方合并的 git vendor 分支，与『官方 7-Zip 整包发布、无上游 git 仓库』现实矛盾——SOP 第一步即不可执行 | 05 §11.2 步骤1(:348)：『获取官方新版源码，在新分支用 git 三方合并(上游 vendor 分支→主分支)』。但 git log 实测每版是整包提交(8c63d71=26.01、839151e=26.00、5e96a82=25.01)，官方以 .tar.xz 整包发布、无公开 git 历史与可合并 vendor 分支。SOP 把不存在的 vendor 分支当合并基线，实操无三方合并的共同祖先。 | §11.2 重写为整包覆盖式 SOP：(1) 解压官方 .tar.xz 到 vendor 临时树；(2) 本地维护『纯上游』git 分支，每版整包覆盖后 commit（人造上游历史）作三方合并 base；(3) 主分支从人造 vendor 分支 merge；(4) 给无 git 退路（逐目录 diff + 补丁重放）。明确 Mac/ 隔离层不参与覆盖。 | **采纳** |
| 5-5 | major | 05-roadmap-execution.md | 第三方 BSD 组件（LZFSE/ZSTD 的 BSD-3、XXH64 的 BSD-2）的二进制再分发署名义务未列入合规清单——代码随 lib7z.dylib 进入二进制 | DOC/License.txt 明确 lib7z.dylib 内含 BSD-3(LzfseDecoder.cpp、ZstdDec.c，版权 Apple/Facebook/Igor Pavlov)与 BSD-2(Xxh64.c，版权 Yann Collet)。两种 BSD 第 2 条均要求『二进制再分发须在文档/随附材料重现版权声明与许可条款』。05 §10 只处理 LGPL/unRAR/商标，§10.1#4(:275) 仅泛泛『保留原始版权声明』，未把 BSD-3/BSD-2 二进制署名作独立合规项；05 全文 grep BSD/LZFSE/ZSTD/XXH64 无命中。XXH64 还出现在哈希子菜单(03/04)是用户可见功能。 | §10 新增『第三方 BSD 组件署名』小节，列 LZFSE(BSD-3, Apple)、ZSTD(BSD-3, Facebook)、XXH64(BSD-2, Yann Collet) 三项，要求随包 License.txt/about 重现各自版权行与许可正文；验收：about 框或 Resources 内可见三组 BSD 署名与条款。 | **采纳** |
| 5-6 | major | 05-roadmap-execution.md | 商标/署名处置只到『建议』层级，未给可验收硬约束：产品名/Bundle ID 仍含『7zip/SevenZip』，且未要求保留引擎内 Igor Pavlov 版权到 about 框 | 05 §10.3(:287-289) 命名只说『建议产品名独立』『建议 about 声明非官方』，最终命名甩进 Q6(:383)。同时 01:59/:312 与 05:68 把 UserDefaults 域/错误域硬编码 com.7zip.SevenZipFM / com.7zip.SevenZipKit；§10.3 自承『SevenZipFM 仅内部 target 名』但全套 Bundle/域/类名都带 7zip/SevenZip，面向用户的发布名空缺。LGPL/BSD 均要求保留版权声明（引擎含 Igor Pavlov 版权），§10 未把 about 框展示列硬验收。 | §10.3 把『最终产品名+图标+Bundle ID(自有域名反写)+about 非官方声明文案』升级为 M5-T8 明确交付物与验收项(非建议+Q6 推迟)；增验收：about 框同时展示(1)第三方移植声明、(2)『基于 7-Zip，Copyright Igor Pavlov』、(3)LGPL/unRAR/BSD 许可入口。评估把 com.7zip.* 域名改自有域名避免商标暗示。 | **采纳** |
| 5-7 | minor | 05-roadmap-execution.md | 签名/公证脚本缺 DMG 的具体签名+公证命令、缺 entitlements 文件清单内容、缺 hardened runtime 下 dlopen 未签名/Team 不一致 dylib 的失败兜底 | 05 §10.4 步骤8(:329) 只写『DMG 再签名+公证+staple（同上）』无 hdiutil/codesign DMG 命令；entitlements 文件在步骤3/4 被引用(:306/:312)但全文未给键(FinderSync 需 application-groups，dlopen 第三方需对应 entitlement)。04 §3.4/§7 称『hardened runtime 下 dlopen 同签名 dylib 无障碍』，但 7z.so 符号链接(02:142 ln -sf)参与签名/公证时 symlink 在 .app 内签名与 stapler 行为需验证。 | §10.4 补全：(1) DMG 的 hdiutil create + codesign --sign + notarytool submit + stapler staple 完整命令；(2) 两个 entitlements 文件最小键集（含 App Group ID、FinderSync 相关）；(3) 验收加『干净机内 .app 内 7z.so 符号链接随 .app staple 后 dlopen 成功』『spctl -a 对 appex 单独 accepted』。 | **采纳** |

---

## 4. 遗留开放问题

> 本节汇总两类未定案项：**(A) 被驳回但有争议**——本轮 43 条 findings 全部采纳，无此类项；**(B) 起草阶段 openQuestions 中仍未定案**——下列均为设计草拟阶段遗留、本轮评审未消解、仍需产品/工程/法务后续拍板的开放问题。
>
> 说明：部分 finding 的处置（如 4-2/4-5/5-1/5-3）已把对应开放问题从『是否需要』升级为『按哪条路径落地』，但落地选项的最终选择仍未定，故相关项继续保留在本清单跟踪。

### 4.1 (A) 被驳回但有争议的 findings

无。本轮全部 43 条 findings 均被修订人采纳并改入对应文档，无驳回项，故无此类争议遗留。

### 4.2 (B) 起草阶段 openQuestions 仍未定案

#### 构建/ABI/dylib

| 编号 | 开放问题 | 待定点 |
|---|---|---|
| O-01 | dylib 文件名取 `7z.so` 还是 `lib7z.dylib` | **已定案（01 §3.3 与 02 §1.2 统一）= `lib7z.dylib` + 兼容软链 `7z.so → lib7z.dylib`**：产物用 `lib7z.dylib`（品牌/习惯），软链让复用 LoadCodecs::kMainDll(`7z.so`，LoadCodecs.cpp:72-77) 的路径零改动命中。残留仅"带软链 vs 改一行 kMainDll"取舍（默认带软链） |
| O-02 | dylib 装载方式：dlopen 外置全格式 bundle（方案B 名义）还是桥接层退化为静态链接全部格式进 framework（底料指出静态链接最稳、已验证；单 dylib 需补模块路径发现与 .so 后缀验证） | 影响仓库布局与构建产线 |
| O-03 | EXPORTS_LIST 相对路径解析：var_mac_arm64_dylib.mak 中 exports7z.txt 在 bundle 目录内执行 make 时如何稳定解析（绝对路径/$(CURDIR)/裸文件名） | 需 M0 构建脚本定案 |
| O-04 | `-Wl,-exported_symbols_list` 与 `-dead_strip` 交互：4041→19 收敛后 dead_strip 是否误删被导出间接引用的内部符号 | 需实测 nm + 完整 roundtrip 确认无运行时 dlsym 失败 |
| O-05 | x86_64 切片汇编/HW intrinsics：var_mac_x64.mak 关闭 USE_ASM，x64 的 SHA/AES/LZMA 走 C 还是 SSE intrinsics、是否为 x64 单独开 USE_ASM | 涉及 x86 .asm 的 clang 兼容性 |
| O-06 | `SetCodecs(NULL)` 卸载链路是否必需：桥接层不走 LoadCodecs 时是否仍需退出前 SetCodecs(NULL)；常驻不 dlclose 时能否省 | FM 复用 Agent→CCodecs 路径会触发该链路 |
| O-07 | 引用计数原子化取舍：默认 ++/-- 非原子，本文默认对象生命周期单线程化规避；若需跨线程共享对象，需定义 Z7_COM_USE_ATOMIC 并补 Interlocked 且双侧重编 | 代价需评估 |

#### 桥接/编码/时间

| 编号 | 开放问题 | 待定点 |
|---|---|---|
| O-08 | NFC/NFD 规范化策略：全仓无任何 Unicode 规范化，档内名(NFC)与磁盘名(NFD)比较会失配（05-platform-layer §5#3）；入档统一 NFC+比较双向规范化是建议方向 | 具体落点（桥接层哪一处、是否影响 wildcard）需专项设计与测试集验证，新增工作项无现成代码 |
| O-09 | NFC/NFD 规范化精确插桩点：插在 SZArchiveEntry.path 读出 / SZCompressItem 入档 / 覆盖比较哪一层，避免双重规范化 | 需结合 03 覆盖/更新检测逻辑确定 |
| O-10 | VT_FILETIME 精度字段在 NSDate 往返的最优保真：全新压缩时 NSDate(毫秒)→FILETIME 的 wReserved1 精度等级默认填什么 | 需对照 tar/zip handler 期望(PropID.h:136-170) |

#### 平台/安全/沙箱

| 编号 | 开放问题 | 待定点 |
|---|---|---|
| O-11 | Finder 集成与主 App 通信机制：URL scheme 唤起 vs NSXPCConnection，在沙箱权限/App Group 文件访问/是否切换主 App 体验上不同 | 需 Finder 扩展原型阶段实测确定 |
| O-12 | 可选 helper 进程是否纳入主线：进程内化是默认决策，但若早期就兼顾 App Store 沙箱权限分离，XPC helper 引入时机需与路线图协调 | 与 4-5 崩溃隔离决策联动 |
| O-13 | quarantine 写入具体 API（qtn_file_* vs NSURL quarantinePropertiesKey）与时机（对可执行/全部文件策略），替代 Windows WriteZoneIdExtract | 需结合 Gatekeeper 预期实测 |
| O-14 | WriteZoneIdExtract 三档策略（始终/仅可执行/从不，ZipRegistry.cpp:544）到 com.apple.quarantine 精确映射（哪些来源/类型打标、如何传播） | 源码标为『重设计而非直译』，需安全评审定档 |
| O-15 | FinderSync 扩展未在『系统设置→扩展』启用时右键无菜单，体验降级：是否需首启引导 + Services 兜底，Services 覆盖哪些命令子集 | 与 2-1 能力边界联动 |

#### 功能范围/裁剪取舍

| 编号 | 开放问题 | 待定点 |
|---|---|---|
| O-16 | OQ-1 列配置持久化格式：FM\Columns 二进制 blob(ViewSettings.cpp:52-120) 首版直搬 blob 还是改结构化 plist/autosaveName | **已定案（finding 3-4 落地）= 首版即结构化 plist（弃 blob，以 05 §4.2 为准）**；属实现细节非功能降级。残留仅"是否额外提供 blob 导入以兼容 Windows 旧配置"为增强项 |
| O-17 | OQ-2 Return 键二义：mac 列表 Return 习惯=重命名而 7zFM Enter=打开，最终 Return 绑 Rename 还是 Open（本章默认 Rename） | 与 finding 2-6 直接相关，需 UX 评审；评审建议默认应站 Open（一对一） |
| O-18 | OQ-3 四视图模式取舍：Large/Small Icons/List/Details 是否首版全做（Icons/List 需 NSCollectionView） | **已分类（finding 3-4 落地，05 §0.4）=【分期·一对一范围内，非裁剪】**：M4 交付 Details+Large Icons，List/Small 目标 v1.1。**需产品签字**"一对一硬标准是否允许 View 菜单项分期"；未签字前从严按四档全进 M4（+≈3 人日） |
| O-19 | OQ-4 CVirtFileSystem 内存优化：归档内打开小文件先入内存(阈值 RAM>>max(层数+1,8)) 是否移植还是首版一律落盘临时文件 | 与 1-1/4-8 预览内存策略联动 |
| O-20 | OQ-5 备选选择模式 _mySelectMode：FAR 风格 Ins/Shift 选择(App.cpp:98-108) 是否移植，mac 用户罕见 | **已分类（finding 3-4 落地，05 §0.4）=【分期·一对一范围内，非裁剪】**：M4 标准多选+保留 `FM.AlternativeSelection` 键，FAR 交互目标 v1.1。**需产品签字**（若认定可裁剪须给替代=键保留但 UI 隐藏并提示）；未签字前从严按 FAR 交互进 M4 |
| O-21 | OQ-6 Cmd+V 粘贴文件进归档：mac 可用 NSPasteboard 实现比 Windows 更完整（Windows EditPaste 空实现） | 是否启用（超出一对一属增强） |
| O-22 | OQ-7 ShowSystemMenu 语义：Windows 右键并入系统 Shell 菜单(PanelMenu.cpp:919-985) 在 mac 无对应 | 改为右键含『在访达中显示』开关还是直接移除 |
| O-23 | OQ-8 地址栏控件选型：面包屑 ComboBoxEx 用 NSPathControl 还是可编辑 NSComboBox+自绘下拉 | 与 finding 2-4 相关，评审倾向自建复合控件，需原型验证 |

#### 本地化/UI 体系

| 编号 | 开放问题 | 待定点 |
|---|---|---|
| O-24 | 本地化体系：保留 7-Zip 自带 Lang/*.txt 纯文件解析（一对一程度高、92 语言可随 .app 分发）还是改 NSLocalizedString/.strings（更原生） | 影响 39 个 .rc 对话框字符串迁移方式，需产品/工程评审 |
| O-25 | 多任务进度并行是否需要『操作中心』汇总面板（统一暂停/取消/清理，类似 Safari 下载列表） | v1 为每操作独立非模态进度窗，操作中心属增强、非一对一必需；与 4-7 并发资源策略联动 |

#### 高风险/范围决策

| 编号 | 开放问题 | 待定点 |
|---|---|---|
| O-26 | 进程内化丧失崩溃隔离：是否对超大任务（>50GB 或 >100k 文件）保留 XPC 子进程模式以隔离崩溃 | 与 finding 4-5 同源，评审已要求升为明确决策项并给阈值判据 |
| O-27 | SFX 自解压在 mac 的形态：Windows PE 模块 7z.sfx 无法复用，是否提供 mac 等价（shell 脚本壳 / 可执行 stub + 附加 .7z） | 属一对一范围外新功能，需范围决策；v1 暂隐藏 SFX 复选 |
| O-28 | Email/分享系列（Compress to Email，Windows 依赖 MAPI）是否进 v1 | 拖放/Email 在 mac 习惯弱，可首版裁剪后续以 NSSharingService 补齐 |
| O-29 | QuickLook 预览/缩略图扩展是否纳入范围（Windows 经 Shell 缩略图提供器，mac 需独立 QuickLook 扩展） | 属平台贴合增强 |
| O-30 | 是否提供 Apple Events/AppleScript 字典(.sdef)：已规划 URL scheme + App Intents 两条主自动化通道，传统 AppleScript 仅兼容老 Automator | 优先级待定 |

#### 发布/法务/基础设施（Q 系列）

| 编号 | 开放问题 | 待定点 |
|---|---|---|
| Q1 | Developer ID 证书/Apple 开发者账号归属与团队 ID | 阻塞 M0 签名公证 |
| Q2 | macOS CI 基础设施：universal 构建+公证是否在 CI 内执行还是手动放行 | 与 4-3 性能 CI 闸门联动 |
| Q3 | SFX 取舍：Windows .exe 自解压在 mac 无等价物，移除/生成 exe SFX/研究 mac SFX 三选一 | 与 O-27 同源 |
| Q4 | Email 命令族（Windows MAPI）在 mac 用 NSSharingService 重做还是首版裁剪 | 与 O-28 同源 |
| Q5 | LGPL 重链接义务范围：app 静态链接的 LGPL 代码（UI/Common/Agent）是否需随包提供对象文件 | finding 5-1 已要求改为『按 §6 哪条路径落地』三选一工程决策，路径最终选择仍待法务确认 |
| Q6 | 产品最终命名与商标：避免暗示 7-Zip 官方出品前提下的用户产品名/图标/Bundle ID 定案 | finding 5-6 已要求升为 M5-T8 交付物，命名最终值仍待定 |
| Q7 | App Store/沙盒优先级：是否纳入首版（额外约 15-20 人日：XPC/security-scoped bookmark/entitlements） | 与 2-2/2-3 沙箱约束联动 |
| Q8 | 对照测试基准来源：能否获得 Windows 7-Zip 26.01 生成对照样本，还是仅以本机 7zz CLI 为基准（GUI 默认值/路径处理可能细微差异） | 影响一对一回归判据 |

---

> 存档说明：本记录为 `01`~`05` 设计文档第一轮对抗评审的最终归档。所有 findings 已闭环（全部采纳），文档级修订改动见各文档对应章节。遗留开放问题（O-01~O-30、Q1~Q8）转入后续设计/产品决策跟踪，不阻塞已采纳修订的合入。
