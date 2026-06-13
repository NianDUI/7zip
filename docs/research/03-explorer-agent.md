# 03 — Shell 集成与 Agent 层报告（UI/Explorer + UI/Agent + IFolder 接口族）

> 盘点对象：`CPP/7zip/UI/Explorer`（12 文件 / 约 2.8k 行）、`CPP/7zip/UI/Agent`（12 文件 / 约 8.7k 行，含头文件），
> 以及 `CPP/7zip/UI/FileManager/IFolder.h`、`PluginInterface.h`、`CPP/7zip/UI/Common/IFileExtractCallback.h` 等接口定义。
> 版本基线：26.01（commit 8c63d71）。所有结论均以 `文件:行号` 标注证据。
> 用途：macOS 移植（方案B：核心 dylib + ObjC++ 桥接 + AppKit）的设计与评审底料。

---

## 0. 文件清单与职责总览

### 0.1 UI/Explorer（Windows Shell 扩展，产物 7-zip.dll / 7-zip32.dll / 7-zip64.dll）

| 文件 | 行数 | 职责 | macOS 移植定性 |
|---|---|---|---|
| ContextMenu.h / .cpp | 173 / 1837 | `CZipContextMenu`：右键菜单核心，同时实现旧协议 `IContextMenu`+`IShellExtInit` 与 Win11 新协议 `IExplorerCommand`+`IEnumExplorerCommand`（ContextMenu.h:28-40） | 业务规则可抽取复用；UI/COM 壳需按 FinderSync/AppKit 重写 |
| ContextMenuFlags.h | 27 | 菜单项开关位掩码 `NContextMenuFlags`（kExtract=1<<0 … kCRC=1<<31）（ContextMenuFlags.h:8-24） | 纯常量，直接复用 |
| DllExportsExplorer.cpp | 268 | DLL 入口：`DllGetClassObject`/`DllCanUnloadNow`/`DllRegisterServer`/`DllUnregisterServer` + `CShellExtClassFactory`；CLSID `{23170F69-40C1-278A-1000-000100020000}`（DllExportsExplorer.cpp:47-53,176-198） | 不移植（COM 注册无对应物） |
| RegistryContextMenu.h / .cpp | 13 / 225 | 写/删 HKCR shellex 注册键（含 WOW64 双视图），供 FM 设置页调用（RegistryContextMenu.cpp:157-223） | 不移植；FinderSync 由 Info.plist 声明 |
| MyExplorerCommand.h | 217 | 为旧 SDK/MinGW 手工声明 `IShellItem/IShellItemArray/IExplorerCommand`（MyExplorerCommand.h:26-56） | 不需要 |
| MyMessages.h / .cpp | 16 / 43 | `ShowErrorMessage` = `MessageBoxW` 包装，受 `g_DisableUserQuestions` 控制（MyMessages.cpp:16-20） | NSAlert 替代 |
| Explorer.def | 9 | 导出 4 个 COM 标准入口（Explorer.def:5-9） | 不需要 |
| makefile | 76 | nmake 构建；额外链接 ZipRegistry/CompressCall/ArchiveName/LangUtils 等（makefile:57-69） | 参考依赖闭包 |
| resource.h / resource.rc / resource2.rc | 15/10/19 | 菜单字符串（IDS_CONTEXT_* 2320-2330、IDS_SELECT_FILES 3015）与菜单位图 IDB_MENU_LOGO=190（resource.h:1-15, resource2.rc） | 字符串迁移到 .strings |
| 7-zip.dll.manifest / MenuLogo.bmp / StdAfx.* | - | 清单/位图/PCH | 不需要 |

### 0.2 UI/Agent（归档"文件夹化"适配层，纯逻辑 + COM 模拟接口）

| 文件 | 行数 | 职责 |
|---|---|---|
| Agent.h | 358 | `CAgentFolder`（实现 14 个 IFolder* 接口）、`CAgent`（IInFolderArchive/IOutFolderArchive/IFolderArcProps/ISetProperties）、`CArchiveFolderManager`（IFolderManager）、`CCodecIcons`、全局 `g_CodecsObj`/`LoadGlobalCodecs()`（Agent.h:19-21,51-98,168-184,340-354） |
| Agent.cpp | 1968 | CAgentFolder 浏览/属性/比较/提取实现；CAgent::Open/ReOpen/Close/ReadItems/BindToRootFolder/Extract/GetArcProp*；LoadGlobalCodecs（Agent.cpp:71-104,1603-1786） |
| AgentProxy.h / .cpp | 162 / 752 | `CProxyArc`（经典路径切分树）与 `CProxyArc2`（tree-mode，NTFS 类）两套目录代理模型 |
| AgentOut.cpp | 718 | CAgent 的更新面：SetFolder/SetFiles/DoOperation(2)/DeleteItems/CreateFolder/RenameItem/CommentItem/UpdateOneFile/SetProperties/CommonUpdate |
| ArchiveFolder.cpp | 57 | CAgentFolder::CopyTo（提取到磁盘）+ SetZoneIdMode/SetZoneIdFile（ArchiveFolder.cpp:19-57） |
| ArchiveFolderOpen.cpp | 231 | `CArchiveFolderManager`：OpenFolderFile/GetExtensions/GetIconPath + 图标表加载（Win 资源） |
| ArchiveFolderOut.cpp | 456 | `CAgentFolder::CommonUpdateOperation`：归档内增删改的统一事务流程 + IFolderOperations 的写方法 |
| IFolderArchive.h | 123 | IArchiveFolder/IInFolderArchive/IOutFolderArchive/IFolderArchiveUpdateCallback(2)/IFolderScanProgress/IFolderSetZoneId*/..._MoveArc 接口定义 |
| UpdateCallbackAgent.h / .cpp | 22 / 208 | `CUpdateCallbackAgent`：把引擎层 `IUpdateCallbackUI` 事件转发给 GUI 层 `IFolderArchiveUpdateCallback(2)` |
| StdAfx.h | 11 | 仅 include Common.h，无 Win 头（StdAfx.h:1-11） |

构建系统已具备 POSIX 规则：`CPP/7zip/7zip_gcc.mak:933-945` 为全部 7 个 Agent .cpp 定义了 `$O/*.o` 编译规则（与 7zz 共用同一 mak 框架）；Windows 侧由 `UI/FileManager/FM.mak:94-100` 链入 7zFM.exe。**GUI 目录（7zG）不使用 Agent**（grep 无引用）；使用者只有 FileManager 与 FAR 插件（Far/Far.cpp:294, Far/PluginWrite.cpp:639）。

---

## 1. Explorer：右键菜单、拖放、设置页、文件关联

