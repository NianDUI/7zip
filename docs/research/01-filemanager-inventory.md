# 7zFM（CPP/7zip/UI/FileManager）功能全清单 —— macOS 移植盘点底料

> 调查对象：7-Zip 26.01 源码 `CPP/7zip/UI/FileManager`（147 文件 / 约 39.2k 行 .cpp+.h，另含 30 个 .rc/资源文件）。
> 所有结论均来自真实源码核读，证据格式 `文件:行号`（相对 `CPP/7zip/UI/FileManager/`，跨目录时给全相对路径）。
> 用途：macOS 方案B（核心 dylib + ObjC++ 桥接 + AppKit）一对一移植的设计与评审底料。

---

## 0. 总览：7zFM 是什么、由什么构成

### 0.1 程序骨架

| 项 | 事实 | 证据 |
|---|---|---|
| 入口 | `WinMain` → `WinMain2`：`OleInitialize`（拖拽必需）、解析命令行（第 1 参数 = 要打开的路径，`-t<format>` 指定格式）、`LoadLangOneTime`、`InitInstance`、加速键消息循环 | FM.cpp:577-783, 634, 639-702, 745-772 |
| 主窗口 | 自注册窗口类 + `WndProc`；`WM_CREATE` 中创建 `g_App`（两面板）、注册 OLE DropTarget；`WM_CLOSE` 时保存全部状态 | FM.cpp:890-1161, 1023, 1028-1048 |
| 全局应用对象 | `CApp g_App`：2 个 `CPanel`、工具栏、DropTarget、`CAppState`（收藏夹+历史） | App.h:57-312 |
| 面板分割 | 主窗口内自绘 splitter（`g_Splitter`），鼠标拖动改变两面板宽度 | FM.cpp:955-968, 1058-1105 |
| 子窗口布局 | `CApp::MoveSubWindows()` 手工布局工具栏与两个面板 | FM.cpp:1176-1223 |
| 工具栏 | 两组按钮：Archive(Add/Extract/Test，命令 ID 1070-1072) + Standard(Copy/Move/Delete/Info=菜单命令)，位图资源 `Add.bmp` 等 | App.cpp:185-198, 255-274; App.h:22-31 |
| 帮助 | `ShowHelpWindow()` → HtmlHelp 打开 `7-zip.chm::/FM/index.htm` | HelpUtils.cpp:38-77; MyLoadMenu.cpp:38 |
| 多语言 | `Z7_LANG`：`Lang` 子目录 `*.txt`（参考 `en.ttt`），运行期替换菜单/对话框文本；语言注册表键 `HKCU\Software\7-Zip\Lang` | LangUtils.h:13-41; LangPage.cpp:79-120; RegistryUtils.cpp:20,58-59 |
| 退出协调 | `CExitEventLauncher`：全局退出事件 + 等待"在归档内打开的外部编辑进程"监视线程 | Panel.h:997-1018; PanelItemOpen.cpp:1079-1106 |

### 0.2 构建依赖（决定移植时哪些模块必须一起搬）

7zFM.exe 的链接清单（makefile）：

| 模块 | 内容 | 证据 |
|---|---|---|
| FM_OBJS | 本目录全部 70+ 目标文件 | FM.mak:13-88 |
| AGENT_OBJS | `UI/Agent`：Agent/AgentOut/AgentProxy/ArchiveFolder*（把 IInArchive 包装成 IFolderFolder 的"归档文件夹"） | FM.mak:93-101 |
| UI_COMMON_OBJS | `UI/Common`：OpenArchive/LoadCodecs/CompressCall/ZipRegistry/HashCalc 等 | makefile:66-85 |
| EXPLORER_OBJS | `UI/Explorer`：ContextMenu.obj（CZipContextMenu）、MyMessages、RegistryContextMenu | makefile:87-90 |
| GUI_OBJS | `UI/GUI`：HashGUI、UpdateCallbackGUI2 | makefile:92-94 |
| Windows 包装层 | Clipboard/CommonDialog/DLL/Menu/Registry/Shell/Window/Control(ComboBox,Dialog,ListView,PropertyPage,Window2) 等 | makefile:22-51 |
| 编译宏 | `-DZ7_EXTERNAL_CODECS`（格式 handler 从外部 7z.dll 加载）、`-DZ7_LANG`、`-DZ7_DEVICE_FILE` | makefile:1-4; FM.mak:1-8 |
| 链接库 | comctl32, htmlhelp, comdlg32, Mpr(网络枚举,延迟加载), Gdi32 | FM.mak:7-10 |

关键事实：归档打开**不经 COM 注册表**，直接 `new CArchiveFolderManager`（Agent 静态链接）；格式 handler 通过 `Z7_EXTERNAL_CODECS`/LoadCodecs 由 7z.dll 提供（FileFolderPluginOpen.cpp:300；PanelCrc.cpp:360-364 `LoadGlobalCodecs()`）。旧的"按 CLSID 加载插件 DLL"路径已被注释掉（FileFolderPluginOpen.cpp:288-304；PluginLoader.h:12-31 仅保留 `CreateObject` 入口）。

### 0.3 中枢抽象：IFolder 接口族（移植的"接口契约"）

`IFolder.h` 定义了面板浏览的全部抽象，**纯 COM 风格、无 UI 依赖**，mac 上随 MyWindows.h 模拟层即可复用：

| 接口 | 用途 | 证据 |
|---|---|---|
| `IFolderFolder` | LoadItems/GetNumberOfItems/GetProperty/BindToFolder(index|name)/BindToParentFolder/GetFolderProperty | IFolder.h:29-40 |
| `IFolderAltStreams` | 绑定到 NTFS 备用流视图 | IFolder.h:47-52 |
| `IFolderWasChanged` | 自动刷新轮询 | IFolder.h:54-56 |
| `IFolderOperations` | CreateFolder/CreateFile/Rename/Delete/CopyTo/CopyFrom/SetProperty/CopyFromFile —— 全部文件操作语义的承载接口 | IFolder.h:76-89 |
| `IFolderOperationsExtractCallback` | AskWrite/ShowMessage/SetCurrentFilePath/SetNumFiles + IProgress | IFolder.h:60-73 |
| `IFolderGetItemName`/`IFolderCompare`/`IFolderGetSystemIconIndex`/`IFolderClone`/`IFolderSetFlatMode`/`IFolderCalcItemFullSize` | 名称快取/排序委托/图标/克隆/平面视图/目录尺寸计算 | IFolder.h:98-154 |
| `IFolderProperties`/`IFolderArcProps`/`IGetFolderArcProps` | 属性窗口的数据源（含嵌套归档逐层属性） | IFolder.h:124-143 |
| `IFolderManager` | OpenFolderFile/GetExtensions/GetIconPath（Agent 实现） | IFolder.h:157-166 |

---

## 1. 菜单命令全清单

### 1.1 菜单树（资源定义）+ 快捷键 + 处理函数

菜单资源：`IDM_MENU MENUEX`（resource.rc:33-161）。顶层：**File / Edit / View / Favorites / Tools / Help**（ID 500-505，resource.h:35-40）。
命令分发：`WndProc WM_COMMAND` → `OnMenuCommand()`（FM.cpp:894-907; MyLoadMenu.cpp:805-964），文件类命令先走 `ExecuteFileCommand()`（MyLoadMenu.cpp:736-796）。

#### File 菜单（resource.rc:35-79）

