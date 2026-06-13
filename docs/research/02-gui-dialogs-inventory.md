# 02 — 7zG 对话框与操作层清单（CPP/7zip/UI/GUI + CPP/7zip/UI/Common）

> 调研对象：7-Zip 26.01 源码（本仓库）。所有结论均出自真实源码核读，证据以 `文件路径:行号` 标注。
> 目标：为 macOS 移植（方案B：核心 dylib + ObjC++ 桥接 + AppKit）提供 7zG（GUI 操作进程）的逐控件、逐接口、逐文件底料。
> 关联事实（已验证，直接采信）：7zz 26.01 已在 macOS arm64 编译/自测通过；`7zip_gcc.mak` 非 Windows 分支支持 `-shared` 出 `.so`；`MyWindows.h/.cpp` 提供 COM 模拟。

---

## 0. 7zG 物料清单（链接级构成）

7zG.exe 的官方构成以 `CPP/7zip/UI/GUI/makefile` 为准（nmake，Windows 构建唯一权威清单）：

| 分组 | 文件 | 证据 |
|---|---|---|
| 编译宏 | `-DZ7_LANG -DZ7_EXTERNAL_CODECS`（7zG 必以外置 7z.dll 模式构建） | CPP/7zip/UI/GUI/makefile:2-4 |
| GUI_OBJS（本目录 9 个 .cpp） | BenchmarkDialog, CompressDialog, ExtractDialog, ExtractGUI, GUI, HashGUI, UpdateCallbackGUI, UpdateCallbackGUI2, UpdateGUI | makefile:13-22 |
| UI_COMMON_OBJS（22 个） | ArchiveCommandLine, ArchiveExtractCallback, ArchiveOpenCallback, Bench, DefaultName, EnumDirItems, Extract, ExtractingFilePath, HashCalc, LoadCodecs, OpenArchive, PropIDUtils, SetProperties, SortUtils, TempFiles, Update, UpdateAction, UpdateCallback, UpdatePair, UpdateProduce, **WorkDir, ZipRegistry** | makefile:82-104 |
| FM_OBJS（FileManager 中被 7zG 复用的 19 个） | EditDialog, **ExtractCallback**, FormatUtils, HelpUtils, LangUtils, **ListViewDialog**, **MemDialog**, OpenCallback, ProgramLocation, PropertyName, RegistryUtils, SplitUtils, StringUtils, **OverwriteDialog**, **PasswordDialog**, **ProgressDialog2**, BrowseDialog, ComboDialog, SysIconUtils | makefile:110-131 |
| EXPLORER_OBJS | MyMessages（消息框助手） | makefile:133-134 |
| 其余 | Windows 包装层（Dialog/ComboBox/ListView/Registry/Shell 等）、7zip Common、CopyCoder、C 层 | makefile:24-148 |

**关键认知**：7zG 的"进度窗/覆盖确认/密码框/Hash结果窗/内存确认窗"物理上位于 `UI/FileManager/` 目录，但属于 7zG 链接单元，本清单将其一并盘点。

7zz（mac 已验证）所含 UI/Common 子集为 20 个 .cpp（`CPP/7zip/Bundles/Alone2/makefile.gcc:48-68`）——与 7zG 的 UI_COMMON_OBJS 相比**仅少 WorkDir.o 和 ZipRegistry.o**（详见 §9）。

---

## 1. 7zG 进程入口与命令分发（GUI.cpp，495 行）

| 步骤 | 逻辑 | 证据 |
|---|---|---|
| 入口 | `WinMain`：`InitCommonControls()`、`OleInitialize()`（任务栏进度条需要）、`LoadLangOneTime()`，再调 `Main2()`，外层 catch 全部异常→消息框+退出码 | CPP/7zip/UI/GUI/GUI.cpp:408-494 |
| 命令行 | `SplitCommandLine(GetCommandLineW())` → `CArcCmdLineParser::Parse1/Parse2` 与 7z.exe 完全同一套解析器（UI/Common/ArchiveCommandLine） | GUI.cpp:139-157 |
| 全局静音 | `g_DisableUserQuestions = options.YesToAll`（`-y` 时不弹任何错误框） | GUI.cpp:50-51,156 |
| 装载格式 | `CREATE_CODECS_OBJECT; codecs->Load(); Codecs_AddHashArcHandler(codecs)`；Z7_EXTERNAL_CODECS 下加载 7z.dll 并 `_externalCodecs.Load()` | GUI.cpp:159-225（宏定义 UI/Common/LoadCodecs.h:469-477） |
| 分发 | `kBenchmark` → `Benchmark(props, numIterations)`；Extract 组（x/t）→ 枚举档案路径 `EnumerateDirItemsAndSort` 后调 `ExtractGUI(...)`；Update 组（a/d/u/rn）→ `UpdateGUI(...)`；`kHash` → `HashCalcGUI(...)`；其余 throw "Unsupported command" | GUI.cpp:227-400 |
| 回调实例 | Extract 用 `CExtractCallbackImp`（FileManager/ExtractCallback）；Update 用 `CUpdateCallbackGUI`；密码从 `-p` 注入回调 | GUI.cpp:249-266, 335-345 |
| 退出码 | `NExitCode`：0/1/2/7/8/255（UI/Common/ExitCode.h:8-24），E_ABORT→kUserBreak | GUI.cpp:456-460 |

**7zG 支持的命令面**（即 7zFM 唤起协议的命令集）：`a`、`x`、`t`、`h`、`b`（GUI.cpp:227-400 的四个分支 + extract 组含 `t`）。`-ad` 开关（"show dialog"）令 7zG 在执行前弹出压缩/解压对话框：开关表 `{ "ad", SWFRM_SIMPLE }`（UI/Common/ArchiveCommandLine.cpp:295），`options.ShowDialog = parser[NKey::kShowDialog].ThereIs`（同文件:1571）。

---

## 2. 压缩对话框 CCompressDialog（+二级 COptionsDialog）

文件：`CPP/7zip/UI/GUI/CompressDialog.{h,cpp}`（483 + 3821 行）、资源 `CompressDialog.rc`、`CompressOptionsDialog.rc`、ID 表 `CompressDialogRes.h`。

### 2.1 主对话框控件全清单（IDD_COMPRESS，400×320 DLU）