### 1.1 双协议结构

`CZipContextMenu` 同时是（ContextMenu.h:28-40）：
- 旧协议（Win7/10 经典右键 & 7zFM 内部）：`IShellExtInit::Initialize` + `IContextMenu::{QueryContextMenu, InvokeCommand, GetCommandString}`；
- 新协议（Win11 顶层菜单）：`IExplorerCommand::{GetTitle, GetIcon, GetState, Invoke, GetFlags, EnumSubCommands}` + `IEnumExplorerCommand::{Next, Skip, Reset, Clone}`（ContextMenu.cpp:1631-1837）。新协议复用旧协议：`LoadItems()` 以 `hMenu=NULL` 调 `QueryContextMenu` 仅填 `_commandMap`，再把每个表项包装为子 `CZipContextMenu` 节点挂进 `SubCommands` 树（ContextMenu.cpp:1565-1628）。

线程安全引用计数 `Z7_COM_UNKNOWN_IMP_4_MT`；DLL 生存期由 `g_DllRefCount` 控制（ContextMenu.cpp:176,184; DllExportsExplorer.cpp:164-174）。

### 1.2 命令全集

内部命令枚举 `enum_CommandInternalID` 共 24 项（ContextMenu.h:74-101）。

**主命令表 `g_Commands`（ContextMenu.cpp:271-284），Verb 前缀 `"SevenZip"`（ContextMenu.cpp:256）：**

| 内部 ID | Verb | 资源串 | InvokeCommandCommon 动作（ContextMenu.cpp:1256-1396） |
|---|---|---|---|
| kOpen | SevenZipOpen | IDS_CONTEXT_OPEN | 启动 `7zFM.exe "<file>" [-t<type>]`（ContextMenu.cpp:1264-1274,1187-1190） |
| kExtract | SevenZipExtract | IDS_CONTEXT_EXTRACT | `ExtractArchives(showDialog=true)`（ContextMenu.cpp:1276-1291） |
| kExtractHere | SevenZipExtractHere | IDS_CONTEXT_EXTRACT_HERE | `ExtractArchives(showDialog=false)` |
| kExtractTo | SevenZipExtractTo | IDS_CONTEXT_EXTRACT_TO | `ExtractArchives(elimDup=设置)`，目标 `<base>/<子目录>/` |
| kTest | SevenZipTest | IDS_CONTEXT_TEST | `TestArchives(_fileNames)`（ContextMenu.cpp:1292-1295） |
| kCompress | SevenZipCompress | IDS_CONTEXT_COMPRESS | `CompressFiles(showDialog=true)`（ContextMenu.cpp:1297-1339） |
| kCompressEmail | SevenZipCompressEmail | IDS_CONTEXT_COMPRESS_EMAIL | 同上 email=true（`EMAIL_SUPPORT` 宏，ContextMenu.cpp:47-49） |
| kCompressTo7z | SevenZipCompressTo7z | IDS_CONTEXT_COMPRESS_TO | 直接压缩为 `<name>.7z`，无对话框 |
| kCompressTo7zEmail | SevenZipCompressTo7zEmail | IDS_CONTEXT_COMPRESS_TO_EMAIL | 同上 + email |
| kCompressToZip | SevenZipCompressToZip | IDS_CONTEXT_COMPRESS_TO | 压缩为 `<name>.zip` |
| kCompressToZipEmail | SevenZipCompressToZipEmail | IDS_CONTEXT_COMPRESS_TO_EMAIL | 同上 + email |

**CRC/哈希子菜单 `g_HashCommands`（ContextMenu.cpp:294-309），Verb 前缀 `"SevenZip.Checksum"`+`.Calc/.Generate/.Test`+`.<Method>`（ContextMenu.cpp:1080-1130）：**

| 内部 ID | 菜单文本 | 方法名 | 动作 |
|---|---|---|---|
| kHash_CRC32/CRC64/XXH64/MD5/SHA1/SHA256/SHA384/SHA512/SHA3_256/BLAKE2SP | "CRC-32" 等 | 同名 | `CalcChecksum(paths, method)`（ContextMenu.cpp:1356-1384） |
| kHash_All | `*` | `*` | 全部哈希 |
| kHash_Generate_SHA256 | "SHA-256 -> file.sha256"（前有分隔符，ContextMenu.cpp:1085-1093） | SHA256 | 生成 `<arcname>.sha256` 文件（CalcChecksum + generateName） |
| kHash_TestArc | "Checksum : Test" | Hash | `TestArchives(paths, hashMode=true)`（ContextMenu.cpp:1361-1364） |

**"Open >" 打开方式子菜单**：仅当选中单个文件且非目录时显示，`kOpenTypes = { "", "*", "#", "#:e", "7z", "zip", "cab", "rar" }`（ContextMenu.cpp:523-534,741-790），Verb 为 `SevenZip.Open.<type>`，子菜单根 Verb `"SevenZip.OpenWithType."`（ContextMenu.cpp:257）。

### 1.3 QueryContextMenu 菜单构建规则（ContextMenu.cpp:585-1176）

1. `_fileNames` 为空直接返回 0（:605-609）；flags 含 CMF_DEFAULTONLY 等时不构建（:616-619）。
2. 读取设置 `CContextMenuInfo ci; ci.Load()`（来自注册表 `HKCU\Software\7-Zip\Options` 等，UI/Common/ZipRegistry.h:190-211）：`Cascaded`（级联进 "7-Zip" 子菜单）、`MenuIcons`（LoadBitmap IDB_MENU_LOGO，:639-646）、`ElimDup`、`WriteZone`、`Flags` 位掩码逐项开关（:632-637,677）。
3. **Explorer 16 项截断协议**：Explorer 对 >16 选中项只传前 16 项，invoke 时重建全量对象；needReduce 时档名显示为 `<base>_` 提示名字未定（:137-162,713-727,888-904）；invoke 阶段如 `_fileNames_WereReduced` 则用全量重算档名（:1304-1323）。
4. **Extract 系列显示条件**：选中含目录则不显示；扩展名命中 `kExtractExcludeExtensions` 白名单（约 120 个常见非归档后缀，:494-516）则不显示；按住 Shift（CMF_EXTENDEDVERBS）跳过该启发式（:794-825）。
5. 解压目标子目录名 `GetSubFolderNameForExtract`：去掉末级扩展名，特判 `*.7z.001`/`*.part01.rar` 之类多卷（:447-470）。
6. 压缩档名由 `CreateArchiveName`（UI/Common/ArchiveName.cpp）按选中集合生成；菜单文本做 64 字符省略与 `&` 转义（:472-487）。
7. CRC 菜单可挂在顶层或 7-Zip 级联菜单内（kCRC vs kCRC_Cascaded，:1030-1068）。
8. 自检：`_commandMap.Size()` 必须等于发出的命令数，否则 throw（:1149-1154）；返回值为命令个数（:1174）。