| 菜单项 | ID | 快捷键 | 处理函数（链路） | 证据 |
|---|---|---|---|---|
| Open | IDM_OPEN=540 | Enter | `g_App.OpenItem()`→`CPanel::OpenSelectedItems(true)` | resource.rc:37; MyLoadMenu.cpp:749; App.h:121 |
| Open Inside | IDM_OPEN_INSIDE=541 | Ctrl+PgDn | `g_App.OpenItemInside(NULL)`→`OpenFocusedItemAsInternal` | resource.rc:38; MyLoadMenu.cpp:751; App.h:122 |
| Open Inside * | IDM_OPEN_INSIDE_ONE=590 | — | `OpenItemInside(L"*")`（强制单格式解析） | resource.rc:39; MyLoadMenu.cpp:752 |
| Open Inside # | IDM_OPEN_INSIDE_PARSER=591 | — | `OpenItemInside(L"#")`（强制 parser 模式） | resource.rc:40; MyLoadMenu.cpp:753 |
| Open Outside | IDM_OPEN_OUTSIDE=542 | Shift+Enter | `g_App.OpenItemOutside()`→`OpenSelectedItems(false)` | resource.rc:41; MyLoadMenu.cpp:755; App.h:123 |
| View | IDM_FILE_VIEW=543 | F3 | `g_App.EditItem(false)`（用 Viewer 程序） | resource.rc:42; MyLoadMenu.cpp:756 |
| Edit | IDM_FILE_EDIT=544 | F4 | `g_App.EditItem(true)`（用 Editor 程序） | resource.rc:43; MyLoadMenu.cpp:757 |
| Rename | IDM_RENAME=545 | F2 | `g_App.Rename()`→`CPanel::RenameFile()`（ListView 就地编辑标签） | resource.rc:45; MyLoadMenu.cpp:758; PanelOperations.cpp:478-485 |
| Copy To... | IDM_COPY_TO=546 | F5 | `g_App.CopyTo()`→`OnCopy(false,false,...)` | resource.rc:46; MyLoadMenu.cpp:759; App.h:126 |
| Move To... | IDM_MOVE_TO=547 | F6 | `g_App.MoveTo()`→`OnCopy(true,false,...)` | resource.rc:47; MyLoadMenu.cpp:760; App.h:127 |
| Delete | IDM_DELETE=548 | Del（Shift+Del=永久删除） | `g_App.Delete(!IsKeyDown(VK_SHIFT))` | resource.rc:48; MyLoadMenu.cpp:761 |
| Split file... | IDM_SPLIT=549 | — | `g_App.Split()` | resource.rc:50; MyLoadMenu.cpp:783; PanelSplitFile.cpp:235-342 |
| Combine files... | IDM_COMBINE=550 | — | `g_App.Combine()` | resource.rc:51; MyLoadMenu.cpp:784 |
| Properties | IDM_PROPERTIES=551 | Alt+Enter | `g_App.Properties()`→`CPanel::Properties()` | resource.rc:53; MyLoadMenu.cpp:785; PanelMenu.cpp:172-423 |
| Comment... | IDM_COMMENT=552 | Ctrl+Z | `g_App.Comment()`→`ChangeComment()` | resource.rc:54; MyLoadMenu.cpp:786; PanelOperations.cpp:487-533 |
| CRC 子菜单（CRC-32/CRC-64/XXH64/MD5/SHA-1/SHA-256/SHA-384/SHA-512/SHA3-256/BLAKE2sp/*) | IDM_CRC32..IDM_HASH_ALL（101-122） | — | `g_App.CalculateCrc("<method>")` | resource.rc:56-69; MyLoadMenu.cpp:763-773; resource.h:23-33 |
| Diff | IDM_DIFF=554 | — | `g_App.DiffFiles()`（仅当注册表配置了 Diff 程序才显示） | resource.rc:70; MyLoadMenu.cpp:775, 614 |
| Create Folder | IDM_CREATE_FOLDER=555 | F7 | `g_App.CreateFolder()` | resource.rc:72; MyLoadMenu.cpp:787 |
| Create File | IDM_CREATE_FILE=556 | Ctrl+N | `g_App.CreateFile()` | resource.rc:73; MyLoadMenu.cpp:788 |
| Link... | IDM_LINK=558 | — | `g_App.Link()`（硬链接/符号链接对话框；仅单选可用） | resource.rc:75; MyLoadMenu.cpp:790; LinkDialog.cpp:353+; MyLoadMenu.cpp:675 |
| Alternate streams | IDM_ALT_STREAMS=559 | — | `g_App.OpenAltStreams()`（仅支持 AltStream 的文件夹可用） | resource.rc:76; MyLoadMenu.cpp:791, 678-679 |
| Exit | IDCLOSE | Alt+F4 | `SendMessage(WM_CLOSE)` | resource.rc:78; MyLoadMenu.cpp:813-817 |
| （隐藏）Ver Edit/Commit/Revert/Diff | IDM_VER_EDIT..IDM_VER_DIFF=580-583 | — | `g_App.VerCtrl(id)`；仅配置了 `7vc` 注册表项且单选 FS 文件时追加 | resource.h:63-66; MyLoadMenu.cpp:572-586, 697-731, 777-781; VerCtrl.cpp |
| （隐藏）Benchmark2 | IDM_BENCHMARK2=902 | — | `MyBenchmark(true)`；仅配置 Diff（"super mode"）时显示 | MyLoadMenu.cpp:626-631, 918 |

**File 菜单为动态菜单**：每次下拉时被清空并由 `CPanel::CreateFileMenu()` 重建（MyLoadMenu.cpp:398-404），其中按上下文插入 7-Zip 右键菜单（CZipContextMenu）与系统右键菜单，并按只读/Hash 文件夹/选中数禁用条目（MyLoadMenu.cpp:588-734；PanelMenu.cpp:919-985）。

#### Edit 菜单（resource.rc:80-94）

| 菜单项 | ID | 快捷键 | 处理 | 证据 |
|---|---|---|---|---|
| Select All | IDM_SELECT_ALL=600 | Shift+[Grey +]（及 Ctrl+A） | `g_App.SelectAll(true)`+刷新状态栏 | resource.rc:86; MyLoadMenu.cpp:831-834; PanelKey.cpp:276-282 |
| Deselect All | IDM_DESELECT_ALL=601 | Shift+[Grey -] | `SelectAll(false)` | resource.rc:87; MyLoadMenu.cpp:835-838 |
| Invert Selection | IDM_INVERT_SELECTION=602 | Grey * | `InvertSelection()` | resource.rc:88; MyLoadMenu.cpp:839-842 |
| Select... | IDM_SELECT=603 | Grey + | `SelectSpec(true)`（通配符对话框） | resource.rc:89; MyLoadMenu.cpp:843-846; PanelSelect.cpp:154-167 |
| Deselect... | IDM_DESELECT=604 | Grey - | `SelectSpec(false)` | resource.rc:90; MyLoadMenu.cpp:847-850 |
| Select by Type | IDM_SELECT_BY_TYPE=605 | Alt+[Grey +] | `SelectByType(true)`（按扩展名/文件夹类型） | resource.rc:92; MyLoadMenu.cpp:851-854; PanelSelect.cpp:169-204 |
| Deselect by Type | IDM_DESELECT_BY_TYPE=606 | Alt+[Grey -] | `SelectByType(false)` | resource.rc:93; MyLoadMenu.cpp:855-858 |
| （注释掉）Cut/Copy/Paste | — | Ctrl+X/C/V | 菜单项被注释，但键仍映射到 `EditCut/EditCopy/EditPaste` | resource.rc:82-85; PanelKey.cpp:283-303 |

#### View 菜单（resource.rc:95-133）

| 菜单项 | ID | 快捷键 | 处理 | 证据 |
|---|---|---|---|---|
| Large Icons / Small Icons / List / Details | IDM_VIEW_LARGE_ICONS..IDM_VIEW_DETAILS=700-703 | Ctrl+1..Ctrl+4 | `g_App.SetListViewMode(0..3)`（切换 ListView 样式） | resource.rc:97-100; MyLoadMenu.cpp:861-878; Panel.cpp:871-892 |
| Name/Type/Date/Size 排序 | IDM_VIEW_ARANGE_BY_*=710-713 | Ctrl+F3..Ctrl+F6 | `SortItemsWithPropID(kpidName/kpidExtension/kpidMTime/kpidSize)` | resource.rc:102-105; MyLoadMenu.cpp:879-882; PanelKey.cpp:21-28,83-88 |
| Unsorted | IDM_VIEW_ARANGE_NO_SORT=730 | Ctrl+F7 | `SortItemsWithPropID(kpidNoProperty)` | resource.rc:106; MyLoadMenu.cpp:883 |
| Flat View | IDM_VIEW_FLAT_VIEW=731 | — | `g_App.ChangeFlatMode()`（盘内/归档内分别记忆） | resource.rc:108; MyLoadMenu.cpp:888; Panel.cpp:894-902 |
| 2 Panels | IDM_VIEW_TWO_PANELS=732 | F9 | `g_App.SwitchOnOffOnePanel()` | resource.rc:109; MyLoadMenu.cpp:902; App.cpp:360-380 |
| 时间戳精度子菜单（动态"2017"） | IDM_VIEW_TIME_POPUP=760 / IDM_VIEW_TIME=761 / IDM_VIEW_TIME_UTC=799 | — | 动态生成 DAY/MIN/SEC/NTFS(100ns)/NS 五级 + UTC 开关；`g_App.SetTimestampLevel()` / `g_Timestamp_Show_UTC` 取反 | resource.rc:111-114; MyLoadMenu.cpp:440-506, 909-912, 955-958 |
| Toolbars 子菜单：Archive Toolbar / Standard Toolbar / Large Buttons / Show Buttons Text | IDM_VIEW_*=750-753 | — | `SwitchArchiveToolbar/SwitchStandardToolbar/SwitchLargeButtons/SwitchButtonsLables`（改后立即存盘） | resource.rc:116-123; MyLoadMenu.cpp:903-907; App.h:279-298 |
| Open Root Folder | IDM_OPEN_ROOT_FOLDER=734 | \ | `g_App.OpenRootFolder()`→`OpenDrivesFolder()` | resource.rc:124; MyLoadMenu.cpp:885; App.h:168 |
| Up One Level | IDM_OPEN_PARENT_FOLDER=735 | Backspace | `g_App.OpenParentFolder()` | resource.rc:125; MyLoadMenu.cpp:886 |
| Folders History... | IDM_FOLDERS_HISTORY=736 | Alt+F12（加速键表） | `g_App.FoldersHistory()`（ListView 对话框，可删条目，回车跳转） | resource.rc:126, 11; MyLoadMenu.cpp:887; PanelFolderChange.cpp:866-891 |
| Refresh | IDM_VIEW_REFRESH=737 | Ctrl+R | `g_App.RefreshView()`→`OnReload()` | resource.rc:127; MyLoadMenu.cpp:889 |
| Auto Refresh | IDM_VIEW_AUTO_REFRESH=738 | — | `g_App.Change_AutoRefresh_Mode()`（勾选态） | resource.rc:128; MyLoadMenu.cpp:890; App.h:230-244 |

菜单下拉时的勾选状态同步（视图模式单选、排序单选、2 Panels/Flat/工具栏/AutoRefresh 勾选）：MyLoadMenu.cpp:415-437。

#### Favorites 菜单（动态，resource.rc:134-141）

- 子菜单 "Add folder to Favorites as" → Bookmark 0-9（`k_MenuID_SetBookmark=810+i`，显示 `Alt+Shift+i`）；下方直接列出 10 个书签（`k_MenuID_OpenBookmark=830+i`，显示 `Alt+i`），路径超过 100 字符截断为"前50 ... 后50"。每次下拉重建。证据：MyLoadMenu.cpp:27-28, 508-559。
- 命令处理：`OpenBookmark(index)/SetBookmark(index)`（MyLoadMenu.cpp:945-953）→ `CPanel::OpenBookmark/SetBookmark`（PanelFolderChange.cpp:335-343），数据存 `AppState.FastFolders`（AppState.h:10-39）。

#### Tools 菜单（resource.rc:142-153）

| 菜单项 | ID | 处理 | 证据 |
|---|---|---|---|
| Options... | IDM_OPTIONS=900 | `OptionsDialog(hWnd, hInstance)`（6 页属性表） | resource.rc:144; MyLoadMenu.cpp:915; OptionsDialog.cpp:32-89 |
| Benchmark | IDM_BENCHMARK=901 | `MyBenchmark(false)` → `Benchmark()`（UI/Common/CompressCall → 启动 `7zG b`） | resource.rc:146; MyLoadMenu.cpp:798-803, 917; ../Common/CompressCall.h:26 |
| Delete Temporary Files... | IDM_TEMP_DIR=910 | `MyBrowseForTempFolder(g_HWND)`（BrowseDialog2 浏览/删除 `7zE*`/`7zO*` 临时目录） | resource.rc:151; MyLoadMenu.cpp:931-941; BrowseDialog2.cpp:1846-1859 |

#### Help 菜单（resource.rc:154-160）

| 菜单项 | ID | 快捷键 | 处理 | 证据 |
|---|---|---|---|---|
| Contents... | IDM_HELP_CONTENTS=960 | F1（加速键表） | `ShowHelpWindow("FM/index.htm")` | resource.rc:156, 10; MyLoadMenu.cpp:921-923 |
| About 7-Zip... | IDM_ABOUT=961 | — | `CAboutDialog` | resource.rc:159; MyLoadMenu.cpp:924-929 |

### 1.2 面板级键盘命令（菜单之外，PanelKey.cpp:39-357 全表）

| 按键 | 行为 | 证据 |
|---|---|---|
| Tab | 切换另一面板焦点 | PanelKey.cpp:41-45; App.cpp:42-47 |
| Alt/右Ctrl + 0-9（+Shift 设置） | 打开/设置书签 | PanelKey.cpp:53-68 |
| Alt+F1 / Alt+F2 | 焦点到左/右面板地址栏并下拉 | PanelKey.cpp:70-76; App.cpp:49-57 |
| F9 | 单/双面板切换 | PanelKey.cpp:78-81 |
| Ctrl+F3..F7 | 按 Name/Ext/MTime/Size/无序排序 | PanelKey.cpp:21-28, 83-88 |
| F2/F3/F4 | 重命名 / View / Edit | PanelKey.cpp:105-135 |
| Shift+F4 | 新建文件 | PanelKey.cpp:130-134 |
| F5 / F6（+Shift→同面板复制为 copyToSame） | Copy / Move | PanelKey.cpp:137-154; App.cpp:565-610 |
| F7 | 新建文件夹（注释说明：故意不走加速键，避免 UNC 下菜单慢） | PanelKey.cpp:155-166 |
| Del（Shift+Del 不进回收站） | 删除 | PanelKey.cpp:167-171 |
| Ctrl+Ins / Shift+Ins | EditCopy / EditPaste；Ins 在备选选择模式下逐项选中 | PanelKey.cpp:172-193 |
| Shift+方向键 | 区段选择（备选模式） | PanelKey.cpp:194-223; PanelSelect.cpp:14-75 |
| Alt+Up/Right/Left | 另一面板同步到当前目录/子目录 | PanelKey.cpp:200-223; App.cpp:858-911 |
| 小键盘 + - *（含 Shift/Alt 组合） | Select/Deselect/Invert（见 Edit 菜单） | PanelKey.cpp:233-252, 344-348 |
| Backspace | 上级目录 | PanelKey.cpp:261-263 |
| Ctrl+A/X/C/V/N/R/W/Z | 全选/剪切/复制/粘贴/新建文件/刷新/关窗/注释 | PanelKey.cpp:276-332 |
| Ctrl+1..4 | 视图模式 | PanelKey.cpp:333-343 |
| Alt+F12 | 文件夹历史 | PanelKey.cpp:349-354 |
| `\` `/`（ListView WM_CHAR） | 打开"计算机"（驱动器列表） | Panel.cpp:161-177 |
| Ctrl+PgDn / Ctrl+PgUp（ListView WM_KEYDOWN） | 内部打开聚焦项 / 上级目录 | Panel.cpp:193-226 |
| 地址栏内：Tab→列表焦点、F9 切双面板、Ctrl+W 关窗、Alt+F1/F2 | 地址栏 Edit 子类化处理 | Panel.cpp:276-347 |
| 加速键表（resource.rc:7-13） | 仅 F1=帮助、Alt+F12=历史 两条 | resource.rc:7-13 |

### 1.3 右键上下文菜单

- `CPanel::OnContextMenu`：列表头右键→列选择菜单 `ShowColumnsContextMenu`；项目右键→`CreateFileMenu(programMenu=false)` 弹出（PanelMenu.cpp:1081-1158）。
- 菜单构成 = [7-Zip 上下文菜单 (CZipContextMenu, `Init_For_7zFM`)] + [可选 系统 Shell 菜单（设置 ShowSystemMenu 开启；通过 `SHGetDesktopFolder`/`ParseDisplayName`/`GetUIObjectOf(IID_IContextMenu)`）] + [File 菜单条目]（PanelMenu.cpp:919-985, 686-783, 502-616）。
- 命令回调：ID≥1100 → `InvokePluginCommand`（`IContextMenu::InvokeCommand`，区分 7-Zip 段 1100-1499 与系统段 1500+）（PanelMenu.cpp:34-35, 997-1079）。
- Shift+右键 = 扩展动词（CMF_EXTENDEDVERBS）（PanelMenu.cpp:927）。

---

## 2. 对话框全清单（*.rc + 配套 .cpp）

| 对话框（资源 ID） | 文件 | 用途 | 关键控件 | 关联设置/数据 | Win32 依赖评级* |
|---|---|---|---|---|---|
| About（IDD_ABOUT） | AboutDialog.rc/.cpp | 关于框：版本/日期/版权 + 官网按钮 | ICON、LTEXT、主页按钮 | `MY_VERSION_INFO` | B |
| Browse（IDD_BROWSE） | BrowseDialog.rc/.cpp(1132 行) | 7-Zip 自绘文件/文件夹选择器（替代系统对话框，支持超长路径）；`MyBrowseForFolder`/`BrowseForFile` | 路径 Edit、过滤 ComboBox、SysListView32、"<--"上级、"+"新建目录 | 被 EditPage/FoldersPage/CopyDialog/LinkDialog 等调用 | B |
| Browse2（IDD_BROWSE2） | BrowseDialog2.rc/.cpp(1866 行) | 临时文件浏览/删除器（Tools→Delete Temporary Files），可浏览 7zE*/7zO* 目录并删除 | 列表、Delete/Refresh/上级按钮、过滤 Combo | 入口 MyLoadMenu.cpp:939 | B |
| Combo（IDD_COMBO） | ComboDialog.rc/.cpp | 通用"单输入框+下拉历史"对话框 | LTEXT + COMBOBOX | 用于 新建文件名（PanelOperations.cpp:437）、注释（:513）、Select 掩码（PanelSelect.cpp:156） | B |
| Copy（IDD_COPY） | CopyDialog.rc/.cpp | Copy To/Move To 目标选择 | 目标路径 Combo（带历史）、"..."浏览按钮、多行信息区（选中项统计，`kCopyDialog_NumInfoLines=11`） | CopyHistory（最多 20 条）App.cpp:612-613, 754-757 | B |
| Edit（IDD_EDIT_DLG） | EditDialog.rc/.cpp | 只读多行文本查看（错误/消息文本） | ES_MULTILINE 只读 Edit | — | B |
| ListView（IDD_LISTVIEW） | ListViewDialog.rc/.cpp | 通用列表对话框：文件夹历史、属性窗口（2 列）、哈希结果等；支持删除条目（DeleteIsAllowed）、复制到剪贴板、回车选择 | SysListView32（无列头） | FoldersHistory（PanelFolderChange.cpp:866-891）、Properties（PanelMenu.cpp:419-421） | B |
| Mem（IDD_MEM） | MemDialog.rc/.cpp | 解压内存超限询问："允许/跳过 + 改限额(GB spin) + 记住本次操作" | 信息文本、checkbox、Edit+Spin、单选组、Continue/Cancel | `NExtract::Save_LimitGB`；由 `IArchiveRequestMemoryUseCallback`（ExtractCallback.h:194）触发 | B |
| Messages（IDD_MESSAGES） | MessagesDialog.rc/.cpp | "诊断消息"批量错误列表（操作结束后） | SysListView32 + Close | 由 ProgressDialog/拖拽错误集合填充（PanelDrag.cpp:1781-1786） | B |
| Overwrite（IDD_OVERWRITE） | OverwriteDialog.rc/.cpp | 覆盖确认：旧/新文件 图标+大小+时间，Yes/No/YesAll/NoAll/AutoRename/Cancel | 2 组 ICON+LTEXT、6 按钮 | 由解压 AskOverwrite 回调弹出（ExtractCallback.cpp） | B |
| Password（IDD_PASSWORD） | PasswordDialog.rc/.cpp | 输入密码（ES_PASSWORD + Show password 勾选） | Edit、checkbox | 由 Open/Extract 密码回调弹出 | B |
| Progress（IDD_PROGRESS） | ProgressDialog.rc/.cpp | 简易进度（仅进度条+Cancel）；用于 CopyFrom（压入归档）等 | msctls_progress32 | PanelCopy.cpp:341-430 | B |
| Progress2（IDD_PROGRESS） | ProgressDialog2.rc/2a.rc/.cpp(1483 行) | 主进度对话框：Elapsed/Remaining/Files/Errors/Total/Speed/Processed/Packed/Ratio 9 值 + 状态行 + 文件名 + 进度条 + 错误列表；按钮 Background/Pause/Cancel；支持后台、暂停、取消确认、错误聚合、标题百分比 | 多 LTEXT/RTEXT、progress、SysListView32 | `CProgressSync`（跨线程状态）+ `CProgressThreadVirt`（工作线程基类） | B |
| Split（IDD_SPLIT） | SplitDialog.rc/.cpp | 拆分文件：目标路径 + 卷大小 Combo（预置 1457664/FAT 4G 等，SplitUtils） | 2 Combo + "..." | 入口 App::Split（PanelSplitFile.cpp:235-342） | B |
| Link（IDD_LINK） | LinkDialog.rc/.cpp | 创建链接：from/to 路径 + 类型单选（Hard/SymFile/SymDir/Junction/WSL） | 2 Combo+浏览、5 RadioButton | `NIO::SetReparseData`/硬链接 API（LinkDialog.cpp:337-341） | **C（Win32 reparse 语义）** |
| 6 个选项属性页 | 见 §3 | | | | |