| 控件 ID | 类型 | 含义 | 成员/读取方法 | 证据（attach/布局） |
|---|---|---|---|---|
| IDC_COMPRESS_ARCHIVE (100) | ComboBox(可编辑,带历史) | 档案名 | `m_ArchivePath` | CompressDialog.cpp:468; rc:63 |
| IDB_COMPRESS_SET_ARCHIVE (101) | 按钮 "..." | 浏览保存路径（带格式过滤器） | `OnButtonSetArchive()` | cpp:586-594, 879-1012 |
| IDT_COMPRESS_ARCHIVE_FOLDER (130) | 静态文本 | 当前目录前缀显示 | `SetArcPathFields` | cpp:854 |
| IDC_COMPRESS_FORMAT (104) | ComboBox(CBS_SORT) | 档案格式（7z/zip/gzip/…来自 codecs->Formats 过滤） | `m_Format`，ItemData=arcIndex | cpp:469,503-522; rc:67 |
| IDC_COMPRESS_LEVEL (102) | ComboBox | 压缩等级 0-9（按格式 LevelsMask 过滤） | `m_Level`，`GetLevelSpec()` | cpp:470,1572-1617 |
| IDC_COMPRESS_METHOD (106) | ComboBox | 压缩方法（首项"* auto"） | `m_Method`，`GetMethodSpec()` | cpp:471,1627-1707 |
| IDC_COMPRESS_DICTIONARY (107) | ComboBox | 字典大小（按方法生成档位） | `m_Dictionary`，`GetDictSpec()` | cpp:472,1859-2167 |
| IDC_COMPRESS_ORDER (108) | ComboBox | Word size / PPMd order | `m_Order`，`GetOrderSpec()` | cpp:484,2213-2361 |
| IDC_COMPRESS_SOLID (109) | ComboBox | 固实块大小（7z/xz 才有） | `m_Solid`，`GetBlockSizeSpec()`（存 log2） | cpp:485,2405-2519 |
| IDC_COMPRESS_THREADS (110) | ComboBox | 线程数（含"* auto"与 ST 标注） | `m_NumThreads`，`GetNumThreadsSpec()` | cpp:486,2559-2711 |
| IDT_COMPRESS_HARDWARE_THREADS (112) | 静态文本 | "/ 进程线程数 / 系统线程数" | `SetNumThreads2` | cpp:2576-2585 |
| IDC_COMPRESS_MEM_USE (117) | ComboBox | 压缩内存上限（80% auto/百分比/字节档位） | `m_MemUse`，`Get_MemUse_Spec()` | cpp:487,2767-2854 |
| IDT_COMPRESS_MEMORY_VALUE (113) | 静态文本 | 估算压缩内存 "实际/限额/RAM" | `PrintMemUsage` | cpp:3099-3144 |
| IDT_COMPRESS_MEMORY_DE_VALUE (114) | 静态文本 | 估算解压内存 | 同上 | cpp:3140 |
| IDC_COMPRESS_VOLUME (105) | ComboBox(可编辑) | 分卷大小（字节表达式，`ParseVolumeSizes`） | `m_Volume` | cpp:492,495,1211-1235 |
| IDE_COMPRESS_PARAMETERS (111) | Edit | 自由参数串（如 `0=LZMA2:d26 mt=4`） | `m_Params` | cpp:493,3244-3254 |
| IDB_COMPRESS_OPTIONS (2100) | 按钮 "Options" | 打开二级 COptionsDialog | cpp:607-613 |
| IDT_COMPRESS_OPTIONS (141) | 静态文本 | 当前选项摘要串（"tp2 tm- SL HL…"） | `ShowOptionsString()` | cpp:3353-3377 |
| IDC_COMPRESS_UPDATE_MODE (103) | ComboBox | 更新模式 Add/Update/Fresh/Sync | `m_UpdateMode` | cpp:489,536-537,367-384 |
| IDC_COMPRESS_PATH_MODE (116) | ComboBox | 路径模式 Relative/Full/Abs | `m_PathMode` | cpp:490,539-540,386-401 |
| IDX_COMPRESS_SFX (4012) | CheckBox | 创建自解压(.exe) | `IsSFX()`/`OnButtonSFX()` | cpp:524,595-601,767-808 |
| IDX_COMPRESS_SHARED (4013) | CheckBox | 压缩共享(被占用)文件 | OnOK 读取 | cpp:542,1174 |
| IDX_COMPRESS_DEL (4019) | CheckBox | 压缩后删除源文件 | OnOK 读取 | cpp:543,1175 |
| IDE_COMPRESS_PASSWORD1/2 (120/121) | Edit(ES_PASSWORD) | 密码/确认密码 | `_password1Control/_password2Control` | cpp:461-464 |
| IDX_PASSWORD_SHOW (3803) | CheckBox | 明文显示密码（隐藏二次输入行） | `UpdatePasswordControl()` | cpp:570-584,602-606 |
| IDC_COMPRESS_ENCRYPTION_METHOD (122) | ComboBox | 加密算法（7z: AES-256；zip: ZipCrypto/AES-256） | `_encryptionMethod` | cpp:465,1721-1751 |
| IDX_COMPRESS_ENCRYPT_FILE_NAMES (4016) | CheckBox | 加密文件名（仅 7z） | OnOK 读取 | cpp:499,1177-1178 |
| IDOK/IDCANCEL/IDHELP | 按钮 | 确定/取消/帮助（help: `fm/plugins/7-zip/add.htm`） | cpp:1254-1260; rc:145-147 |

### 2.2 静态格式能力表 g_Formats（决定控件可用性）

`CFormatInfo g_Formats[]`（CompressDialog.cpp:271-356）按格式声明：LevelsMask、可选方法集、Flags（`kFF_Filter/kFF_Solid/kFF_MultiThread/kFF_Encrypt/kFF_EncryptFileNames/kFF_MemUse/kFF_SFX`，cpp:236-242）：

| 格式 | Levels | 方法 | 能力 |
|---|---|---|---|
| ""(未知/外部) | 0-9 | — | MT+MemUse |
| 7z | 0-9 | LZMA2,LZMA,PPMd,BZip2,Deflate,Deflate64,Copy（cpp:162-172；7z 下 Copy/Deflate* 在 SetMethod2 中被跳过 cpp:1664-1669） | Filter+Solid+MT+Encrypt+EncryptNames+MemUse+SFX |
| Zip | 0,1,3,5,7,9 | Deflate,Deflate64,BZip2,LZMA,PPMd | MT+Encrypt+MemUse |
| GZip | 1,5,7,9 | Deflate | MemUse |
| BZip2 | 1,3,5,7,9 | BZip2 | MT+MemUse |
| xz | 1-9 | LZMA2 | Solid+MT+MemUse |
| Tar | 0 | GNU,POSIX | — |
| wim | 0 | — | — |
| Hash | — | SHA256,SHA1 | —（hash 伪格式，输出校验文件） |

SFX 仅允许 Copy/LZMA/LZMA2/PPMd（g_7zSfxMethods，cpp:174-180,358-364）。7z 格式下方法 Combo 末尾追加外部编解码器（`SetMethods`/`ExternalMethods`，cpp:405-426,1671-1680）。

### 2.3 参数联动逻辑（事件→函数链，移植时必须 1:1 保留）

初始化链：`OnInit`（cpp:429-552）→ 读 RAM（`NSystem::GetRamSize`，cpp:437-459，32 位降额、`_ramUsage_Auto=80%`）→ attach 全部控件 → `m_RegistryInfo.Load()`（cpp:497）→ 填格式 Combo → `FormatChanged(false)`。

`FormatChanged(isChanged)`（cpp:698-764）：`SetLevel()`→`SetSolidBlockSize()`→`SetParams()`→`SetMemUseCombo()`→`SetNumThreads()`；置 `Info.SolidIsSpecified/EncryptHeadersIsAllowed`；合并 SymLinks/HardLinks/AltStreams/NtSecurity/PreserveATime 的"命令行 Info 与注册表"两源布尔（`SET_GUI_BOOL`，cpp:664-696,723-744）；按 `CArcInfoEx` flags 决定支持位（cpp:735-741）；启停加密区控件（cpp:747-762）；`SetEncryptionMethod(); SetMemoryUsage()`。

`SetLevel()` = `SetLevel2`+`EnableMultiCombo`+`SetMethod()`；`SetMethod()` = `SetMethod2`+enable；`MethodChanged()` = `SetDictionary2`+`SetOrder2`+enable（CompressDialog.h:216-238）。

CBN_SELCHANGE 矩阵（`OnCommand`，cpp:1313-1440）：

| 变更控件 | 触发链 |
|---|---|
| ARCHIVE（历史项选择） | `ArcPath_WasChanged` + PostMsg(k_Message_ArcChanged=WM_APP+1) 延迟改文本（cpp:1319-1337,1290-1310） |
| FORMAT | `SaveOptionsInMem()`（把旧格式 UI 状态写回内存注册表镜像）→ `FormatChanged(true)` → `SetArchiveName2(isSFX)`（换扩展名，cpp:1339-1346,1450-1516） |
| LEVEL | `Get_FormatOptions().ResetForLevelChange()`（清空 method/dict/order/threads/blockLog 记忆，ZipRegistry.h:120-127）→ `SetMethod()`→`SetSolidBlockSize()`→`SetNumThreads()`→`CheckSFXNameChange()`→`SetMemoryUsage()`（cpp:1348-1368） |
| METHOD | `MethodChanged()`→Solid→Threads→SFX 名→内存（cpp:1370-1381）；hash 伪格式还会改档案扩展名（cpp:1377-1378） |
| DICTIONARY | `SaveOptionsInMem()`；若 solid 非 0/64 档则 `Reset_BlockLogSize()`；`SetDictionary2`→`SetSolidBlockSize`→`SetNumThreads`→`SetMemoryUsage`（cpp:1383-1404） |
| ORDER | （仅调试打印）（cpp:1406-1412） |
| SOLID / THREADS | `SetMemoryUsage()`（cpp:1414-1424） |
| MEM_USE | `SaveOptionsInMem()`→`SetNumThreads()`（auto 线程档随限额缩减）→`SetMemoryUsage()`（cpp:1426-1436） |

按钮（`OnButtonClicked`，cpp:586-616）：SET_ARCHIVE→浏览；SFX→`SetMethod(GetMethodID())`+`OnButtonSFX()`（加/去 .exe 后缀）+内存重算；PASSWORD_SHOW→`UpdatePasswordControl`；OPTIONS→模态 COptionsDialog，IDOK 后 `ShowOptionsString()`。