### 1.4 InvokeCommand 解析

- Unicode verb（CMINVOKECOMMANDINFOEX + CMIC_MASK_UNICODE）→ `FindVerb`；整数 offset（IS_INTRESOURCE）→ 直接下标（ContextMenu.cpp:1209-1250）。
- `GetCommandString` 把 Verb 同时当 HelpString 返回（:1420-1465）。
- 实际执行全部走 `InvokeCommandCommon(cmi)`，再分派到 `UI/Common/CompressCall.cpp`：**以子进程方式启动 `7zG.exe`**（k7zGui，CompressCall.cpp:34,74-98），文件清单通过**命名 FileMapping `7zMap########` + 命名 Event `7zEvent########` 共享内存 IPC** 传递（CompressCall.cpp:121-184）；Open 命令则启动 `7zFM.exe`（ContextMenu.cpp:1187-1190,1273）。错误经 `MessageBoxW(g_HWND,…)`（CompressCall.cpp:58-61）。

### 1.5 拖放处理

- 注册两类 shellex：`ContextMenuHandlers`（`*`、`Folder`、`Directory`）与 **`DragDropHandlers`**（`Directory`、`Drive`）——见开关矩阵 `k_shellex_Statuses`（RegistryContextMenu.cpp:28-48,204-220）。
- 右键拖放时 Explorer 以**目标文件夹 pidl** 调 `IShellExtInit::Initialize(pidlFolder,…)`：`NShell::GetPathFromIDList` 取出路径 → 去 `\\?\` 前缀、规范化 → `_dropMode=true, _dropPath=目标`（ContextMenu.cpp:201-231）。
- 拖放模式下：Extract 目标 = `_dropPath`（:830-832），Compress 输出目录 = `_dropPath`（:919-923,946-949），Email 系列被禁（`!_dropMode` 条件，:931,960,993）。
- 选中项文件名与属性经 `NShell::DataObject_GetData_HDROP_or_IDLIST_Names` / `DataObject_GetData_FILE_ATTRS` 从 IDataObject 提取（ContextMenu.cpp:236-243; Windows/Shell.h:89-116）。
- 注意：7zFM 面板自身的拖放（`CDropTarget`/IDropTarget, FileManager/PanelDrag.cpp、App.h:84）属 FileManager 报告范围，不在本目录。

### 1.6 注册与反注册（两条路径）

| 路径 | 代码 | 写入内容 |
|---|---|---|
| regsvr32 自注册 | DllExportsExplorer.cpp:201-268 | `HKCR\CLSID\{...}\InprocServer32`（ThreadingModel=Apartment）+ `HKLM\...\Shell Extensions\Approved` |
| 7zFM 设置页 "集成到右键菜单" | RegistryContextMenu.cpp:157-223（被 MenuPage.cpp:310 调用） | 同上 + 4 类 shellex 键；`wow` 参数（KEY_WOW64_32/64KEY）同时管理 32/64 位注册表视图，动态加载 `RegDeleteKeyExW`（RegistryContextMenu.cpp:53-92） |

设置页 `CMenuPage`（FileManager/MenuPage.cpp）管理：两个 DLL 复选框（`7-zip.dll` + 异位宽的 `7-zip32.dll`/`7-zip64.dll`，MenuPage.cpp:132-181）、级联/图标/ElimDup 复选框、WriteZone（MOTW ZoneId）下拉（:189-229）、以及与 `NContextMenuFlags` 一一对应的菜单项勾选 ListView `kMenuItems[]`（:49-71,237-280）；Apply 时写回 `CContextMenuInfo::Save()` 并调 `SetContextMenuHandler`（:299-334）。

### 1.7 文件关联注册

在 FileManager（设置页 SystemPage）而非 Explorer 目录：`NRegistryAssoc::AddShellExtensionInfo / DeleteShellExtensionInfo`（FileManager/RegistryAssociations.cpp:93-165）写 `Software\Classes\.<ext>` → ProgID `7-Zip.<ext>`，含 `DefaultIcon`（`<iconPath>,<index>`）与 `shell\open\command`；SystemPage.cpp:307-311 按用户勾选逐扩展名调用（HKCU/HKLM 双目标）。图标路径/索引来源是 `IFolderManager::GetIconPath`（见 §2.8）。

### 1.8 7zFM 进程内复用同一菜单类

7zFM 文件菜单/右键菜单**不经 COM 注册**，直接 `new CZipContextMenu`，手工填 `_fileNames`（绕过 IShellExtInit），调 `Init_For_7zFM()`、`_attribs.FirstDirIndex`，再 `QueryContextMenu(menu, 0, kSevenZipStartMenuID, …, CMF_EXPLORE)`（FileManager/PanelMenu.cpp:803-826）。这证明**菜单业务逻辑与 Shell 宿主是解耦的**——macOS 方案B 可同样在 app 内复用命令决策层。

### 1.9 macOS 映射提示（盘点性结论）

- 命令枚举/Verb/启发式（§1.2-1.3 的表、kExtractExcludeExtensions、GetSubFolderNameForExtract、ReduceString、16 项协议除外）是纯逻辑，可整体抽为"命令模型"复用。
- IContextMenu/IExplorerCommand → FinderSync 扩展（`FIFinderSyncController` + `menuForMenuKind`）或 App 内 NSMenu；注册表开关 → NSUserDefaults/App Group。
- CompressCall 的"7zG 子进程 + FileMapping IPC" → 方案B 中可退化为进程内直接调用 GUI 控制器；若保留 FinderSync 扩展进程，则需 XPC/NSXPCConnection 替代共享内存。

---

## 2. Agent 层：接口族、文件夹模型与更新路径

### 2.1 接口 GUID 体系

所有接口经 `Z7_DECL_IFACE_7ZIP_SUB(i, base, groupId, subId)` 声明，IID = `{23170F69-40C1-278A-0000-00gg00ss0000}`（IDecl.h:9-27）。三个分组：

- **group 0x01（FOLDERARC）**：宏定义于 UI/Common/IFileExtractCallback.h:15-20；
- **group 0x08（FOLDER）**：宏定义于 FileManager/IFolder.h:11-16；
- **group 0x09**：IFolderManager（IFolder.h:165-166）。

### 2.2 IFolder.h 接口族（group 8，浏览侧；FileManager/IFolder.h）

| 接口 (subId) | 方法 | 职责 / CAgentFolder 是否实现 |
|---|---|---|
| IFolderFolder (0x00) | LoadItems / GetNumberOfItems / GetProperty / BindToFolder(index)/(name) / BindToParentFolder / GetNumberOfProperties / GetPropertyInfo / GetFolderProperty（IFolder.h:29-40） | 核心导航接口。是 |
| IFolderAltStreams (0x17) | BindToAltStreams(index/name) / AreAltStreamsSupported（:47-52） | NTFS 备用流文件夹。是 |
| IFolderWasChanged (0x04) | WasChanged（:54-56） | 否（FS 文件夹用） |
| IFolderOperationsExtractCallback (0x0B, 基类 IProgress) | AskWrite / ShowMessage / SetCurrentFilePath / SetNumFiles（:60-73） | 由 FM 的 ExtractCallback 实现 |
| **IFolderOperations (0x13)** | CreateFolder / CreateFile / Rename / Delete / CopyTo / CopyFrom / SetProperty / CopyFromFile（:76-89） | 读写文件夹统一接口。是（写操作走 §2.6） |
| IFolderGetSystemIconIndex (0x07) | GetSystemIconIndex（:98-100） | 否（FS 文件夹用，Win shell 图标） |
| IFolderGetItemFullSize (0x08) / IFolderCalcItemFullSize (0x14) | 目录尺寸计算（:102-108） | 否 |
| IFolderClone (0x09) / IFolderSetFlatMode (0x0A) | Clone / SetFlatMode（:110-116） | SetFlatMode 是（Agent.cpp:1370-1374） |
| IFolderProperties (0x0E) | GetNumberOfFolderProperties / GetFolderPropertyInfo（:124-128） | 是（kFolderProps：Size/PackSize/NumSubDirs/NumSubFiles/CRC，Agent.cpp:1220-1300） |
| IFolderArcProps (0x10) / IGetFolderArcProps (0x11) | 多层归档属性（:130-143） | CAgent 实现前者，CAgentFolder 实现后者（Agent.cpp:1362-1367,1858-1968） |
| IFolderCompare (0x15) | CompareItems（:145-147） | 是（排序加速，Agent.cpp:688-836） |
| IFolderGetItemName (0x16) | GetItemName / GetItemPrefix / GetItemSize（:149-154） | 是（零拷贝名字指针，Agent.cpp:443-498） |
| **IFolderManager (group 9, subId 5)** | OpenFolderFile / GetExtensions / GetIconPath（:157-166） | CArchiveFolderManager 实现 |

`PluginInterface.h` 整体已被注释禁用（PluginInterface.h:6-31），IInitContextMenu/IPluginOptions 机制在 26.x 已废弃。

### 2.3 IFolderArchive.h 接口族（group 1，归档侧；UI/Agent/IFolderArchive.h）

| 接口 (subId) | 方法 | 实现者 → 使用者 |
|---|---|---|
| IArchiveFolder (0x0D) | Extract(indices, …, pathMode, overwriteMode, path, testMode, callback)（IFolderArchive.h:26-35） | CAgentFolder → FM PanelCopy（测试/提取）、FAR（头部注释 :17-24） |
| IInFolderArchive (0x0E) | Open / ReOpen / Close / GetNumberOfProperties / GetPropertyInfo / BindToRootFolder / Extract（:43-54） | CAgent → FAR 插件、CArchiveFolderManager |
| IFolderArchiveUpdateCallback (0x0B, IProgress) | CompressOperation / DeleteOperation / OperationResult / UpdateErrorMessage / SetNumFiles（:56-63） | FM 进度对话框 → Agent 更新路径 |
| IOutFolderArchive (0x0F) | SetFolder / SetFiles / DeleteItems / DoOperation / DoOperation2（:65-82） | CAgent → CAgentFolder::CommonUpdateOperation、FAR PluginWrite |
| IFolderArchiveUpdateCallback2 (0x10) | OpenFileError / ReadingFileError / ReportExtractResult / ReportUpdateOperation（:85-91） | 细粒度错误上报 |
| IFolderScanProgress (0x11) | ScanError / ScanProgress（:94-98） | 磁盘枚举进度 |
| IFolderSetZoneIdMode (0x12) / IFolderSetZoneIdFile (0x13) | MOTW ZoneId 透传（:101-109） | Win 专属语义（mac 对应 quarantine xattr，需重设计） |
| IFolderArchiveUpdateCallback_MoveArc (0x14) | MoveArc_Start / MoveArc_Progress / MoveArc_Finish / Before_ArcReopen（:112-120） | 更新后回写原档案的进度/中断协议 |
| （内部）IArchiveFolderInternal (0x0C) | GetAgentFolder（Agent.h:27-29） | CAgent::SetFolder 取回具体 CAgentFolder（AgentOut.cpp:32-42） |
| （相关，group 1）IFolderArchiveExtractCallback (0x07) / 2 (0x08) | AskOverwrite / PrepareOperation / MessageError / SetOperationResult（IFileExtractCallback.h:54-68） | FM ExtractCallback 实现；CopyTo 时被 QI 出来传入 Extract（ArchiveFolder.cpp:39-43） |

### 2.4 AgentProxy：把 IInArchive 适配成树

**两套模型，按 handler 能力选择**（Agent.cpp:1734-1772 `CAgent::ReadItems`：`useProxy2 = arc.GetRawProps && arc.IsTree`）：

- **CProxyArc（经典）**：`Dirs[0]` 为根；`Load()` 遍历 `GetNumberOfItems`，对每项取 `kpidPath`（优先 `IArchiveGetRawProps::GetRawProp(kpidPath)` 零拷贝 UTF-16 指针，仅 `MY_CPU_LE && _WIN32`，AgentProxy.cpp:274-295；否则 PROPVARIANT BSTR），按 `/`（及平台分隔符）切层 `AddDir`，目录层级上限 1<<10（:332-359）；文件挂 `SubFiles`，目录项挂 `SubDirs` 且记录 `ArcIndex`（IsLeaf）（:374-398）；最后 `CalculateSizes` 递归聚合 Size/PackSize/CRC/子计数（:188-234）。`CProxyDir{Name,ArcIndex,ParentDir,SubDirs,SubFiles,Size,PackSize,Crc,…}`（AgentProxy.h:20-42）。
- **CProxyArc2（tree-mode，如 NTFS）**：要求 `GetRawProps`（AgentProxy.cpp:584-585）；`Dirs[0]`=根、`Dirs[1]`=根的 altstream 目录（:601-610）；每项取 `kpidName`（裸指针/UTF-8/BSTR 三分支，:631-665）+ `GetParent`（:667-670）+ IsDir/IsAltStream，第二遍按 Parent 关系把 item 挂到对应 dir，altstream 懒建 AltDirIndex（:696-730）。`CProxyFile2{DirIndex,AltDirIndex,Parent,Name,IsAltStream,Ignore}`（AgentProxy.h:72-98）。
- **索引语义**：UI 的 `index` 是"当前文件夹内序号"（proxy 模型序），`realIndex/ArcIndex` 是 IInArchive 条目号。换算函数 `GetRealIndex / GetRealIndices / AddRealIndices`（AgentProxy.cpp:134-174; Agent.cpp:1377-1454）；目录选择会递归展开全部子项后 `HeapSort`（AgentProxy.cpp:173; Agent.cpp:1453）。

**CAgentFolder 浏览语义**：每个文件夹是轻量对象 `{_proxy/_proxy2, _proxyDirIndex, _agent}`（Agent.h:120-134）；`BindToFolder/BindToParentFolder/BindToAltStreams` 都只是换 `_proxyDirIndex` new 一个 CAgentFolder（Agent.cpp:839-1096）；FlatMode 时 `LoadItems` 递归铺平 `_items`（Agent.cpp:112-165）；`GetProperty` 对目录项提供聚合 Size/PackSize/CRC，其余转发 `GetArchive()->GetProperty(arcIndex,…)`（Agent.cpp:316-430）；属性表把归档的 `kpidPath` 替换为 `kpidName` 并按需补 kpidPrefix/kpidNumSubDirs/kpidNumSubFiles（Agent.cpp:1147-1218）。

### 2.5 打开与提取路径

```
7zFM CPanel::OpenAsArc (FileManager/PanelItemOpen.cpp:456-501)
 └─ CFfpOpen::OpenFileFolderPlugin (FileManager/FileFolderPluginOpen.cpp:295-351, 后台线程 + 进度对话框)
     └─ new CArchiveFolderManager (FileFolderPluginOpen.cpp:300)   ← 插件 DLL 枚举已废弃 (RegistryPlugins.cpp 全注释)
         └─ IFolderManager::OpenFolderFile (Agent/ArchiveFolderOpen.cpp:92-119)
             ├─ new CAgent; IInFolderArchive::Open (Agent.cpp:1603-1686)
             │    ├─ LoadGlobalCodecs (Agent.cpp:71-104)        ← 格式发现，见 §2.7
             │    ├─ ParseOpenTypes(arcFormat)                   ← "-t" 类型限定
             │    └─ _archiveLink.Open(COpenOptions)             ← UI/Common/OpenArchive
             └─ BindToRootFolder → CAgent::ReadItems → CProxyArc(2)::Load → CAgentFolder(root) (Agent.cpp:1774-1787)
