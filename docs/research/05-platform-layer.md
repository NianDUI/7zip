# 05 平台层盘点：CPP/Windows + CPP/Common（7-Zip 26.01 → macOS 移植）

> 盘点人：平台层解构员；日期：2026-06-13；基线：仓库 main @ 8c63d71 (26.01)。
> 适用技术路线：方案 B —— 核心编成 dylib（Format7zF → 7z.so/dylib）+ Objective-C++ 桥接 + AppKit 原生 GUI。
> 所有结论均出自真实源码，证据格式为 `文件路径:行号`（路径相对仓库根 /Users/lyd/WorkSpace/MyProjects/7zip）。

---

## 0. 总览

| 范围 | 文件数/行数 | 结论 |
|---|---|---|
| CPP/Windows 全目录 | 18,239 行（`wc -l` 实测，含 Control/） | 分为三档：A=有 POSIX 分支且已随 7zz mac 构建验证（约 8.6k 行）；B=仅 Win32、GUI 移植必须替换（约 6.9k 行，20+ 文件）；C=仅 Win32 但 mac 上不需要/可整体砍掉（Net、Console、NtCheck、CommandBar 等） |
| CPP/Common | 70 文件 | 除 `Lang.cpp`/`MyWindows.cpp` 等全部已在 7zz mac 构建中验证；是字符串/COM 模拟/编码的可移植底座 |
| 关键边界 | — | **引擎（Format7zF dylib）完全不依赖 B/C 档文件**；B 档全部位于 UI 层（FileManager/GUI/Explorer），其中控件包装类在 AppKit 重写中自然消失，真正需要"桥接实现"的只有 Registry、Clipboard、Shell 文件操作、进程调用、目录监视等少数几类 |

构建系统旁证：

- 非 Windows 分支以 `-shared -fPIC` 产出 `.so`：`CPP/7zip/7zip_gcc.mak:106-107`（`SHARED_EXT=.so`）；Windows 分支 `.dll` 在 `:103-104`。
- 全格式动态库 bundle：`CPP/7zip/Bundles/Format7zF/makefile.gcc:1-2`（`PROG = 7z`，`DEF_FILE = ../../Archive/Archive2.def`）。
- Alone2(7zz) 在非 MinGW 平台仅额外链接 COM 模拟层：`CPP/7zip/Bundles/Alone2/makefile.gcc:37-38`（`SYS_OBJS = $O/MyWindows.o`）；Windows 才链接 `FileSystem/Registry/MemoryLock/DLL/DllSecur`（同文件 :27-33）。

---

## 1. 基线：已证实可移植的平台层（随 7zz mac arm64 构建链接）

链接证据（哪些 .o 进入 7zz）：

- `CPP/7zip/Bundles/Format7zF/Arc_gcc.mak:69-78`：`WIN_OBJS = FileDir.o FileFind.o FileIO.o FileName.o PropVariant.o PropVariantConv.o PropVariantUtils.o System.o TimeUtils.o`
- `CPP/7zip/Bundles/Format7zF/Arc_gcc.mak:35`：`Synchronization.o`（MT_OBJS）
- `CPP/7zip/Bundles/Alone2/makefile.gcc:89-92`：`WIN_OBJS_2 = ErrorMsg.o FileLink.o SystemInfo.o`
- `CPP/7zip/Bundles/Alone2/makefile.gcc:37-38`：`MyWindows.o`
- `CPP/7zip/Bundles/Format7zF/Arc_gcc.mak:42-67`：`COMMON_OBJS`（MyString/StringConvert/UTFConvert/Wildcard/IntToString/MyVector/MyXml/NewHandler/各 hash 注册等）

### 1.1 CPP/Windows 可移植文件逐个说明（POSIX 实现方式）