**自动档（auto）计算**（移植需平移的纯算法，全部与 UI 无关）：
- LZMA/LZMA2 默认字典按等级：`level≤4 → 1<<(level*2+16)`，否则 `1<<(level+20)` 封顶（cpp:1941-1945）；档位生成 16KB…4GB 截断 `kLzmaMaxDictSize=15<<28`（cpp:91,1948-1984）。
- PPMd `1<<(level+19)`（cpp:2069）；BZip2 100/500/900KB（cpp:2138-2142）；Deflate 32/64KB（cpp:2128）。
- Order：LZMA 32/64（level<7?32:64，cpp:2242）；Deflate 32/64/128（cpp:2294-2298）；PPMd 4/6/16/32（cpp:2317-2322）；PPMdZip level+3（cpp:2344）。
- Solid 块：xz=lzma2 chunk（`Get_Lzma2_ChunkSize` cpp:2375-2387）；7z LZMA2=cs<<6 (≤16GB)，其它 dict<<7（≥16MB ≤4GB）（cpp:2447-2480）；档位 1MB…64GB + "Non-solid"/"Solid"。
- 线程上限按方法：LZMA=2，LZMA2/xz=512，BZip2=64，zip=32/128，单线程方法=1（cpp:2606-2627）；auto 线程在内存限额内回退（zip 逐档减、LZMA2 按 numThreads1=level≥5?2:1 分组减，cpp:2632-2679）。
- 内存估算 `GetMemoryUsage_Threads_Dict_DecompMem`（cpp:2901-3068）：LZMA hashtable/dict 公式、LZMA2 chunk 模型、PPMd=dict+2MB、BZip2=10MB/线程等；解压内存同步给出。
- MemUse 档位：80%(auto)、10%-100%、128MB…2^(20+sizeof(size_t)*3-1) 字节档（cpp:2811-2853）；`Get_MemUse_Bytes()` 默认返回 `_ramUsage_Auto`（cpp:2865-2876）。

### 2.4 OnOK 校验与产出（cpp:1066-1252）

校验顺序：zip 密码必须 ASCII（IDS_PASSWORD_USE_ASCII）、AES 密码 ≤99（cpp:1069-1085）→ 双密码一致（cpp:1086-1095）→ 内存估算超限弹 `IDS_MEM_OPERATION_BLOCKED` 并拒绝（cpp:1097-1120, 3000 行 `SetErrorMessage_MemUsage` cpp:1046-1063）→ 路径合法（`GetFinalPath_Smart`）→ 分卷表达式合法（`ParseVolumeSizes`，<100KB 需确认 IDS_SPLIT_CONFIRM，cpp:1216-1235）。

产出双向写：(a) `Info`（NCompressDialog::CInfo，CompressDialog.h:31-104）供调用方；(b) `m_RegistryInfo`（NCompression::CInfo）持久化 `Save()`（cpp:1249），含每格式 `CFormatOptions`（level/dict/order/blockLog/threads/method/options/encryptionMethod/memUse/timePrec/tm/tc/ta/ztime，ZipRegistry.h:83-156）与档案路径历史（≤20 条，cpp:86,1241-1247）。

### 2.5 二级选项对话框 COptionsDialog（IDD_COMPRESS_OPTIONS）

控件（CompressOptionsDialog.rc:21-79 + CompressDialogRes.h:100-118）：
- NTFS 组：IDX_COMPRESS_NT_SYM_LINKS/HARD_LINKS/ALT_STREAMS/SECUR（按 `cd->XXX.Supported` 显隐，OnInit cpp:3698-3762）。
- IDX_COMPRESS_PRESERVE_ATIME（"不修改源文件访问时间"）。
- 时间组：时间精度 Combo IDC_COMPRESS_TIME_PREC（档位由 `ai.Get_TimePrecFlags()/Get_DefaultTimePrec()` 生成：Win100ns/Unix1s/DOS2s/1ns/base-prec，`SetPrec` cpp:3482-3581）+ 4 组"set"复选对（MTime/CTime/ATime/SetArcMTime=ZTime，`CBoolBox` 双复选模型：左侧 set 勾选才启用右侧值，cpp:3397-3417,3655-3674）；tar 格式按 GNU/POSIX 限制 c/a 时间，zip 非 Win 精度禁 c/a（`SetTimeMAC` cpp:3584-3651）。
- OnOK 把 5 个 CBool1 写回 `cd->SymLinks…PreserveATime`，时间组写回 `cd->Get_FormatOptions()`（cpp:3797-3816）。

### 2.6 字段 → 7z 接口属性映射（最终落点）

对话框确认后 `UpdateGUI.cpp::ShowDialog()` 读 `dialog.Info` 并改写 `CUpdateOptions`，再由 `SetOutProperties` 生成 **属性名/值对**（最终经 `SetProperties(outArchive, options.MethodMode.Properties)` → `IOutArchive/ISetProperties::SetProperties`，Update.cpp:397；SetProperties.cpp 把字符串转 PROPVARIANT）：

| 对话框字段（控件） | CInfo 字段 | 7z 属性 / CUpdateOptions 落点 | 证据 |
|---|---|---|---|
| Level Combo | `Info.Level` | 属性 `"x"`=N | UpdateGUI.cpp:211-212 |
| Method Combo（非 auto 时） | `Info.Method` | 7z: 属性 `"0"`=LZMA2…；其它格式 `"m"`=Deflate… | UpdateGUI.cpp:215-216 |
| Dictionary Combo | `Info.Dict64` | `"0d"`/`"d"`=Nb；PPMd(OrderMode) 时 `"0mem"`/`"mem"`=Nb | UpdateGUI.cpp:217-224（OrderMode 判定 CompressDialog.cpp:2363-2372） |
| Order Combo | `Info.Order` | OrderMode: `"0o"`/`"o"`=N；否则 `"0fb"`/`"fb"`=N | UpdateGUI.cpp:235-242 |
| Encryption method Combo | `Info.EncryptionMethod`（"AES256"/"ZipCrypto"，去 '-'，非默认项才填） | 属性 `"em"` | CompressDialog.cpp:1810-1820; UpdateGUI.cpp:245-246 |
| Encrypt file names | `Info.EncryptHeaders` | 属性 `"he"`=on/off（仅 EncryptHeadersIsAllowed） | UpdateGUI.cpp:248-249 |
| Solid Combo | `Info.SolidIsSpecified/SolidBlockSize`（log→字节，64=全固实=(UInt64)-1） | 属性 `"s"`=Nb | CompressDialog.cpp:1158-1168; UpdateGUI.cpp:251-252 |
| Threads Combo | `Info.NumThreads` | 属性 `"mt"`=N | UpdateGUI.cpp:254-257 |
| MemUse Combo | `Info.MemUsage`（CMemUse 解析 "80%"/"4g"） | 属性 `"memuse"`=N% 或 Nb | CompressDialog.cpp:1146-1156; UpdateGUI.cpp:259-273 |
| Options 对话框时间复选 | `Info.MTime/CTime/ATime`（CBoolPair） | 属性 `"tm"/"tc"/"ta"`=on/off | UpdateGUI.cpp:275-277 |
| 时间精度 Combo | `Info.TimePrec` | 属性 `"tp"`=N | UpdateGUI.cpp:279-280 |
| Parameters Edit | `Info.Options` 自由串 | `SplitOptionsToStrings`（剥 `-m` 前缀）→ 逐项 name=value 追加；若含方法覆盖（`0=`/`m=`）则跳过 GUI 的 method/dict/order 写入 | UpdateGUI.cpp:141-193, 505-514 |
| Update mode Combo | `Info.UpdateMode` | `options.Commands[0].ActionSet` ← k_ActionSet_{Add,Update,Fresh,Sync} | UpdateGUI.cpp:284-312,486-491 |
| Path mode Combo | `Info.PathMode` | `options.PathMode`（NWildcard::k_RelatPath/k_FullPath/k_AbsPath → 影响 censor 收集） | UpdateGUI.cpp:493 |
| Archive 路径+Format | `Info.ArcPath/FormatIndex` | `options.ArchivePath.ParseFromPath`、`options.MethodMode.Type.FormatIndex` | UpdateGUI.cpp:518-527 |
| 分卷 Combo | `Info.VolumeSizes` | `options.VolumesSizes` | UpdateGUI.cpp:476 |
| SFX 复选 | `Info.SFXMode` | `options.SfxMode=true`；SfxModule 默认 `<exe目录>/7z.sfx`，BaseExtension="exe" | UpdateGUI.cpp:516-526,561-565（kDefaultSfxModule:31） |
| 共享文件复选 | `Info.OpenShareForWrite` | `options.OpenShareForWrite` | UpdateGUI.cpp:513 |
| 压后删除复选 | `Info.DeleteAfterCompressing` | `options.DeleteAfterCompressing` | UpdateGUI.cpp:460 |
| NTFS 4 复选+ATime | `Info.SymLinks/HardLinks/AltStreams/NtSecurity/PreserveATime` | `options` 同名 CBoolPair → Update.cpp 写进 `CArchiveUpdateCallback.Store*` 与 `CDirItems` 扫描开关（**非档案属性**） | UpdateGUI.cpp:462-468; Update.cpp:623,638-642,1381-1394 |
| Set archive mtime（ZTime） | `Info.SetArcMTime` | `options.SetArcMTime` → 输出流 `SetMTime`（Update.cpp:899-900） | UpdateGUI.cpp:466 |
| 密码框 | `Info.Password` | `callback->Password/PasswordIsDefined`（CUpdateCallbackGUI）→ `CryptoGetTextPassword(2)` | UpdateGUI.cpp:496-498 |
| 工作目录（非 UI，注册表） | — | `NWorkDir::CInfo.Load()` → `options.WorkingDir`（临时档案位置） | UpdateGUI.cpp:529-539 |

