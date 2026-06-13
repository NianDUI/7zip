# 03 7zFM 功能一对一映射（FileManager → macOS AppKit）

> 适用方案：方案 B（lib7z.dylib 核心库 → SevenZipKit.framework ObjC++ 桥接 → SevenZipFM.app AppKit）。
> 目标：macOS 13.0+，universal（arm64 + x86_64）。
> 本章是 7zFM（`CPP/7zip/UI/FileManager`，147 文件 / 约 39.2k 行）的**逐功能可执行移植清单**。源码证据格式 `文件:行号`，相对 `CPP/7zip/UI/FileManager/`，跨目录给全相对路径。
> 架构总览见 `01-architecture.md`；桥接 API（SevenZipKit）的头文件草案与所有权约定见 `02-core-bridge.md`；7zG 系列对话框（压缩/解压/覆盖/密码/进度/内存）的窗口设计见 `04-feature-map-dialogs-finder.md`；执行排期见 `05-roadmap-execution.md`。

---

## 0. 本章范围与读者须知

### 0.1 本章 vs 04 章的边界

7zFM 在 Windows 上把"压缩/解压 GUI"委托给独立进程 7zG（`UI/Common/CompressCall.cpp`，命令行 + FileMapping IPC，见 03-explorer-agent.md §1.4 / 05-platform-layer.md §6）。源码中**物理上位于 `UI/FileManager/` 但属于 7zG 链接单元**的对话框有 6 个：OverwriteDialog、PasswordDialog、ProgressDialog2、MemDialog、ListViewDialog（哈希结果用）、EditDialog（02-gui-dialogs-inventory.md §0 FM_OBJS）。本章 §2 仅给"7zFM 自身专属"对话框的窗口设计；上述 6 个共享对话框的控件级设计归 04 章，本章只在功能映射表里指向它们。

方案 B 取消 7zG 子进程（05-platform-layer.md §6 决议：FM 与 GUI 操作合并为单进程），因此本章所有"调 7zG"的命令在 mac 上改为 **进程内调用 SevenZipKit + 弹 AppKit 窗口**；具体压缩/解压窗口仍由 04 章定义，本章负责"从 7zFM 哪个命令唤起它"。

### 0.2 命名约定

| 缩写 | 含义 |
|---|---|
| `SZ*` | SevenZipKit.framework 导出的 ObjC 类/协议（头文件草案见 02-core-bridge.md） |
| PanelModel | 从 `CPanel`（Panel.h）抽取的无 UI 状态机（路径栈/选择集/排序/列模型），编入 dylib 或 framework，见 01-filemanager-inventory.md §9.2 |
| 工作量 | S=≤2 人日；M=3–8 人日；L=>8 人日（含设计+实现+测试，单工程师口径） |

### 0.3 贯穿全章的桥接依赖（先声明，后表中引用代号）

| 代号 | 桥接能力 | 来源 |
|---|---|---|
| BR-Folder | `SZFolder`（包装 IFolderFolder）：LoadItems/枚举/属性/BindToFolder/BindToParent | 02-core-bridge.md；接口 IFolder.h:29-40 |
| BR-Ops | `SZFolderOperations`（包装 IFolderOperations）：CreateFolder/CreateFile/Rename/Delete/CopyTo/CopyFrom/CopyFromFile/SetProperty | IFolder.h:76-89 |
| BR-Open | `SZArchiveSession`（CArchiveFolderManager::OpenFolderFile 后台线程 + 进度 + 密码回调） | 03-explorer-agent.md §2.5 |
| BR-Extract | `SZExtractCallback`（IFolderArchiveExtractCallback：AskOverwrite/SetOperationResult） | 03-explorer-agent.md §2.3 |
| BR-Update | `SZUpdateCallback`（IFolderArchiveUpdateCallback(2)：进度/错误，含 MoveArc 回写协议） | 03-explorer-agent.md §2.6 |
| BR-Hash | `SZHashCalculator`（CHashBundle 流式哈希） | 01-filemanager-inventory.md §7 |
| BR-Codecs | `SZEngine`（dlopen 7z.so + LoadGlobalCodecs，进程级单例） | 04-core-dylib.md §4.1 |
| SYS-* | macOS 系统能力（NSWorkspace/NSPasteboard/FSEvents/NSTask/UTType/NSOpenPanel…） | 05-platform-layer.md §2 |

---

## 1. 主映射表（按菜单 / 面板行为分组）

> 列含义：**功能**（菜单命令/行为 + 源码引用）→ **mac 实现**（AppKit 组件 + SevenZipKit 调用）→ **依赖**（桥接 API/系统能力代号）→ **工作量**→ **行为差异备注**。
> 命令 ID 与处理链来自 01-filemanager-inventory.md §1（已全量覆盖 File/Edit/View/Favorites/Tools/Help 六菜单 + 面板键盘命令 + 右键菜单）。所有命令在 mac 统一收口到一个 `SZFMCommandRouter`（对应 Windows 的 `OnMenuCommand`/`ExecuteFileCommand`，MyLoadMenu.cpp:736-964），用 `NSMenuItem.tag`= 原 IDM_* 常量驱动，使命令决策层与 Windows 一一对应。

### 1.1 File 菜单（resource.rc:35-79）

| 功能（IDM / 源码） | mac 实现 | 依赖 | 量 | 行为差异 |
|---|---|---|---|---|
| Open=540（OpenSelectedItems(true)，App.h:121）| 默认动作：归档→进入面板（BindToPath）；非归档→`-[NSWorkspace openURL:]`。沿用 `kStartExtensions` 智能判定（PanelItemOpen.cpp:629-668） | BR-Open / SYS-NSWorkspace | M | exe 类无"可执行"概念；用 LaunchServices 默认应用 |
| Open Inside=541（OpenItemInside(NULL)）| 强制按归档打开（即便扩展名在 kStartExtensions），新建 SZArchiveSession 入栈 | BR-Open | S | 一致 |
| Open Inside *=590 / # =591 / #:e（`*`/`#` 强制格式/parser，MyLoadMenu.cpp:752-753）| 同上，OpenFolderFile 传 `-t*`/`-t#`（ParseOpenTypes，03-explorer-agent.md §2.5） | BR-Open | S | 一致 |
| Open Outside=542（OpenSelectedItems(false)，App.h:123）| 强制外部打开：`NSWorkspace openURLs:withApplicationAtURL:`（归档项需先解压临时文件，见 §5.1） | SYS-NSWorkspace / BR-Extract | M | Shift+Enter |
| View=543 / Edit=544（EditItem(false/true)，F3/F4）| 用 Settings 配置的 Viewer/Editor 程序打开（NSTask 或 NSWorkspace openURLs:withApplicationAtURL:）；归档内项触发"解压临时→编辑→回写"全流程（§5.1） | SYS-NSTask / 见 §5.1 | M | Viewer/Editor 默认空=用系统默认应用 |
| Rename=545（RenameFile，F2，就地编辑，PanelOperations.cpp:264-359）| NSTableView 行内编辑（`-tableView:shouldEditTableColumn:`→`NSTextField`）；提交→`SZFolderOperations rename:to:`；FS 名合法化用 `CorrectFsPath` | BR-Ops | M | mac 文件名禁 `/` 与 NUL；`:` 在 Finder 显示为 `/`，需提示。`..`/只读层禁止 |
| Copy To=546 / Move To=547（OnCopy，F5/F6，App.cpp:565-856）| CopyDialog（见 §2 CopyDialog）→ 四条复制路径（§5.4）；目标默认=另一面板路径 | BR-Ops / BR-Extract / BR-Update | L | 见 §5.4；无回收站语义参与 |
| Delete=548（Delete，Del / Shift+Del，PanelOperations.cpp:112-262）| FS 项：默认 `-[NSWorkspace recycleURLs:completionHandler:]`（废纸篓）；Shift+Del=`NSFileManager removeItemAtURL:`（永久）；归档内项=`SZFolderOperations delete:`（重压缩）。确认框 NSAlert（单文件/单目录/N 项三文案） | SYS-NSWorkspace / BR-Ops | M | `SHFileOperation FOF_ALLOWUNDO` → recycleURLs；无 MAX_PATH 限制 |
| Split file=549（Split，PanelSplitFile.cpp:235-342）| 见 §2 SplitDialog；`CThreadSplit` 逻辑（顺序写 .001…，预分配，进度）整体复用，进度走 SZ 进度窗 | BR-Codecs(无需) / 纯 IO | M | 卷数≥100 二次确认保留 |
| Combine files=550（Combine，PanelSplitFile.cpp:345-560）| 选第一卷→探测 .001/.002 序列→`CThreadCombine` 拼接 | 纯 IO | S | 一致 |
| Properties=551（Properties，Alt+Enter，PanelMenu.cpp:172-423）| **双路径（与 Windows 一致区分）**：① 归档/归档内项（实现 IGetFolderArcProps，PanelMenu.cpp:174-180）→ `SZPropertiesWindow`（自绘属性窗，见 §2）；② 纯 FS 项（无 IGetFolderArcProps，Windows 走 `InvokeSystemCommand("properties")` 调系统 Shell 属性对话框并 return，PanelMenu.cpp:178）→ mac 无 Shell "properties" 动词，**新建基于 `NSURL resourceValuesForKeys:` 的 FS 属性窗**（行为新增，非平移） | BR-Folder / SYS-NSURL | M | **行为差异澄清**：Windows 下 FS 项从不显示自绘窗（走系统对话框），mac 因无等价动词改为新建 FS 属性窗——这是行为新增；归档项两端均为自绘窗 |
| Comment=552（ChangeComment，Ctrl+Z，PanelOperations.cpp:487-533）| ComboDialog 读写 `kpidComment`→`SZFolderOperations setProperty:kpidComment`（仅 zip 支持，03-explorer-agent.md §2.6） | BR-Ops | S | Ctrl+Z 在 mac 是撤销→改 Cmd+/ 或菜单项（见 §4） |
| CRC 子菜单 101-122（CalculateCrc("method")，10 种算法，resource.rc:56-69）| File 子菜单 + 右键，每项调 `SZHashCalculator calculate:method:`；结果弹 SZHashResults 窗（ListViewDialog 等价） | BR-Hash | M | 算法集 = dylib 支持集（CRC32/64/XXH64/MD5/SHA1/256/384/512/SHA3-256/BLAKE2sp，"*"=全部） |
| Diff=554（DiffFiles，PanelItemOpen.cpp:747-814）| 仅当 Settings 配置 Diff 程序才显示；选 2 文件→NSTask 启动外部 diff | SYS-NSTask | S | 同 Windows：默认隐藏 |
| Create Folder=555（CreateFolder，F7，PanelOperations.cpp:363-476）| ComboDialog 输入名（默认 "New Folder"）→`SZFolderOperations createFolder:`（FS 与归档内均支持） | BR-Ops | S | 一致 |
| Create File=556（CreateFile，Ctrl+N / Shift+F4）| 同上→`createFile:`。**归档内 createFile 引擎未实现（E_NOTIMPL，ArchiveFolderOut.cpp:439-442）**，归档内禁用该项 | BR-Ops | S | 归档内置灰并提示（避免按 Finder 习惯过度承诺，03-explorer-agent.md 风险#11） |
| Link=558（Link，LinkDialog.cpp:79-400）| 见 §2 LinkDialog；mac 仅保留 Hard / Symbolic（file/dir 合一）两类，砍 Junction/WSL | SYS-symlink/link | M | Junction/WSL 无对应（01 §10）；reparse 直写改 `symlink()`/`link()` |
| Alternate streams=559（OpenAltStreams）| **砍掉**（NTFS ADS，mac 无对应，01 §10；AltStreamsFolder 不编译，05 §5.7）| — | — | 菜单项移除 |
| Exit=IDCLOSE（WM_CLOSE）| Cmd+Q→`-[NSApplication terminate:]`，关窗前保存全部状态（§3） | — | S | mac 关窗≠退出；保留 Quit 与关窗分离 |
| Ver Edit/Commit/Revert/Diff=580-583（VerCtrl，7vc，隐藏，VerCtrl.cpp）| 仅当 Settings 配置 `7vc` 目录且单选 FS 文件时显示；逻辑（带编号快照复制）可复用，启动外部程序改 NSTask | SYS-NSTask | M | 小众功能，可后置（05 排期） |
| Benchmark2=902（隐藏 super mode）| 同 Tools→Benchmark，传 totalMode | BR-Codecs | S | 见 Tools |