| 文件 | 行数 | POSIX 实现（源内 `#ifndef _WIN32` 分支） | 关键证据 |
|---|---|---|---|
| FileIO.cpp/.h | 954+467 | `CFileBase` 持 `int _handle`；`::open()` + flags（FileIO.cpp:647）、`::lseek`（:716）、`O_RDONLY` 打开（:743）、`O_CREAT|O_EXCL` 语义（:826）、`ftruncate` 截断（:902）、`::read`/`::write` 分片循环（:781-790, :868-890）。类分界 `#else // _WIN32` 在 FileIO.h:339，POSIX 版 `CFileBase/CInFile/COutFile` 在 FileIO.h:351-462 | FileIO.h:351-354（`int _handle`） |
| FileFind.cpp/.h | 1458+347 | `MY_lstat()` 封装 `lstat/stat`（FileFind.cpp:1040-1054）；目录枚举 `opendir/readdir`（:1345, :1353）；`CFileInfo` POSIX 字段为 `dev/ino/mode/nlink/uid/gid/rdev`（FileFind.h:90-98 段，实测 :92 `mode_t mode`）；`SetFrom_stat`（FileFind.cpp:1129）；POSIX `CDirEntry{ino_t,d_type,Name}` + `CEnumerator(DIR*)`（FileFind.h:284-302）；stdin 探测 `fstat(0,&st)`（FileFind.cpp:175-177） | 全部如左 |
| FileDir.cpp/.h | 1362+172 | `mkdir(path,0777)`（FileDir.cpp:1120,1125）、`rmdir`（:1034）、`rename`（:1092，跨设备失败后手工复制+`chmod`+`unlink` :1107-1109）、`chdir/getcwd`（:1136,1148）、时间戳 `utimensat(AT_FDCWD,…)` 纳秒精度（:1229）、权限恢复 `fchmodat/chmod`+umask（:1338,1345，符号链接跳过 chmod :1315-1316）、硬链接 `link()`（:1352-1355 `MyCreateHardLink`）、临时目录回退 `/tmp`（:861-864） | 全部如左 |
| FileName.cpp/.h | 911+142 | 分隔符归一化按 `CHAR_PATH_SEPARATOR`；超长路径前缀 `\\?\` 逻辑整体 `#if defined(_WIN32)` 排除（FileName.cpp:105-120, :150-184）；`IsAbsolutePath` POSIX 即判首字符 `/`（:282-292 段） | FileName.cpp:5-9（POSIX include） |
| FileLink.cpp | 697 | POSIX 段 :630-695：`GetReparseData`=`readlink()`（:643）、`SetSymLink`=`symlink(to,from)`（:676-684）、`SetSymLink_UString` 先 `ConvertUnicodeToUTF8`（:686-691）。Windows 重解析点/Junction 代码整体在 `#if defined(_WIN32)` 内（:135-627） | 如左 |
| PropVariant.cpp/.h | 393+173 | 不含任何 Win32 API；完全建立在 MyWindows.h 的 PROPVARIANT/BSTR 模拟之上（`SysAllocStringLen` 分配，PropVariant.cpp:12-37）。`_WIN32` 出现次数为 0（grep 实测） | PropVariant.cpp:1-40 |
| PropVariantConv.cpp | 274 | 纯算术：FILETIME(100ns)↔字符串/UInt64 转换，无系统调用 | grep `_WIN32` = 0 |
| PropVariantUtils.cpp | 161 | 纯逻辑（flags/枚举转字符串） | grep `_WIN32` = 0 |
| System.cpp/.h | 423+209 | CPU 数 `sysconf(_SC_NPROCESSORS_CONF)`（System.cpp:197）；物理内存 `sysctl(HW_MEMSIZE)` macOS 专用分支（:311-323，32 位回退 :333） | 如左 |
| SystemInfo.cpp | 1308 | macOS 用 `sysctlbyname`：CPU 名 `machdep.cpu.brand_string`（:631）、核数 `machdep.cpu.core_count/thread_count`（:725-730）、页大小 `hw.pagesize`/`sysconf(_SC_PAGESIZE)`（:788-797） | 含 `#include <sys/sysctl.h>`（:20） |
| TimeUtils.cpp/.h | 467+154 | FILETIME 模拟值与 Unix 时间互转（`kUnixTimeOffset` TimeUtils.cpp:22，:160-220）；当前时间 `timespec_get`/`clock_gettime(CLOCK_REALTIME)`/`gettimeofday` 三级选择（:261-310, :323-340） | 如左 |
| ErrorMsg.cpp | 133 | POSIX 分支用 `strerror()`，并先映射 7-Zip 自定义错误码（:80-89）；Windows 分支 `FormatMessage`（:30-54 段） | 如左 |
| Synchronization.cpp/.h | 87+386 | POSIX 用 `pthread_mutex_t + pthread_cond_t` 实现 Event/Semaphore/CriticalSection（Synchronization.h:202-230 起）；`WaitForMultiObj`（WFMO）模拟在 Synchronization.cpp（整文件 `#ifndef _WIN32`，:5） | 如左 |
| Thread.h | 46 | 包一层 `C/Threads.h`；POSIX 下 `pthread_create`（C/Threads.c:494）；`Resume/Suspend/SetPriority` 等仅 `#ifdef _WIN32`（Thread.h:30-41） | 如左 |
| DLL.cpp/.h | 178+103 | **双分支均存在**：POSIX 段 :113-176 用 `dlopen(RTLD_LOCAL|RTLD_NOW)`（:162）、`dlsym`（:123）、`dlclose`（:134)。注意：`GetModuleDirPrefix()` 只在 Win32 段定义（DLL.cpp:95-107）；POSIX 版定义在 `CPP/7zip/UI/Common/ArchiveCommandLine.cpp:1875-1900`，靠 `Set_ModuleDirPrefix_From_ProgArg0(argv[0])` 注入（:1880-1886） | 如左；7zz Alone2 虽未链 DLL.o，但 7zG/FM 动态加载 7z.dylib 时此分支即为现成方案 |
| Console.cpp | 10 | 实际为空壳（仅 Windows 控制台 ctrl 处理在 UI/Console 内），GUI 移植无关 | wc 实测 10 行 |

> 说明：`FileSystem.cpp / Registry.cpp / MemoryLock.cpp / Clipboard.cpp …` 等不在上表者均**未**进入 mac 7zz 链接（Alone2 makefile.gcc:27-33 仅 MinGW 链接），归入第 2 节。

### 1.2 CPP/Common 可移植底座（重点文件）

| 文件 | 作用 | POSIX 关键点 | 证据 |
|---|---|---|---|
| MyWindows.h/.cpp | 非 Windows 平台 COM 模拟：`HRESULT/BSTR/VARIANT_BOOL/FILETIME/PROPVARIANT/IUnknown` | `BSTR` 为带长度前缀的 `malloc` 块（MyWindows.cpp:15,49-67）；`VariantClear/SysAllocString*` EXTERN_C（MyWindows.h:256-268）；`CompareFileTime`（:275）；FileTime↔本地时间转换（:307-310）；IUnknown 虚析构兼容性说明（:149-157） | 如左 |
| MyString.h/.cpp | `AString`(char)/`UString`(wchar_t)/`FString`(文件系统字符串) | POSIX 下 **不定义** `USE_UNICODE_FSTRING`（MyString.h:961-963 仅 `_WIN32` 定义），故 `FString = AString`（UTF-8 字节串，MyString.h:1027-1029）；`fs2us/us2fs` 经 `GetCurrentCodePage()` 走 MultiByte↔Unicode（MyString.cpp:1763-1777）；`Z7_WCHART_IS_16BIT` 仅当 wchar_t 为 16 位才定义（MyString.h:1063-1069）→ macOS wchar_t=32 位，UString 实为 UTF-32 | 如左 |
| StringConvert.cpp | 多字节↔宽字符 | POSIX 强制 UTF-8：`bool g_ForceToUTF8 = true`（:260），CP_UTF8 或强制时直接 `ConvertUTF8ToUnicode`（:262-271），否则 `mbstowcs/wcstombs`（:278, :383）；启动时 `setlocale(LC_ALL,…)` + `IsNativeUTF8()` 检测（:554-575, :690-745） | 如左 |
| UTFConvert.cpp/.h | UTF-8↔UTF-16/32 | 32 位 wchar_t 下可携带超 BMP 码点与 UTF-16↔UTF-32 互转（UTFConvert.h:255-256；UTFConvert.cpp:39-44, :323） | 如左 |
| Wildcard.cpp | 路径通配/大小写策略 | `g_CaseSensitive`：`_WIN32`=false、`__APPLE__`(桌面)=false、其它 POSIX=true（:8-20） | 如左 |
| Lang.cpp + UI/FileManager/LangUtils.cpp | 7-Zip 自带语言文件体系 | 读 `<模块目录>/Lang/*.txt`（LangUtils.cpp:33-35），与注册表只有 `Lang` 一个值耦合 → **mac 可整套保留** | 如左 |

---

## 2. 仅 Win32 部分：分类盘点与 macOS 替代物

> 判定依据：文件无 `#ifndef _WIN32` 功能分支（grep `_WIN32` 计数与通读确认），且不在 mac 7zz 链接清单。

### 2.1 Control/*（通用控件包装，~1,980 行）—— AppKit 重写时整体消失