进入对话框前的反向注入（命令行→UI）：`options.MethodMode.Properties` 中 `tm/tc/ta` 预解析进 di（`ParseProperties`，UpdateGUI.cpp:88-105）；ActionSet→UpdateMode（cpp:446-453）；`-p` 密码、SFX、PathMode、KeepName（单文件压缩时用原名）等（cpp:421-444）。

---

## 3. 解压对话框 CExtractDialog

文件：`CPP/7zip/UI/GUI/ExtractDialog.{h,cpp}`（113+420 行）、`ExtractDialog.rc`、`ExtractDialogRes.h`。被 `ExtractGUI()` 在 `-ad` 时弹出。

### 3.1 控件清单（IDD_EXTRACT，336×168 DLU；rc:28-60）

| 控件 ID | 类型 | 含义 | 落点 |
|---|---|---|---|
| IDC_EXTRACT_PATH (100) | ComboBox(可编辑+历史≤16) | 目标目录 | `DirPath` → `options.OutputDir`（ExtractGUI.cpp:236,249-255） |
| IDB_EXTRACT_SET_PATH (101) | 按钮"..." | 选目录 `MyBrowseForFolder` | ExtractDialog.cpp:276-288 |
| IDX_EXTRACT_NAME_ENABLE (131) + IDE_EXTRACT_NAME (130) | CheckBox+Edit | 追加子目录名（SplitDest：默认拆出档案同名末级目录） | cpp:195-208,373-390 |
| IDC_EXTRACT_PATH_MODE (102) | ComboBox | 路径模式：Full/No/Abs（注意：**无 Relative**；值表 kPathModeButtonsVals） | cpp:33-57 → `PathMode` |
| IDC_EXTRACT_OVERWRITE_MODE (103) | ComboBox | 覆盖模式：Ask/Overwrite/Skip/Rename/RenameExisting | cpp:40-69 → `OverwriteMode` |
| IDX_EXTRACT_ELIM_DUP (3430) | CheckBox | 消除根目录重复 | `ElimDup` |
| IDX_EXTRACT_NT_SECUR (3431) | CheckBox | 还原文件安全描述符（Win 专属） | `NtSecurity` |
| IDE_EXTRACT_PASSWORD (120) + IDX_PASSWORD_SHOW (3803) | Edit(密码)+CheckBox | 密码 | `Password` |
| IDOK/IDCANCEL/IDHELP | 按钮 | help: `fm/plugins/7-zip/extract.htm` | cpp:413-420 |

### 3.2 行为与持久化

- OnInit：标题追加档案名（cpp:139-154）；`_info.Load()`（NExtract::CInfo 注册表）→ 未被命令行强制时采用注册表的 PathMode/OverwriteMode（cpp:170-178）；ElimDup/NtSecurity/ShowPassword 双源合并（`CheckButton_TwoBools`，cpp:113-133）。
- OnOK：读两个 Combo（kCurPaths 特例保留，cpp:302-307），读密码；写回 `_info` 并 `Save()`（含路径历史去重，cpp:315-408）。
- `AddComboItems`/`GetBoolsVal` 与 CompressDialog 共用（cpp:94-119）。

### 3.3 字段→操作层映射（ExtractGUI.cpp:196-255）

dialog.DirPath→`options.OutputDir`（标准化）；OverwriteMode/PathMode/ElimDup→`options.*`；NtSecurity→`options.NtOptions.NtSecurity`；Password→`extractCallback->Password, PasswordIsDefined`。`CExtractOptions` 定义见 UI/Common/Extract.h:26-83；PathMode/OverwriteMode 枚举最终进入 `CArchiveExtractCallback::InitForMulti`（Extract.cpp:336-342）。

---

## 4. 进度窗（CProgressDialog / CProgressSync / CProgressThreadVirt）

文件：`CPP/7zip/UI/FileManager/ProgressDialog2.{h,cpp}`（356+约1500 行）、`ProgressDialog2Res.h`、`ProgressDialog2.rc`。7zG 的压缩/解压/测试/哈希全部复用此窗。

### 4.1 线程模型（移植关键）

- `CProgressThreadVirt::Create(title,parent)`：先 `thread.Create(MyThreadFunction,this)` 起工作线程，再在 GUI 线程 `CProgressDialog::Create(title,thread,parent)` 进模态循环（ProgressDialog2.cpp:1399-1421）。
- 工作线程 `Process()`：`Result=ProcessVirt()`（子类实现真实工作），捕获所有异常→`Sync.FinalMessage`，`CProgressCloser` 析构时 `ProcessWasFinished()`→Post `kCloseMessage(WM_APP+1)` 到 GUI 线程（cpp:30,1432-1475；机制注释 ProgressDialog2.h:269-276,315-353）。
- GUI 收到 kCloseMessage→`OnExternalCloseMessage()`：显示 FinalMessage（OK 或 Error 消息框）、调 `ProcessWasFinished_GuiVirt()`（哈希/测试结果窗的挂接点）、置 `MessagesDisplayed`、关窗。
- 对话框创建延迟 500ms（`kCreateDelay`，cpp:42-48）：短任务不闪进度窗；`WaitCreating()` 供回调在弹子对话框（覆盖/密码）前确保进度窗已建（ExtractCallback.cpp:218,692）。

### 4.2 共享状态 CProgressSync（互斥+轮询，无消息推送）

字段：`_stopped/_paused/_totalBytes/_completedBytes/_totalFiles/_curFiles/_inSize/_outSize/_titleFileName/_status/_filePath/Messages/FinalMessage` + CriticalSection（ProgressDialog2.h:32-103）。
- 工作线程经 `Set_NumBytesCur/Set_NumFilesCur/Set_Ratio/Set_Status2/ScanProgress/AddError_*` 写入；每次写入内嵌 `CHECK_STOP`。
- **暂停实现**：`CheckStop()` 在 `_paused` 时循环 `Sleep(100)`（`kPauseSleepTime=100`，cpp:49,100-110）——工作线程被动停在下一次回调。
- GUI 线程 `SetTimer(kTimerID=3, kTimerElapse=200ms)`（cpp:28-39,422）周期调 `UpdateStatInfo`。

### 4.3 控件与统计显示

控件 ID（ProgressDialog2Res.h）：进度条 IDC_PROGRESS1、消息 ListView IDL_PROGRESS_MESSAGES、文件名/状态 IDT_PROGRESS_FILE_NAME/STATUS、统计对 Elapsed/Remaining/Files/Errors/Total/Speed/Processed/Packed/Ratio（…_VAL 120-126/110-112）、按钮 IDB_PROGRESS_BACKGROUND(444)/IDB_PAUSE(446)/IDCANCEL。
- `UpdateStatInfo`（cpp:695-940）：经过时间=GetTickCount 累计（暂停期不计，OnPauseButton 里结转 `_elapsedTime`，cpp:1130-1140）；剩余时间=`(total-completed)*elapsed/completed`（cpp:782-799）；**速率**=`completed*1000/elapsed` 带 KB/MB/GB 位移显示（cpp:801-825）；Ratio=`packed*100/unpack`（cpp:884-895）；压缩模式与解压模式 in/out 角色互换（`CompressingMode`，ExtractGUI.cpp:282 置 false）；百分比进 Win7 任务栏 `ITaskbarList3->SetProgressValue`（h:177-208）与窗口标题（cpp:1085-1122）。
- 标题格式：`[暂停] N% [后台] 主标题 文件名`（cpp:1085-1122）。

### 4.4 暂停 / 后台 / 取消

| 按钮 | 行为 | 证据 |
|---|---|---|
| IDB_PAUSE | `Sync.Set_Paused(!paused)`，按钮文本 Pause↔Continue（IDS_CONTINUE 411），暂停时任务栏置黄 | cpp:1124-1140,1286-1288 |
| IDB_PROGRESS_BACKGROUND | `_background=!_background; SetPriorityClass(GetCurrentProcess(), IDLE_PRIORITY_CLASS/NORMAL_PRIORITY_CLASS)`，文本 Background↔Foreground（IDS_PROGRESS_FOREGROUND 445） | cpp:1142-1157,1289-1291 |
| IDCANCEL | 先自动暂停→`MessageBoxW(IDS_PROGRESS_ASK_CANCEL 448, MB_YESNOCANCEL)`→YES 则 `_cancelWasPressed`，OnCancel 里 `Sync.Set_Stopped(true)`；期间若收到 kCloseMessage 再补处理 | cpp:1240-1284 |