\* 评级：A=纯逻辑可直接复用；B=逻辑可保留、UI 壳需 AppKit 重写（对话框布局/控件为 Win32 资源）；C=连语义都要为 macOS 重新设计。所有对话框 .rc 布局本身都必须重做（DLU 布局、Win32 控件类）。

通用对话框基建：`DialogSize.h`（大屏/小屏两套尺寸）、`../../GuiCommon.rc`（OK_CANCEL 宏等）、`NControl::CModalDialog/CDialog/CPropertyPage`（CPP/Windows/Control/*）。

---

## 3. 选项对话框（Tools→Options，6 个属性页）

入口 `OptionsDialog()`：`MyPropertySheet` 组合 6 页：**System / 7-Zip(Menu) / Folders / Editor / Settings / Language**（OptionsDialog.cpp:44-52）。应用后：语言变更→重载菜单与工具栏；`SetListSettings()`+`RefreshAllPanels()`（OptionsDialog.cpp:66-88）。

| 页（IDD） | 文件 | 内容 | 写入的设置 | 证据 |
|---|---|---|---|---|
| System（IDD_SYSTEM） | SystemPage.cpp/.rc | 文件关联列表（每扩展名 × [当前用户/所有用户] 两列），图标取自 Agent `GetExtensions/GetIconPath`（FilePlugins.cpp） | `HKCU/HKLM Software\Classes\.<ext>` → `7-Zip.<ext>`（含 DefaultIcon、shell\open\command） | SystemPage.cpp:269-311; RegistryAssociations.cpp:20-165 |
| 7-Zip/Menu（IDD_MENU） | MenuPage.cpp/.rc | Explorer 集成：注册/反注册 7-zip.dll + 7-zip32/64.dll 上下文菜单 handler；Cascaded menu；Icons in menu；Eliminate duplication；Zone.Id 传播（combo：No/Office/All）；上下文菜单条目勾选列表（Open/Extract/ExtractHere/ExtractTo/Test/Add/AddTo/Email×3/CRC） | `CContextMenuInfo`（Options 键：CascadedMenu/MenuIcons/ElimDupExtract/WriteZoneIdExtract/ContextMenu 位掩码）+ COM 注册 | MenuPage.cpp:49-71, 132-200; ../Common/ZipRegistry.cpp:540-560 |
| Folders（IDD_FOLDERS） | FoldersPage.cpp/.rc | 工作目录（写归档临时文件位置）：系统 temp / 当前目录 / 指定路径 + "仅可移动盘使用" | `NWorkDir::CInfo`（Options 键：WorkDirType/WorkDirPath/TempRemovableOnly） | FoldersPage.cpp:36-85; ../Common/ZipRegistry.cpp:490-536 |
| Editor（IDD_EDIT） | EditPage.cpp/.rc | Viewer / Editor / Diff 三个外部程序命令行 | `FM 键：Viewer/Editor/Diff` | EditPage.cpp:30-80; RegistryUtils.cpp:22-25, 61-65 |
| Settings（IDD_SETTINGS） | SettingsPage.cpp/.rc | 9 项：Show ".." item；Show real file icons；Full row select；Show grid lines；Single-click open；Alternative selection mode；Show system menu；Use large memory pages；解压内存上限（GB，spin，含 RAM 显示） | `CFmSettings`（FM 键 7 项）+ `LargePages`（7-Zip 键）+ `NExtract::Save_LimitGB` | SettingsPage.cpp:114-247, 272-384; SettingsPage2.rc |
| Language（IDD_LANG） | LangPage.cpp/.rc | 语言下拉（扫描 `Lang/` 目录，含翻译完成度行数对比），切换立即生效 | `Software\7-Zip\Lang` | LangPage.cpp:54-160; RegistryUtils.cpp:58-59 |

---

## 4. 面板能力（CPanel）

### 4.1 面板构成

每个 `CPanel`（自定义子窗口类 `CWindow2`）包含：ReBar（_headerReBar）+ 头部工具栏（仅"上级目录"按钮）+ **地址栏 ComboBoxEx**（带系统图标、可编辑、Edit 子类化）+ **ListView（SysListView32, LVS_EDITLABELS|LVS_SHAREIMAGELISTS, 系统图标列表）** + **状态栏（4 格：220/320/420/-1）** + 1s 定时器。证据：Panel.cpp:383-597（创建全流程）、Panel.cpp:43-44（kTimerElapse=1000）。

### 4.2 列模型

- 列 = 当前 `IFolderFolder` 报告的属性集（`GetNumberOfProperties/GetPropertyInfo`）+ rawProps（`IArchiveGetRawProps`，如 SHA/NtSecure/NtReparse）；`kpidIsDir` 不作列（PanelItems.cpp:96-199）。
- 每"文件夹类型 ID"（如 FSFolder、7-Zip、7-Zip.Zip…`_typeIDString=GetFolderTypeID()`）独立持久化列集：可见性/宽度/顺序/排序列/升降序，二进制 blob 存 `HKCU\Software\7-Zip\FM\Columns\<TypeID>`（PanelItems.cpp:103-116; ViewSettings.cpp:21, 52-120）。
- 默认隐藏列（FS 文件夹）：ATime/ChangeTime/Attrib/PackSize/INode/Links/NtReparse（PanelItems.cpp:25-42）；kpidName 强制可见（PanelItems.cpp:215-216）；列对齐按 VARTYPE（数字右对齐）（PanelItems.cpp:53-87）。
- 列头拖动重排（LVS_EX_HEADERDRAGDROP，App.cpp:80）；列头右键→列显示菜单（PanelMenu.cpp:1083-1086）。
- 文本按需提供（LVN_GETDISPINFOW → `SetItemText`，PanelListNotify.cpp:152-470, 578-586），含时间戳格式化（5 级精度+UTC）、NtReparse/NtSecure 十六进制、尺寸千分位。

### 4.3 排序模型

- 当前排序 = `_sortID`(PROPID) + `_ascending`；列头点击切换；Size/PackSize/CTime/ATime/MTime 首次默认降序（PanelSort.cpp:256-278）。
- 比较规则：父项("..")恒在最前；**目录恒在文件前**；优先 `IFolderCompare::CompareItems` 委托给 folder 实现；kpidName 用 `CompareFileNames_ForFolderList`；并 kpidName→kpidPrefix 三轮平局打破；最终兜底为加载顺序（PanelSort.cpp:98-221）。
- rawProp（NtReparse 等）二进制比较（PanelSort.cpp:104-128）。"无序"=按 LoadItems 顺序（kpidNoProperty，PanelSort.cpp:101-102）。

### 4.4 选择模型

- 真实选择集保存在 `_selectedStatusVector`（按 folder 项索引），与 ListView 选中态双向同步（Panel.h:446; PanelSelect.cpp:135-151）。
- 两种模式：标准（ListView 多选）与 **Alternative selection（_mySelectMode，LVS_SINGLESEL + Ins/Shift 方向键标记，FAR 风格）**（App.cpp:98-108; PanelKey.cpp:172-223; PanelSelect.cpp:14-133）。
- 操作目标集 `Get_ItemIndices_Operated`：有选中用选中集，否则用焦点项；`OperSmart` 变体（PanelItems.cpp:941-1005）。
- 通配选择/按类型选择/全选/反选（PanelSelect.cpp:154-241）。

### 4.5 双面板（F9）

- `CApp` 固定 2 个 `CPanel`（kNumPanelsMax=2），`NumPanels` ∈ {1,2}，`LastFocusedPanel` 记录焦点；F9 即时创建/隐藏第二面板（App.cpp:360-380）。
- 面板间交互经 `CPanelCallback`（OnTab/SetFocusToPath/OnCopy/OnSetSameFolder/OnSetSubFolder/PanelWasFocused/DragBegin/DragEnd/RefreshTitle）（Panel.h:70-81; App.cpp:42-66）。
- F5/F6 的默认目标 = 另一面板路径（单面板时弹对话框输入）（App.cpp:565-610）。
- 窗口标题 = 焦点面板当前路径（App.cpp:963-972）。

### 4.6 地址栏（面包屑 ComboBoxEx）

下拉时动态构建：`\\server\share` 前缀 → 根前缀 → 逐级目录（带缩进与系统图标，归档层用 ARCHIVE 图标）→ 固定项 **Documents / Computer / 各盘符 / Network**（PanelFolderChange.cpp:627-801）。选择即 `BindToPathAndRefresh`（:803-821）；手输路径回车经 `OnNotifyComboBoxEndEdit`（:532-563）。

### 4.7 根视图与文件夹实现（IFolderFolder 实例）

| 实现 | 文件（行数） | 类型 ID | 说明 | mac 适用性 |
|---|---|---|---|---|
| CRootFolder | RootFolder.cpp (343) | "RootFolder" | 根视图 4 项：Computer(→CFSDrives)、Documents(→CSIDL_PERSONAL 的 FSFolder)、Network(→CNetFolder)、`\\.`卷视图；**非 Windows 分支已存在：仅 Computer→FSFolder("/")**（`USE_WIN_PATHS` 守卫） | RootFolder.cpp:21-31, 92-101, 175-216 |
| NFsFolder::CFSFolder | FSFolder.cpp (1199) + FSFolderCopy.cpp (871) | "FSFolder" | 文件系统文件夹：枚举/属性/重命名/删除/创建/复制（CopyFileSystemItems 带进度）；支持 flat 模式、AltStream 列、目录大小计算 | 部分 `#ifdef _WIN32` 守卫已存在（FSFolder.cpp:102 等）；Copy 实现基于 Win32 CopyFileW/MoveFileW（FSFolderCopy.cpp）须替换 |
| CFSDrives | FSDrives.cpp (512) | "FSDrives" | "计算机"：盘符列表（名称/标签/总量/剩余/文件系统/类型），也用于 `\\.\` 设备卷与 `\\?\` 超级路径视图 | 纯 Win32（GetLogicalDriveStrings 等），mac 重写为卷列表 |
| CNetFolder | NetFolder.cpp (276) | "NetFolder" | 网络邻居（WNet 枚举） | mac 无对应，砍或重写 |
| NAltStreamsFolder::CAltStreamsFolder | AltStreamsFolder.cpp (946) | "AltStreamsFolder" | NTFS 备用流 `base:` 视图 | mac 无对应（xattr 语义不同），建议砍 |
| Agent 归档文件夹 | ../Agent/* | "7-Zip"/"7-Zip.<Type>" | 归档内容视图 + IFolderOperations（增删改/CopyTo/CopyFrom 即压缩/解压） | 纯逻辑（已随 7zz 验证），直接复用 |
| Hash 结果文件夹 | （Agent/HashGUI 提供，`kpidIsHash`） | — | `IsHashFolder()` 判定，多数操作被禁 | Panel.cpp:843-853 |

`BindToPath`（PanelFolderChange.cpp:76-313）是路径→文件夹栈的总调度：能解析"FS 路径 + 归档内路径 + 嵌套归档 + `name:`AltStream"混合串；`_parentFolders`（`CFolderLink` 栈）记录每层归档（临时文件/虚拟流、密码、库句柄）（Panel.h:147-195, 451-452）。

### 4.8 文件夹历史 / 收藏夹

- FolderHistory：每次成功换目录加入头部、去重、上限 100；Alt+F12 打开可编辑列表（App.cpp:992-1004; PanelFolderChange.cpp:866-891）；持久化 `FM\FolderHistory`（ViewSettings.cpp:30, 292-295）。
- FastFolders（收藏 0-9）：`FM\FolderShortcuts`（AppState.h:10-39; ViewSettings.cpp:31, 297-300）。

### 4.9 状态栏 / 自动刷新 / 标题

- 状态栏 4 格：`选中数/总数`、选中合计大小、焦点项大小、焦点项修改时间（PanelListNotify.cpp:759-830）。
- 自动刷新：1s 定时器轮询 `IFolderWasChanged`（FS 文件夹用目录变更通知句柄），变化即 `OnReload`，保持选中态（PanelItems.cpp:1435-1453; Panel.cpp:591）。可经 View→Auto Refresh 关闭（App.h:230-244）。
- 危险名提示：打开外部程序前检测 RLO 字符/连续空格/伪装扩展名 → "looks like a virus" 警告（PanelItemOpen.cpp:867-947）。

---

## 5. 设置与注册表持久化（逐项）

### 5.1 `HKCU\Software\7-Zip`（RegistryUtils.cpp:14-16）

| 值 | 类型 | 含义 | 读/写 | 证据 |
|---|---|---|---|---|
| `Lang` | SZ | 语言文件路径/ID（"-"=英文） | ReadRegLang/SaveRegLang | RegistryUtils.cpp:20, 58-59 |
| `LargePages` | DWORD(bool) | 压缩用大页内存 | ReadLockMemoryEnable/SaveLockMemoryEnable | RegistryUtils.cpp:38, 170-171 |

### 5.2 `HKCU\Software\7-Zip\FM`（RegistryUtils.cpp:17; ViewSettings.cpp:18-32）

| 值 | 类型 | 含义 | 证据 |
|---|---|---|---|
| `Viewer` / `Editor` / `Diff` / `7vc` | SZ | 外部查看器/编辑器/比较器/版本控制目录 | RegistryUtils.cpp:22-25, 61-67 |
| `ShowDots` | bool | 显示 ".." 项 | RegistryUtils.cpp:27, 121-163 |
| `ShowRealFileIcons` | bool | FS 文件夹用真实系统图标（否则仅扩展名图标缓存） | 同上 |
| `FullRow` | bool | 整行选中（LVS_EX_FULLROWSELECT） | 同上; App.cpp:81-82 |
| `ShowGrid` | bool | 网格线（LVS_EX_GRIDLINES） | 同上; App.cpp:83-84 |
| `SingleClick` | bool | 单击打开（ONECLICKACTIVATE+TRACKSELECT） | 同上; App.cpp:86-93 |
| `AlternativeSelection` | bool | FAR 式选择模式 | 同上; App.cpp:98 |
| `ShowSystemMenu` | bool | 文件菜单/右键并入系统 Shell 菜单 | RegistryUtils.cpp:35, 131, 162; PanelMenu.cpp:941-942 |
| `FlatViewArc0` / `FlatViewArc1` | bool | 每面板"归档内平面视图"记忆 | RegistryUtils.cpp:40, 173-189; App.cpp:321, 398 |
| `Position` | BIN(20B) | 主窗 rect(l,t,r,b)+maximized | ViewSettings.cpp:23, 138-195; FM.cpp:849-875 |
| `Panels` | BIN(12B) | numPanels/currentPanel/splitterPos | ViewSettings.cpp:24, 156-194 |
| `Toolbars` | DWORD 掩码 | bit0=ShowButtonsText bit1=Large bit2=Standard bit3=Archive；bit31=默认 | ViewSettings.cpp:25, 213-226; App.h:250-275 |
| `ListMode` | DWORD | 两面板各 8bit 视图模式（3=Details 默认） | ViewSettings.cpp:29, 229-248 |
| `PanelPath0` / `PanelPath1` | SZ | 各面板最近路径（启动恢复） | ViewSettings.cpp:27, 250-272; App.cpp:127-133, 388-399 |
| `FolderHistory` | MULTI_SZ 风格 | 文件夹历史（≤100） | ViewSettings.cpp:30, 292-295 |
| `FolderShortcuts` | 同上 | 收藏夹 0-9 | ViewSettings.cpp:31, 297-300 |
| `CopyHistory` | 同上 | Copy/Move 目标历史（≤20） | ViewSettings.cpp:32, 302-305; App.cpp:754-757 |

### 5.3 `HKCU\Software\7-Zip\FM\Columns\<FolderTypeID>`（ViewSettings.cpp:21）

二进制：版本(4B)+SortID(4B)+Ascending(4B) + N×[PropID, IsVisible, Width]（ViewSettings.cpp:52-120）。

### 5.4 `HKCU\Software\7-Zip\Extraction|Compression|Options`（UI/Common/ZipRegistry.cpp，被 FM 直接读写）

| 键\值 | 含义 | 证据 |
|---|---|---|
| Extraction：`ExtractMode/OverwriteMode/ShowPassword/PathHistory/SplitDest/ElimDup/Security/MemLimit`（MemLimit 即 Settings 页 GB 上限，`NExtract::Read_LimitGB`） | 解压 GUI 选项 | ../Common/ZipRegistry.cpp:91-101; SettingsPage.cpp:229-242, 304-321 |
| Compression：`ArcHistory/ShowPassword/EncryptHeaders/Level/Dictionary/Order/BlockSize/NumThreads/…/Options\<format>` | 压缩对话框记忆 | ../Common/ZipRegistry.cpp:203-232 |
| Options：`WorkDirType/WorkDirPath/TempRemovableOnly` | 工作目录策略（Folders 页） | ../Common/ZipRegistry.cpp:490-536 |
| Options：`CascadedMenu/MenuIcons/ElimDupExtract/WriteZoneIdExtract/ContextMenu` | Explorer 菜单策略（Menu 页；FM 的解压/打开也读 `WriteZone`） | ../Common/ZipRegistry.cpp:540-560; PanelCopy.cpp:188-194; Panel.cpp:1031-1038 |

### 5.5 文件关联 `Software\Classes`（RegistryAssociations.cpp）

`.<ext>` 默认值 → `7-Zip.<ext>`；该 ProgID 下写 `DefaultIcon=<path>,<idx>`、`shell\open\command=<7zFM.exe "%1">`（GetProgramCommand，SystemPage.cpp:269-283）；删除时仅清理 7-Zip.* ProgID（RegistryAssociations.cpp:93-165）。

> 移植映射建议：5.1-5.3 → `NSUserDefaults`/plist 一对一映射；5.5 → macOS 为 LaunchServices/UTType 声明（Info.plist CFBundleDocumentTypes），语义完全不同，须重设计。

---

## 6. 文件操作语义

### 6.1 通用机制

- 所有可写操作走 `IFolderOperations`；操作前 `CheckBeforeUpdate` 逐层检查归档栈只读性（kpidReadOnly）并弹错（PanelMenu.cpp:851-917）。
- 长操作模式：`CProgressThreadVirt` 派生类在工作线程跑 `ProcessVirt()`，UI 线程跑 `CProgressDialog`（支持 Pause/Background/Cancel/错误列表/最终消息）（PanelOperations.cpp:38-96; ProgressDialog2.h/cpp）。
- 删除/重命名/新建期间挂起定时器与通知（`CDisableTimerProcessing`/`CDisableNotify`），完成后 `RefreshListCtrl(state)` 恢复选中与焦点（Panel.h:756-837; PanelItems.cpp:378-426）。

### 6.2 各操作

| 操作 | 语义细节 | 证据 |
|---|---|---|
| 删除 | FS 文件夹 + toRecycleBin → `SHFileOperationW(FO_DELETE|FOF_ALLOWUNDO)`（回收站）；路径≥MAX_PATH→报错或转内部删除；其余（含归档内）→确认框（单文件/单目录/N 项三种文案）→ `IFolderOperations::Delete`（归档内=重压缩更新） | PanelOperations.cpp:112-262 |
| 重命名 | F2→ListView 就地编辑；`OnEndLabelEdit`→`IFolderOperations::Rename`+线程进度；FS 名称合法化 `CorrectFsPath`（去尾点/空格）；".."与只读层禁止 | PanelOperations.cpp:264-359; BrowseDialog.h:22-28 |
| 新建文件夹/文件 | ComboDialog 输入名（默认 "New Folder"/"New File"）→ `CreateFolder/CreateFile`（folder 实现；归档内同样支持）→焦点定位新项 | PanelOperations.cpp:363-476 |
| 归档内复制/移动（F5/F6） | `CApp::OnCopy`：目标=另一面板或输入路径；CopyDialog 确认；4 条路径——①FS→FS：`CopyTo`（FSFolderCopy）②归档→FS：`CopyTo`=解压 ③FS→归档：`CopyFrom`=压缩（CThreadUpdate→`IFolderOperations::CopyFrom`）④归档→归档：经临时目录两段（useTemp，仅双面板允许）；"Cannot copy onto itself"防护；copyToSame（Shift+F5）=同目录复制改名 | App.cpp:565-856; PanelCopy.cpp:182-338, 375-450 |
| 在归档内打开/编辑并回写 | `OpenItemInArchive`：解压单项到 `%TEMP%\7zO…`（小文件先入内存 `CVirtFileSystem`，阈值=RAM>>max(层数+1,8)）→ 启动关联程序/编辑器 → 监视线程（进程快照追子进程+2s 心跳）等待退出或文件变更 → 文件变更且非只读 → 询问"update it in the archive?" → `IFolderOperations::CopyFromFile` 回写 → 删临时目录；嵌套归档返回上级时同样检测并提示回写（`OpenParentArchiveFolder`） | PanelItemOpen.cpp:1461-1780, 1110-1300, 598-626; Panel.h:147-170 |
| 打开（智能） | Enter：`kStartExtensions` 列表（exe/doc/pdf/txt/html/源码等）直接外部打开，否则先尝试按归档打开（失败再外部）；Shift+Enter 强制外部；外部打开前病毒名检测 | PanelItemOpen.cpp:629-668, 950-995, 1451-1459 |
| 剪贴板 | `EditCopy`=仅复制**名称文本**到剪贴板（CRLF 分隔）；`EditCut`/`EditPaste` 实际为空实现（注释掉 InvokeSystemCommand("cut"/"paste")）；ListViewDialog 内 Ctrl+C 复制行文本 | PanelMenu.cpp:427-472 |
| 拖拽（源） | `OnDrag`（LVN_BEGINDRAG/右键拖）：FS 源直接 HDROP 真实路径；归档源先建 `%TEMP%\7zE…` 并暴露**将解压出的目标名列表**（延迟解压：目标 GetData 时才解）；私有剪贴板格式 `7-Zip::SetTargetFolder/SetTransfer/GetTransfer` 让 7-Zip↔7-Zip 拖拽协商"由源直接 CopyTo 目标路径"绕过临时拷贝；`DoDragDrop(MOVE|COPY)`；结束后按 effect/Transfer 决定 moveMode 并 `CopyTo`；错误集合弹 MessagesDialog | PanelDrag.cpp:76-105, 1500-1786; EnumFormatEtc.cpp |
| 拖拽（目标） | `CDropTarget`（注册于主窗 FM.cpp:1023）：面板列表上高亮目标子文件夹（m_DropHighlighted）；目标为 FS 文件夹→发送 TargetFolder 给源（7-Zip 源自己写）或 `CopyFsItems`/`CopyFromNoAsk`；目标为归档→`CompressDropFiles`（压入归档=CopyFrom，或"新建归档"模式调 `CompressFiles` 弹压缩对话框）；右键拖出菜单（Copy/Move/AddToArc/Cancel，`Drag_OnContextMenu`）；`CFSTR_PERFORMEDDROPEFFECT` 防 Explorer 误删源 | PanelDrag.cpp:386-455, 1808-2030, 2505-2735, 2817-2900 |
| 跨进程压缩/解压 | 工具栏 Add/Extract/Test 与拖拽建档最终调 `CompressFiles/ExtractArchives/TestArchives/Benchmark`（UI/Common/CompressCall.cpp）——**以命令行方式启动 7zG.exe** 完成实际 GUI 压缩/解压 | Panel.cpp:922-958, 1008-1039, 1103-1177; ../Common/CompressCall.h:10-26 |

---

## 7. 内嵌工具

| 工具 | 入口 | 实现 | 证据 |
|---|---|---|---|
| 基准测试 | Tools→Benchmark（隐藏 Benchmark2=totalMode） | 暂停两面板定时器 → `::Benchmark(totalMode)`（CompressCall，启动 7zG b） | MyLoadMenu.cpp:798-803, 917-918 |
| 哈希计算 | File→CRC 子菜单/右键 | FS 路径：`CThreadCrc` 用 `CHashBundle`+`CDirItemsEnumerator` 本地多文件流式计算（支持 `Z7_EXTERNAL_CODECS` 全部哈希法，"*"=全部）；归档内：`CopyTo(streamMode+hashMethods)` 即"解压到哈希器"；结果 `ShowHashResults`（GUI/HashGUI） | PanelCrc.cpp:230-423; PanelCopy.cpp:255-268 |
| 分卷拆分 | File→Split | SplitDialog（目标+卷大小序列）→ 卷数≥100 二次确认 → `CThreadSplit` 顺序写 `name.001…`（预分配、进度） | PanelSplitFile.cpp:140-342 |
| 分卷合并 | File→Combine | 选第一卷 → 自动探测 `.001/.002…` 序列 → `CThreadCombine` 拼接 | PanelSplitFile.cpp:345-560; resource.rc:263-268 |
| 属性窗口 | Alt+Enter | 非归档：系统 Shell "properties" 动词；归档/项：ListViewDialog 两列展示 单项全部属性 + rawProps(十六进制) + 文件夹属性 + **逐层归档属性（含错误旗标解码）**；多选：数目/文件/目录/Size/PackSize 汇总 | PanelMenu.cpp:57-76, 172-423 |
| 归档注释 | Ctrl+Z | 读 `kpidComment` → ComboDialog 编辑 → `IFolderOperations::SetProperty(kpidComment)` | PanelOperations.cpp:487-533 |
| 链接创建 | File→Link... | Hard/SymFile/SymDir/Junction/WSL 五种（reparse data 直写） | LinkDialog.cpp:79-400 |
| Diff | File→Diff | 同面板选 2 个文件或双面板各 1 个 → 启动外部 Diff 程序 | PanelItemOpen.cpp:747-814 |
| 版本控制（7vc） | File→Ver * | 把文件复制进 `7vc` 目录带编号快照，Edit/Commit/Revert/Diff | VerCtrl.cpp; RegistryUtils.cpp:67 |
| 临时文件清理 | Tools→Delete Temporary Files... | BrowseDialog2 列出 temp 下 7-Zip 临时目录，可手动删 | BrowseDialog2.cpp:1846-1866 |
| 备用流浏览 | File→Alternate streams | `IFolderAltStreams::BindToAltStreams` 或 FS 路径加 `:` | PanelFolderChange.cpp:1082-1119 |

---

## 8. Win32 依赖分级矩阵（按文件/模块）

评级定义：
- **A 纯逻辑可复用**：不含 UI；仅依赖 MyWindows.h COM 模拟 + CPP/Windows 文件系统包装（mac 已验证编译路径）。
- **B 仅靠 Win32 包装类可替换**：逻辑骨架可保留，但依赖 `CPP/Windows/Control/*`、`CDialog/CWindow2`、资源 .rc、消息循环——在 mac 上需以 AppKit 重写 UI 壳，逻辑层可平移。
- **C 必须全部重写/重新设计**：语义本身绑定 Windows（Shell/OLE/注册表布局/NTFS）。

| 模块 | 文件 | 评级 | 说明 |
|---|---|---|---|
| IFolder 抽象 | IFolder.h | **A** | 纯接口宏，已具备非 Windows 形态 |
| 归档文件夹（Agent） | ../Agent/*（5.1k 行） | **A** | 7zz 已验证核心；UI 无关 |
| 打开归档管线 | FileFolderPluginOpen.cpp, OpenCallback.*, PluginLoader.h | **A-**（进度对话框接口处为 B） | 线程+回调逻辑可复用；`CProgressDialog` 引用需桥接 |
| 回调集 | ExtractCallback.*, UpdateCallback100.* | **A-/B** | COM 回调逻辑 A；内部弹 Overwrite/Password/Mem 对话框处 B |
| 文件夹实现 | RootFolder.cpp | **A-** | 已有非 Win 分支（仅 Computer→"/"） |
| | FSFolder.cpp | **A-/B** | 枚举/属性大多可移植（已有 ifdef）；图标/压缩大小等 Win 特有列需裁剪 |
| | FSFolderCopy.cpp | **C→重写** | 基于 CopyFileW/MoveFileW/进度钩子；mac 用 copyfile/FSEvents 重写（或复用 POSIX 实现） |
| | FSDrives.cpp / NetFolder.cpp / AltStreamsFolder.cpp | **C** | 盘符/WNet/NTFS 流，mac 语义重设计（卷列表可用 NSFileManager mountedVolumeURLs 重做） |
| 面板核心状态机 | Panel.h, PanelFolderChange.cpp, PanelSort.cpp, PanelSelect.cpp（逻辑部分）, PanelItems.cpp（列模型/索引集逻辑） | **B（高复用）** | 路径栈/排序比较器/选择集/列持久化均为纯逻辑，可提为"PanelModel"；ListView 调用点需换 NSTableView/NSOutlineView |
| 面板 UI 壳 | Panel.cpp（窗口创建/ReBar/StatusBar/Timer）、PanelListNotify.cpp（LVN_GETDISPINFO 绘制）、PanelKey.cpp（VK 键表） | **B/C** | 控件树、虚拟列表回调、键盘映射须按 AppKit 重写（键表语义可表驱动平移） |
| 菜单系统 | MyLoadMenu.cpp, resource.rc 菜单 | **B** | 命令 ID→动作映射表可全部平移为 NSMenu；动态 File/Favorites/时间戳子菜单逻辑可保留 |
| 打开/编辑/回写 | PanelItemOpen.cpp | **B/C** | 临时目录+变更检测+回写流程可保留；**进程监视（Toolhelp32 快照、OpenProcess、GetProcessImageFileName）必须重写**（mac 用 NSWorkspace/ kqueue/ NSFilePresenter 方案） |
| 操作线程 | PanelOperations.cpp, PanelCopy.cpp, PanelCrc.cpp, PanelSplitFile.cpp | **A-/B** | IFolderOperations 调用+线程模型可复用；回收站删除（SHFileOperationW）→ NSWorkspace recycle；进度对话框桥接 |
| 拖拽 | PanelDrag.cpp(3006 行), EnumFormatEtc.* | **C** | OLE IDataObject/IDropSource/IDropTarget + HDROP + 私有剪贴板格式，全部重写为 NSDraggingSource/Destination + NSFilePromiseProvider（延迟解压语义可映射 file promise） |
| 剪贴板 | PanelMenu.cpp:427-472 + ../../Windows/Clipboard | **B** | 仅文本名复制；NSPasteboard 即可 |
| 右键菜单 | PanelMenu.cpp（CreateSystemMenu/CreateShellContextMenu/InvokePluginCommand） | **C**（系统部分）/**B**（CZipContextMenu 部分） | IShellFolder/IContextMenu 无对应；CZipContextMenu 的命令集（Open/Extract/Compress…）可作为普通菜单逻辑平移（../Explorer/ContextMenu.cpp） |
| 属性窗口 | PanelMenu.cpp:172-423 | **B** | 全部数据来自 IFolder*，纯展示 |
| 对话框群 | §2 全部 | **B** | 逻辑薄；布局/控件重写 |
| 选项页 | SystemPage/MenuPage | **C** | 文件关联+Explorer 集成是 Windows 专属（mac→LaunchServices/Finder 扩展重新设计） |
| | FoldersPage/EditPage/SettingsPage/LangPage | **B** | 设置项语义可保留（LargePages 在 mac 无意义可裁剪） |
| 设置存取 | RegistryUtils.cpp, ViewSettings.cpp, ../Common/ZipRegistry.cpp | **B** | 全部经 `CPP/Windows/Registry.h CKey`——单点替换为 NSUserDefaults/plist 后语义不变；二进制 blob 格式可原样保留 |
| 文件关联 | RegistryAssociations.cpp, SystemPage.cpp, FilePlugins.cpp | **C** | Software\Classes 布局专属 |
| 图标 | SysIconUtils.cpp(351) | **C** | SHGetFileInfo/系统 ImageList → NSWorkspace iconForFile/UTType 重写；`CExtToIconMap` 缓存策略可保留 |
| 语言 | LangUtils.cpp, TextPairs.cpp, LangPage.cpp | **B** | 自有 .txt 词表加载逻辑可复用（或换 NSLocalizedString，建议保留以复用 90+ 语言资产） |
| 帮助 | HelpUtils.cpp | **C** | .chm/HtmlHelp → 网页帮助 |
| 进程启动 | ../../Windows/ProcessUtils + StartApplication*（PanelItemOpen.cpp:817-832, 697-744） | **C** | ShellExecute/CreateProcess → NSWorkspace openURL/NSTask |
| 主窗骨架 | FM.cpp, App.cpp/.h | **B** | 启动序列/状态保存/双面板编排逻辑平移到 NSApplicationDelegate+NSSplitView |
| 跨进程 GUI 调用 | ../Common/CompressCall.cpp（7zG 命令行） | **B/C 决策点** | mac 可改为进程内调用 GUI 模块或保留独立辅助进程 |
| 工具类 | FormatUtils, StringUtils, ProgramLocation, SplitUtils, TextPairs, ClassDefs, MyCom2.h, DialogSize.h | **A/B** | 几乎纯逻辑 |

---

## 9. 移植要点提炼（给后续设计/评审）

1. **解耦面已经存在**：UI(CPanel/CApp) ↔ IFolder*/IFolderOperations ↔ Agent/7z 内核。方案B 的桥接层应严格落在 IFolder 接口上（dylib 导出 Agent + LoadCodecs），AppKit 侧只重写 §2/§4 的"壳"。
2. **PanelModel 抽取**：`_folder/_parentFolders/_selectedStatusVector/_columns/_sortID/_flatMode` + BindToPath/排序比较器/索引集合方法构成无 UI 状态机（Panel.h:319-978），可几乎原样编入 dylib。
3. **三大必重写子系统**：拖拽（OLE→NSDragging+FilePromise）、系统右键菜单/Shell 集成（无对应）、图标/文件关联（LaunchServices）。
4. **7zG 依赖**：7zFM 的压缩/解压 GUI、基准测试均为**外部进程调用**（CompressCall）；mac 上需要决定等价物（进程内窗口 or 辅助进程），这是架构评审必答题。
5. **临时文件+回写"在归档内编辑"**是体验关键路径，进程监视部分（PanelItemOpen.cpp:1110-1300）需要 macOS 原生方案（NSRunningApplication/KVO + 文件变更 dispatch source）。
6. 设置项总量有限且已列全（§5），NSUserDefaults 映射可一对一；列配置 blob、工具栏掩码、ListMode 等格式可直接保留以便将来互换。