| 文件（行数） | 包装的 Win32 实体 | 关键 API | macOS 替代 |
|---|---|---|---|
| Control/Dialog.cpp/.h (446+213) | 对话框 `DialogBoxParam/CreateDialogParam`，`CDialog::GetItem/SetItemText/OnInit/OnButtonClicked` 虚函数框架（Dialog.h:15-70） | GetDlgItem/EnableWindow/SetDlgItemText | NSWindowController/NSViewController + IBOutlet；模态用 `-[NSApplication runModalForWindow:]` 或 sheet |
| Control/Window2.cpp/.h (202+53) | 自绘窗口类注册 + WndProc 分发 | RegisterClass/DefWindowProc | NSView 子类/NSWindowDelegate（事件由 responder chain 取代） |
| Control/ListView.cpp/.h (162+156) | SysListView32（报表/虚拟列表） | LVM_* 宏、LVITEM | NSTableView（view-based, `dataSource` 即虚拟模式）；多列排序用 `sortDescriptors` |
| Control/PropertyPage.cpp/.h (165+50) | PropertySheet 多页设置 | PROPSHEETPAGE/PropertySheet | NSTabViewController 或 macOS 风格 Preferences 工具栏窗口 |
| Control/ComboBox.cpp/.h (75+79) | ComboBox/ComboBoxEx | CB_* 宏 | NSComboBox / NSPopUpButton |
| Control/Edit.h (19) | Edit 控件 | EM_* | NSTextField/NSTextView |
| Control/Static.h (28) | Static 文本/图标 | STM_* | NSTextField(label)/NSImageView |
| Control/ProgressBar.h (35) | msctls_progress32 | PBM_* | NSProgressIndicator |
| Control/StatusBar.h (42) | msctls_statusbar32 | SB_* | 自绘底部 NSView（AppKit 无原生 StatusBar） |
| Control/ToolBar.h (43) / ReBar.h (34) | ToolbarWindow32/ReBarWindow32 | TB_*/RB_* | NSToolbar |
| Control/ImageList.cpp/.h (10+87) | ImageList_* | HIMAGELIST | NSImage 数组 / NSTableCellView.imageView |
| Control/Trackbar.h (27) | Trackbar | TBM_* | NSSlider |
| Control/CommandBar.h (52) | **WinCE 专用**（`#ifdef UNDER_CE`） | — | 无需移植 |

### 2.2 其余仅 Win32 文件（按职责分类）