```
开档失败但有 NonOpen_ErrorInfo 时仍返回 folder 以展示错误属性（ArchiveFolderOpen.cpp:107-115）。Panel 随后 `QueryInterface(IFolderOperations)` 存入 `_folderOperations`（FileManager/Panel.h:460）。

**提取**：`CPanel::CopyTo` → `IFolderOperations::CopyTo`（ArchiveFolder.cpp:32-57：flat 模式映射 pathMode，QI 出 IFolderArchiveExtractCallback）→ `CAgentFolder::Extract`（Agent.cpp:1456-1567）：构造引擎级 `CArchiveExtractCallback`，传 pathParts（当前文件夹前缀）、ZoneId 模式（`#if defined(_WIN32)` 读取 `:Zone.Identifier`，Agent.cpp:1515-1522）、realIndices，最终 `GetArchive()->Extract(realIndices,…)`。整档提取走 `CAgent::Extract`（Agent.cpp:1789-1838）。

### 2.6 归档内增删改（Update）调用路径 —— 核心事务流程

所有写操作收敛到 **`CAgentFolder::CommonUpdateOperation`**（ArchiveFolderOut.cpp:92-373）：

| IFolderOperations 入口 | AGENT_OP（Agent.h:41-49） | CAgent 方法 | CUpdatePair2 构造要点 |
|---|---|---|---|
| CopyFrom(moveMode, fromFolder, items…)（ArchiveFolderOut.cpp:376-390） | AGENT_OP_Uni + k_ActionSet_Add | DoOperation2 → DoOperation（AgentOut.cpp:197-423） | 磁盘枚举 `CDirItems::EnumerateItems2` + 归档枚举 `EnumerateArchiveItems(2)` → `GetUpdatePairInfoList` + `UpdateProduce`（AgentOut.cpp:291-313） |
| Delete(indices)（:401-407） | AGENT_OP_Delete | DeleteItems（AgentOut.cpp:435-478） | 命中项跳过（即删除）+ 回调 DeleteOperation，其余 `SetAs_NoChangeArcItem` |
| CreateFolder(name)（:409-429，重名预检） | AGENT_OP_CreateFolder | CreateFolder（AgentOut.cpp:480-532） | 全保留 + 追加 1 个 `FILE_ATTRIBUTE_DIRECTORY` 的 CDirItem，时间取 `GetCurUtcFileTime`（AgentOut.cpp:510-521） |
| Rename(index,newName)（:431-437） | AGENT_OP_Rename | RenameItem（AgentOut.cpp:535-601） | 命中前缀的所有子项 `NewProps=true` + NewNames 重写路径前缀；名字斜杠规范化（AgentOut.cpp:560-563） |
| SetProperty(kpidComment)（:444-456，仅 zip） | AGENT_OP_Comment | CommentItem（AgentOut.cpp:604-647） | 主项 NewProps + `updateCallback->Comment` |
| CopyFromFile(destIndex, path)（:392-399，FM"在归档内编辑保存"用） | AGENT_OP_CopyFromFile | UpdateOneFile（AgentOut.cpp:651-706） | 单项 NewData+NewProps，`KeepOriginalItemNames=true` |
| CreateFile | — | E_NOTIMPL（ArchiveFolderOut.cpp:439-442） | |