### 1.2 Edit 菜单（resource.rc:80-94）

| 功能（IDM / 源码） | mac 实现 | 依赖 | 量 | 行为差异 |
|---|---|---|---|---|
| Select All=600（SelectAll(true)，MyLoadMenu.cpp:831-834；键 Ctrl+A 与 Shift+Grey+）| `-[NSTableView selectAll:]` 同步 PanelModel `_selectedStatusVector`；刷新状态栏 | PanelModel | S | Cmd+A |
| Deselect All=601 / Invert=602（SelectAll(false)/InvertSelection）| PanelModel 操作 + 重设 NSTableView selectionIndexes | PanelModel | S | 见 §4 键位 |
| Select…=603 / Deselect…=604（SelectSpec，通配框，PanelSelect.cpp:154-167）| ComboDialog 输入通配符→PanelModel 通配匹配（Wildcard.cpp，mac 默认大小写不敏感）→设选中集 | PanelModel | S | 一致 |
| Select by Type=605 / Deselect by Type=606（SelectByType，PanelSelect.cpp:169-204）| 按焦点项扩展名/文件夹类型批选 | PanelModel | S | 一致 |
| Cut/Copy/Paste（注释掉的菜单项，键仍映射 EditCut/Copy/Paste，PanelKey.cpp:283-303）| 见 §5.5 剪贴板专节；EditCopy=复制名称文本到 NSPasteboard；EditCut/EditPaste 现为空实现 | SYS-NSPasteboard | S | 与 Windows 一致（仅文本名） |

### 1.3 View 菜单（resource.rc:95-133）