错误消息：`AddError_Message/AddError_Code_Name` 进 `Sync.Messages`，GUI 每拍搬进 ListView（`UpdateMessagesDialog`），出现错误时窗口拉大显示错误区（`EnableErrorsControls`，cpp:334-335）；支持全选复制剪贴板（`CopyToClipboard`，h:219）。

---

## 5. 覆盖确认对话框 COverwriteDialog

文件：`CPP/7zip/UI/FileManager/OverwriteDialog.{h,cpp,rc}`。
- 数据：`OldFileInfo/NewFileInfo`（`NOverwriteDialog::CFileInfo`：Path/Size?/FILETIME?/是否文件系统文件→决定图标，OverwriteDialog.h:13-55,71-77）。
- 按钮→`NOverwriteAnswer`：IDYES/IDNO/IDB_YES_TO_ALL/IDB_NO_TO_ALL/IDB_AUTO_RENAME/IDCANCEL → kYes/kNo/kYesToAll/kNoToAll/kAutoRename/kCancel（枚举 UI/Common/IFileExtractCallback.h:22-33）。
- 唯一调用点（7zG 内）：`CExtractCallbackImp::AskOverwrite`：`ProgressDialog->WaitCreating(); dialog.Create(*ProgressDialog)`，CANCEL→`E_ABORT`（FileManager/ExtractCallback.cpp:201-232）。AskOverwrite 由操作层 `CArchiveExtractCallback` 在 `OverwriteMode==kAsk` 且目标存在时发起（经 IFolderArchiveExtractCallback COM 接口，IFileExtractCallback.h:54-63）；`AskWrite`（FM 复制路径）亦复用（ExtractCallback.cpp:710-806）。

## 6. 密码对话框 CPasswordDialog

文件：`CPP/7zip/UI/FileManager/PasswordDialog.{h,cpp,rc}`：单 Edit + ShowPassword 复选（PasswordDialog.h:11-26）。
- 解压侧：`CExtractCallbackImp::CryptoGetTextPassword`——未预设密码时弹窗（读/写注册表 ShowPassword 偏好 `NExtract::Read_ShowPassword/Save_ShowPassword`），取消→E_ABORT；打开档案时 `Open_CryptoGetTextPassword` 复用同函数（ExtractCallback.cpp:683-704,151-153）。
- 压缩/更新侧：`CUpdateCallbackGUI2::ShowAskPasswordDialog`（UpdateCallbackGUI2.cpp:52-61），由 `CryptoGetTextPassword2` 在 `AskPassword`（命令行 `-p` 无值）时触发（UpdateCallbackGUI.cpp:164-184）。
- 压缩对话框自身的密码框是另一套（§2 控件，非本对话框）。

## 7. 错误与消息框体系

| 机制 | 内容 | 证据 |
|---|---|---|
| Explorer/MyMessages | `ShowErrorMessage(HWND,LPCWSTR)`/`ShowErrorMessageHwndRes`/`ShowLastErrorMessage`——MessageBoxW 包装，GUI/Common 两层广泛使用 | UI/Explorer/MyMessages.h:1-16 |
| GUI.cpp 顶层 | `ErrorMessage/ErrorLangMessage/ShowSysErrorMessage/ShowMemErrorMessage`，受 `g_DisableUserQuestions` 抑制 | GUI.cpp:99-129 |
| HResultToMessage | HRESULT→本地化串（E_OUTOFMEMORY→IDS_MEM_ERROR） | ProgressDialog2.cpp:1477-1485 |
| 进度窗内错误列表与 FinalMessage | §4.4 | — |
| 打开结果诊断 | `OpenResult_GUI(s, codecs, arcLink, name, result)`（拼"无法以该类型打开/偏移打开/加密档案"等，资源 IDS_CANT_OPEN_*、IDS_IS_OPEN_*，ExtractRes.h:5-19） | UpdateCallbackGUI.cpp:29-42; ExtractCallback.cpp（OpenResult 同名实现） |
| 解压条目错误文案 | `SetExtractErrorMessage(opRes, encrypted, name)`：UnsupportedMethod/DataError/CRC/Unavailable/UnexpectedEnd/…（IDS_EXTRACT_MSG_*, ExtractRes.h:30-48） | UpdateCallbackGUI.cpp:146-157 |
| Hash/测试结果窗 | `CListViewDialog`（名称/值两列，可复制）`ShowHashResults`；测试 OK 走 FinalMessage.OkMessage（"There are no errors"） | HashGUI.cpp:310-341; ExtractGUI.cpp:94-99,128-159 |
| 内存请求确认 | `CMemDialog`（IArchiveRequestMemoryUseCallback 路径，超限弹窗） | ExtractCallback.cpp:29,1012+；makefile:117 |

## 8. 基准测试 GUI（CBenchmarkDialog）

文件：`CPP/7zip/UI/GUI/BenchmarkDialog.{h,cpp}`（15+1921 行）、`BenchmarkDialogRes.h`、`BenchmarkDialog.rc`。

- 入口 `Benchmark(EXTERNAL_CODECS props, numIterations, hwndParent)`（BenchmarkDialog.h:11-13, cpp:1820-1907）：解析 `-mm=*`→TotalMode（文本控制台式输出 IDD_BENCH_TOTAL/IDE_BENCH2_EDIT）、`mt`→线程、字典/level 从 props；GUI.cpp:227-243 直接调用；7zFM 菜单经 CompressCall `b -mm=*`。
- 双线程：`CThreadBenchmark::Process`（cpp:1600+）在工作线程跑 `Bench()`（UI/Common/Bench.cpp:3759，核心已随 7zz mac 验证），传入三个回调：`CBenchCallback`(IBenchCallback: SetTotal/SetCompleted/进度)、`CBenchCallback2`(IBenchPrintCallback: Print/NewLine/CheckBreak，cpp:1493-1523)、`CFreqCallback`(IBenchFreqCallback: CPU 频率测量，cpp:1527-1578)。
- 同步体 `CBenchProgressSync`（cpp:159-218）：CS + `Exit` 停止旗标 + `NumThreads/DictSize/NumPasses_Limit/Level` 参数 + `RatingVector`（逐 pass 成绩）+ `CSyncData`（Enc/Dec 当前与累计 `CTotalBenchRes2`、NeedPrint_* 脏标记，cpp:100-156）。
- GUI 侧：1 秒级 OnTimer + `k_Message_Finished`(PostMsg) 双驱动刷新（cpp:1240+,355-361）；控件：字典 IDC_BENCH_DICTIONARY、线程 IDC_BENCH_NUM_THREADS、遍数 IDC_BENCH_NUM_PASSES 三个 Combo（CBN_SELCHANGE 即 `RestartBenchmark`，cpp:1390-1400）、Stop/Restart 按钮（IDB_STOP=442/IDB_RESTART=443，cpp:1404-1415）、压缩/解压两组 Speed/Rating/Usage/RPU 当前+累计文本（Res.h:110-125）、总评 Rating/RPU/Usage（130-133）、CPU/系统信息行（105-109）。
- 启动前内存检查 `GetBenchMemoryUsage`+`IsMemoryUsageOK`（RamSize_Limit），超限弹 `SetErrorMessage_MemUsage`（与压缩对话框共用该函数，cpp:857-895）。
- 退出：OnCancel 置 `Sync.SendExit()` 等线程结束（`Disable_Stop_Button/OnStopButton` cpp:936-945）。

---

## 9. UI/Common 操作层逐文件清单与复用性

判定标准：A=已含于 7zz mac 构建（Alone2 makefile.gcc:48-68），逻辑+编译双验证，可直接复用；B=不在 7zz 构建但代码与平台无关（含 `#ifndef _WIN32` 分支），预期可直接编译复用；C=Windows 专属，需替换/重写。