**事务骨架**（ArchiveFolderOut.cpp:110-359）：
1. `SetFolder(this)` 经 IArchiveFolderInternal 把更新前缀定位到当前文件夹（AgentOut.cpp:23-49）；保存 pathParts 以便重开后恢复位置。
2. `CWorkDirTempFile::CreateTempFile(原档路径)`：临时文件目录由 `NWorkDir::CInfo`（ZipRegistry 设置）决定（UI/Common/WorkDir.cpp:14-75）。
3. SFX/前缀数据（`ArcStreamOffset != 0`）先原样拷贝，再用 `CTailOutStream` 偏移写（ArchiveFolderOut.cpp:127-144）。
4. 分派上表 CAgent 方法 → 统一 `CommonUpdate` → `QueryInterface(IID_IOutArchive)` → **`IOutArchive::UpdateItems(tailStream, n, CArchiveUpdateCallback)`**（AgentOut.cpp:425-433）——与命令行 Update 共用引擎回调 `CArchiveUpdateCallback`，UI 事件经 `CUpdateCallbackAgent`(IUpdateCallbackUI→IFolderArchiveUpdateCallback/2 转发，UpdateCallbackAgent.cpp:13-208) 上抛。
5. `KeepModeForNextOpen(); _agent->Close()` → `tempFile.MoveToOriginal(deleteOriginal=true)` 回写原位，若回调支持 `IFolderArchiveUpdateCallback_MoveArc` 则带进度且 E_ABORT 被刻意延迟（ArchiveFolderOut.cpp:192-233）。
6. moveMode（"移到压缩包"）成功后删除源文件 `DeleteFileAlways` + 递归删空目录（:238-252,30-63）。
7. `_agent->ReOpen()`（重新 Load proxy，Agent.cpp:1689-1718）→ `BindToRootFolder` → 按保存的 pathParts 走 `FindSubDir/FindItem` 恢复 `_proxyDirIndex`（:271-313）。
8. 失败兜底：UString 异常转 `UpdateErrorMessage`（:362-372）。