| 类别 | 文件（行数） | 现职责（证据） | macOS 替代物建议 |
|---|---|---|---|
| 窗口基类 | Window.cpp/.h (179+363) | `CWindow` 包 HWND：CreateWindowEx/SetText/GetText、GWLP_USERDATA 槽（Window.h:60-110） | NSWindow/NSView；userdata 槽改 ivar |
| 消息泵 | ProcessMessages.cpp (22) | `PeekMessage→TranslateMessage→DispatchMessage` 手动泵（:9-20），供长操作中保活 UI | 不需要：NSRunLoop + 后台线程/GCD；长操作必须移出主线程 |
| 菜单 | Menu.cpp/.h (265+170) | `CMenu` 包 HMENU：GetItemCount/InsertItem/TrackPopupMenu（Menu.h:45-130） | NSMenu/NSMenuItem；上下文菜单 `-[NSMenu popUpMenuPositioningItem:…]`；FM 主菜单→Main Menu nib |
| 注册表 | Registry.cpp/.h (474+96) | `CKey` 包 HKEY：RegCreateKeyEx/RegOpenKeyEx/RegSetValueEx/RegEnumKeyEx（Registry.cpp:44,60,105,151,167）；API 面 `SetValue(UInt32/bool/SZ/binary)`、`SetValue_Strings/GetValue_Strings`、`QueryValue_Binary`、`EnumKeys`、`RecurseDeleteKey`（Registry.h:14-93） | **建议写 CKey 的 NSUserDefaults/CFPreferences 适配实现**（API 面小、调用方仅 6 个文件，见 §4），键路径→域内层级 key；详见 §4 映射表 |
| 剪贴板 | Clipboard.cpp/.h (130+25) | OpenClipboard/CF_TEXT/CF_HDROP（Clipboard.cpp:20-121），`ClipboardSetText`（:109） | NSPasteboard：文本 `NSPasteboardTypeString`；文件列表 `NSPasteboardTypeFileURL`（替代 CF_HDROP） |
| Shell 集成 | Shell.cpp/.h (839+129) | `CItemIDList`(PIDL)、`CDrop`(HDROP 解析 :58-84)、`DataObject_GetData_HDROP_or_IDLIST_Names`（Shell.h:114）、`BrowseForFolder`(SHBrowseForFolder, Shell.h:119-123) | PIDL/HDROP 概念整体消失：拖放用 NSDraggingInfo + NSPasteboard 读 fileURL；选目录用 NSOpenPanel(`canChooseDirectories`) |
| 文件对话框 | CommonDialog.cpp/.h (269+45) | GetOpenFileName/GetSaveFileName 封装 `CommonDlg_BrowseForFile`（CommonDialog.h:10-38） | NSOpenPanel/NSSavePanel（沙盒下还自动获得 security-scoped bookmark 能力） |
| 动态库(Win 分支) | DLL.cpp Win 段 (:7-111) | LoadLibrary/GetModuleFileNameW | 已有 POSIX 分支（§1.1）；mac 另需用 `_NSGetExecutablePath`/`NSBundle` 实现 `GetModuleDirPrefix`（替代 ArchiveCommandLine.cpp:1881-1900 的 argv[0] 方案） |
| COM 生命周期 | COM.cpp/.h (41+80) | `CComInitializer`=CoInitializeEx（COM.h:13-23）、StgMedium 包装 | 桥接侧 no-op stub（MyWindows 已模拟 IUnknown；无系统 COM 运行时） |
| 安全特权 | SecurityUtils.cpp/.h (186+154) | OpenProcessToken/AdjustTokenPrivileges/LSA（SecurityUtils.h:44-150）；服务于 NT 安全描述符恢复与大页特权 | 无对应物：NtSecure 功能在 mac 编译期即被排除（§6.7）；大页→`mmap(VM_FLAGS_SUPERPAGE…)` 无必要，stub |
| 大页内存 | MemoryLock.cpp/.h (127+37) | `EnablePrivilege(SE_LOCK_MEMORY_NAME)`（MemoryLock.h:13-17）、`EnablePrivilege_SymLink`（:20-29）、`Get_LargePages_RiskLevel`（:34） | stub 返回不支持；`-slp` 开关在 mac 隐藏（LargePages 设置项一并隐藏） |
| 全局内存 | MemoryGlobal.cpp/.h (36+60) | GlobalAlloc/GlobalLock（供剪贴板 DDB 数据） | 随剪贴板改 NSPasteboard 后消失 |
| 卷信息 | FileSystem.cpp/.h (187+30) | GetVolumeInformation/GetDriveType/GetDiskFreeSpace（FileSystem.h:15-25） | `statfs/statvfs` + `NSURL resourceValues`（volumeName/volumeIsRemovable…）；驱动器列表→`/Volumes`（见 §6.9） |
| 文件映射 | FileMapping.h (66) | CreateFileMapping/OpenFileMapping（:17,36）+ 命名事件 `CreateWithName`（Synchronization.h:68） | 仅服务 7zFM↔7zG IPC（§7）；进程内化后删除，或改 POSIX `shm_open`/XPC |
| 网络邻居 | Net.cpp/.h (398+87) | WNetOpenEnum 枚举网络资源（Net.h:44-63） | 砍掉（FM 的"网络"虚拟文件夹 Windows 专属）；mac 可用 NSFileManager 浏览挂载点 |
| 进程启动 | ProcessUtils.cpp/.h (102+138) | `CProcess::Create`=CreateProcess（ProcessUtils.h:47-134） | `NSTask`(posix_spawn) 或进程内直调；打开文档用 `NSWorkspace openURL` |
| 资源字符串 | ResourceString.cpp/.h (103+15) | LoadString 从 .rc 资源载入（ResourceString.h:11-13）；是 LangString 的 fallback | 内置英文字符串表（编译进二进制的 C 数组）或 NSLocalizedString；7-Zip Lang/*.txt 体系本身可移植（§1.2） |
| 区域时间格式 | NationalTime.cpp/.h (37+20) | GetTimeFormat/GetDateFormat（NationalTime.h:12-15） | NSDateFormatter（按用户 locale） |
| NT 版本检查 | NtCheck.h (58) | WinMain 入口处 NT 版本探测 | 不需要 |
| 杂项 | Handle.h (39), Defs.h (17), StdAfx.h | CHandle=CloseHandle 包装；BOOLToBool 宏 | Defs.h 可直接复用；Handle.h 随宿主功能消失 |

### 2.3 GUI 源码中绕过包装直接使用的 Win32 SDK

- `#include <windows.h>` 直接出现次数：FM/GUI/Explorer/Common/Agent 合计 **0**（均经 StdAfx.h/MyWindows.h 间接），grep 实测。
- 直接 include `CommCtrl.h / ShlObj.h / ShellAPI.h` 的文件共 8 个：`FileManager/StdAfx.h`、`RootFolder.cpp`、`SystemPage.cpp`、`MemDialog.cpp`、`Panel.h`、`SysIconUtils.cpp/.h`、`SettingsPage.cpp`（grep 实测清单）。
- 典型硬依赖：`SysIconUtils.cpp:33-63` 动态绑定 `SHGetFileInfoW` 取系统图标 → mac 用 `NSWorkspace iconForFile:`/`UTType`；`PanelDrag.cpp` 使用 OLE `DoDragDrop`/IDataObject（grep `IDropTarget|DoDragDrop` 命中 PanelDrag.cpp、App.h）→ NSDraggingSource/Destination。

---

## 3. 替换面量化：7zFM/7zG/Explorer 对 Win32-only 头的 include 统计

统计方法：`grep -rl '"…/Windows/<header>"'`（按文件计数，每文件一次 include，与逐条 tally 一致）。FM=UI/FileManager(147 文件)，GUI=UI/GUI(25)，EXP=UI/Explorer(12)，C+A=UI/Common(55)+UI/Agent(12)。

### 3.1 仅 Win32 头（= 必须替换/重写的面）

| 头文件 | FM | GUI | EXP | C+A | 合计 | 处置 |
|---|---:|---:|---:|---:|---:|---|
| Control/Dialog.h | 18 | 0 | 0 | 0 | 18 | AppKit 重写消失 |
| Control/ComboBox.h | 12 | 3 | 0 | 0 | 15 | 同上 |
| Control/ListView.h | 8 | 0 | 0 | 0 | 8 | NSTableView |
| Control/Edit.h | 7 | 3 | 0 | 0 | 10 | NSTextField |
| Control/PropertyPage.h | 7 | 0 | 0 | 0 | 7 | NSTabViewController |
| Control/Static.h | 4 | 0 | 0 | 0 | 4 | — |
| Control/ImageList.h | 2 | 0 | 0 | 0 | 2 | — |
| Control/ProgressBar.h | 2 | 0 | 0 | 0 | 2 | NSProgressIndicator |
| Control/StatusBar/ToolBar/ReBar/Window2/CommandBar.h | 各1 | 0 | 0 | 0 | 5 | — |
| **Control/* 小计** | **65** | **6** | **0** | **0** | **71** | 全部随视图层重写消失 |
| Menu.h | 5 | 0 | 1 | 0 | 6 | NSMenu |
| Window.h（直接） | 2 | 0 | 1 | 0 | 3 | NSWindow/NSView |
| Registry.h | 3 | 0 | 2 | 2 | 7 | CKey→UserDefaults 适配层（§4） |
| Clipboard.h | 3 | 0 | 0 | 0 | 3 | NSPasteboard |
| Shell.h | 3 | 0 | 1 | 0 | 4 | NSOpenPanel/NSDragging* |
| CommonDialog.h | 2 | 0 | 0 | 0 | 2 | NSSave/OpenPanel |
| COM.h | 4 | 0 | 1 | 0 | 5 | stub |
| ResourceString.h | 4 | 1 | 1 | 1 | 7 | 内置英文表 |
| ProcessUtils.h | 3 | 0 | 1 | 1 | 5 | NSTask/进程内化 |
| SecurityUtils.h | 1 | 0 | 0 | 3 | 4 | 已被 `#ifdef _WIN32` 包住（C+A 三处：ArchiveExtractCallback.cpp:26-29、EnumDirItems.cpp:20-22、UpdateCallback.cpp:39-41）；FM.cpp:27-28 仅 `#ifndef UNDER_CE` **需补 `_WIN32` guard** |
| MemoryLock.h | 2 | 0 | 0 | 2 | 4 | stub/隐藏设置 |
| MemoryGlobal.h | 1 | 0 | 0 | 0 | 1 | 消失 |
| FileSystem.h | 1 | 0 | 0 | 1 | 2 | statfs 适配 |
| FileMapping.h | 0 | 0 | 0 | 2 | 2 | §7 IPC 重设计（ArchiveCommandLine.cpp:34、CompressCall.cpp:15） |
| Net.h | 1 | 0 | 0 | 0 | 1 | 砍掉 |
| NtCheck.h | 1 | 1 | 0 | 0 | 2 | 砍掉 |

### 3.2 可移植头（无需替换，列出以示规模对比）

| 头文件 | FM | GUI | EXP+C+A | 合计 |
|---|---:|---:|---:|---:|
| FileName.h | 24 | 4 | 14 | 42 |
| FileDir.h | 15 | 5 | 16 | 36 |
| PropVariant.h | 16 | 1 | 11 | 28 |
| FileFind.h | 13 | 1 | 8 | 22 |
| ErrorMsg.h | 14 | 1 | 8 | 23 |
| DLL.h | 13 | 1 | 7 | 21 |
| PropVariantConv.h | 10 | 0 | 7 | 17 |
| Synchronization.h | 6 | 1 | 6 | 13 |
| Thread.h | 5 | 3 | 1 | 9 |
| FileIO.h | 5 | 0 | 4 | 9 |
| System.h / SystemInfo.h / TimeUtils.h 等 | 3+1+1 | 2+1+0 | 3+1+4 | 16 |

**解读**：FM 对 Win32-only 头共约 **110 个 include 点**，其中 65 个是控件包装（AppKit 重写自然消失，不需要模拟层），真正需要"功能等价实现"的是 Registry(7)、Shell/CommonDialog/Clipboard(9)、ProcessUtils(5)、ResourceString(7)、Menu(6) 等约 40 个点。可移植头 include 点 200+，全部直接复用。

---

## 4. 设置持久化：注册表键全清单 → UserDefaults/plist 映射

### 4.1 现有键全清单（HKCU 为主）

来源文件仅 6 处（grep `HKEY_|NRegistry` 实测）：`UI/Common/ZipRegistry.cpp`、`UI/Common/LoadCodecs.cpp`、`UI/FileManager/RegistryUtils.cpp`、`UI/FileManager/ViewSettings.cpp`、`UI/FileManager/RegistryAssociations.cpp`（+SystemPage 调用）、`UI/Explorer/RegistryContextMenu.cpp`（+DllExportsExplorer）。

#### A. `HKCU\Software\7-Zip`（根键，RegistryUtils.cpp:14-16）

| 值名 | 类型 | 含义 | 证据 |
|---|---|---|---|
| Lang | SZ | 语言文件路径/标识 | RegistryUtils.cpp:20,58-59 |
| LargePages | bool(DWORD) | 大页开关（-slp） | RegistryUtils.cpp:38,170-171 |

#### B. `HKCU\Software\7-Zip\FM`（RegistryUtils.cpp:17 / ViewSettings.cpp:18-32）

| 值名 | 类型 | 含义 | 证据 |
|---|---|---|---|
| Viewer / Editor / Diff / 7vc | SZ(W) | 外部查看器/编辑器/对比工具/版本控制路径 | RegistryUtils.cpp:22-25,61-67 |
| ShowDots / ShowRealFileIcons / FullRow / ShowGrid / SingleClick / AlternativeSelection / ShowSystemMenu | bool | FM 浏览选项（默认全 false，RegistryUtils.cpp:136-149） | RegistryUtils.cpp:27-35,121-163 |
| FlatViewArc0 / FlatViewArc1 | bool | 每面板平铺视图 | RegistryUtils.cpp:40,173-188 |
| Position | BINARY 20B | 窗口 left/top/right/bottom/maximized（各 UInt32 LE） | ViewSettings.cpp:138,141-153 |
| Panels | BINARY 12B | numPanels/currentPanel/splitterPos | ViewSettings.cpp:139,156-161 |
| Toolbars | DWORD | 工具栏掩码，默认 `(1<<31)|8|4|1` | ViewSettings.cpp:25,213-226 |
| ListMode | DWORD | 两面板列表模式各占 8bit | ViewSettings.cpp:29,229-248 |
| PanelPath0 / PanelPath1 | SZ(W) | 面板当前路径 | ViewSettings.cpp:27,250-272 |
| FolderHistory | multi-SZ（SetValue_Strings） | 地址栏历史 | ViewSettings.cpp:30,292-295 |
| FolderShortcuts | multi-SZ | 收藏夹（Alt+数字书签） | ViewSettings.cpp:31,297-300 |
| CopyHistory | multi-SZ | 复制目标历史 | ViewSettings.cpp:32,302-304 |

#### C. `HKCU\Software\7-Zip\FM\Columns`（ViewSettings.cpp:21）

| 值名 | 类型 | 含义 | 证据 |
|---|---|---|---|
| `<FolderTypeID>`（按文件夹类型一个值） | BINARY | 头部 version/SortID/Ascending(3×4B) + N×(PropID,IsVisible,Width)(3×4B)；version=1 | ViewSettings.cpp:52-77（写）, :80-119（读） |

#### D. `HKCU\Software\7-Zip\Extraction`（ZipRegistry.cpp:91-101）

| 值名 | 类型 | 含义 |
|---|---|---|
| ExtractMode | DWORD | 路径模式（kCurPaths…kAbsPaths，校验 :158） |
| OverwriteMode | DWORD | 覆盖模式（校验 :163） |
| ShowPassword | bool | 显示密码 |
| PathHistory | multi-SZ | 解压目标历史（写前 RecurseDeleteKey :120-121） |
| SplitDest | bool | "每档一目录"（默认 true，:147,169） |
| ElimDup | bool | 消除重复根目录 |
| Security | bool | **NtSecurity**（mac 无意义，§6.7） |
| MemLimit | DWORD(GB) | 解压内存上限（:132-138,188-196） |

#### E. `HKCU\Software\7-Zip\Compression`（ZipRegistry.cpp:203-232）

| 值名 | 类型 | 含义 |
|---|---|---|
| ArcHistory | multi-SZ | 压缩目标历史 |
| Archiver | SZ | 默认格式（默认 "7z"，:313） |
| ShowPassword / EncryptHeaders | bool | — |
| Level | DWORD | 默认等级（默认 5，:312） |
| Security / AltStreams / HardLinks / SymLinks / PreserveATime | bool（不存在=未定义三态，CBoolPair） | NTFS 语义开关（mac 取舍见 §6） |
| 子键 `Options\<FormatID>`（每格式） | — | Method / Options / EncryptionMethod / MemUse32 或 MemUse64（按指针宽度，:248-253）/ Level / Dictionary / Order / BlockSize / NumThreads / TimePrec / MTime / ATime / CTime / SetArcMTime（:210-232,255-304） |

#### F. `HKCU\Software\7-Zip\Options`（ZipRegistry.cpp:488-544 + :540-599）

| 值名 | 类型 | 含义 |
|---|---|---|
| WorkDirType | DWORD | 临时目录模式（kSystem/kCurrent/kSpecified） |
| WorkDirPath | SZ(W) | 指定工作目录 |
| TempRemovableOnly | bool | 仅可移动盘使用工作目录 |
| CascadedMenu / MenuIcons / ElimDupExtract | bool | Explorer 右键菜单选项 |
| ContextMenu | DWORD | 右键菜单项 flags（默认全开 :577-584） |
| WriteZoneIdExtract | DWORD | Zone.Identifier 写出策略（mac 对应 com.apple.quarantine，§6.6） |

#### G. 其它（程序注册/系统集成，非用户偏好）

| 键 | 用途 | 证据 | mac 对应 |
|---|---|---|---|
| `HKCU/HKLM\Software\7-zip` 值 `Path`、`Path32/Path64` | 定位 7z.dll/Codecs 目录；**仅 `#ifdef _WIN32` 分支使用** | LoadCodecs.cpp:80-89,209-219 | 不需要：dylib 随 .app bundle（`GetModuleDirPrefix` 改 NSBundle） |
| `Software\Classes\.{ext}`、`7-Zip.{ext}`、`DefaultIcon`、`shell\open\command` | 文件关联（FM"系统"设置页） | RegistryAssociations.cpp:20-26,42-60,93-160；SystemPage.cpp 调用 | Info.plist `CFBundleDocumentTypes`/`UTImportedTypeDeclarations` 静态声明 + `LSSetDefaultRoleHandlerForContentType` 动态设默认 |
| `HKCR\CLSID\{…}`、`*\shellex\ContextMenuHandlers\7-Zip`、`HKLM\…\Shell Extensions\Approved` | Explorer 右键扩展 COM 注册 | RegistryContextMenu.cpp:23-26,96-220 | Finder Sync Extension / macOS 13+ App Extensions（无注册表，Info.plist 声明）；服务菜单 NSServices |

### 4.2 UserDefaults / plist 映射建议

建议域：`com.7zip.SevenZipFM`（suite 供 FM 与 7zG 等价物共享）。原则：**键空间扁平化为 `<Section>.<Name>`，标量直映射；字符串数组→NSArray；CBoolPair 三态→"键不存在=未定义"**（与现语义一致，ZipRegistry.cpp:53-86 的 Def/Val 协议天然兼容 `objectForKey==nil`）。

| 注册表 | UserDefaults 键（建议） | 类型 | 备注 |
|---|---|---|---|
| 根\Lang | `Lang` | String | 不存在=跟随系统（mac 可优先 `NSLocale preferredLanguages` 自动选 Lang/*.txt） |
| 根\LargePages | （不迁移） | — | mac 隐藏该功能 |
| FM\Viewer/Editor/Diff/7vc | `FM.Viewer` 等 | String | mac 默认空=用 `NSWorkspace` 打开 |
| FM\Show* 等 7 个 bool | `FM.ShowDots` 等 | Bool | 默认值照搬 RegistryUtils.cpp:136-149 |
| FM\FlatViewArc{N} | `FM.FlatView` | [Bool] 数组 | 面板索引下标 |
| FM\Position / Panels | **不迁移** | — | 用 `NSWindow setFrameAutosaveName:` + NSSplitView autosave；splitterPos/currentPanel 另存 `FM.CurrentPanel` Int |
| FM\Toolbars / ListMode | `FM.ToolbarsMask` / `FM.ListMode` | Int | 语义不变可直搬 |
| FM\PanelPath{N} | `FM.PanelPaths` | [String] | — |
| FM\FolderHistory / FolderShortcuts / CopyHistory | `FM.FolderHistory` 等 | [String] | multi-SZ→数组一一对应 |
| FM\Columns\<id> | `FM.Columns.<id>` | Dictionary：`{sortID:Int, ascending:Bool, columns:[{prop:Int,visible:Bool,width:Int}]}` | **建议弃用二进制 blob**，改结构化 plist；或直接用 NSTableView `autosaveName` |
| Extraction\* | `Extraction.PathMode` 等 8 键 | Int/Bool/[String] | `Security` 在 mac 隐藏但保留键名兼容 |
| Compression\* | `Compression.Level` 等 | 同上 | `Options.<FormatID>.<name>` 两级字典：`Compression.Options = {“7z”: {Level:…, Method:…}, …}` |
| Options\WorkDir* | `Options.WorkDirType/Path/RemovableOnly` | Int/String/Bool | — |
| Options\ContextMenu 等 | `Menu.Flags` 等 | Int | 服务于 Finder 扩展（App Group UserDefaults 共享给 extension 进程） |
| Classes 关联 / CLSID | 不进 defaults | — | 见 §4.1-G |

实现策略（与 §2.2 Registry 行对应）：保留 `NRegistry::CKey` API 面，新写 `Registry_mac.mm`，将 `HKEY_CURRENT_USER + "Software/7-Zip/..."` 键路径直接转为 defaults 键前缀；`QueryValue_Binary/SetValue(binary)` 映射 NSData——可让 ViewSettings/ZipRegistry **零改动**先跑通，再逐步替换为原生 autosave。注意 `RecurseDeleteKey`（ZipRegistry.cpp:120,273,276）需实现"按前缀删除"。

---

## 5. 文件系统语义差异清单（macOS vs Windows）

| # | 差异点 | 7-Zip 现状（证据） | macOS 影响与决策 |
|---|---|---|---|
| 1 | **路径分隔符** | 编译期切换：`CHAR_PATH_SEPARATOR='/'`（C/7zTypes.h:567-579）；POSIX 下 `IS_PATH_SEPAR` 只认 `/`（CPP/Common/MyString.h:48-53）；档内名→OS 路径转换在 POSIX 为恒等（CPP/7zip/Archive/Common/ItemNameUtils.cpp:10-35：`WCHAR_PATH_SEPARATOR==L'/'` 时 ReplaceSlashes 为 no-op） | 已解决；UI 层新代码不得再写 `'\\'` 字面量。档内含 `\` 的文件名在 mac 是合法字符，原样落盘（Windows 的 0xF05C 替换仅在 `WCHAR_PATH_SEPARATOR==L'\\'` 时编译，MyString.h:1075-1077） |
| 2 | **字符串编码/宽度** | `UString=wchar_t`，mac 上 32 位（`Z7_WCHART_IS_16BIT` 不成立，MyString.h:1063-1069）即 UTF-32；`FString=AString`=UTF-8 字节串（MyString.h:961-963 仅 Win 定义 USE_UNICODE_FSTRING）；POSIX 默认强制 UTF-8（StringConvert.cpp:260,268-271）；UTF-16↔UTF-32 互转已备（UTFConvert.h:255-256） | 桥接层 NSString(UTF-16)↔UString(UTF-32) 必须经 UTF8/UTF32 转换函数，**不可 memcpy**；BSTR（MyWindows OLECHAR=wchar_t=4B）与 NSString 也不同宽 |
| 3 | **Unicode 规范化 (NFC/NFD)** | 全仓库无任何 NFC/NFD 处理（grep `Normaliz|NFD|NFC` 无命中，亦无 CFStringNormalize 调用） | HFS+ 强制 NFD、APFS 保留原样但 Finder 输入多为 NFD：档内 NFC 名 vs 磁盘 NFD 名做字符串比较（更新/覆盖检测、wildcard）会失配。**需在桥接层统一规范化**（建议入档 NFC，比较时双向规范化）——新增工作项，无现成代码 |
| 4 | **大小写敏感性** | `g_CaseSensitive`：`__APPLE__` 桌面默认 **false**（CPP/Common/Wildcard.cpp:8-20），与 Windows 行为一致 | 上游已替 mac 选好默认；但 APFS 可格式化为区分大小写卷——FM 同目录 `A.txt/a.txt` 共存场景在 case-insensitive 匹配下会有歧义，列为已知限制 |
| 5 | **符号链接** | POSIX 读 `readlink`（CPP/Windows/FileLink.cpp:643）写 `symlink`（:682）；解压走 `NIO::SetSymLink`（UI/Common/ArchiveExtractCallback.cpp:2318-2321，`#else // !_WIN32` 分支）；Tar 原生支持（Archive/Tar/TarHandler.cpp:49,621 kpidSymLink）；权限不 chmod（FileDir.cpp:1315-1316） | 已可用（7zz 实测过）。GUI 需暴露 `SymLinks` 压缩开关（注册表键 E 节） |
| 6 | **硬链接** | POSIX `link()`（FileDir.cpp:1352-1355）；解压端按 dev/ino 聚类（ArchiveExtractCallback.cpp:202-291 CHardLinkNode，创建 :2058 MyCreateHardLink） | 已可用；APFS 支持文件硬链接，目录硬链接不支持（7-Zip 也不创建目录硬链） |
| 7 | **NTFS ADS（替代流）与 NT 安全描述符** | ADS：档内属性仍可读（Archive/7z/7zHandler.cpp:241,620 kpidIsAltStream），但**宿主 FS 枚举/写 ADS 仅 Windows**；FM 的 ADS 面板（FileManager/AltStreamsFolder.h）依赖 Win API。NtSecure：捕获/恢复整体 `#if defined(_WIN32)`（`Z7_USE_SECURITY_CODE`：ArchiveExtractCallback.cpp:26-29、EnumDirItems.cpp:20-22、UpdateCallback.cpp:39-41；恢复点 :2650） | **取舍：mac 砍 UI 入口**（AltStreamsFolder 不编译；压缩对话框 AltStreams/NtSecurity 复选隐藏）。档内 ADS 条目仍按普通"file:stream"名解出（需决定落盘命名策略）。FM.cpp:27-28 的 SecurityUtils include 需补 `_WIN32` guard |
| 8 | **xattr / resource fork / quarantine** | 核心**完全不读写宿主 xattr**（CPP/Windows、C/ 无 getxattr/setxattr/copyfile，grep 实测）；APFS/HFS 镜像 handler 仅读取档内 attr：`com.apple.fs.symlink/decmpfs/ResourceFork`（Archive/ApfsHandler.cpp:2790-2802）；Tar 仅支持 `SCHILY.fflags`（Archive/Tar/TarIn.cpp:763-768），**无 SCHILY.xattr/LIBARCHIVE.xattr** | 取舍建议：v1 不保真 xattr/resource fork（与 7zz CLI 行为一致），但 **GUI 解压网络来源档案必须写 `com.apple.quarantine`**（对应 Windows WriteZoneIdExtract 设置，ZipRegistry.cpp:544,556；mac 用 `qtn_file_*` 或 NSURL quarantinePropertiesKey）——新增桥接工作项 |
| 9 | **驱动器/卷模型** | FM 驱动器列表 `MyGetLogicalDriveStrings`+`MyGetDriveType`（FileManager/FSDrives.cpp:135-147；API 声明仅 Win：FileFind.h:283、FileSystem.h:23） | "计算机"虚拟文件夹→枚举 `/Volumes`（NSFileManager mountedVolumeURLs）；根路径解析逻辑（`C:\` 前缀判断）在 FileName.cpp POSIX 分支已是 `/` 语义 |
| 10 | **目录变更通知** | `CFindChangeNotification`=FindFirstChangeNotification，仅 Win（FileFind.h:246-280 段）；FM 面板成员直接持有：FSFolder.h:141、AltStreamsFolder.h:69 | mac 用 FSEvents（目录级）或 dispatch source(vnode)；需为 FSFolder 抽象一个跨平台 watcher 类型，否则 FSFolder.h 无法编译 |
| 11 | **时间戳精度/属性** | FILETIME(100ns) 为内部统一表示（TimeUtils.cpp:22 起）；落盘 `utimensat` ns 级（FileDir.cpp:1229）；POSIX 文件属性经 `FILE_ATTRIBUTE_UNIX_EXTENSION`（0x8000）把 st_mode 放入 attrib 高 16 位（FileFind.cpp:1104-1112,1383-1385），7z/zip/tar 由此保存/恢复 POSIX 权限 | 已工作；注意 HFS+ 卷只有秒级 mtime（APFS ns 级），往返测试在 HFS+ 上会差异 |
| 12 | **稀疏文件/克隆** | 无 APFS clonefile/稀疏支持（grep 无命中） | 可选优化项，非移植阻塞 |

---

## 6. 进程模型与 IPC（7zFM ↔ 7zG）

这是平台层最隐蔽的 Windows 依赖，方案 B 必须重设计：

1. 7zFM 通过 `Call7zGui` 用 `CreateProcess` 启动 **`7zG.exe`**（UI/Common/CompressCall.cpp:33 `#define k7zGui "7zG.exe"`；:73-96，等待用 `WaitForMultipleObjects(process, event)` :93-94）。
2. 文件列表不走命令行，而是写入**命名共享内存** `7zMap<rand>`（CompressCall.cpp:136 `fileMapping.Create(PAGE_READWRITE,…)`）+ **命名事件** `7zEvent<rand>`（:148-150），参数形如 `-i#7zMapNNN:size:7zEventNNN`（:158-166），内容为 0 标记 + UTF-16/wchar NUL 分隔串（:168-182）。
3. 7zG 端解析在 `ParseMapWithPaths`（UI/Common/ArchiveCommandLine.cpp:651-705），整段连同 `CEventSetEnd` 包在 `#ifdef _WIN32`（:634），非 Windows 落入 `throw "not implemented"`（:620-622）。
4. `CFileMapping` 本身无 POSIX 分支（CPP/Windows/FileMapping.h:17,36 直接 CreateFileMapping/OpenFileMapping）。

**mac 建议**：FM 与 GUI 操作合并为单进程（dylib 直调 + NSOperation/线程承载压缩解压，进度对话框为窗口而非子进程），删除 CompressCall 的进程路径；若保留独立 helper（如为沙盒/权限分离），用 XPC 传 `[String]`，彻底绕开 7zMap 协议。`GetModuleDirPrefix` 的 argv[0] 方案（ArchiveCommandLine.cpp:1875-1900）替换为 `NSBundle.mainBundle`（dylib、Lang/、License 等资源定位统一走 bundle 布局）。

附：程序入口 `WinMain` 在 FileManager/FM.cpp:785（窗口类注册+消息循环）与 GUI/GUI.cpp:408 → 替换为 `NSApplicationMain` + AppDelegate；Explorer 的 COM DllMain/注册导出（Explorer/DllExportsExplorer.cpp）→ Finder 扩展 target。

---

## 7. 本地化资源

- `.rc` 资源共 39 个文件（FileManager/GUI/Explorer，ls 实测），含全部对话框模板与 LANGUAGE 字符串表 → AppKit 下需以 xib/programmatic UI 重建（属 GUI 工作量，不在平台层）。
- 字符串获取双轨：`LangString(id)` 优先查 `Lang/*.txt`（LangUtils.cpp:51,33-35），**fallback 是 `MyLoadString`（.rc 资源）**（ResourceString.h:11-13）。mac 移植要点：把英文默认串以静态表编入（7-Zip 的 Lang/en.ttt 即模板），保证无 .rc 时 fallback 不为空；Lang/*.txt 92 种语言可直接随 .app Resources 分发——**本地化体系基本免费移植**。

---

## 8. 移植风险清单（平台层视角）

| 级别 | 风险 | 缓解 |
|---|---|---|
| 高 | FM 39k 行与 Win32 控件强耦合（Control/* 65 个 include 点 + 8 文件直用 CommCtrl/ShlObj；ListView 虚拟列表、PropertySheet、自绘 StatusBar 行为差异大） | 视图层全量重写（AppKit），逻辑层（IFolderFolder/Panel 数据模型）保留；不做 Win32 模拟层 |
| 高 | NFC/NFD 无任何现成处理，档内/磁盘文件名比较会失配（§5.3） | 桥接层统一规范化 + 专项测试集（中文/韩文/带变音符文件名） |
| 高 | 7zFM↔7zG 的 7zMap/7zEvent IPC 为 `#ifdef _WIN32` 专属（§6），决定 mac 进程架构 | 首选进程内化；保留 helper 则 XPC |
| 中 | wchar_t 宽度差异：任何把 UString 按 UTF-16 用的桥接代码（NSString 直接转）都会在非 BMP 字符上出错 | 统一经 UTFConvert（UTF8 中转），代码评审检查项 |
| 中 | 二进制注册表 blob（Position/Panels/Columns）直搬 plist 需自管版本与字节序 | 弃用 blob，改 NSWindow/NSTableView autosave + 结构化 plist（§4.2） |
| 中 | 目录监视：FSFolder.h:141 直接持有 Win 专属 `CFindChangeNotification` 成员，不是 ifdef 可绕的调用点而是**类型成员** | 先抽象 IDirWatcher，mac 实现 FSEvents；否则 FSFolder 不可编译 |
| 中 | FM.cpp:27-28 无条件 include SecurityUtils.h（仅 `#ifndef UNDER_CE`），以及散落的 `MessageBoxW`（CompressCall.cpp:59）等会让"非 GUI 公共文件"在 mac 编译失败 | 移植首步：为 UI/Common+FileManager 公共 cpp 补 `_WIN32` guard 清单（本档 §3 表即排查清单） |
| 中 | quarantine/xattr 全空白：解压可执行文件不打 quarantine 会触犯 Gatekeeper 预期；WriteZoneIdExtract 设置在 mac 语义悬空 | 桥接层新增 quarantine 写入；xattr 保真列为 v2 |
| 低 | NtSecurity/ADS/网络邻居/大页/文件关联注册表/Explorer COM 注册在 mac 无对应物 | 编译期裁剪 + 设置页隐藏；关联走 Info.plist，右键走 Finder 扩展 |
| 低 | ResourceString fallback 为空导致 UI 字符串空白 | 内置英文默认表（§7） |
| 低 | HFS+ 秒级 mtime、APFS case-sensitive 卷等边缘卷特性 | 已知限制文档化 + 测试矩阵覆盖 |

---

## 9. 给后续起草人的速查结论

1. **不要写 Win32 模拟层**：Control/Window/Menu/Dialog 类在 AppKit 重写后无调用方；唯一值得做 API 兼容适配的是 `NRegistry::CKey`（6 个调用文件、API 面 ~15 个方法，Registry.h:14-93）。
2. **引擎侧零改动**：dylib（Format7zF）+ DLL.cpp 的 dlopen 分支 + MyWindows COM 模拟即为现成加载链路；只补一个 bundle 版 `GetModuleDirPrefix`。
3. **PROPVARIANT/BSTR 跨边界即 malloc 块**（MyWindows.cpp:15-67），Objective-C++ 桥接可以安全持有/释放，但要用 `SysFreeString/VariantClear` 配对，不可 free()。
4. 设置迁移工作量集中在 §4.2 表，约 60 个标量/数组键 + 3 个建议弃用的 blob；`CBoolPair` 三态语义务必保留（影响压缩对话框"默认/强制"行为）。
5. 文件系统语义差异里只有 **NFD 规范化** 和 **quarantine** 是需要"新写代码"的，其余（符号链接/硬链接/权限/时间戳/大小写）上游 POSIX 分支已经给齐并经 7zz 验证。