| 文件（.cpp/.h） | 行数(cpp) | 职责 | 关键入口/类型 | 7zG 角色 | mac 复用性 |
|---|---|---|---|---|---|
| ArchiveCommandLine | 1913 | 命令行→`CArcCmdLineOptions`（命令/开关/censor） | `CArcCmdLineParser::Parse1/Parse2`（ArchiveCommandLine.h:161-168） | GUI.cpp 直接用 | **A**；注意 `#` 文件映射解析仅 `_WIN32`（cpp:634,833-836）；含 POSIX 分支（cpp:1875-1913） |
| ArchiveExtractCallback | 3077 | 解压执行核心 COM 回调（建目录/写文件/时间戳/属性/符号链接/owner） | `CArchiveExtractCallback`: IArchiveExtractCallback+ICryptoGetTextPassword+ICompressProgressInfo…（ArchiveExtractCallback.h:330-363）；POSIX owner/attrib 支持（h:243-299） | Extract() 内部创建，回呼 IFolderArchiveExtractCallback | **A** |
| ArchiveOpenCallback | 398 | 打开档案 COM 回调（分卷、密码、进度），包装 `IOpenCallbackUI` | `COpenCallbackImp`（h:97-121）；非 COM 接口 `IOpenCallbackUI`（h:33-40） | `CArchiveLink::Open2` 创建（OpenArchive.cpp:3397-3407） | **A** |
| Bench | 5031 | 基准测试核心（含 CPU 频率、rating 计算） | `Bench()`（Bench.h:100）；回调 IBenchCallback/IBenchPrintCallback/IBenchFreqCallback | BenchmarkDialog 工作线程调用 | **A** |
| CompressCall | 343 | **7zFM→7zG 进程派生协议**（见 §11） | `CompressFiles/ExtractArchives/TestArchives/CalcChecksum/Benchmark/Call7zGui` | 7zG 不链接；7zFM/Explorer 链接 | **C**（CProcess/CFileMapping/CManualResetEvent 均 Win32；进程内化后整体废弃） |
| CompressCall2 | 327 | 同 API 的**进程内实现**（`#ifndef Z7_EXTERNAL_CODECS` 才编译） | 直接调 UpdateGUI/ExtractGUI/HashCalcGUI/Benchmark（cpp:5,13-16,90-325） | 单体 FM 构型使用 | **B**（去 Win 化后即 macOS 方案 B 的范本） |
| DefaultName | 40 | 由档案名推默认输出名 | `GetDefaultName2` | Extract 用 | **A** |
| EnumDirItems | 1637 | 目录枚举（censor 过滤、链接、安全描述符、进度回调） | `EnumerateItems/EnumerateDirItemsAndSort`（EnumDirItems.h:11-32）；`ConvertToLongNames` 仅 _WIN32（h:34-36） | Update 扫描、GUI.cpp 档案列表展开 | **A** |
| Extract | 583 | 多档案解压编排（统计、跳过、错误聚合） | `Extract()`（Extract.h:101-116）、`CExtractOptions`（h:26-83）、`CDecompressStat` | CThreadExtracting::ProcessVirt 调用 | **A** |
| ExtractingFilePath | 296 | 落盘路径净化（非法字符/保留名/绝对路径剥离） | `Correct_FsPath/MakePathFromParts` 等 | ArchiveExtractCallback 用 | **A** |
| HashCalc | 2273 | 哈希计算编排+hash 伪档案 handler | `HashCalc()`、`CHashBundle/IHashCalc`（HashCalc.h:71-109）、`IHashCallbackUI`（h:115+） | HashGUI 工作线程调用 | **A** |
| LoadCodecs | 1353 | 格式/编解码器注册表：内置或外置 dll 扫描 | `CCodecs::Load()`、`LoadDll`(cpp:565)、`CArcInfoEx`（Flags_* LoadCodecs.h:144-166） | 所有入口先 Load | **A**（内置模式已验证）；**外置模式（Z7_EXTERNAL_CODECS）非 Windows 主库名为 `7z.so`（cpp:72-77），但依赖 `GetModuleDirPrefix` 解析程序目录（cpp:206）——该函数 POSIX 未实现，见风险表** |
| OpenArchive | 3702 | 档案打开/类型探测/父子链（CArc/CArchiveLink） | `CArchiveLink::Open2/Open_Strict`（cpp:3397+）、`COpenType`、`ParseOpenTypes` | Extract/Update/GUI 公用 | **A** |
| PropIDUtils | 745 | PROPID→显示串（权限、时间、CRC…） | `ConvertPropertyToString2` 等 | GUI 结果显示用 | **A** |
| SetProperties | ~120 | 属性名值对→PROPVARIANT→`ISetProperties::SetProperties` | `SetProperties(IUnknown*, CObjectVector<CProperty>&)`（cpp:1-40+） | Update.cpp:397 调用 | **A** |
| SortUtils | ~60 | 文件名排序 | `SortFileNames`（SortUtils.h:8） | Extract 排序 | **A** |
| TempFiles | ~40 | 临时文件集合自动清理 | `CTempFiles`（TempFiles.h:8-19） | Update（email 模式等） | **A** |
| Update | 1931 | 更新/压缩编排：枚举→配对→produce→Compress→分卷/SFX/MoveArc | `UpdateArchive()`（Update.h:210-219）、`CUpdateOptions`（h:80-157）、`IUpdateCallbackUI2`（h:189-207）；内部 `Compress()`(cpp:347)、EnumerateItems(cpp:1397)、GetUpdatePairInfoList/UpdateProduce(cpp:534-537)、CArchiveUpdateCallback(cpp:620-642)、MoveArc 回调(cpp:1644-1682) | CThreadUpdating::ProcessVirt 调用 | **A** |
| UpdateAction | ~70 | 4 组动作集常量（Add/Update/Fresh/Sync 的 NPairAction 矩阵） | `NUpdateArchive::k_ActionSet_*` | UpdateGUI 模式映射 | **A** |
| UpdateCallback | 1069 | 更新执行 COM 回调（读源文件/汇报/密码） | `CArchiveUpdateCallback`（UpdateCallback.h:78-115）、非 COM `IUpdateCallbackUI`（h:33-60） | Update() 内部创建，回呼 IUpdateCallbackUI2 | **A** |
| UpdatePair | 302 | 磁盘项 vs 档案项配对（按名+时间） | `GetUpdatePairInfoList` | Update 内部 | **A** |
| UpdateProduce | ~80 | 配对+动作集→操作表（压入/复制/删除） | `UpdateProduce()`、`IUpdateProduceCallback` | Update 内部 | **A** |
| WorkDir | ~100 | 工作目录策略+临时文件→`MoveToOriginal` | `GetWorkDir`、`CWorkDirTempFile`（WorkDir.h:12-28） | UpdateGUI.cpp:529-539 | **B**（仅依赖 FileDir/FileStreams 可移植层；7zz 未含但无 Win 专属 API） |
| ZipRegistry | 599 | **GUI 设置持久化**（压缩档案历史/每格式参数/解压偏好/工作目录/右键菜单） | `NCompression::CInfo`、`NExtract::CInfo`、`NWorkDir::CInfo`、`CContextMenuInfo`（ZipRegistry.h:23-210） | Compress/Extract 对话框读写 | **C**（实现层全部 `HKEY_CURRENT_USER` 注册表，cpp:11,27-35；接口层平台无关——重写 .cpp 为 plist/NSUserDefaults 即可，键集见 §2.4/§3.2） |
| ArchiveName | 176 | 由选中路径生成默认档案名 | `CreateArchiveName`（ArchiveName.h:10-14） | 7zFM/右键菜单用（7zG 不链） | **B** |
| 头文件-only：DirItem.h(407)/ExtractMode.h/IFileExtractCallback.h/Property.h/ExitCode.h/UpdateAction.h… | — | `CDirItems`+`IDirItemsCallback`（扫描回调）、`NExtract::NPathMode/NOverwriteMode`、`IFolderArchiveExtractCallback(2)`/`IExtractCallbackUI`、CProperty、退出码 | — | 接口契约层 | **A**（随上述 .cpp 验证） |

---

## 10. GUI 层 ↔ UI/Common 层调用关系（谁调谁、经哪些回调）

### 10.1 三条主流水线