**可更新性判定**：`CAgent::CanUpdate()`——空 agent（FAR 新建档）可、设备文件不可、多层嵌套（Arcs.Size()!=1）不可、有尾部垃圾不可（Agent.cpp:1589-1601）；外加 `IsThere_ReadOnlyArc`（格式 UpdateEnabled=CreateOutArchive 非空，Agent.h:256-267; LoadCodecs.cpp:829）与文件只读属性（Agent.h:251-254）→ FM 端 `CheckBeforeUpdate` 弹错（PanelMenu.cpp:880-899）。

### 2.7 格式发现：LoadCodecs 的两种模式与单 dylib 退化

`LoadGlobalCodecs()`（Agent.cpp:71-104）创建全局 `CCodecs g_CodecsObj` 并 `Load()`，外加 `Codecs_AddHashArcHandler`（哈希文件伪格式）。`CCodecs::Load()`（UI/Common/LoadCodecs.cpp:790-875）：

| 模式 | 触发 | 行为 | 证据 |
|---|---|---|---|
| **静态注册（7zz/Alone2 现状）** | 未定义 `Z7_EXTERNAL_CODECS` | 各格式 .o 的静态对象构造期调 `RegisterArc` 填 `g_Arcs[]`（上限 72），Load 时逐个转成 `CArcInfoEx`（含 CreateInArchive/CreateOutArchive/签名/扩展名） | LoadCodecs.cpp:112-124,807-845 |
| **外部 DLL 枚举（Windows 7zFM/7zG + 7z.dll）** | 定义 `Z7_EXTERNAL_CODECS`（如 Bundles/Format7zF/makefile:5） | 基准目录 = 模块目录，否则注册表 `HKCU/HKLM\Software\7-Zip\Path(32/64)`（LoadCodecs.cpp:6-20,202-210）；加载 **kMainDll：`_WIN32` 为 "7z.dll"，否则 "7z.so"**（:72-77），再扫 `Codecs/`、`Formats/` 子目录（:849-858）；DLL 经 GetProcAddress 取 CreateObject/GetHandlerProperty2 等导出（:565+） | LoadCodecs.cpp:790-875 |

**macOS 退化结论**：
- 最简：FM app 直接静态链接全部格式（同 7zz），`g_CodecsObj->Load()` 零改动可用——格式集 = Alone2 已验证集合。
- 方案B 单 dylib：把 Format7zF（全格式 bundle，Windows 上即 7z.dll）以 `-DZ7_EXTERNAL_CODECS` 构建为 `7z.so`/`.dylib`，宿主仅需保证可执行文件同目录存在该库（kMainDll 非 Windows 分支已存在，LoadCodecs.cpp:76）；注册表查找路径分支天然走不进（`#ifdef _WIN32`，:80-107）。需验证 `Windows/DLL.cpp` 的 dlopen 封装在 mac 的 `.so` 后缀约定（7zip_gcc.mak SHARED_EXT=.so，已验证事实）。
- **图标/扩展名注册的资源依赖**：`CArchiveFolderManager::LoadFormats` 从每个 codec DLL 与自身 `g_hInstance` 读字符串资源 ID=100 的"ext:iconIndex ..."表（ArchiveFolderOpen.cpp:13-80），`GetIconPath` 返回 DLL 路径+图标索引（:175-206）供 FM 图标与文件关联用——**这是 Agent 目录里唯一实质 Win 资源依赖**，mac 需以静态表/AssetCatalog 替代。

### 2.8 7zFM 使用 Agent 的全部入口（汇总）

| 入口 | 文件:行 | 用途 |
|---|---|---|
| `new CArchiveFolderManager` + OpenFolderFile | FileManager/FileFolderPluginOpen.cpp:300,47 | 打开归档为 IFolderFolder（后台线程） |
| `new CArchiveFolderManager` + GetExtensions/GetIconPath | FileManager/FilePlugins.cpp:29-76 | 扩展名→图标数据库（CExtDatabase::Read，供文件关联设置页/图标） |
| IFolderOperations（QI 自 folder） | FileManager/Panel.h:460; PanelOperations.cpp:47 | 删除/重命名/新建文件夹/属性 |
| IArchiveFolder::Extract（QI） | IFolderArchive.h:17-24 注释; PanelCopy.cpp:122 | 提取/测试 |
| IGetFolderArcProps | FileFolderPluginOpen.cpp:111-117 | 错误/属性展示 |
| FAR 插件 | Far/Far.cpp:294; Far/PluginWrite.cpp:639 | 同一接口族的第二个消费者（佐证接口稳定性） |

插件机制现状：`RegistryPlugins.cpp` 的 DLL 插件枚举（GetPluginProperty 导出协议）**整体被注释**（RegistryPlugins.cpp:5-80），`PluginInterface.h` 同样全注释——26.x 的 FM 只有内置 CArchiveFolderManager 一个"插件"，**移植无需实现插件发现**。

---

## 3. POSIX 可编译性逐文件评估（重点回答）

背景事实：MyWindows.h 已提供 IUnknown/HRESULT/PROPVARIANT/BSTR 模拟且随 7zz 在 mac 链接通过；Windows/{FileDir,FileName,FileFind,FileIO,TimeUtils,ErrorMsg,PropVariant,PropVariantConv,Synchronization,DLL}.cpp 均有 POSIX 分支并已进 Alone2 构建（如 ErrorMsg POSIX 分支 Windows/ErrorMsg.cpp:54；GetCurUtcFileTime POSIX 实现 Windows/TimeUtils.cpp:320-345；Alone2/makefile:19 含 ErrorMsg.obj）。