## 10. 已确认的"Windows-only 可裁剪"清单（mac 1:1 移植时建议明确砍掉/替换）

| 功能 | 理由 | 证据 |
|---|---|---|
| NetFolder（网络邻居）、`\\.\` 设备卷、`\\?\` 超级路径视图 | WNet/NT 路径语义 | NetFolder.cpp; Panel.h:714-722 |
| AltStreamsFolder 与 `IDM_ALT_STREAMS` | NTFS ADS | AltStreamsFolder.cpp; PanelFolderChange.cpp:1082-1119 |
| Zone.Identifier 传播（WriteZone/ZoneBuf） | Mark-of-the-Web，mac 对应 com.apple.quarantine（语义需重新设计） | PanelCopy.cpp:156-198; MenuPage2.rc |
| Large memory pages 设置 | Windows 特权 API | SettingsPage.cpp:291-302 |
| 回收站删除（SHFileOperation） | → NSWorkspace recycleURLs | PanelOperations.cpp:122-217 |
| Explorer 上下文菜单 DLL 注册（MenuPage 的 7-zip.dll/7-zip32.dll） | → Finder Sync/Action 扩展另行设计 | MenuPage.cpp:132-181 |
| Junction/WSL 链接类型 | mac 仅 hardlink/symlink | LinkDialog.rc:30-40 |
| .chm 帮助 | → 在线帮助 | HelpUtils.cpp:38-77 |