```
[解压/测试]
GUI.cpp:Main2 ──ExtractGUI()──> CExtractDialog(-ad 时) 
   └→ CThreadExtracting(CProgressThreadVirt 子类).Create()
        工作线程 ProcessVirt() ──> UI/Common Extract()           (ExtractGUI.cpp:101-126)
             Extract() ─创建→ CArchiveExtractCallback (COM)      (Extract.cpp:331)
             Extract() ─打开→ CArchiveLink::Open_Strict ─创建→ COpenCallbackImp (OpenArchive.cpp:3397-3407)
        回调向上：COpenCallbackImp →(IOpenCallbackUI)→ CExtractCallbackImp
                  CArchiveExtractCallback →(IFolderArchiveExtractCallback[2]/COM)→ CExtractCallbackImp
                  Extract() →(IExtractCallbackUI 非COM)→ CExtractCallbackImp
        CExtractCallbackImp → ProgressDialog->Sync.*（进度/错误） / COverwriteDialog / CPasswordDialog / CMemDialog

[压缩/更新]
GUI.cpp:Main2 ──UpdateGUI()──> ShowDialog()→CCompressDialog(-ad 时)  (UpdateGUI.cpp:315-541)
   └→ CThreadUpdating.Create()
        工作线程 ProcessVirt() ──> UI/Common UpdateArchive()      (UpdateGUI.cpp:51-62)
             UpdateArchive() → EnumerateItems(censor)             (Update.cpp:1397)
                            → GetUpdatePairInfoList/UpdateProduce (Update.cpp:534-537)
                            → Compress(): CArchiveUpdateCallback (COM, Update.cpp:620)
                            → SetProperties(outArchive, props)    (Update.cpp:397)
                            → MoveArc_Start/Progress/Finish       (Update.cpp:1644-1682)
        回调向上：CArchiveUpdateCallback →(IUpdateCallbackUI 非COM)→ CUpdateCallbackGUI
                  COpenCallbackImp →(IOpenCallbackUI)→ CUpdateCallbackGUI
                  扫描 →(IDirItemsCallback)→ CUpdateCallbackGUI (ScanProgress/ScanError)
        CUpdateCallbackGUI → ProgressDialog->Sync.* / CPasswordDialog(ShowAskPasswordDialog)

[哈希]
GUI.cpp:Main2 ──HashCalcGUI()──> CHashCallbackGUI(CProgressThreadVirt+IHashCallbackUI)
        工作线程 ProcessVirt() ──> UI/Common HashCalc()           (HashGUI.cpp:273-280)
        结束后 GUI 线程 ProcessWasFinished_GuiVirt() → ShowHashResults(CListViewDialog) (HashGUI.cpp:337-341)

[基准]
GUI.cpp:Main2 ──Benchmark()──> CBenchmarkDialog + CThreadBenchmark ──> UI/Common Bench()
        回调：IBenchCallback/IBenchPrintCallback/IBenchFreqCallback → CBenchProgressSync (BenchmarkDialog.cpp:1493-1578)
```

### 10.2 回调接口矩阵（GUI 实现方 × 接口 × 定义处）

| GUI 实现类 | 实现的接口 | 接口定义 | 被谁调用 |
|---|---|---|---|
| CExtractCallbackImp（FileManager/ExtractCallback.h:181-227） | IFolderArchiveExtractCallback(2)（COM）、IExtractCallbackUI、IOpenCallbackUI、IFolderOperationsExtractCallback、IFolderExtractToStreamCallback、ICompressProgressInfo、IArchiveRequestMemoryUseCallback、ICryptoGetTextPassword | UI/Common/IFileExtractCallback.h:54-108；ArchiveOpenCallback.h:33-40 | CArchiveExtractCallback / Extract() / COpenCallbackImp |
| CUpdateCallbackGUI（GUI/UpdateCallbackGUI.h:11-29） | IOpenCallbackUI、IUpdateCallbackUI、IDirItemsCallback、IUpdateCallbackUI2 | UpdateCallback.h:33-60；Update.h:189-207；DirItem.h（IDirItemsCallback） | UpdateArchive()/CArchiveUpdateCallback/COpenCallbackImp |
| CUpdateCallbackGUI2（基类，GUI/UpdateCallbackGUI2.h:8-51） | 进度桥（SetOperation_Base→Sync.Set_Status2；MoveArc_*→百分比状态行；ShowAskPasswordDialog） | — | CUpdateCallbackGUI 各方法转发（UpdateCallbackGUI.cpp:123-126,159-162,256-267） |
| CHashCallbackGUI（GUI/HashGUI.cpp:25-56） | IHashCallbackUI、IDirItemsCallback | HashCalc.h:115+ | HashCalc() |
| CThreadExtracting/CThreadUpdating/CHashCallbackGUI | CProgressThreadVirt::ProcessVirt + ProcessWasFinished_GuiVirt | ProgressDialog2.h:292-311 | 进度窗框架 |

**进度数据通道唯一**：所有工作线程状态都写 `ProgressDialog->Sync`（CProgressSync），GUI 定时拉取——该模式天然适配"ObjC++ 桥接 + 主线程 NSTimer 拉取"，无需引入消息泵。

### 10.3 GUI 对 FileManager 头的依赖（移植时的"第三目录"耦合）

CompressDialog.cpp 包含 FileManager 的 BrowseDialog/FormatUtils/HelpUtils/PropertyName/SplitUtils/resourceGui/LangUtils（cpp:16-33）；ExtractGUI/UpdateGUI/HashGUI 依赖 ExtractCallback/LangUtils/resourceGui/ProgressDialog2/ListViewDialog（各文件 include 段）。即：**7zG 移植无法只动 GUI+Common 两目录，必须连带 FileManager 中 §0 FM_OBJS 列出的 19 个文件**。

---

## 11. 7zG 进程模型与 7zFM 唤起协议

### 11.1 协议全貌（UI/Common/CompressCall.cpp —— 7zFM/Explorer 侧）

- 可执行体：`<7zFM所在目录>/7zG.exe`（`#define k7zGui "7zG.exe"`，cpp:34；`Call7zGui` 用 `NDLL::GetModuleDirPrefix()+k7zGui` 经 `CProcess::Create` 启动，cpp:74-98）。
- **文件清单传递不走命令行**：`CreateMap`（cpp:121-184）建命名共享内存 `7zMap<rand>`（首 wchar=0 作格式标记 + 以 NUL 分隔的 UTF-16 路径序列）和命名事件 `7zEvent<rand>`，拼成参数 `#7zMapNNN:size:7zEventNNN`，挂在 `-i`/`-ai` 开关后。
- 等待语义：`waitFinish` 时 `process.Wait()`；否则 `WaitForMultipleObjects({process, event})`——7zG 解析完清单即 set 事件（`CEventSetEnd` 析构，ArchiveCommandLine.cpp:636-647），7zFM 才释放映射并返回（cpp:90-96）。
- 7zG 侧解析：`kMapNameID '#'`（ArchiveCommandLine.cpp:248）→ `ParseMapWithPaths`（cpp:651-704）打开映射读路径进 censor；**该分支仅 `#ifdef _WIN32`**（cpp:634,833-836）。

各操作命令行模板（cpp:186-343）：

| FM API | 7zG 命令行 |
|---|---|
| CompressFiles | `a -i#<map> [-t<type>] [-seml.] [-ad] [-slp] [-an] (-saa|-sae) -- "<arcPath>"`（cpp:195-239） |
| ExtractArchives | `x [-o"<dir>"] [-spe] [-snz<N>] [-ad] -an -ai#<map>`（cpp:255-275） |
| TestArchives | `t [-thash] -an -ai#<map>`（cpp:278-289） |
| CalcChecksum | `h [-scrc<method>] -i#<map>`；带输出文件时转 CompressFiles type=hash（cpp:292-330） |
| Benchmark | `b [-mm=*] [-slp]`（cpp:332-343） |

调用点：7zFM `Panel.cpp:946(CompressFiles)/1034(ExtractArchives)/1176(TestArchives)`、`MyLoadMenu.cpp:798-802(Benchmark)`、拖拽 `PanelDrag.cpp:2869`；Explorer 右键菜单 `ContextMenu.cpp:1285/1294/1333/1363/1380`——**Explorer 集成与 7zFM 走完全相同的 5 个 API**。

### 11.2 进程内化先例：CompressCall2.cpp

当 FM 以"无外置 codecs"单体构型编译（`#ifndef Z7_EXTERNAL_CODECS`，cpp:5），同名 5 个 API 换为**同进程直调**：`CompressFiles→UpdateGUI(...)`、`ExtractArchives/TestArchives→ExtractGUI(...)`、`CalcChecksum→HashCalcGUI(...)`、`Benchmark→Benchmark(...)`，父窗为全局 `g_HWND`（cpp:22,90-325）。upstream 已维护这条路径——**macOS 方案 B 应以 CompressCall2 为蓝本（FM 链接 GUI 9 文件，去 IPC），而非移植 CompressCall 的 Win32 IPC**。

### 11.3 进程内化（mac 单 App）影响清单