### 3.1 UI/Agent —— **结论：7/7 个 .cpp 均可在 POSIX 下编译复用，仅 1.5 处需要动手**

| 文件 | include 的 Windows/* 头 | 调用的 Win32 概念 | 平台分支现状 | 替换难度 |
|---|---|---|---|---|
| Agent.cpp | FileDir/FileName/PropVariantConv/Synchronization（Agent.cpp:11-17） | `GetLastError_noZero_HRESULT`（:1620，已跨平台）；ZoneId 读取已 `#if defined(_WIN32)`（:1515-1522）；`#ifndef Z7_ST` 临界区（:46-51） | 良好 | **低**。唯一杂质：`#include "../FileManager/RegistryUtils.h"`（:20）只被注释代码 `Read_ShowDeleted()`（:1640-1649）引用，删 include 即可 |
| AgentProxy.cpp | PropVariant/PropVariantConv（AgentProxy.cpp:18-19） | 无；零拷贝名字优化已限定 `MY_CPU_LE && _WIN32`（:274），POSIX 自动走 BSTR 慢路径 | 良好 | **极低**（纯算法） |
| AgentOut.cpp | FileDir/FileName/TimeUtils（AgentOut.cpp:7-9） | FILETIME（MyWindows 模拟）+ GetCurUtcFileTime（POSIX 已实现）；FILE_ATTRIBUTE_DIRECTORY 常量 | 良好 | **极低** |
| ArchiveFolder.cpp | 无 Windows 头（ArchiveFolder.cpp:1-9） | 无 | — | **零** |
| ArchiveFolderOut.cpp | FileDir（ArchiveFolderOut.cpp:7） | RemoveDir/SetFileAttrib/DeleteFileAlways（POSIX 已有）；**间接依赖 WorkDir.cpp → NWorkDir::CInfo::Load() → ZipRegistry 注册表**（WorkDir.cpp:61-66; ZipRegistry.cpp:10-29） | WorkDir.cpp 自身仅 1 处 `_WIN32` guard（WorkDir.cpp:18-37） | **中**：必须为 ZipRegistry 提供 mac 设置后端（见风险#1），或让 CWorkDirTempFile 默认"同目录临时文件"短路设置读取 |
| ArchiveFolderOpen.cpp | DLL/ResourceString（ArchiveFolderOpen.cpp:8-9） | `extern HINSTANCE g_hInstance` + `MyLoadString(HMODULE, 100)` 读 RC 字符串表 + `Lib.Get_HMODULE()`（:13-20,75,78） | 无 POSIX 分支 | **中**：图标/扩展表机制整体重写（静态表或 plist）；`OpenFolderFile/GetExtensions` 逻辑本身无 Win 依赖 |
| UpdateCallbackAgent.cpp | ErrorMsg（UpdateCallbackAgent.cpp:7） | `HRESULT_FROM_WIN32` + MyFormatMessage（均有 POSIX 路径） | 良好 | **极低** |
| Agent.h / AgentProxy.h / IFolderArchive.h / UpdateCallbackAgent.h | PropVariant（Agent.h:8） | `DWORD _attrib` / `INVALID_FILE_ATTRIBUTES` / `HMODULE`（仅 CCodecIcons，Agent.h:231,253,335） | — | **低**（CCodecIcons 可整段裁剪/重写） |

佐证：`7zip_gcc.mak:933-945` 已为全部 Agent 源文件提供 gcc/clang 规则（该 mak 即 mac 7zz 所用框架），只是当前无任何 POSIX bundle 把它们加入 OBJS——把 7 个 .o 加进新 target 即可开编。预期编译阻力集中在 ArchiveFolderOpen.cpp（g_hInstance/MyLoadString）与链接期 ZipRegistry 符号。

### 3.2 UI/Explorer —— 结论：**Shell 壳不可移植，业务规则层可平移**

| 文件 | Win32 依赖点（include + API） | 替换难度 |
|---|---|---|
| ContextMenu.cpp | Windows/{COM,DLL,FileDir,FileName,Menu,ProcessUtils,Window}.h（:9-17）；HMENU/CMenu/CMenuItem/InsertItem、HBITMAP/LoadBitmap/DeleteObject（:165-185,639-646）、InterlockedIncrement、IS_INTRESOURCE、CoTaskMemAlloc/Free（:1471-1533）、IShellItemArray/IDataObject/NShell（:201-243,1535-1562）、`CContextMenuInfo::Load()`→注册表、CompressCall→CreateProcess+FileMapping | **高**（宿主协议整体换成 FinderSync/NSMenu）；但 §1.2-1.3 的命令表、verb 体系、扩展名启发式、档名生成为纯逻辑，**建议原样抽出复用** |
| DllExportsExplorer.cpp | OleCtl/ShlGuid 头、DllMain、IClassFactory、NRegistry 写 CLSID（:9-37,201-268） | 不移植 |
| RegistryContextMenu.cpp | Registry.h、RegDeleteKeyExW 动态加载、WOW64（:7,53-97） | 不移植 |
| MyMessages.cpp | MessageBoxW（:19） | 极低（NSAlert） |
| MyExplorerCommand.h | shobjidl 接口声明 | 不需要 |
| ContextMenuFlags.h | 无 | 零 |
| 关联设置页（FileManager/MenuPage.cpp、SystemPage.cpp、RegistryAssociations.cpp） | Win 对话框 + 注册表（RegistryAssociations.cpp:9,20-27） | 文件关联 → mac UTType/LSSetDefaultRoleHandlerForContentType 体系，全新实现 |

### 3.3 Agent 所依赖的 UI/Common 模块可移植性补充

| 依赖 | 状态 |
|---|---|
| OpenArchive / ArchiveExtractCallback / UpdateCallback / UpdatePair / UpdateProduce / EnumDirItems / FileStreams / LimitedStreams / CopyCoder / WorkDir(逻辑部分) | 已随 7zz 在 mac 编译通过（已验证事实） |
| **ZipRegistry.cpp** | **未进** 7zz 构建（Alone2/makefile 无该 obj），实现为 `HKEY_CURRENT_USER\Software\7-Zip\*` 读写（ZipRegistry.cpp:11,23-29）——FM/Explorer/WorkDir/ContextMenuInfo 的设置存储，mac 必须重写后端（保留结构体接口 `NExtract::CInfo/NCompression::CInfo/NWorkDir::CInfo/CContextMenuInfo`，ZipRegistry.h:190-211） |
| **CompressCall.cpp** | 未进 7zz；依赖 FileMapping/MemoryLock/ProcessUtils/RegistryUtils（CompressCall.cpp:12-20）。方案B 进程内调用可绕开 |
| FileManager/RegistryUtils.cpp、RegistryAssociations.cpp | Registry.h 依赖（RegistryUtils.cpp:7），需 mac 后端 |

---

## 4. 关键调用链速查（供起草人引用）

```text
[打开]   Panel::OpenAsArc → CFfpOpen::OpenFileFolderPlugin → CArchiveFolderManager::OpenFolderFile
        → CAgent::Open(LoadGlobalCodecs → CCodecs::Load[静态 g_Arcs | 外部 7z.so]) → CArchiveLink::Open
        → CAgent::BindToRootFolder → ReadItems → CProxyArc(2)::Load → CAgentFolder(root)

[导航]   CAgentFolder::BindToFolder(index|name) → BindToFolder_Internal(new CAgentFolder{proxyDirIndex})

[提取]   Panel::CopyTo → IFolderOperations::CopyTo → CAgentFolder::Extract
        → CArchiveExtractCallback::Init(pathParts, zone, …) → IInArchive::Extract(realIndices)

[更新]   IFolderOperations::{Delete|Rename|CreateFolder|SetProperty|CopyFrom|CopyFromFile}
        → CAgentFolder::CommonUpdateOperation(op)
        → CWorkDirTempFile + (SFX 头拷贝/CTailOutStream)
        → CAgent::{DeleteItems|RenameItem|CreateFolder|CommentItem|UpdateOneFile|DoOperation2}
        → CommonUpdate → IOutArchive::UpdateItems(CArchiveUpdateCallback ← CUpdateCallbackAgent ← IFolderArchiveUpdateCallback)
        → Close → MoveToOriginal(MoveArc 进度协议) → ReOpen → 按 pathParts 恢复当前文件夹

[Shell] Explorer 右键 → DllGetClassObject → CZipContextMenu::Initialize(IDataObject→_fileNames)
        → QueryContextMenu(读 CContextMenuInfo) → InvokeCommand → CompressCall: 7zG.exe + 7zMap IPC / 7zFM.exe
[FM 内] PanelMenu::CreateSevenZipMenu → new CZipContextMenu（进程内，无 COM 注册）
```

---

## 5. 移植风险清单（按影响排序）

1. **设置存储后端缺失（阻塞级）**：ZipRegistry.cpp 全部基于 Win 注册表且未在 mac 编译过；Agent 更新路径（WorkDir）、Explorer 菜单配置（CContextMenuInfo）、FM 大量选项都挂在它上面。必须先做 NSUserDefaults/plist 适配层并保持 `CInfo` 结构体 API 不变（ZipRegistry.cpp:23-29; WorkDir.cpp:63-66）。
2. **Finder 集成模型差异（架构级）**：IContextMenu/IShellExtInit/IExplorerCommand 与 FinderSync 在生命周期、沙箱、菜单粒度上完全不同；Windows 侧"右键 → 7zG 子进程 + FileMapping/Event IPC"（CompressCall.cpp:121-184）在 mac 沙箱扩展里不可用，需改为 XPC/打开主 App 的 URL scheme，16 项截断协议等 Explorer 特化逻辑应剥离。
3. **图标/资源机制**：CCodecIcons 读 PE 字符串资源 ID=100 与 DLL 图标索引（ArchiveFolderOpen.cpp:14-20,188-191），FM 图标、文件关联 DefaultIcon 都依赖它；mac 需以静态表 + UTType/AssetCatalog 重建，涉及 FilePlugins/SystemPage 联动。
4. **ZoneId/MOTW 语义**（IFolderSetZoneIdMode/SetZoneIdFile、WriteZone 设置、`ReadZoneFile_Of_BaseFile` 的 `:Zone.Identifier` ADS）是 Windows 专属；mac 对应 `com.apple.quarantine` xattr，行为需重新设计而非直译（Agent.cpp:1515-1522; IFolderArchive.h:101-109）。
5. **归档内更新的临时文件→回写流程**对文件系统语义敏感：`MoveToOriginal(deleteOriginal)`（WorkDir.cpp:77-84）在 APFS/沙箱/TCC 下需验证跨卷移动、权限继承与 quarantine 传播；中断协议（MoveArc_* 延迟 E_ABORT，ArchiveFolderOut.cpp:192-233）必须在 UI 桥接中保真，否则可能损档。
6. **COM 模拟跨 dylib ABI**：CAgentFolder 多继承 14 个接口（Agent.h:51-66），若核心走 dylib 边界传接口指针，必须全程同一 clang/同一 C++ 运行时，禁止跨界异常（代码内 throw int 常见，如 ContextMenu.cpp:326,392; AgentProxy.cpp:184），建议 dylib 边界仍走 C 风格 CreateObject 工厂。
7. **全局可变状态**：`g_CodecsObj`/`g_ExternalCodecs`/`g_CodecsRef` + 临界区（Agent.cpp:26-51）、`g_hInstance/g_HWND/g_DllRefCount`（DllExportsExplorer.cpp:57-67）——多窗口/多线程 AppKit 下需要明确初始化顺序与生存期管理。
8. **wchar_t 宽度差异**：mac 上 wchar_t 为 4 字节，AgentProxy 的 UTF-16 裸指针优化自动关闭（AgentProxy.cpp:274）只损性能；但所有名字内存由 proxy 持有裸指针（CProxyFile::Name，AgentProxy.h:8-16），UI 层（NSString 转换）必须遵守 LoadItems/ReOpen 后指针失效的隐含约定（ArchiveFolderOut.cpp:261-276 重建 proxy）。
9. **Email 命令族**依赖 MAPI（7zG 端实现），mac 需 NSSharingService 重做或首版裁剪（ContextMenu.cpp:929-1004 共 3 项）。
10. **格式发现退化选择**：静态链接最稳（已验证）；若坚持 Z7_EXTERNAL_CODECS 单 dylib，需补 mac 端模块路径发现（现仅"可执行文件目录"一条路，注册表分支不可用，LoadCodecs.cpp:80-107,849-858）并验证 `.so` 后缀/`dlopen` 封装。
11. **更新功能矩阵不完整带来的 UX 预期**：CreateFile 不支持（E_NOTIMPL）、CopyTo 的 moveMode 不支持（ArchiveFolder.cpp:36-37）、注释仅 zip、多层嵌套归档/带尾部数据归档只读（Agent.cpp:1589-1601）——评审 UI 时需如实呈现禁用态，避免按 Finder 习惯过度承诺。