| 功能（IDM / 源码） | mac 实现 | 依赖 | 量 | 行为差异 |
|---|---|---|---|---|
| Large/Small Icons / List / Details=700-703（SetListViewMode(0..3)，Ctrl+1..4，Panel.cpp:871-892）| Details=NSTableView（多列）；Large/Small Icons + List=`NSCollectionView`（flow layout，图标大小区分）。视图模式切换=换 NSScrollView 文档视图 | SYS-NSCollectionView | L | mac 四种视图须自建；Icons/List 用 CollectionView，Details 用 TableView。**四档均属一对一范围（必做、不砍）；分期：M4 交付 Details + Large Icons，List/Small 延至 v1.1 补齐**（分期分类与产品拍板项见 OQ-3） |
| 排序 Name/Type/Date/Size=710-713（SortItemsWithPropID(kpid*)，Ctrl+F3..F6，PanelSort.cpp:256-278）| NSTableView `sortDescriptors`（Details）+ 排序菜单（Icons）；比较委托 PanelModel `IFolderCompare`（目录恒在文件前，".."恒最前，PanelSort.cpp:98-221） | PanelModel | M | 默认降序列（Size/时间）保留；自定义比较器不可纯用 NSSortDescriptor key path，须用 `comparator:` 桥到 PanelModel |
| Unsorted=730（kpidNoProperty，Ctrl+F7）| PanelModel 关排序，按 LoadItems 顺序 | PanelModel | S | 一致 |
| Flat View=731（ChangeFlatMode，Panel.cpp:894-902，每面板/盘内归档内分记忆）| PanelModel FlatMode（Agent.cpp:112-165 递归铺平）；Details 视图展示全路径前缀列 | PanelModel | M | 一致（FlatViewArc0/1 持久化照搬） |
| 2 Panels=732（SwitchOnOffOnePanel，F9，App.cpp:360-380）| 见 §5.2 双面板专节；NSSplitView 显隐第二面板 | — | M | F9 在 mac 无冲突，保留 |
| 时间戳精度子菜单 760/761/799（动态 DAY/MIN/SEC/NTFS/NS + UTC，SetTimestampLevel，MyLoadMenu.cpp:440-506）| 动态 NSMenu 子菜单（同结构）；格式化逻辑（PanelListNotify.cpp 5 级精度）复用，输出经 `NSDateFormatter` 或自管格式串 | PanelModel | M | 一致；FILETIME 精度协议保留（02-core-bridge.md §2.4 wReserved 字段） |
| Toolbars 子菜单 750-753（Archive/Standard Toolbar / Large Buttons / Show Text，MyLoadMenu.cpp:903-907）| NSToolbar 配置：显隐两组工具栏项、`displayMode`（icon/icon+text）、`sizeMode`（regular/large）；改后存盘 | SYS-NSToolbar | M | mac 用单一 NSToolbar，"两组"→分区项；勾选态映射到 toolbar 自定义面板 |
| Open Root Folder=734（OpenDrivesFolder，`\` 键，App.h:168）| 进入"计算机"虚拟文件夹=`/Volumes` 卷列表（CFSDrives 重写，01 §4.7 / 05 §5.9）| SYS-NSFileManager | M | `\` 键改 Cmd+Shift+C 或保留（mac `\` 可用）；驱动器→卷 |
| Up One Level=735（OpenParentFolder，Backspace）| BindToParentFolder；返回归档上级时触发回写检测（§5.1） | BR-Folder | S | Cmd+↑（mac 惯例）+ Delete/Backspace 备选 |
| Folders History=736（FoldersHistory，Alt+F12，可编辑列表，PanelFolderChange.cpp:866-891）| SZListWindow（ListViewDialog 等价）：历史列表，回车跳转，可删条目 | PanelModel | S | Cmd+Shift+H 或保留 |
| Refresh=737（RefreshView/OnReload，Ctrl+R）| 重新 LoadItems，保留选中焦点 | BR-Folder | S | Cmd+R |
| Auto Refresh=738（Change_AutoRefresh_Mode，App.h:230-244）| FS 文件夹用 FSEvents/dispatch vnode source（替代 CFindChangeNotification，05 §5.10）；勾选态控制开关 | SYS-FSEvents | M | 须先抽象 `SZDirWatcher`（05 风险：FSFolder.h:141 是类型成员） |

### 1.4 Favorites 菜单（动态，resource.rc:134-141）

| 功能（源码） | mac 实现 | 依赖 | 量 | 行为差异 |
|---|---|---|---|---|
| "Add folder to Favorites as" 子菜单 + 书签 0-9（k_MenuID_SetBookmark=810+i / OpenBookmark=830+i，MyLoadMenu.cpp:508-559）| 动态 NSMenu：上半"设为书签 i"（Cmd+Shift+i），下半"打开书签 i"（Cmd+Ctrl+i）；路径>100 字符截断"前50…后50"逻辑复用 | PanelModel.FastFolders | S | Alt+i → Cmd+Ctrl+i（Alt 在 mac 是 Option，按惯例不占菜单，见 §4） |
| OpenBookmark/SetBookmark（PanelFolderChange.cpp:335-343，存 AppState.FastFolders）| PanelModel 收藏数组（`FM.FolderShortcuts` UserDefaults，05 §4.2） | PanelModel | S | 一致 |

### 1.5 Tools 菜单（resource.rc:142-153）

| 功能（IDM / 源码） | mac 实现 | 依赖 | 量 | 行为差异 |
|---|---|---|---|---|
| Options=900（OptionsDialog，6 页，OptionsDialog.cpp:32-89）| 见 §2 + §3 设置；NSTabViewController 或 macOS Preferences 工具栏窗 | 见 §3 | L | 6 页 → System 页（文件关联）改 LaunchServices；Menu 页改 Finder 扩展 |
| Benchmark=901（MyBenchmark(false)，CompressCall→7zG b）| 进程内调 `SZEngine benchmark:`（Bench.cpp 逻辑）→弹 SZBenchmark 窗（04 章 BenchmarkDialog）；暂停两面板定时器 | BR-Codecs | M | 不再启子进程；窗口设计见 04 |
| Delete Temporary Files=910（MyBrowseForTempFolder，BrowseDialog2，BrowseDialog2.cpp:1846-1859）| 浏览 `NSTemporaryDirectory()`/app 临时目录下 `7zE*`/`7zO*` 子目录列表，可删 | SYS-NSFileManager | S | 临时目录路径改 app 容器内（沙盒友好） |

### 1.6 Help 菜单（resource.rc:154-160）

| 功能（IDM / 源码） | mac 实现 | 依赖 | 量 | 行为差异 |
|---|---|---|---|---|
| Contents=960（ShowHelpWindow "FM/index.htm"，F1，HelpUtils.cpp:38-77）| .chm/HtmlHelp 无对应（01 §10）→ 打开在线帮助或随包 HTML（NSWorkspace openURL） | SYS-NSWorkspace | S | mac Help 菜单挂 `NSApp.helpMenu`；F1→Cmd+? |
| About 7-Zip=961（CAboutDialog）| 见 §2 AboutDialog；标准 macOS About 面板（`orderFrontStandardAboutPanel:` 可定制，或自绘窗） | — | S | 版本/版权信息照搬 |

### 1.7 面板级键盘命令（菜单外，PanelKey.cpp:39-357 全表覆盖）

> 键位的 mac 化总表见 §4；此处列功能映射。所有键最终转发到与菜单同一的 `SZFMCommandRouter`。

| 功能（PanelKey.cpp） | mac 实现 | 依赖 | 量 | 行为差异 |
|---|---|---|---|---|
| Tab 切换面板焦点（:41-45）| `-[NSWindow makeFirstResponder:]` 在两 NSTableView 间切换 | — | S | Tab 在 mac 也用于控件遍历；面板内 Tab 须拦截 |
| Alt/RCtrl+0-9 书签（:53-68）| 见 §1.4（Cmd+Ctrl+i） | PanelModel | S | 见 §4 |
| Alt+F1/F2 焦点到左/右地址栏并下拉（:70-76）| Cmd+Shift+G（"前往"）聚焦地址栏 | — | S | 见 §4 |
| Ctrl+F3..F7 排序（:83-88）| 排序菜单快捷键（见 §1.3） | PanelModel | S | — |
| F2/F3/F4 Rename/View/Edit（:105-135）| 见 §1.1 | BR-Ops | — | 保留 F2-F4 或加 Cmd 等价 |
| F5/F6 Copy/Move（+Shift→copyToSame，:137-154）| 见 §1.1 + §5.4 | BR-Ops | — | F5/F6 保留；Shift+F5=同目录复制改名 |
| F7 新建文件夹（故意不走加速键，:155-166）| Cmd+Shift+N（mac 新建文件夹惯例） | BR-Ops | S | — |
| Del / Shift+Del（:167-171）| 见 §1.1 Delete | SYS-NSWorkspace | — | Cmd+Delete=废纸篓（mac 惯例）；Cmd+Opt+Delete=永久 |
| Ctrl+Ins / Shift+Ins（EditCopy/EditPaste，:172-193）| Cmd+C / Cmd+V（见 §5.5） | SYS-NSPasteboard | S | — |
| Shift+方向键 区段选择（备选模式，:194-223）| NSTableView 原生 Shift+方向扩展选择；备选模式见 §5.2 注 | PanelModel | M | mac 多选交互不同，备选模式可后置 |
| Alt+Up/Right/Left 另一面板同步目录（:200-223，App.cpp:858-911）| 双面板同步命令（菜单项 + 快捷键），见 §5.2 | PanelModel | S | Alt→Cmd+Opt 组合 |
| 小键盘 + - *（Select/Deselect/Invert，:233-252）| Cmd+加/减号 + 反选菜单（见 §4） | PanelModel | S | mac 笔记本无小键盘，须用主键盘等价 |
| Backspace 上级（:261-263）| Cmd+↑ + Delete（见 §1.3） | BR-Folder | S | — |
| Ctrl+A/X/C/V/N/R/W/Z（:276-332）| Cmd+对应键；Ctrl+W=Cmd+W 关窗；Ctrl+Z=注释（改键，见 §4） | 各对应 | S | Cmd+Z 在 mac 是撤销，注释改键 |
| Ctrl+1..4 视图模式（:333-343）| Cmd+1..4 | SYS | S | — |
| Alt+F12 文件夹历史（:349-354）| 见 §1.3 | PanelModel | S | — |
| `\` `/` 打开"计算机"（ListView WM_CHAR，Panel.cpp:161-177）| 进入 `/Volumes`（见 §1.3 Open Root） | SYS-NSFileManager | S | — |
| Ctrl+PgDn / Ctrl+PgUp 内部打开/上级（Panel.cpp:193-226）| Cmd+↓（进入）/ Cmd+↑（上级） | BR-Folder | S | — |
| 地址栏内 Tab/F9/Ctrl+W/Alt+F1/F2（Edit 子类化，Panel.cpp:276-347）| NSTextField 委托内拦截对应键 | — | S | — |

### 1.8 右键上下文菜单（PanelMenu.cpp / 03-explorer-agent.md §1.8）

| 功能（源码） | mac 实现 | 依赖 | 量 | 行为差异 |
|---|---|---|---|---|
| 项目右键=CreateFileMenu（PanelMenu.cpp:1081-1158）| NSTableView `menuForEvent:` 返回动态 NSMenu = [7-Zip 命令组] + [File 菜单条目]；按只读/Hash 文件夹/选中数禁用（PanelMenu.cpp:919-985） | PanelModel | M | 命令决策层复用（CZipContextMenu 在 FM 内进程内复用，已解耦，03-explorer-agent.md §1.8） |
| 列头右键=列显示菜单（ShowColumnsContextMenu，PanelMenu.cpp:1083-1086）| NSTableHeaderView `menu`：列勾选项；NSTableView 列拖动重排原生支持（替代 LVS_EX_HEADERDRAGDROP，App.cpp:80） | PanelModel | S | — |
| 系统 Shell 菜单并入（ShowSystemMenu 开启，IContextMenu，PanelMenu.cpp:919-985）| **砍系统 Shell 菜单注入**（mac 无 IShellFolder/IContextMenu，01 §8 评 C）；改提供"在访达中显示"`-[NSWorkspace activateFileViewerSelectingURLs:]` | SYS-NSWorkspace | M | ShowSystemMenu 设置项语义改为"显示访达项"开关或移除 |
| Shift+右键扩展动词（CMF_EXTENDEDVERBS，PanelMenu.cpp:927）| Option+右键显示扩展项（mac 惯例 Option=备用动作） | — | S | — |
| 7-Zip 命令组（Open/Extract/Compress/Test/CRC，ContextMenu.cpp:271-309）| 同命令模型（03-explorer-agent.md §1.2 表）平移为 NSMenuItem | BR-* | M | Email 系列首版裁剪或改 NSSharingService（03 风险#9） |

---

## 2. 对话框映射（7zFM 自身专属）

> 7zG 共享对话框（Overwrite/Password/Progress2/Mem）的窗口设计见 04-feature-map-dialogs-finder.md。本节给 7zFM 专属的 13 个对话框（含 §2.3 补回的 MessagesDialog 与简易 ProgressDialog——这两个物理位于 `UI/FileManager/` 但既非 §2.2 自绘列表/表单窗、也不在 04 章 7zG 共享集，曾落在两者夹缝）。选型原则（01-architecture.md 公约）：表单类规则窗优先 AppKit（可嵌 SwiftUI）；自绘列表窗用 AppKit。所有 .rc 布局（DLU/Win32 控件）一律重做。

### 2.1 通用对话框基建（先建，被多个对话框复用）

对应 Windows 的 `NControl::CModalDialog`/`CDialog`、`DialogSize.h`、`GuiCommon.rc`（01-filemanager-inventory.md §2 末）。mac 侧建立：

- `SZDialogController`（NSWindowController 基类）：封装 OK/Cancel 按钮布局、`runModalSheet`（模态 sheet）/`runModalWindow`、Esc=取消、Return=默认按钮。
- `SZComboHistory`（带历史下拉的输入控件）：NSComboBox + UserDefaults 历史数组（对应多个对话框的 ComboBox 历史，如 Copy/Split/Combo）。

### 2.2 对话框逐个设计

| Windows 对话框（资源 / 源码）| mac 窗口设计（选型 + 控件清单）| 工作量 |
|---|---|---|
| **About**（IDD_ABOUT，AboutDialog.cpp）| AppKit 自绘小窗或定制标准 About 面板。控件：App 图标 NSImageView、版本/日期/版权 NSTextField、官网按钮（NSButton→openURL）。`MY_VERSION_INFO` 编入 Info.plist | S |
| **Browse**（IDD_BROWSE，BrowseDialog.cpp，1132 行：7-Zip 自绘文件/文件夹选择器）| **改用系统 `NSOpenPanel`/`NSSavePanel`**（支持 `canChooseDirectories`、过滤 UTType、沙盒 security-scoped bookmark，05 §2.2）。自绘选择器（超长路径目的）在 mac 无必要 → 砍自绘，统一系统面板。被 EditPage/FoldersPage/CopyDialog/LinkDialog 调用处全部改 NSOpenPanel | M |
| **Browse2**（IDD_BROWSE2，BrowseDialog2.cpp，临时文件删除器）| AppKit 列表窗：NSTableView（临时目录列表）+ Delete/Refresh/上级 按钮 + 过滤 NSComboBox。数据源=app 临时目录枚举 | M |
| **Combo**（IDD_COMBO，ComboDialog.cpp，单输入+下拉历史）| `SZInputSheet`（AppKit sheet）：NSTextField 标签 + SZComboHistory。复用于 新建文件名/注释/Select 掩码（PanelOperations.cpp:437,513；PanelSelect.cpp:156）| S |
| **Copy**（IDD_COPY，CopyDialog.cpp，Copy/Move 目标选择）| `SZCopySheet`（AppKit sheet）：目标路径 SZComboHistory（历史 ≤20，App.cpp:612-613）+ "…"浏览（NSOpenPanel）+ 多行信息区 NSTextField（选中项统计，kCopyDialog_NumInfoLines=11）| M |
| **Edit**（IDD_EDIT_DLG，EditDialog.cpp，只读多行文本查看）| AppKit：只读 NSTextView（NSScrollView 包裹）+ Close。用于错误/消息文本展示 | S |
| **ListView**（IDD_LISTVIEW，ListViewDialog.cpp，通用列表对话框）| `SZListWindow`（AppKit）：NSTableView（可无列头，2 列）+ 支持删除条目（deleteIsAllowed）、Cmd+C 复制行、回车选择。复用于 文件夹历史/属性窗口/哈希结果（共享给 7zG，本表注明协调） | M |
| **Split**（IDD_SPLIT，SplitDialog.cpp，拆分文件）| `SZSplitSheet`（AppKit sheet）：目标路径 + 卷大小 NSComboBox（预置档位照搬 SplitUtils.cpp:60-73 `k_Sizes[]`：`10M / 100M / 1000M / 650M - CD / 700M - CD / 4092M - FAT / 4480M - DVD / 8128M - DVD DL / 23040M - BD`；1457664 软盘项已在源码注释禁用，不移植）+ "…"浏览 | S |
| **Link**（IDD_LINK，LinkDialog.cpp，创建链接）| `SZLinkSheet`（AppKit sheet）：from/to 路径 + 浏览 + 类型单选（**仅 Hard / Symbolic 两项**，砍 Junction/WSL/SymFile-SymDir 区分）。实现改 `link()`/`symlink()`（05 §5.5） | M |
| **属性窗口**（PanelMenu.cpp:172-423，复用 ListViewDialog）| `SZPropertiesWindow`（AppKit）：NSTableView 两列（属性名/值）；数据源=BR-Folder 的 GetProperty + rawProps（十六进制）+ 文件夹属性 + 逐层归档属性（含错误旗标解码）；多选=汇总统计 | M |
| **About/Combo/Edit/ListView/Split** 之外的 6 个 7zG 共享对话框 | → 见 04 章 | — |

> 注：ListViewDialog（属性窗/历史/哈希结果三处用）与 04 章哈希结果窗共用同一 `SZListWindow` 实现，由 SevenZipKit 提供，FM 与 GUI 等价物共享。

### 2.3 夹缝对话框补回（MessagesDialog / 简易 ProgressDialog）

> 这两个对话框物理位于 `CPP/7zip/UI/FileManager/`，.cpp/.h/.rc 真实存在且被链接，但既不在 §2.2（自绘列表/表单窗）也不在 04 章 7zG 共享集——补回以满足对话框全覆盖承诺。注意它们与 04 章已映射对象的**触发差异**。

| Windows 对话框（资源 / 源码）| 触发场景（与 04 章对象的区别）| mac 窗口设计 | 工作量 |
|---|---|---|---|
| **MessagesDialog**（IDD_MESSAGES，MessagesDialog.cpp/.h）| 操作**结束后独立弹出**的批量错误聚合窗：拖放结束后汇总错误（PanelDrag.cpp:1788 `CMessagesDialog messagesDialog; messagesDialog.Messages = &...Messages`）。**区别于** 04 §2.4 的 ProgressDialog2 内嵌错误列表（IDL_PROGRESS_MESSAGES，进度窗内联）——MessagesDialog 用于**无进度窗**的拖放/批量操作错误汇总，是独立模态窗。| `SZMessagesWindow`（AppKit）：NSTableView（无列头，单列 = `Messages` UStringVector 逐行）+ Close + Cmd+C 复制选中行/全部。可复用 `SZListWindow` 基建（只读、deleteIsAllowed=false）。挂接点：§5.3 拖拽落点错误、§5.4 批量操作无进度场景的错误收尾。| S |
| **简易 ProgressDialog**（IDD_PROGRESS，ProgressDialog.cpp/.h，区别于 ProgressDialog2.cpp）| 仅"进度条 + 标题 + Cancel/暂停"的**轻量进度窗**，无逐文件统计/速度/错误内嵌列表（CProgressSync 只有 total/completed/paused/stopped）。被 PanelCopy.cpp:347（`CProgressDialog ProgressDialog`，CThreadUpdate 压入归档 CopyFrom 路径）使用。**区别于** 04 §2.4 的 ProgressDialog2（多行统计 + 内嵌错误列表）。| **并入 `SZProgressWindowController`（04 章）作为"无统计的轻量变体"**：同一控制器以 `style = .simple`（仅进度条 + 标题 + 取消/暂停，隐藏统计区与内嵌错误表）渲染。不新建独立类；§5.4 表里"进度走 SZ 进度窗"即指此控制器，简易/完整由调用方按操作类型选 style。| S（并入 04 控制器，无独立实现）|

> 协调说明：(1) `SZProgressWindowController` 的 `.simple`/`.full` 两态须在 04 章 §2.4 标注（本表是 7zFM 侧的触发登记，控件级设计归 04）；(2) MessagesDialog 的错误来源（`Messages` UStringVector）由 BR-Extract/BR-Update/拖拽回调累积，操作结束时若非空则弹 `SZMessagesWindow`。

---

## 3. 设置项映射（注册表键 → UserDefaults → 设置界面归属）

> 全键清单与 UserDefaults 映射建议见 05-platform-layer.md §4（权威）。本节给"设置界面归属"——即每键属于 Tools→Options 的哪一页，以及该页在 mac 的形态。建议 UserDefaults 域 `com.7zip.SevenZipFM`（suite 与 Finder 扩展共享，05 §4.2）。

### 3.1 选项窗结构（OptionsDialog.cpp:44-52，6 页）

mac 用单一设置窗（NSTabViewController，工具栏式标签页，macOS Preferences 惯例），6 个标签页一一对应：

| Windows 页（IDD）| mac 标签页 | 内容与变更 |
|---|---|---|
| System（SystemPage.cpp）| **文件类型**（重设计）| Windows 的注册表文件关联（`Software\Classes\.ext`→`7-Zip.ext`）→ mac LaunchServices：Info.plist 静态声明 `CFBundleDocumentTypes`/`UTImportedTypeDeclarations` + 运行期 `LSSetDefaultRoleHandlerForContentType` 设默认应用。列表展示"按扩展名 × 设为默认"开关（05 §4.1-G）。**语义完全不同，全新实现**（01 §8 评 C）| L |
| 7-Zip/Menu（MenuPage.cpp）| **访达集成**（重设计）| Windows 的 7-zip.dll 右键 handler 注册 → mac Finder Sync / Action 扩展（Info.plist 声明，无注册表）。级联/图标/ElimDup/WriteZone 等开关映射到 App Group UserDefaults，供扩展进程读（03-explorer-agent.md §1.9，04 章 Finder 集成详述）| L |
| Folders（FoldersPage.cpp）| **工作目录** | `NWorkDir::CInfo`（WorkDirType/WorkDirPath/TempRemovableOnly）→ `Options.WorkDir*` UserDefaults。形态：单选（系统 temp / 当前目录 / 指定）+ NSOpenPanel 选路径 + "仅可移动盘"勾选。**保留 CInfo 结构体 API，改 Registry_mac 后端**（05 §2.2/§4.2，零改动逻辑） | S |
| Editor（EditPage.cpp）| **编辑器** | Viewer/Editor/Diff 三个外部程序路径（`FM.Viewer/Editor/Diff` UserDefaults）。形态：3 个路径输入 + "选择应用"（NSOpenPanel 选 .app）。默认空=用系统默认应用 | S |
| Settings（SettingsPage.cpp）| **常规** | 9 项浏览选项：见 §3.2 表。**Use large memory pages 隐藏**（mac 无意义，05 §2.2 stub）| M |
| Language（LangPage.cpp）| **语言** | 扫描 `Lang/*.txt`（随 .app Resources，可整套保留，05 §1.2/§7）+ 翻译完成度行数比对；NSPopUpButton 下拉，切换立即生效（重载菜单文本） | M |

### 3.2 Settings 页 9 项逐键映射（SettingsPage.cpp:114-247）

| Windows 项（注册表 FM\*）| UserDefaults 键 | mac 控件 | mac 行为 |
|---|---|---|---|
| Show ".." item（ShowDots）| `FM.ShowDots` | NSButton 勾选 | 一致 |
| Show real file icons（ShowRealFileIcons）| `FM.ShowRealFileIcons` | 勾选 | 真实图标用 `-[NSWorkspace iconForFile:]`/UTType（替代 SHGetFileInfo，05 §2.3）|
| Full row select（FullRow）| `FM.FullRow` | 勾选 | NSTableView `selectionHighlightStyle`/整行高亮（默认即整行，可改样式） |
| Show grid lines（ShowGrid）| `FM.ShowGrid` | 勾选 | NSTableView `gridStyleMask` |
| Single-click open（SingleClick）| `FM.SingleClick` | 勾选 | 自定义单击/双击判定（mac 默认双击打开） |
| Alternative selection mode（AlternativeSelection）| `FM.AlternativeSelection` | 勾选 | FAR 式选择，见 §5.2 注。**一对一范围内、M4 保留设置键、FAR 交互 v1.1 补齐**（分期分类见 OQ-5） |
| Show system menu（ShowSystemMenu）| `FM.ShowSystemMenu` | 勾选 | 语义改为"右键含'在访达中显示'"或移除（§1.8） |
| Use large memory pages（LargePages，7-Zip 根键）| （不迁移）| 隐藏 | mac stub（05 §2.2） |
| 解压内存上限 GB（NExtract::Save_LimitGB，Extraction\MemLimit）| `Extraction.MemLimit` | NSStepper + NSTextField（显示 RAM）| 一致 |

### 3.3 非选项页持久化（启动恢复 / 视图状态，05 §4.2）

| Windows 键 | mac 处置 |
|---|---|
| FM\Position（窗口矩形+最大化，20B blob）| **弃 blob**，用 `-[NSWindow setFrameAutosaveName:]` |
| FM\Panels（numPanels/currentPanel/splitterPos，12B）| NSSplitView autosave + `FM.CurrentPanel` Int |
| FM\Toolbars / ListMode（DWORD 掩码）| `FM.ToolbarsMask` / `FM.ListMode` Int，语义直搬 |
| FM\PanelPath0/1（启动恢复路径）| `FM.PanelPaths` [String] |
| FM\FolderHistory / FolderShortcuts / CopyHistory（multi-SZ）| `FM.FolderHistory` 等 [String] |
| FM\Columns\<TypeID>（二进制 blob：version/SortID/Ascending + N×[PropID,Visible,Width]，ViewSettings.cpp:52-120）| **定案=弃 blob**，改结构化 plist `FM.Columns.<id>={sortID,ascending,columns:[{prop,visible,width}]}` 或 NSTableView `autosaveName`（05 §4.2 为准）。**首版即结构化 plist**（不再 blob 直搬，理由见 OQ-1：blob 直搬反而更费且不利于配置互换） |
| Extraction/Compression/Options\*（解压/压缩/工作目录/菜单策略）| 见 05 §4.2 表；Security/AltStreams/NtSecurity 等在 mac 隐藏但保留键名兼容 |

---

## 4. 快捷键总表（Windows → mac 键位建议）

> 原则：遵守 mac 平台惯例（Cmd 为主修饰键；Option=备用动作；Ctrl 保留给系统）。Windows 用 Ctrl 的命令统一改 Cmd；Windows 用 Alt 的菜单访问键在 mac 不存在（无菜单助记符），书签类 Alt+数字改 Cmd+Ctrl+数字。功能键 F1-F12 在 mac 默认是系统媒体键，须用户在系统设置开"标准功能键"或我们同时提供 Cmd 等价；因此每条**优先给 Cmd 组合，F 键作为兼容保留**。冲突处理逐条标注。

| 功能 | Windows 键 | mac 建议 | 冲突/说明 |
|---|---|---|---|
| Open | Enter | **Return** / Cmd+↓ | **一对一决议：Return=Open**（与 Windows OpenSelectedItems(true)，App.h:121 一致）。这是最高频交互（进入目录/打开档案），按自定纲领（01 §1.1 等价复刻 Windows）默认站一对一侧；Cmd+↓ 兼容 |
| Open Inside | Ctrl+PgDn | Cmd+↓ | — |
| Open Outside | Shift+Enter | Shift+Return | — |
| View | F3 | F3 / Cmd+Y | F3 兼容；Cmd+Y=快速查看惯例 |
| Edit | F4 | F4 / Cmd+E | — |
| Rename | F2 | **F2 / Cmd+Return** + 单击已选项延时进入编辑 | **一对一决议：Rename 不抢 Return**。Windows Rename=F2（PanelKey.cpp:105-109），保留 F2 并加 Cmd+Return；另提供 Finder 式"单击已选中项延时进入行内编辑"（不绑 Return，避免与 Open 冲突）。见 OQ-2 |
| Copy To | F5 | F5 / Cmd+Opt+C | F5 在 mac 无强占用 |
| Move To | F6 | F6 / Cmd+Opt+M | — |
| Copy to same（改名复制）| Shift+F5 | Shift+F5 | — |
| Delete（废纸篓）| Del | Cmd+Delete | mac 惯例 |
| Delete（永久）| Shift+Del | Cmd+Opt+Delete | — |
| Properties | Alt+Enter | Cmd+I | mac"显示简介"惯例 |
| Comment | Ctrl+Z | Cmd+/ | Cmd+Z=撤销，改键 |
| Create Folder | F7 | Cmd+Shift+N | mac 新建文件夹惯例 |
| Create File | Ctrl+N / Shift+F4 | Cmd+N | Cmd+N 在 mac 常为"新建窗口"；FM 无多文档窗→可占用，否则 Cmd+Ctrl+N |
| Select All | Ctrl+A | Cmd+A | — |
| Deselect All | Shift+Grey- | Cmd+Opt+A | 小键盘不可靠 |
| Invert Selection | Grey* | （菜单项，无快捷键）| 笔记本无小键盘 |
| Select… | Grey+ | Cmd+加号 | — |
| Deselect… | Grey- | Cmd+减号 | — |
| Select by Type | Alt+Grey+ | Cmd+Opt+加号 | — |
| Copy（剪贴板名）| Ctrl+Ins / Ctrl+C | Cmd+C | — |
| Paste | Shift+Ins / Ctrl+V | Cmd+V | （空实现，§5.5） |
| 视图模式 1-4 | Ctrl+1..4 | Cmd+1..4 | — |
| 排序 Name/Type/Date/Size | Ctrl+F3..F6 | （排序菜单，Cmd 不占）| 排序经菜单或列头 |
| Unsorted | Ctrl+F7 | （排序菜单）| — |
| 2 Panels | F9 | F9 / Cmd+Shift+P | F9 在 mac 是 Mission Control，可能冲突 → Cmd+Shift+P 主用 |
| Refresh | Ctrl+R | Cmd+R | — |
| Up One Level | Backspace | Cmd+↑ | mac Finder 惯例（Backspace 兼容） |
| Open Root（计算机）| `\` | Cmd+Shift+C | `\` 兼容保留 |
| Folders History | Alt+F12 | Cmd+Shift+H | — |
| Switch panel | Tab | Tab | 须拦截控件遍历 |
| Sync 另一面板目录 | Alt+Up/Right/Left | Cmd+Opt+↑/→/← | — |
| 焦点地址栏 | Alt+F1/F2 | Cmd+Shift+G | "前往"惯例 |
| 书签打开 0-9 | Alt+0..9 | Cmd+Ctrl+0..9 | Alt=Option 不占菜单 |
| 书签设置 0-9 | Alt+Shift+0..9 | Cmd+Ctrl+Shift+0..9 | — |
| Help Contents | F1 | Cmd+? | mac Help 惯例 |
| Close window | Ctrl+W | Cmd+W | — |
| Quit | Alt+F4 | Cmd+Q | mac 关窗≠退出 |
| Add（压缩）| 工具栏 | Cmd+Opt+A 冲突 → Cmd+Shift+A | 与 Deselect All（Cmd+Opt+A）区分 |

> 冲突汇总处理：(1) Return 一键二义（Open vs Rename）**按一对一硬标准定为 Open**（与 Windows 一致），Rename 走 F2 / Cmd+Return + Finder 式"单击已选项延时进入编辑"（不抢 Return）——"贴 Windows 还是贴 Finder"作为产品决策显式上抛 OQ-2，但方案默认值站一对一侧；(2) F9 与 Mission Control 冲突，主快捷键改 Cmd+Shift+P；(3) 所有 F 键提供 Cmd 等价，避免依赖"标准功能键"系统设置。最终键表落 `SZKeyBindings`（表驱动，对应 Windows 加速键表 resource.rc:7-13 + PanelKey.cpp 键表），便于将来用户自定义。

---

## 5. 特殊语义专节

> 这 4 项是 7zFM 体验关键路径，也是 mac 与 Windows 语义差异最大处。逐个给实现路径 + 验收标准。

### 5.1 归档内文件就地打开编辑回写

**Windows 行为**（PanelItemOpen.cpp:1461-1780, 1110-1300）：解压单项到 `%TEMP%\7zO…`（小文件先入内存 `CVirtFileSystem`，阈值=RAM>>max(层数+1,8)）→ 启动关联程序/编辑器 → 监视线程（Toolhelp32 进程快照追子进程 + 2s 心跳）等待进程退出或文件变更 → 文件变更且非只读 → 询问"update it in the archive?" → `IFolderOperations::CopyFromFile` 回写 → 删临时目录。嵌套归档返回上级时同样检测并回写（`OpenParentArchiveFolder`）。

**mac 实现路径**：

0. **原档访问权保活（书签生命周期，先于一切回写）**：本流程的回写目标是**原归档文件**，监视期可达分钟到小时级，必须在此期间持续持有对原档及其父目录的访问授权——否则 BR-Update 的 `MoveToOriginal`（先写临时档再覆盖原位，WorkDir.cpp:77-84；03-explorer-agent.md 风险#5）会因原档父目录无写权而失败或损档。书签策略按分发主线分两档（设计公约：分发主线 = Developer ID 签名 + 公证，非沙箱；App Store/沙盒为可选后续阶段）：
   - **非沙箱主线（默认）**：原档由 NSOpenPanel/拖入获得后，记录其 `NSURL` 与**父目录 URL**；打开归档会话时即对原档父目录 `-[NSURL startAccessingSecurityScopedResource]`（NSOpenPanel 返回的 URL 在非沙箱下虽无强制沙箱限制，但 `replaceItemAtURL:` 跨目录替换仍需父目录可写——以 `-[NSFileManager isWritableFileAtPath:]` 预检并在不可写时直接禁用回写、改"另存到…"）。封装为 `SZScopedAccess`（RAII，持 startAccessing 到回写完成或放弃 stop）。
   - **沙箱后续阶段（App Store）**：打开归档时即对**原档父目录**申请并持久化 security-scoped bookmark（`-[NSURL bookmarkDataWithOptions:NSURLBookmarkCreationWithSecurityScope ...]`，存入会话对象而非 UserDefaults），监视全程持有 `startAccessingSecurityScopedResource`，回写阶段用该书签 resolve 出的父目录 URL 调 `-[NSFileManager replaceItemAtURL:withItemAtURL:...]`。单文件书签不足以覆盖跨目录 replace，必须对父目录申请书签。
   - 监视全程（步骤 2-5）`SZScopedAccess` 保活；回写成功/取消/放弃后才 `stopAccessingSecurityScopedResource` 并清临时目录。`MoveToOriginal` 路径需在 mac 上验证 `replaceItemAtURL:` 对书签/startAccessing 授予的父目录是否成立（跨卷退化为 copy+原子 rename，见 05 §5#5）。
1. **解压临时文件**：`SZArchiveSession extractItem:toTempDir:` → 临时目录 `<app容器>/Caches/7zO<rand>/`（沙盒友好，替代 %TEMP%）。CVirtFileSystem 内存优化逻辑可保留（纯逻辑）或首版直接落盘（OQ-4）。
2. **启动编辑器**：`-[NSWorkspace openURLs:withApplicationAtURL:configuration:completionHandler:]`（Settings 配置的 Editor，或默认应用）。返回 `NSRunningApplication`。
3. **变更监视**（替代 Toolhelp32 + 心跳，05 §5.10）：
   - 文件变更：`dispatch_source`（DISPATCH_SOURCE_TYPE_VNODE，监 WRITE/RENAME/DELETE）或 `NSFilePresenter`（`presentedItemDidChange`）监临时文件。
   - 进程退出：`-[NSRunningApplication observeValueForKeyPath:@"terminated"]`（KVO）或 `NSWorkspaceDidTerminateApplicationNotification`。**注意**：多文档编辑器（一个进程开多文件）下，进程退出不等于该文件编辑完成 → 以"文件 mtime 变化 + app 失活/退出"组合判定，与 Windows 心跳意图等价。
4. **回写**：检测到变更且临时文件非只读 → NSAlert "在归档中更新此文件？" → `SZFolderOperations copyFromFile:atIndex:`（即 UpdateOneFile，KeepOriginalItemNames=true，03-explorer-agent.md §2.6）。回写走 BR-Update（含 MoveArc 协议，E_ABORT 延迟，防损档）。
5. **嵌套归档回写**：BindToParentFolder 时（§1.3 Up）对 _parentFolders 栈逐层检测临时变更并提示。
6. **退出协调**：对应 `CExitEventLauncher`（Panel.h:997-1018）——app 退出前若有未回写的打开项，弹确认。mac 用 `applicationShouldTerminate:` 拦截。

**验收标准**：
- [ ] 在 .7z/.zip 内双击 txt → 系统默认编辑器打开 → 保存 → 切回 7zFM → 弹回写确认 → 确认后归档内该文件已更新（重开归档校验内容+mtime）。
- [ ] 编辑器为多文档应用（如同时开 2 个临时文件）时，各自保存均能独立检测并提示回写，互不串扰。
- [ ] 取消回写 → 归档不变，临时文件清理。
- [ ] 回写过程中点取消（E_ABORT）→ 原归档完好无损（MoveArc 延迟中断生效），临时备份可恢复。
- [ ] 只读归档（多层嵌套/带尾部数据，Agent.cpp:1589-1601）内打开的文件，编辑后**不提示回写**（CheckBeforeUpdate 置灰）。
- [ ] 嵌套归档（归档内的归档）内编辑文件，返回上级时正确逐层回写。
- [ ] 危险名检测（RLO 字符/伪装扩展名，PanelItemOpen.cpp:867-947）在 mac 打开外部程序前同样警告。
- [ ] app 退出时有未回写项 → 拦截并提示。
- [ ] **原档位于 ~/Downloads 之外的任意位置（如 ~/Desktop/子目录、外置卷、用户自选目录）时，编辑后回写成功**——验证父目录访问授权（非沙箱 startAccessing / 沙箱阶段父目录书签）在分钟级监视后回写阶段仍有效，`MoveToOriginal`/`replaceItemAtURL:` 不因书签失效或父目录无写权而失败或损档。
- [ ] 原档父目录不可写（如只读卷、权限受限目录）时，回写按钮置灰并提示"原归档目录不可写，请改用『另存到…』"，原档不被破坏。

### 5.2 双面板（F9）

**Windows 行为**（App.cpp:360-380；Panel.h:70-81）：`CApp` 固定 2 个 `CPanel`，F9 即时显隐第二面板；面板交互经 `CPanelCallback`（OnTab/SetFocusToPath/OnCopy/OnSetSameFolder/OnSetSubFolder/DragBegin/DragEnd）；F5/F6 默认目标=另一面板路径；窗口标题=焦点面板路径。

**mac 实现路径**：

1. **布局**：主窗 `NSSplitView`（水平分割，对应 Windows 自绘 splitter，FM.cpp:955-968），两个 `SZPanelViewController`（封装 NSToolbar 上级按钮 + 地址栏 + NSScrollView(NSTableView/NSCollectionView) + 状态栏视图）。第二面板=移除/插入 NSSplitView 的子视图（F9，对应 SwitchOnOffOnePanel）。NSSplitView autosave 持久化分隔位（替代 Panels blob 的 splitterPos）。
2. **焦点模型**：`LastFocusedPanel` = 记录最后 firstResponder 所在面板控制器；窗口标题随焦点面板路径更新（KVO 绑定）。
3. **面板间交互**：`SZPanelCallback`（ObjC protocol，一一对应 CPanelCallback 方法）。F5/F6/拖拽的默认目标取另一面板 `currentPath`。
4. **同步命令**（Alt+方向 → Cmd+Opt+方向，§4）：OnSetSameFolder/OnSetSubFolder 直接调另一面板控制器 BindToPath。
5. **备选选择模式**（_mySelectMode，FAR 风格，App.cpp:98-108）：NSTableView 单选 + 空格/方向标记选中集。**一对一范围内、分期实现**：M4 先做标准多选并保留 `FM.AlternativeSelection` 设置键，FAR 式交互延至 v1.1 补齐（分期分类与产品拍板项见 OQ-5），非裁剪。

**验收标准**：
- [ ] Cmd+Shift+P（F9）切换单/双面板，分隔位记忆并下次启动恢复。
- [ ] Tab 在两面板间切换焦点，窗口标题随焦点面板路径变化。
- [ ] 双面板下 F5/F6/拖拽默认目标为另一面板当前目录；单面板下 F5/F6 弹 CopyDialog 输入目标。
- [ ] Cmd+Opt+→ 使另一面板同步到当前焦点项的子目录；Cmd+Opt+↑ 同步到当前目录。
- [ ] 两面板可独立浏览不同归档/不同目录，各自维护选择集与排序。

### 5.3 拖拽进出归档

**Windows 行为**（PanelDrag.cpp，3006 行；01-filemanager-inventory.md §6.2）：
- 源：FS 源直接 HDROP 真实路径；归档源先建 `%TEMP%\7zE…` 暴露"将解压出的目标名列表"，**延迟解压**（目标 GetData 时才解）；私有剪贴板格式 `7-Zip::SetTargetFolder/GetTransfer` 让 7-Zip↔7-Zip 拖拽协商"源直接 CopyTo 目标"绕过临时拷贝；DoDragDrop(MOVE|COPY)。
- 目标：`CDropTarget`（IDropTarget，FM.cpp:1023）高亮目标子文件夹；目标 FS 文件夹→CopyFsItems/CopyFromNoAsk；目标归档→CompressDropFiles（CopyFrom=压入）；右键拖出菜单（Copy/Move/AddToArc/Cancel）。

**mac 实现路径**（全部重写，01 §8 评 C；OLE→NSDragging + NSFilePromise）：

1. **拖出归档（源，延迟解压）**：NSTableView/NSCollectionView 实现 `NSDraggingSource`；归档内项用 **`NSFilePromiseProvider`**（file promise，延迟解压语义天然对应 Windows 的延迟 HDROP，05 §2.2 提示）。`NSFilePromiseProviderDelegate filePromiseProvider:writePromiseToURL:` 回调时才调 `SZArchiveSession extractItem:toURL:`（解压到 Finder 落点）。
2. **拖出 FS 项（源）**：直接写 `NSPasteboardTypeFileURL`（真实路径，替代 HDROP）。
3. **拖入 FS 文件夹（目标）**：实现 `NSDraggingDestination`；`-draggingEntered:` 高亮目标行（替代 m_DropHighlighted）；`-performDragOperation:` 读 fileURL → 若源是归档内项（同 app，经私有 pasteboard type `com.7zip.transfer` 协商）→ 直接 `SZFolderOperations copyTo:`（绕过临时，对应 7-Zip↔7-Zip Transfer 协议）；否则 NSFileManager 复制/移动。
4. **拖入归档（目标）**：目标行是归档/归档内文件夹 → `SZFolderOperations copyFrom:`（压入=CopyFrom），或"新建归档"模式弹压缩窗（04 章）。
5. **右键拖出菜单**：mac 用 Option 拖=复制、Cmd 拖=移动（系统惯例修饰键）替代 Windows 右键拖出菜单；或落点后弹 NSMenu（Copy/Move/Compress/Cancel）。
6. **防误删源**：Windows 的 `CFSTR_PERFORMEDDROPEFFECT` 在 mac 由 file promise / NSDraggingInfo 的 `draggingSourceOperationMask` 自然处理（move vs copy 明确）。

**验收标准**：
- [ ] 从归档内拖文件到 Finder/桌面 → 落点处出现解压后的真实文件（延迟解压：拖动期间不解压，落下才解）。
- [ ] 从 Finder 拖文件到 7zFM 归档面板 → 文件被压入归档（重压缩，进度窗显示）。
- [ ] 7zFM 两面板间拖拽（归档→FS、FS→归档、FS→FS、归档→归档）四条路径均正确（与 §5.4 一致）。
- [ ] Option 拖=复制源保留；Cmd 拖=移动源删除（仅 FS 源）。
- [ ] 拖入只读归档 → 拒绝并提示（CheckBeforeUpdate）。
- [ ] 拖拽过程中目标文件夹行高亮，落点准确（拖到子文件夹行=进入该文件夹）。
- [ ] 大文件/多文件拖出时进度可见、可取消，取消后落点无残留半成品。

### 5.4 剪贴板复制粘贴进归档（含 Copy/Move 四路径）

> 此处覆盖两件事：(a) §5.5 的"剪贴板名称文本复制"是 Windows 现状；(b) 真正的"复制粘贴文件进/出归档"在 Windows 由 F5/F6 CopyDialog 承载（EditCut/EditPaste 是空实现，PanelMenu.cpp:427-472）。mac 上我们**可以**用 NSPasteboard 实现真正的 Cmd+C/Cmd+V 文件粘贴（比 Windows 更完整），但为保持一对一，默认 Cmd+C=复制名称文本、文件复制走 F5/F6 与拖拽；是否启用"Cmd+V 粘贴文件进归档"列为增强项（OQ-6）。

**Copy/Move 四条路径**（App.cpp:565-856；PanelCopy.cpp，对应 F5/F6 与拖拽落点）：

| 路径 | Windows 实现 | mac 实现 | 依赖 |
|---|---|---|---|
| ① FS→FS | CopyTo（FSFolderCopy，CopyFileW/MoveFileW，01 §8 评 C 重写）| `NSFileManager copyItemAtURL:`/`moveItemAtURL:` 或 POSIX copyfile，带进度 | SYS-NSFileManager |
| ② 归档→FS | CopyTo=解压（IFolderOperations::CopyTo→CAgentFolder::Extract）| `SZFolderOperations copyTo:`（BR-Extract）| BR-Extract |
| ③ FS→归档 | CopyFrom=压缩（CThreadUpdate→IFolderOperations::CopyFrom）| `SZFolderOperations copyFrom:`（BR-Update，重压缩）| BR-Update |
| ④ 归档→归档 | 经临时目录两段（useTemp，仅双面板允许）| 同：先 ② 解压临时 → 再 ③ 压入目标 | BR-Extract + BR-Update |

公共逻辑保留："Cannot copy onto itself"防护、copyToSame（Shift+F5 同目录改名）、CopyDialog 确认（§2）、进度走 SZ 进度窗（04 章 ProgressDialog2 等价）。

**验收标准**：
- [ ] F5（Copy To）四条路径各通过：FS→FS 文件复制；归档→FS 解压；FS→归档 压入；归档→归档（双面板）经临时中转。
- [ ] F6（Move To）：FS→FS 移动后源删除；FS→归档 压入后按 moveMode 删源（成功后递归删空目录，03 §2.6）。
- [ ] Shift+F5 同目录复制改名弹输入框。
- [ ] 自我复制（源=目标）被拦截并提示。
- [ ] 进度窗显示文件名/速度/可取消；取消后目标无半成品（FS）或归档回滚（归档内，MoveArc 协议）。
- [ ] Cmd+C 在归档内项=复制名称文本到剪贴板（CRLF→换行分隔），与 Windows EditCopy 一致。

### 5.5 剪贴板（名称文本，PanelMenu.cpp:427-472）

**Windows 现状**：`EditCopy`=仅复制**名称文本**（CRLF 分隔）到剪贴板；`EditCut`/`EditPaste` 为空实现（InvokeSystemCommand("cut"/"paste") 被注释）；ListViewDialog 内 Ctrl+C 复制行文本。

**mac 实现**：Cmd+C → `-[NSPasteboard writeObjects:]` 写 `NSPasteboardTypeString`（选中项名称，换行分隔）；属性窗/历史窗内 Cmd+C 复制行文本。EditCut/EditPaste 保持空实现（与 Windows 一致）。

**验收标准**：
- [ ] 选多项 Cmd+C → 系统剪贴板得到换行分隔的文件名列表，可粘贴到文本编辑器。
- [ ] 属性窗 Cmd+C 复制选中属性行。

### 5.6 大目录虚拟化（视图虚拟化 ≠ 模型/桥接全量物化）

> 此节澄清一个易错点：§1.3 把四视图选型定为 NSTableView/NSCollectionView，二者确实虚拟化**cell/item 视图**（只为可见行创建视图）。但这不解决**数据模型与桥接层的全量物化**——若 LoadItems 后同步对每行每列 `GetProperty`（PROPVARIANT）并 NSString 化全量缓存，10 万项归档（大型 tar/zip，CProxyArc::Load 遍历 GetNumberOfItems 全量建树、CalculateSizes 递归聚合，03-explorer-agent.md §2.4）在 LoadItems 时刻就会同步阻塞，卡住 §5.1/§5.4 时序里的"完成 block"。NSTableView 选型正确，但全量物化的实现会在大档上失败。

**mac 实现路径（惰性属性 + 轻量索引）**：

1. **PanelModel `_items` 只持轻量索引**：每行仅存引擎内的 `UInt32 itemIndex`（对应 CProxyArc/CAgentFolder 行号）+ 排序/选择所需的最小键（如缓存 kpidName 用于排序比较），**不**预先把 kpidPath/kpidSize/kpidMTime 等全列 NSString 化。
2. **属性按需惰性读取**：桥接层 `SZFolder` 暴露 `propertyForRow:column:`，只在 `-tableView:objectValueForTableColumn:row:`（Details）或 NSCollectionView item 配置回调被调时，才对该行该列 `GetProperty` → PROPVARIANT→NSString，并写入按行 LRU 缓存（容量与可视区 + 预取窗口同量级，如 ~2000 项）。滚出可视区的缓存项可回收。所有权约定不变（不向 App 层暴露引擎裸指针，桥接层瞬时拷出值，02-core-bridge.md）。
3. **排序的全量代价收敛**：排序需要全量比较键——但只取排序列单一属性（如 kpidName/kpidSize），用 PanelModel 的 `IFolderCompare` 桥（PanelSort.cpp，目录恒在文件前、".."最前）在 ObjC 侧对 itemIndex 数组排序，避免全列物化。排序列属性同样走惰性缓存预热（仅该列）。
4. **首屏分批**：LoadItems 完成 block 只需返回 `numberOfRows`（= GetNumberOfItems，O(1)）即可让 NSTableView 上屏；列值随滚动惰性填充。建树/CalculateSizes 的递归聚合（若 FlatView 或目录大小列需要）放到后台 NSOperation，完成后增量刷新对应列，不阻塞首屏。

**验收标准**：
- [ ] 打开 10 万项归档（如大型 tar/zip），首屏可交互 < 2 秒（LoadItems 完成 block 不做全列 NSString 化）。
- [ ] 上下快速滚动 10 万项列表，帧率不掉档、无可感卡顿；内存占用随可视区 + 缓存窗口有界（不随总行数线性膨胀到全量 NSString）。
- [ ] 按 Name/Size/Date 排序 10 万项在 < 1 秒内完成且只读取排序列属性（不触发全列物化）。
- [ ] 目录大小列（FlatView / 含子项聚合）后台计算期间列表仍可滚动浏览，聚合完成后该列增量刷新。

---

## 6. 工作量汇总（粗粒度，供 05 排期对接）

| 子系统 | 量级 | 关键依赖 |
|---|---|---|
| 命令路由 + 6 菜单 + 键表（§1, §4）| M | SZFMCommandRouter、SZKeyBindings |
| 面板核心（PanelModel 抽取 + NSTableView Details 视图 + 列模型/排序/选择 + **大目录惰性物化** §5.6）| L | PanelModel、BR-Folder |
| Icons/List/CollectionView 视图（§1.3）| M（可后置）| NSCollectionView |
| 双面板（§5.2）| M | NSSplitView、SZPanelCallback |
| 地址栏（面包屑 ComboBoxEx → 自建复合控件 `SZAddressBar`：自绘面包屑展示态 + NSTextField 编辑态 + 固定项/历史下拉，OQ-8）| L | PanelModel |
| 13 个专属对话框（§2，含 §2.3 补回的 MessagesDialog→`SZMessagesWindow`、简易 ProgressDialog→并入 04 `SZProgressWindowController` `.simple` 态）| M | SZDialogController 基建 |
| 设置窗 6 页（§3）| L（System/Menu 页是 LaunchServices/Finder 扩展重设计）| 见 04 Finder 集成 |
| 文件操作（删除/重命名/新建/Copy 四路径，§5.4）| L | BR-Ops、BR-Extract、BR-Update、SYS-NSWorkspace |
| 归档内打开编辑回写（§5.1）| L | NSFilePresenter/dispatch vnode、BR-Update |
| 拖拽（§5.3）| L | NSFilePromise、NSDragging |
| 剪贴板（§5.5）| S | NSPasteboard |
| 内嵌工具（Split/Combine/Hash/属性/注释/Link/Diff/Ver/临时清理，§1）| M | BR-Hash、纯 IO、NSTask |
| 设置持久化后端（Registry_mac，05 §2.2）| M | CKey→UserDefaults 适配 |
| 目录监视抽象（SZDirWatcher→FSEvents，05 §5.10）| M | FSEvents |

---

## 7. 开放问题

> 以下问题无法仅凭源码定案，需在实现/评审阶段决策，已在返回值 openQuestions 列出。

- **OQ-1（列配置持久化格式）**：FM\Columns 二进制 blob（ViewSettings.cpp:52-120）首版是"直搬 blob 最快跑通"还是"立即改结构化 plist / NSTableView autosaveName"？
  - **分类 = 实现细节取舍（非功能分期、非裁剪）**：列配置功能（每列显隐/宽度/排序键持久化）一对一保留，**两条路径都交付该功能**，区别仅在存储格式。因此**不属于"一对一功能被降级"**，无需产品对"是否分期"拍板，仅需工程定存储格式。
  - **定案（消除 03/05 表述冲突，以 05 §4.2 为准）= 首版即改结构化 plist `FM.Columns.<id>`（弃 blob）**。理由：blob 直搬需在 mac 重写 ViewSettings 的二进制读写并维护字节布局兼容，反而比写结构化 plist 更费；结构化 plist 还便于将来与 Windows 配置互换。§3.3 表内"首版可保留 blob 直搬"的旧表述据此收敛为"首版即结构化 plist"（已同步修订 §3.3）。残留待定仅"是否额外提供 blob 导入以兼容 Windows 旧配置"，列为增强项，不阻塞首版。
- **OQ-2（Return 键二义）**：mac 列表 Return 习惯=重命名（Finder），但 7zFM Enter=打开（OpenSelectedItems(true)，App.h:121）。**本章默认已按一对一硬标准定为 Return=Open**（Rename 走 F2 / Cmd+Return + 单击已选项延时编辑，不抢 Return）；OQ-2 仅作为"是否为贴 Finder 习惯而偏离一对一"的产品/UX 决策上抛——若产品最终选择贴 Finder（Return=Rename），需在文档显式标注为**违反一对一纲领的范围变更**并重定 Open 键位。此点须 UX 评审先于实现拍板。
- **OQ-3（四视图模式取舍）**：Large/Small Icons/List/Details 四模式（§1.3，resource.rc:97-100 / Panel.cpp:871-892 真实四档，View 菜单 IDM_700-703 已登记）是否首版全做？Icons/List 需 NSCollectionView 额外工作量。
  - **分类（按一对一基线，登记于 05 §0.4 分期/裁剪表）= 一对一范围内的分期实现（非裁剪）**：四档全部属 View 菜单登记的一对一功能，**最终必须全做**，不得砍。首版分期建议：M4 交付 **Details + Large Icons 两档**（覆盖最常用），**List + Small Icons 延至 v1.1 补齐**（给目标版本，不是无限期后置）。
  - **验收硬标准**：M4 出口要求 Details + Icons 两档可用且与 Windows 行为一致；v1.1 出口要求四档齐全、Ctrl/Cmd+1..4 全部映射、视图状态持久化（ListMode 键）。**分期项写入 05 §0.4 登记表的"已知分期缺口"清单**，标注"一对一范围内、v1.1 补齐"。
  - **需产品拍板项**：若产品要求"一对一硬标准不允许任何 View 菜单项分期"，则四档须全部进 M4（+NSCollectionView List/Small 工作量约 +3 人日，调整 05 M4 估算）。本方案默认值 = 允许分期到 v1.1，但**此分期是否被一对一硬标准接受须产品签字**，否则按"四档全进 M4"执行。
- **OQ-4（CVirtFileSystem 内存优化）**：归档内打开小文件先入内存（阈值 RAM>>max(层数+1,8)，PanelItemOpen.cpp）是否移植，还是首版一律落盘临时文件？影响小文件预览性能与内存占用。
- **OQ-5（备选选择模式 _mySelectMode）**：FAR 风格 Ins/Shift 选择（App.cpp:98-108，对应 Settings 页 `AlternativeSelection` 注册表键，已在 §3.2 设置页登记）是否移植？mac 用户罕见此交互。
  - **分类（按一对一基线，登记于 05 §0.4 分期/裁剪表）= 一对一范围内的分期实现（非裁剪）**：`AlternativeSelection` 是设置页登记的一对一键，**最终须做**（含设置开关 + FAR 式交互），不得静默砍。首版分期：M4 先做标准多选（默认值），**FAR 式备选选择模式延至 v1.1**（给目标版本）；设置键 `FM.AlternativeSelection` 自 M4 即保留（读写不丢，仅交互后置）。
  - **验收硬标准**：M4 出口要求设置键存在且可持久化、标准多选可用；v1.1 出口要求勾选 `AlternativeSelection` 后 FAR 式 Ins/Shift/方向标记选择生效。**分期项写入 05 §0.4 登记表的"已知分期缺口"清单**，标注"一对一范围内、v1.1 补齐"。
  - **需产品拍板项**：若产品认定该交互对 mac 用户无价值且可**明确裁剪**，则须给出替代（保留设置键但 UI 隐藏、勾选无效并提示"该模式 macOS 不提供"）并记为范围变更；默认 = 分期实现而非裁剪，**取舍须产品签字**。
- **OQ-6（Cmd+V 粘贴文件进归档）**：mac 可用 NSPasteboard 实现比 Windows 更完整的"复制文件→粘贴进归档"（Windows EditPaste 是空实现）。是否启用（超出一对一、属增强）？若启用需定义 pasteboard 文件来源的归档压入路径。
- **OQ-7（ShowSystemMenu 语义）**：Windows 的"右键并入系统 Shell 菜单"（PanelMenu.cpp:919-985）在 mac 无对应。该设置项是改为"右键含'在访达中显示'"开关、还是直接移除？影响 Settings 页一对一完整性。
- **OQ-8（地址栏控件选型）**：面包屑 ComboBoxEx（动态构建路径栈 + Documents/Computer/卷/Network 固定项，PanelFolderChange.cpp:627-801；实证：AddComboBoxItem 同时铺路径段缩进 + Documents/Computer/各卷/Network 固定项，且整体可编辑输入路径）三合一能力。**结论（已定案，非纯原型问题）**：两个候选各缺一半——NSPathControl 是只读面包屑展示控件（无 `setEditable`，无法在路径段就地输入），NSComboBox 可编辑但无面包屑分段；任一单控件都不满足。**首版方案**：自建复合控件 `SZAddressBar`——展示态用自绘面包屑（NSStackView/自绘 NSView 分段，每段点击 BindToPath，最右段可溢出折叠）+ 编辑态切换为 NSTextField（聚焦/Cmd+Shift+G 时切入，输入完整路径，Esc 退回展示态），下拉历史与固定项（Documents/Computer/各卷）用 NSPopover/自管 NSMenu 承载。NSPathControl 仅作为"纯展示态降级"备选（若 SZAddressBar 延期）。**降级容许**：首版可接受"纯可编辑 NSComboBox（含历史下拉与固定项，但无面包屑分段展示）"并显式标注为已知 UX 缺口（范围变更：地址栏面包屑分段展示后置），但不得把可行性悬置。工作量从 M 上调为 **L**（自绘复合控件 + 编辑/展示态切换 + 固定项下拉）。