| 影响面 | 7zG 双进程现状 | 进程内化后果与对策 | 证据 |
|---|---|---|---|
| 进程级全局 | `g_HWND`、`g_DisableUserQuestions`、`g_ExternalCodecs_Ptr`、`g_hInstance`、Lang 单次加载 | 原"每操作一进程"使全局=每操作私有；同进程并发多操作（FM 允许同时多个压缩）会互相踩踏 → 需 per-operation context 或操作串行化 | GUI.cpp:40-51,416,435; CompressCall2.cpp:22 |
| 退出码语义 | NExitCode 经进程退出码回传（FM 仅在 waitFinish 时关心） | 变为函数返回值/NSError；E_ABORT→用户取消需静默 | GUI.cpp:456-460; ExitCode.h:8-24 |
| 后台按钮 | `SetPriorityClass(GetCurrentProcess(), IDLE_PRIORITY_CLASS)` 只降 7zG 自身 | 同进程会把整个 FM 降速 → 必须改为 per-thread QoS（工作线程 `QOS_CLASS_BACKGROUND`） | ProgressDialog2.cpp:1150-1157 |
| 崩溃隔离 | 7zG 崩溃不影响 FM | 失去隔离；要么接受（7zz 核心稳定），要么对超大任务保留 XPC/子进程选项 | — |
| 当前目录 | 解压默认输出=7zG 进程 cwd | 同进程 cwd 共享且 GUI App cwd 通常为 "/" → 必须显式传 outFolder（FM 调用本就传，ContextMenu 也传） | ExtractGUI.cpp:198-201 |
| 文件清单 IPC | #7zMap 共享内存 | 直接传 `UStringVector`，协议整体删除 | CompressCall.cpp:121-184 |
| 大页/低碎片开关 `-slp` | 进程启动早期生效 | mlock 特权 mac 不适用，删除 | CompressCall.cpp:100-107 |
| 模态进度窗 | 每进程一个模态循环 | 同进程多操作需多个非模态窗口/sheet；CProgressDialog 本身按实例设计，可多开，但其 `WaitCreating` 握手与模态 Create 需改为窗口控制器生命周期 | ProgressDialog2.h:260-266; cpp:1412-1421 |

---

## 12. 移植映射建议（结构性结论）

1. **可整体平移的纯逻辑**（不碰 AppKit）：§2.3 全部 auto 档/内存估算算法、g_Formats 能力表、SetOutProperties 属性合成、ExtractDialog 的枚举映射表、CProgressSync、CBenchProgressSync —— 建议抽成无 UI 的 "ParamsModel/ProgressModel" C++ 类，ObjC++ 仅做控件绑定。
2. **必须重写的 Win32 面**：`NWindows::NControl::CModalDialog/CComboBox/CEdit/CListView`（Windows/Control/*）、.rc 布局、MessageBoxW、SetTimer/PostMsg、ITaskbarList3（→NSProgressIndicator/dock）、SetPriorityClass（→QoS）、HtmlHelp（→帮助 URL）。
3. **持久化**：ZipRegistry.h 的四个结构（NCompression::CInfo / NExtract::CInfo / NWorkDir::CInfo / CContextMenuInfo）接口保留，.cpp 以 plist 重写；键集与默认值已在 §2.4/§3.2 列明。
4. **dylib 装载**：保留 Z7_EXTERNAL_CODECS 路径（Format7zF → `7z.so`/`.dylib`，LoadCodecs.cpp:72-77 已有非 Win 名称），需补 POSIX `GetModuleDirPrefix`（见风险 R2），或改为传入显式 bundle 路径。

---

## 13. 风险登记（详细版）

| # | 风险 | 证据 | 缓解 |
|---|---|---|---|
| R1 | ZipRegistry.cpp 全量依赖 Windows 注册表（HKEY_CURRENT_USER），7zz 从未在 mac 编译过该文件 | ZipRegistry.cpp:11,27-35 | 按 ZipRegistry.h 接口以 NSUserDefaults/plist 重写（≈600 行）；键名沿用以便文档化 |
| R2 | Z7_EXTERNAL_CODECS（外置 7z 动态库）在 POSIX 链路断点：`NDLL::GetModuleDirPrefix/MyGetModuleFileName` 仅有 `_WIN32` 实现，而 LoadCodecs.cpp:206 无条件调用 | Windows/DLL.cpp:7-113（_WIN32 段）、DLL.h:97-99（无守卫声明）、DLL.cpp:113-176（POSIX 段无此函数） | 用 `dladdr`/`_NSGetExecutablePath` 补实现；7zz 之所以没踩坑是因为其不开 Z7_EXTERNAL_CODECS |
| R3 | `#7zMap` 共享内存 + 命名事件协议是 `_WIN32`-only；若 mac 仍想保留双进程模式需自建 IPC | ArchiveCommandLine.cpp:634-704,833-836; CompressCall.cpp:121-184 | 方案 B 进程内化（CompressCall2 蓝本）直接绕开 |
| R4 | 对话框联动逻辑与 Win32 控件 API 深度交织（CCompressDialog 3821 行中估算/联动可平移，但每条链以 CBN_SELCHANGE/CheckButton/EnableItem 表达） | CompressDialog.cpp:1313-1440 等 | 先抽 ParamsModel（纯函数）再绑 AppKit；联动矩阵已在 §2.3 完整登记，照表回放 |
| R5 | worker→GUI 的阻塞式子对话框（AskOverwrite/密码/MemDialog 在工作线程经 WaitCreating 后直接 `dialog.Create(*ProgressDialog)`）在 AppKit 必须改为 dispatch 到主线程+信号量回传，易引入死锁 | ExtractCallback.cpp:218-219,692-695; UpdateCallbackGUI2.cpp:52-61 | 桥接层提供同步回调注入点（block + dispatch_semaphore），保持"工作线程阻塞等答案"的语义 |
| R6 | 进程内化使 7zG 的进程级全局（g_HWND/g_DisableUserQuestions/语言单例/SetPriorityClass/cwd）变成共享态，并发操作互相污染 | GUI.cpp:46-51,416-435; ProgressDialog2.cpp:1150-1157 | per-operation context；后台按钮改 thread QoS；输出目录全部显式传参 |
| R7 | 进度窗依赖 200ms 定时拉取 + 暂停 Sleep(100) 轮询；mac 上可平移但 ITaskbarList3、GetTickCount、SetTimer 需逐一替换 | ProgressDialog2.cpp:28-49,100-110,422 | NSTimer + mach_absolute_time；NSProgress 暴露给 dock |
| R8 | Windows 专属功能项需要决策（隐藏/禁用）：SFX(.exe+7z.sfx)、NTFS AltStreams/NtSecurity 复选、共享文件(-ssw)、大页(-slp)、Email(-seml MAPI)、ZoneId(-snz) | CompressDialog 控件 §2.1；UpdateGUI.cpp:561-565；CompressCall.cpp:100-107,208-209,266-270 | mac 版置 Supported=false 走既有显隐逻辑（FormatChanged 已按 Flags 控制，改动极小）；符号链/硬链在 POSIX 反而原生支持 |
| R9 | 帮助/本地化：ShowHelpWindow(htmlhelp)、Z7_LANG 的 .txt 语言文件加载（LoadLangOneTime） | CompressDialog.cpp:1254-1260; GUI.cpp:434-436 | 帮助跳 web；Lang 机制可保留（纯文件解析）或换 NSLocalizedString，二选一需评审 |
| R10 | FileManager 三方耦合：7zG 必须连带 FileManager 19 文件（进度/覆盖/密码/浏览/Lang/资源串），这些文件同样满是 Win32 | GUI/makefile:110-131; CompressDialog.cpp:16-33 | 该 19 文件清单已锁定（§0），作为移植批次一并排期，避免后期发现隐藏依赖 |
| R11 | BrowseDialog（保存/选目录）在 mac 应换 NSSavePanel/NSOpenPanel，但 CompressDialog 的"按格式过滤器+自动补扩展名"逻辑（OnButtonSetArchive 130 行）依赖过滤器索引回传 | CompressDialog.cpp:879-1012 | NSSavePanel allowedContentTypes + accessory view 重建；格式↔扩展名映射用 CArcInfoEx.Exts 原数据 |
| R12 | 7zG 命令行协议若需兼容（mac 上第三方脚本唤起），SplitCommandLine(GetCommandLineW) 需改 argv 直传；`-ad` 等开关解析本身可复用 | GUI.cpp:139-150 | 进程内化后保留 ArchiveCommandLine 仅服务于调试入口 |

---

## 附：证据密度说明

本清单引用的行号基于当前仓库（26.01，commit 8c63d71）。CompressDialog/ExtractDialog/ProgressDialog2/BenchmarkDialog/GUI/UpdateGUI/ExtractGUI/HashGUI/UpdateCallbackGUI(2)/CompressCall(2)/ArchiveCommandLine/LoadCodecs/Update/Extract/OpenArchive/ZipRegistry/DLL 等文件均经直接核读；UI/Common 的 A 类文件复用性结论同时由 `Bundles/Alone2/makefile.gcc:48-68`（mac 已验证构建清单）与源码 `#ifdef` 双重确认。
