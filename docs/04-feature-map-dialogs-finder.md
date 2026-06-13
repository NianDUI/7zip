# 04 — 7zG 对话框与 Finder 集成映射

> 一对一移植方案（方案B：核心 dylib + ObjC++ 桥接 + AppKit）。本章是给工程师直接照着开工的可执行方案，覆盖 7zG 的全部对话框（压缩/解压/覆盖确认/密码/进度/Hash 结果/内存确认/基准）逐控件映射，以及 Windows Shell 集成（文件关联、右键菜单、拖放、自动化）在 macOS 的等价实现与能力差异。
>
> 引用约定：源码证据用 `路径:行号`；底料引用用研究文档名（02-gui-dialogs-inventory.md 等，本仓库 `docs/research/`）；本方案文档间引用用固定文件名（见各处）。
>
> 范围分工：7zFM 菜单/面板/设置见 03-feature-map-filemanager.md；SevenZipKit API 形态与 COM/ABI 约束见 02-core-bridge.md；dylib 构建与 lib7z 接口见 02-core-bridge.md；持久化（ZipRegistry→NSUserDefaults）键集与桥接通用约定见 02-core-bridge.md 与 03-feature-map-filemanager.md；任务排期与验收见 05-roadmap-execution.md。本章只负责"对话框 + Finder 集成"这两块的端到端落地。

---

## 0. 本章总纲与三层落点约定

7zG 在 Windows 上是独立 GUI 进程，由 7zFM/Explorer 经 `CompressCall.cpp` 以子进程 + `7zMap` 共享内存唤起（证据见 02-gui-dialogs-inventory.md §11，源码 `CPP/7zip/UI/Common/CompressCall.cpp:121-184`）。方案B 一对一移植采用**进程内化**：以 upstream 已维护的 `CompressCall2.cpp`（`#ifndef Z7_EXTERNAL_CODECS` 时的同进程直调路径，证据 `CPP/7zip/UI/Common/CompressCall2.cpp:90-325`）为蓝本，把 `CompressFiles/ExtractArchives/TestArchives/CalcChecksum/Benchmark` 五个 API 实现为 SevenZipKit 内的直接调用。本章所有对话框因此都是 **SevenZipFM.app 内的窗口/sheet**，而非独立进程。

三层落点的统一表达（本章所有映射表的列含义）：

| 层 | 角色 | 本章如何体现 |
|---|---|---|
| lib7z.dylib | COM 风格 handler/codec，经 `CreateObject` 工厂 + `ISetProperties::SetProperties(names[],values[],n)` 接收压缩参数（证据 `CPP/7zip/Archive/IArchive.h:537-550`） | 映射表"7z 属性"列：即最终 `SetProperties` 的 name=value 对，或 `CExtractOptions/CUpdateOptions` 字段 |
| SevenZipKit.framework | ObjC++ 桥接，把对话框产出的"参数模型"翻译成引擎调用；并把引擎回调（进度/覆盖/密码）hop 到主线程 | 映射表"SevenZipKit API"列：建议的 ObjC 接口（头文件草案级别，见 §1.7、§2.5） |
| SevenZipFM.app | AppKit 控件/窗口控制器 | 映射表"mac 控件"列 |

**核心移植策略（贯穿全章，务必照做）**：CompressDialog 的 3821 行里，参数联动与自动档/内存估算算法是**纯 C++、零 UI 依赖**，必须原样抽成一个无 AppKit 的 `CParamsModel` 类复用（底料已把全部联动链与算法登记在 02-gui-dialogs-inventory.md §2.3）；AppKit 控件只做"读控件值→喂 model→把 model 算出的可选项/使能态/估算文本回填控件"。**不要在 Swift/ObjC 里重写这些算法**——任何重写都会偏离 Windows 行为，违反一对一。

---

## 1. 压缩对话框（CCompressDialog → SZCompressPanel）

源文件：`CPP/7zip/UI/GUI/CompressDialog.{h,cpp}`、`CompressOptionsDialog.rc`。控件总清单、格式能力表、联动矩阵、OnOK 校验、字段→属性映射均已在 02-gui-dialogs-inventory.md §2 完整登记并附 `路径:行号`。本节给出逐控件三层映射与还原说明，**联动逻辑一律指回 02 的链路表**，此处只补充 mac 控件类型与桥接接口。

### 1.1 主对话框逐控件映射表（IDD_COMPRESS）

| Windows 控件（ID） | 7z 参数/接口属性 | SevenZipKit API（CParamsModel/产出） | mac 控件 | 还原说明 |
|---|---|---|---|---|
| 档案名 IDC_COMPRESS_ARCHIVE(100) | `options.ArchivePath` | `model.archivePath`（NSString） | NSComboBox（可编辑 + 历史下拉），历史来自 `Compression.ArcHistory` defaults（≤20，CompressDialog.cpp:86） | 选历史项触发延迟改文本，见 02 §2.3 ARCHIVE 行（PostMsg 改为 GCD `dispatch_async(main)` 重置文本） |
| "..." IDB_SET_ARCHIVE(101) | — | `-[SZCompressPanel browseForArchive]` | NSButton → NSSavePanel | `allowedContentTypes` 取当前格式 UTType；accessory view 放格式过滤器；自动补扩展名逻辑见 §1.6（替代 OnButtonSetArchive 130 行，CompressDialog.cpp:879-1012） |
| 当前目录前缀 IDT_ARCHIVE_FOLDER(130) | — | `model.archiveFolderDisplay` | NSTextField(label) | 纯显示，`SetArcPathFields`（cpp:854） |
| 格式 IDC_COMPRESS_FORMAT(104) | `options.MethodMode.Type.FormatIndex` | `model.formatIndex`（itemData=arcIndex） | NSPopUpButton | 候选来自 `codecs->Formats` 过滤（仅可写格式）；选格式先 `SaveOptionsInMem()` 再 `FormatChanged(true)` 再换扩展名，见 02 §2.3 FORMAT 行 |
| 等级 IDC_COMPRESS_LEVEL(102) | 属性 `"x"=N`（UpdateGUI.cpp:211） | `model.level` | NSPopUpButton | 候选按 `g_Formats[].LevelsMask` 过滤（CompressDialog.cpp:1572-1617）；选级触发 `ResetForLevelChange()` 清空 method/dict/order 记忆，见 02 §2.3 LEVEL 行 |
| 方法 IDC_COMPRESS_METHOD(106) | 7z: 属性 `"0"=LZMA2…`；其它: `"m"=…`（UpdateGUI.cpp:215） | `model.method` | NSPopUpButton | 首项"* auto"；7z 下跳过 Copy/Deflate*（cpp:1664）；末尾追加外部 codec；见 02 §2.2 能力表 |
| 字典 IDC_DICTIONARY(107) | `"0d"/"d"=Nb`，PPMd 时 `"0mem"/"mem"`（UpdateGUI.cpp:217-224） | `model.dict64` | NSPopUpButton | 档位由方法+等级算法生成（02 §2.3 自动档：LZMA `1<<(level+20)` 封顶 `15<<28` 等），照表回放 |
| Word/PPMd order IDC_ORDER(108) | OrderMode `"0o"/"o"=N` 否则 `"0fb"/"fb"`（UpdateGUI.cpp:235） | `model.order` | NSPopUpButton | OrderMode 判定 CompressDialog.cpp:2363；档位算法见 02 §2.3 |
| 固实块 IDC_SOLID(109) | 属性 `"s"=Nb`（64=全固实=(UInt64)-1，UpdateGUI.cpp:251） | `model.solidBlockLog` | NSPopUpButton | 仅 `kFF_Solid` 格式（7z/xz）可见；档位算法 02 §2.3；不支持格式置 hidden |
| 线程 IDC_THREADS(110) | 属性 `"mt"=N`（UpdateGUI.cpp:254） | `model.numThreads` | NSPopUpButton | 上限按方法（LZMA=2/LZMA2=512/...，cpp:2606）；auto 在内存限额内回退（cpp:2632），随 MemUse 变化重算，见 02 §2.3 MEM_USE 行 |
| 硬件线程数 IDT_HARDWARE_THREADS(112) | — | `model.hwThreadsDisplay` | NSTextField | "/ 进程线程数 / 系统线程数"，`SetNumThreads2`（cpp:2576） |
| 内存上限 IDC_MEM_USE(117) | 属性 `"memuse"=N%` 或 `Nb`（UpdateGUI.cpp:259） | `model.memUse`（CMemUse 解析 "80%"/"4g"） | NSPopUpButton（可编辑）| 档位 80%(auto)/10-100%/128MB…（cpp:2811）；改值触发线程与内存估算重算 |
| 估算压缩内存 IDT_MEMORY_VALUE(113) | — | `model.memCompressDisplay` | NSTextField | "实际/限额/RAM"，`PrintMemUsage`（cpp:3099）；纯算法 `GetMemoryUsage_Threads_Dict_DecompMem`（cpp:2901） |
| 估算解压内存 IDT_MEMORY_DE_VALUE(114) | — | `model.memDecompressDisplay` | NSTextField | 同上 |
| 分卷 IDC_VOLUME(105) | `options.VolumesSizes`（UpdateGUI.cpp:476） | `model.volumeSizesText` | NSComboBox（可编辑） | 字节表达式 `ParseVolumeSizes`；<100KB 弹确认（cpp:1216），见 §1.4 |
| 参数 IDE_PARAMETERS(111) | 自由串经 `SplitOptionsToStrings` 剥 `-m` 逐项追加（UpdateGUI.cpp:141-193） | `model.paramsText` | NSTextField | 含方法覆盖（`0=`/`m=`）则跳过 GUI 的 method/dict/order 写入——此跳过逻辑在 model 内 |
| Options IDB_OPTIONS(2100) | — | `-[SZCompressPanel showOptions]` | NSButton → sheet（§1.5） | 打开二级选项 sheet |
| 选项摘要 IDT_OPTIONS(141) | — | `model.optionsSummary` | NSTextField | "tp2 tm- SL HL…"，`ShowOptionsString`（cpp:3353） |
| 更新模式 IDC_UPDATE_MODE(103) | `options.Commands[0].ActionSet` ← k_ActionSet_{Add,Update,Fresh,Sync}（UpdateGUI.cpp:284-312） | `model.updateMode` | NSPopUpButton | 4 项；命令行 ActionSet 反向注入见 02 §2.6 末 |
| 路径模式 IDC_PATH_MODE(116) | `options.PathMode`（k_RelatPath/k_FullPath/k_AbsPath，UpdateGUI.cpp:493） | `model.pathMode` | NSPopUpButton | 影响 censor 收集 |
| 自解压 IDX_SFX(4012) | `options.SfxMode`（UpdateGUI.cpp:516） | `model.sfxMode` | NSButton(checkbox) | **见 §6 能力差异**：mac 默认隐藏（无 `7z.sfx` Win PE 模块）；勾选改后缀逻辑 `OnButtonSFX` 保留供未来 |
| 共享文件 IDX_SHARED(4013) | `options.OpenShareForWrite`（UpdateGUI.cpp:513） | `model.openShareForWrite` | NSButton(checkbox) | macOS 无强制锁，语义弱化但保留键 |
| 压后删除 IDX_DEL(4019) | `options.DeleteAfterCompressing`（UpdateGUI.cpp:460） | `model.deleteAfterCompressing` | NSButton(checkbox) | 直搬 |
| 密码/确认 IDE_PASSWORD1/2(120/121) | `callback->Password`（UpdateGUI.cpp:496） | `model.password` | 2× NSSecureTextField | 见 §1.3 |
| 显示密码 IDX_PASSWORD_SHOW(3803) | — | `model.showPassword` | NSButton(checkbox) | 勾选时隐藏第二行、用 NSTextField 明文（`UpdatePasswordControl`，cpp:570） |
| 加密算法 IDC_ENCRYPTION_METHOD(122) | 属性 `"em"`（去 '-'，非默认才填，UpdateGUI.cpp:245） | `model.encryptionMethod` | NSPopUpButton | 7z: AES-256；zip: ZipCrypto/AES-256（cpp:1721） |
| 加密文件名 IDX_ENCRYPT_FILE_NAMES(4016) | 属性 `"he"=on/off`（仅 EncryptHeadersIsAllowed，UpdateGUI.cpp:248） | `model.encryptHeaders` | NSButton(checkbox) | 仅 7z 可用 |
| OK/Cancel/Help | — | `-[... ok]`/`cancel` | NSButton | Help 跳 web（§6） |

### 1.2 联动逻辑还原（一对一硬要求）

完整联动矩阵在 02-gui-dialogs-inventory.md §2.3（CBN_SELCHANGE 矩阵 + 自动档算法 + 初始化链 + FormatChanged 链）。移植落地规则：

1. **把 §2.3 整段实现为 `CParamsModel`（C++，放 SevenZipKit 的 C++ 私有层）**。它持有等价于 `CCompressDialog` 的全部成员（_ramSize、m_RegistryInfo 的 NCompression::CInfo 镜像、每格式 CFormatOptions）。对外暴露：
   - setter（用户改了哪个控件）：`OnFormatChanged(int)`/`OnLevelChanged(int)`/`OnMethodChanged(int)`/`OnDictChanged(int)`/`OnSolidChanged`/`OnThreadsChanged`/`OnMemUseChanged`/`OnArchiveTextChanged` —— 内部**完全照搬** `FormatChanged/SetLevel/SetMethod/MethodChanged/SetSolidBlockSize/SetNumThreads/SetMemUseCombo/SetMemoryUsage` 的调用顺序（CompressDialog.h:216-238、cpp:698-764、cpp:1313-1440）。
   - getter（重建控件）：`enumLevels()/enumMethods()/enumDicts()/enumOrders()/enumSolid()/enumThreads()/enumMemUse()` 返回 `{label, itemData, enabled}` 列表 + 当前选中下标；`memCompressString()/memDecompressString()/hwThreadsString()/optionsSummaryString()`。
2. **控件回调统一形态**：每个 NSPopUpButton 的 action → 调对应 `model.OnXxxChanged(selectedTag)` → 重新询问受影响的 enum getter 并 `removeAllItems`/`addItem` 重建（与 Windows 的 `ResetXxx`+`AddString` 一一对应）。`SaveOptionsInMem()`（把旧格式 UI 状态写回内存镜像，cpp:1450）在 FORMAT/DICTIONARY/MEM_USE 改变前调用，必须保留。
3. **使能态**：Windows 用 `EnableItem`，mac 用 `NSControl.enabled`；显隐用 `NSView.hidden`（替代 `ShowWindow(SW_HIDE)`）。`FormatChanged` 按 `g_Formats[].Flags`（kFF_Filter/Solid/MultiThread/Encrypt/EncryptFileNames/MemUse/SFX，cpp:236-242）决定哪些控件可见——Windows 专属能力（SFX）在 mac 把对应格式的 `kFF_SFX` 视作 false（与现有显隐逻辑零冲突，R8 缓解，见 02 §13）。

> 反例警示：曾有移植把"等级改变后字典默认值"硬编码进 Swift。正确做法是调 `model.OnLevelChanged()` 后读 `model.enumDicts()` 的当前选中项——因为 7z 与 zip 的默认字典公式不同（02 §2.3 自动档表），硬编码必错。

### 1.3 压缩对话框内的密码框（与独立密码对话框 §3 区分）

压缩对话框自带密码/确认/显示密码三件套（CompressDialog.cpp:461-606），**不是** §3 的 CPasswordDialog。校验在 OnOK：zip 密码必须 ASCII、AES 密码 ≤99、双密码一致（cpp:1069-1095，见 §1.4）。mac 用 NSSecureTextField，"显示密码"勾选时把 password1 切成 NSTextField 明文并隐藏 password2 行。

### 1.4 OnOK 校验链（必须 1:1）

证据 CompressDialog.cpp:1066-1252，顺序不可乱：

1. zip 密码非 ASCII → 报 `IDS_PASSWORD_USE_ASCII`（NSAlert）；AES 密码 >99 字符 → 拒绝。
2. 双密码不一致 → 报错聚焦 password1。
3. **内存估算超限 → 报 `IDS_MEM_OPERATION_BLOCKED` 并拒绝提交**（`SetErrorMessage_MemUsage`，cpp:1046）——此校验 model 已能算，桥接层只负责弹 NSAlert。
4. 路径合法性 `GetFinalPath_Smart`。
5. 分卷表达式 `ParseVolumeSizes`；单卷 <100KB 需二次确认 `IDS_SPLIT_CONFIRM`（cpp:1216）→ NSAlert YES/NO。

通过后双向写出：(a) 产出 `NCompressDialog::CInfo`（CompressDialog.h:31-104）给调用方；(b) 持久化 `NCompression::CInfo`（含每格式 CFormatOptions + 档案历史 ≤20）—— 持久化后端从注册表改 NSUserDefaults，键集见 05-platform-layer.md §4.1-E，桥接通用约定见 02-core-bridge.md。

### 1.5 二级选项对话框（COptionsDialog → sheet）

证据 CompressDialog.cpp:3397-3816、CompressOptionsDialog.rc。控件分三组，逐项映射：

| Windows 控件 | 7z 落点 | mac 控件 | mac 取舍 |
|---|---|---|---|
| NT SymLinks / HardLinks / AltStreams / NtSecurity（IDX_NT_*） | `options.SymLinks/HardLinks/AltStreams/NtSecurity`（CBoolPair → CDirItems 扫描开关，**非档案属性**，UpdateGUI.cpp:462） | NSButton(checkbox) | **SymLinks/HardLinks 在 macOS 原生支持，保留可见**（POSIX 已实测，05-platform-layer.md §5.5-5.6）；**AltStreams/NtSecurity 在 mac 编译期排除 → 设 Supported=false，按 `cd->XXX.Supported` 现有显隐逻辑自动隐藏**（cpp:3698-3762） |
| PreserveATime（IDX_PRESERVE_ATIME） | `options.PreserveATime` | NSButton(checkbox) | 保留（POSIX `utimensat` 可控） |
| 时间精度 Combo IDC_TIME_PREC | 属性 `"tp"=N`（UpdateGUI.cpp:279） | NSPopUpButton | 档位由 `ai.Get_TimePrecFlags()` 生成（Win100ns/Unix1s/DOS2s/1ns/base-prec，`SetPrec` cpp:3482）；tar/zip 精度限制逻辑（cpp:3584）照搬 |
| MTime/CTime/ATime/SetArcMTime 4 组"set"复选对 | 属性 `"tm"/"tc"/"ta"=on/off`（UpdateGUI.cpp:275）；SetArcMTime→`options.SetArcMTime`（输出流 SetMTime） | 4× NSButton(checkbox) 对（CBoolBox 双复选模型：左 set 勾选才启用右值） | mac 用"主复选 + 从复选 enabled 绑定"复刻 CBoolBox（cpp:3397-3417） |

实现为模态 sheet（`-[NSWindow beginSheet:completionHandler:]`），IDOK 后回 `ShowOptionsString()` 刷新主面板摘要。

### 1.6 浏览保存路径的格式过滤器还原（R11）

`OnButtonSetArchive`（CompressDialog.cpp:879-1012）的核心是"过滤器索引回传 → 自动补扩展名 → 必要时切换格式 Combo"。mac 用 NSSavePanel：

- `allowedContentTypes` = 当前格式的全部 UTType（由 §4.2 的格式↔UTType 表反查）；`allowsOtherFileTypes = YES`。
- accessory view 放一个 NSPopUpButton 复刻 Windows 的"保存类型"下拉；切换时 `setAllowedContentTypes:` 并回写主面板的格式 Combo（保持 Windows"在保存对话框里换格式会同步主对话框格式"的行为）。
- 扩展名映射用 `CArcInfoEx.Exts` 原数据（不要硬编码），与 §4.2 同源。

### 1.7 SevenZipKit 压缩接口草案

```objc
// SZCompressOptions.h  —— 对话框产出物（≈ NCompressDialog::CInfo），值类型，纯数据
@interface SZCompressOptions : NSObject
@property(copy) NSString *archivePath;
@property NSInteger formatIndex;        // 对应 codecs Formats 下标
@property NSInteger level;              // 0..9
@property(copy, nullable) NSString *method;        // nil = auto
@property uint64_t dictionary;          // 0 = auto
@property NSInteger order;              // -1 = auto
@property int64_t  solidBlockLog;       // -1 = unspecified; 64 = fully solid
@property NSInteger numThreads;         // 0 = auto
@property(copy) NSString *memUse;       // "80%" / "4g" / ""
@property(copy, nullable) NSString *volumeSizes;
@property(copy, nullable) NSString *paramsText;
@property NSInteger updateMode;         // Add/Update/Fresh/Sync
@property NSInteger pathMode;           // Relative/Full/Abs
@property BOOL deleteAfterCompressing, openShareForWrite, sfxMode;
@property(copy, nullable) NSString *password;
@property(copy, nullable) NSString *encryptionMethod;  // "AES256"/"ZipCrypto"; nil=default
@property BOOL encryptHeaders;
@property SZTriState symLinks, hardLinks, altStreams, ntSecurity, preserveATime; // CBoolPair 三态
@property(copy) NSDictionary *timeOptions;  // tm/tc/ta/setArcMTime/timePrec
@end

// SZCompressParamsModel.h —— 包装 CParamsModel（C++），驱动控件联动；详细行为见本节 §1.2
@interface SZCompressParamsModel : NSObject
- (instancetype)initWithCodecs:(SZCodecs *)codecs ramSize:(uint64_t)ram;
- (void)onFormatChanged:(NSInteger)tag;   // 等共 8 个 setter，见 §1.2
- (NSArray<SZPopupItem *> *)levels;       // 等共 N 个 enum getter
- (NSString *)memCompressString;          // 估算文本
- (BOOL)validateOnOK:(NSError **)err;     // §1.4 校验链（不弹 UI，返回 NSError）
- (SZCompressOptions *)buildOptions;       // 通过校验后产出
@end

// SZArchiver.h —— 执行入口（≈ CompressCall2::CompressFiles → UpdateGUI 进程内调用）
@interface SZArchiver : NSObject
- (SZOperation *)compressFiles:(NSArray<NSURL *> *)inputs
                       options:(SZCompressOptions *)opts
                      progress:(id<SZProgressSink>)sink;  // SZOperation 见 §2.4
@end
```

---

## 2. 解压对话框 / 覆盖确认 / 密码框 / 进度窗

### 2.1 解压对话框（CExtractDialog → SZExtractPanel）

源文件 `CPP/7zip/UI/GUI/ExtractDialog.{h,cpp}`，控件清单见 02-gui-dialogs-inventory.md §3.1，字段→操作层映射见 §3.3（ExtractGUI.cpp:196-255，落 `CExtractOptions`，定义 Extract.h:26-83）。

| Windows 控件（ID） | 操作层落点 | SevenZipKit | mac 控件 | 还原说明 |
|---|---|---|---|---|
| 目标目录 IDC_EXTRACT_PATH(100) | `options.OutputDir`（ExtractGUI.cpp:236） | `SZExtractOptions.outputDir` | NSComboBox（可编辑+历史≤16） | 历史 `Extraction.PathHistory` defaults；`kCurPaths` 特例保留（cpp:302） |
| "..." IDB_SET_PATH(101) | — | `browseForFolder` | NSButton → NSOpenPanel(`canChooseDirectories=YES`) | 替代 `MyBrowseForFolder` |
| 子目录名 enable+edit IDX/IDE_EXTRACT_NAME(131/130) | SplitDest（默认拆档案同名末级目录） | `SZExtractOptions.subFolderName`/`splitDest` | NSButton(checkbox) + NSTextField | `SplitDest` 默认 true（ZipRegistry），见 ExtractDialog.cpp:195-208 |
| 路径模式 IDC_PATH_MODE(102) | `PathMode`（Full/No/Abs，**无 Relative**） | `SZExtractOptions.pathMode` | NSPopUpButton | 值表 kPathModeButtonsVals（cpp:33-57），注意与压缩对话框枚举不同 |
| 覆盖模式 IDC_OVERWRITE_MODE(103) | `OverwriteMode`（Ask/Overwrite/Skip/Rename/RenameExisting） | `SZExtractOptions.overwriteMode` | NSPopUpButton | 进入 `CArchiveExtractCallback::InitForMulti`（Extract.cpp:336） |
| 消除根重复 IDX_ELIM_DUP(3430) | `ElimDup` | `SZExtractOptions.elimDup` | NSButton(checkbox) | 双源合并（命令行/注册表，`CheckButton_TwoBools` cpp:113） |
| 还原安全描述符 IDX_NT_SECUR(3431) | `NtSecurity` | — | **mac 隐藏**（Win 专属，编译期排除） | 见 §6 能力差异 |
| 密码 IDE_PASSWORD(120)+显示 IDX_PASSWORD_SHOW(3803) | `Password`（callback） | `SZExtractOptions.password`/`showPassword` | NSSecureTextField + NSButton | 与 §3 解压侧密码回调可不同时出现（对话框预设 vs 运行时弹窗） |
| OK/Cancel/Help | — | — | NSButton | Help 跳 web |

行为：OnInit 标题追加档案名（cpp:139）；`_info.Load()` 后未被命令行强制时采用注册表 PathMode/OverwriteMode（cpp:170）；OnOK 写回 `_info` 并 Save（路径历史去重）。持久化键集见 05-platform-layer.md §4.1-D。

### 2.2 覆盖确认对话框（COverwriteDialog → SZOverwriteSheet）

源文件 `CPP/7zip/UI/FileManager/OverwriteDialog.{h,cpp}`，唯一调用点 `CExtractCallbackImp::AskOverwrite`（ExtractCallback.cpp:201-232，复制路径 `AskWrite` 亦复用，cpp:710-806）。

数据：`OldFileInfo/NewFileInfo`（Path/Size?/FILETIME?/是否文件系统文件→图标，OverwriteDialog.h:13-55）。
按钮→`NOverwriteAnswer`（IFileExtractCallback.h:22-33）：

| Windows 按钮 | 枚举值 | mac 控件 |
|---|---|---|
| Yes | kYes | NSButton |
| No | kNo | NSButton |
| Yes to All | kYesToAll | NSButton |
| No to All | kNoToAll | NSButton |
| Auto Rename | kAutoRename | NSButton |
| Cancel | kCancel → `E_ABORT` | NSButton |

**关键移植约束（R5，死锁风险）**：`AskOverwrite` 在**工作线程**被调用，原逻辑 `ProgressDialog->WaitCreating(); dialog.Create(*ProgressDialog)` 同步阻塞工作线程直到用户作答。mac 必须：工作线程 `dispatch_sync(main)` 弹 sheet（或 `dispatch_semaphore` + 主线程 sheet），把答案回传后工作线程继续。桥接层提供统一注入点（block + `dispatch_semaphore_t`），保持"工作线程阻塞等答案"的语义。两文件信息（旧/新）的图标用 `NSWorkspace iconForContentType:` 按扩展名/UTType 取。

### 2.3 密码对话框（CPasswordDialog → SZPasswordSheet）

源文件 `CPP/7zip/UI/FileManager/PasswordDialog.{h,cpp}`：单 Edit + ShowPassword 复选。三个触发点（02-gui-dialogs-inventory.md §6）：

| 触发场景 | 调用点 | 行为 |
|---|---|---|
| 解压时无预设密码 | `CExtractCallbackImp::CryptoGetTextPassword`（ExtractCallback.cpp:683） | 弹窗；读写 ShowPassword 偏好；取消→E_ABORT |
| 打开加密档案 | `Open_CryptoGetTextPassword`（复用同函数，cpp:151） | 同上 |
| 压缩/更新时 `-p` 无值 | `CUpdateCallbackGUI2::ShowAskPasswordDialog`（UpdateCallbackGUI2.cpp:52） | 经 CryptoGetTextPassword2 |

mac：NSSecureTextField + 显示明文切换的 sheet，同样在工作线程经 dispatch 到主线程弹出、阻塞等待（同 §2.2 死锁约束）。`ShowPassword` 偏好存 `Extraction.ShowPassword`/`Compression.ShowPassword` defaults。

### 2.4 进度窗（CProgressDialog / CProgressSync → SZProgressWindowController）

源文件 `CPP/7zip/UI/FileManager/ProgressDialog2.{h,cpp}`。线程模型、共享状态、统计算法、暂停/后台/取消已在 02-gui-dialogs-inventory.md §4 完整登记。逐项映射：

**线程模型（§4.1）**：`CProgressThreadVirt::Create` 起工作线程跑 `ProcessVirt()`，GUI 线程进模态循环。mac 改为：SevenZipKit 提供 `SZOperation`（包一个 `NSOperation` 或 GCD 工作队列项 + 一个进度窗控制器）。工作线程结束经 `kCloseMessage`（WM_APP+1）通知 GUI → 改为 `dispatch_async(main)` 调 `-[SZProgressWindowController operationFinished:]`。**500ms 创建延迟**（kCreateDelay，cpp:42）保留：短任务不闪窗，用 `dispatch_after(500ms)` 决定是否真正 `makeKeyAndOrderFront`。`WaitCreating()`（保证弹覆盖/密码 sheet 前进度窗已存在）→ 桥接为"sheet 必须挂在进度窗上，故先确保窗已建"。

**共享状态 CProgressSync（§4.2，互斥+轮询）**：字段（_stopped/_paused/_totalBytes/_completedBytes/...，ProgressDialog2.h:32-103）原样保留为 C++ struct（带 mutex）。GUI 用 `SetTimer(200ms)` 轮询 → mac 用 `NSTimer`(0.2s) 拉取 `Sync` 并刷新控件（**不引入消息推送**，与原架构一致，02 §10.2 末尾结论）。**暂停**：`CheckStop()` 在 `_paused` 时 `Sleep(100)` 轮询（kPauseSleepTime，cpp:100）——工作线程被动停在下一次回调，mac 直接保留（pthread/GCD 工作线程上 sleep 无碍）。

**控件与统计（§4.3）**：

| Windows 控件 | 内容/算法 | mac 控件 |
|---|---|---|
| 进度条 IDC_PROGRESS1 | 百分比 | NSProgressIndicator(determinate) |
| 消息 ListView IDL_PROGRESS_MESSAGES | 错误列表（AddError_*→Sync.Messages） | NSTableView（出错时窗口拉大，`EnableErrorsControls` cpp:334）；支持全选复制（→ NSPasteboard） |
| 文件名/状态 IDT_FILE_NAME/STATUS | 当前文件/状态串 | NSTextField |
| 统计对 Elapsed/Remaining/Files/Errors/Total/Speed/Processed/Packed/Ratio | 算法：经过时间累计（暂停期不计，结转 `_elapsedTime` cpp:1130）；剩余=`(total-completed)*elapsed/completed`；速率=`completed*1000/elapsed`；Ratio=`packed*100/unpack`（cpp:782-895） | 9× NSTextField（label+value） |
| Win7 任务栏进度 ITaskbarList3 | `SetProgressValue` | **NSDockTile**（`NSApp.dockTile` + badge/自绘进度），或 `NSProgress`(publish) 让 Dock 显示 |
| 窗口标题 | `[暂停] N% [后台] 主标题 文件名`（cpp:1085） | `NSWindow.title` 同格式 |

**压缩/解压角色互换**：in/out 角色由 `CompressingMode` 控制（ExtractGUI.cpp:282 置 false）——model 内已处理，控件只读 Sync。

**暂停/后台/取消（§4.4）**：

| Windows 按钮 | 行为 | mac 实现 |
|---|---|---|
| IDB_PAUSE | `Sync.Set_Paused(!paused)`；文本 Pause↔Continue；任务栏置黄 | NSButton 切换；Dock badge 变色 |
| IDB_PROGRESS_BACKGROUND | `SetPriorityClass(GetCurrentProcess(), IDLE/NORMAL)` | **必须改 per-thread QoS**（R6/02 §11.3）：`pthread_set_qos_class_self_np(QOS_CLASS_BACKGROUND/UTILITY)` 只降工作线程，否则进程内化会拖慢整个 App |
| IDCANCEL | 先自动暂停→`MessageBoxW(MB_YESNOCANCEL)`→YES 则 `_cancelWasPressed`→`Sync.Set_Stopped(true)` | 先 Set_Paused → NSAlert(YESNOCANCEL) → YES 则 Set_Stopped；E_ABORT 静默 |

### 2.5 进度窗多任务并行的 mac 设计（新增设计，方案B 必须定案）

Windows 下"每操作一进程一模态窗"天然隔离；进程内化后（02 §11.3）多操作共享进程，必须显式设计并行模型：

**设计结论**：
1. **每个 SZOperation 拥有独立的 `CProgressSync` 实例 + 独立工作线程 + 独立 `SZProgressWindowController`（非模态窗口，非 sheet）**。多个压缩/解压可同时进行，各自一个进度窗（与 Windows 多开 7zG 进程的视觉效果一致）。
2. **引擎并发约束（来自核心 dylib，硬约束）**：同一 `IInArchive` 实例禁止跨线程并发（02-core-bridge.md / `CPP/7zip/Archive/IArchive.h:305-308`）。因此并行的是"不同档案的不同操作"；每个 SZOperation 用自己的 handler 实例与 IInStream。SevenZipKit 内每个 SZOperation 绑定一个串行 dispatch queue，所有该操作的引擎调用排队。
3. **进度回调线程性**：进度回调可能发生在引擎 worker 线程（02-core-bridge.md 实证 ZIP MT 压缩 `SetCompleted` 在 worker 线程持锁调用）。所有刷 UI 的回调必须 `dispatch_async(main)`；回调内禁止重入同一 archive 对象。`CProgressSync` 的 mutex 已保证写入串行，UI 侧 NSTimer 拉取即可。
4. **后台/QoS**：每个工作线程独立 QoS，互不影响（§2.4 后台按钮）。
5. **窗口管理**：进度窗可堆叠/层叠；建议提供一个"操作中心"（可选，类似 Safari 下载列表）汇总所有进行中 SZOperation——但 v1 一对一只需各自独立窗口即可，操作中心列为增强项写入开放问题。
6. **取消与退出**：App 退出时若有进行中 SZOperation，需逐个 Set_Stopped 并等待（或弹确认）；崩溃隔离丧失（R 在 02 §11.3），核心稳定性已由 7zz 实测背书，可接受；超大任务保留 XPC 子进程选项作为后续（开放问题）。

```objc
// SZProgressSink.h —— 工作线程→UI 的桥（包 CProgressSync）
@protocol SZProgressSink <NSObject>
- (void)setTotalBytes:(uint64_t)t files:(uint64_t)f;     // 引擎线程调用，内部 hop main
- (void)setCompletedBytes:(uint64_t)c files:(uint64_t)cf;
- (void)setStatus:(NSString *)s filePath:(NSString *)p;
- (void)addError:(NSString *)msg;
// 阻塞式问询（工作线程同步等待，内部 dispatch_sync(main)+semaphore）
- (SZOverwriteAnswer)askOverwrite:(SZFileInfo *)old new:(SZFileInfo *)neu;  // §2.2
- (nullable NSString *)askPassword:(BOOL *)cancelled;                       // §2.3
// §2.6 内存确认：sheet（非 NSAlert），返回结构携带新限额与记忆/跳过状态
- (SZMemoryAnswer *)askMemoryUse:(uint64_t)required limit:(uint64_t)lim;     // §2.6
@end

// SZMemoryAnswer —— CMemDialog 产出（MemDialog.cpp:189-218），承载步进器/单选/勾选状态
@interface SZMemoryAnswer : NSObject
@property BOOL cancelled;        // Cancel → E_ABORT (k_Stop)
@property BOOL skipArc;          // 跳过此档（k_SkipArc） vs 允许（k_Allow）；IDR_MEM_ACTION_*
@property BOOL remember;         // "记住本次操作" IDX_MEM_REMEMBER → _remember/_skipArc
@property BOOL saveLimit;        // "改限额" IDX_MEM_SAVE_LIMIT → 勾选才写回
@property uint32_t newLimitGB;   // 步进器新值；saveLimit 时 → *allowedSize=GB<<30 且 Save_LimitGB
@end

@interface SZOperation : NSObject     // 一个进度窗 + 一个工作线程 + 一个 CProgressSync
@property(readonly) SZProgressWindowController *progressController;
- (void)pause; - (void)resume; - (void)cancel;     // → Sync.Set_Paused/Set_Stopped
- (void)setBackground:(BOOL)bg;                     // → 工作线程 QoS
@end
```

### 2.6 内存请求确认 / Hash 结果窗 / 测试结果

- **内存确认 CMemDialog**（`IArchiveRequestMemoryUseCallback` 路径，超限弹窗，`CPP/7zip/UI/FileManager/ExtractCallback.cpp:1048-1090`）→ **独立 sheet（不是 NSAlert——NSAlert 无法承载 GB 步进器与记忆选项）**。`CMemDialog`（`MemDialog.{h,cpp}`）是一个含有状态控件的对话框，必须逐控件复刻：
  - **GB 限额步进器**：`NSStepper` + `NSTextField`（对应 `IDC_MEM_SPIN`/`IDE_MEM_SPIN_EDIT`，范围 1..min(RAM-1, 16384) GB，`MemDialog.cpp:130-150`）；仅当"改限额"勾选时启用（`EnableSpin`，`MemDialog.cpp:42`、`OnButtonClicked` 切换 `MemDialog.cpp:181`）。
  - **"改限额并记住"勾选**：对应 `IDX_MEM_SAVE_LIMIT`（`NeedSave`）——勾选时把新 GB 值写回 `NExtract::Save_LimitGB`（`ZipRegistry.h:47`、`ExtractCallback.cpp:1076`，mac 落 NSUserDefaults `Extraction.MemLimit`）。
  - **"允许 / 跳过此档"单选**：对应 `IDR_MEM_ACTION_ALLOW` / `IDR_MEM_ACTION_SKIP_ARC`（`SkipArc`，默认按 `is_Allowed` 选中，`MemDialog.cpp:160-167`）。
  - **"记住本次操作"勾选**：对应 `IDX_MEM_REMEMBER`（`Remember`；`ShowRemember=false` 时隐藏，`MemDialog.cpp:172`），勾选后多档/多项后续不再弹窗（`_remember`/`_skipArc`，`ExtractCallback.cpp:1062-1079`）。
  - **Continue / Cancel**（Cancel→`E_ABORT`，`MemDialog::OnContinue` 校验 GB 串合法性后写 `Limit_GB`，`MemDialog.cpp:189-218`）。

  因此 `askMemoryUse:` 的返回必须携带**新限额值**与**记忆/跳过状态**，而非仅 yes/no——回调据此设置引擎的 `*allowedSize = Limit_GB << 30` 与 `*answerFlags`（k_Allow / k_SkipArc / k_Stop，`ExtractCallback.cpp:1084-1090`）。结构见 §2.5 `SZMemoryAnswer`。
- **Hash 结果窗**（`ShowHashResults` → CListViewDialog 名称/值两列，HashGUI.cpp:310）→ NSTableView(2 列) 窗口，支持复制到 NSPasteboard。哈希命令经 `CalcChecksum`（CompressCall2 蓝本）进程内调用 `HashCalcGUI`。
- **测试结果**：OK 走 FinalMessage.OkMessage（"There are no errors"，ExtractGUI.cpp:94）→ NSAlert(info)；错误进进度窗错误列表。
- **基准测试 CBenchmarkDialog**（02 §8）：独立窗口，双线程 + 1s OnTimer 刷新；mac 用 NSTimer + NSTextField 矩阵。属增强功能，可与主线对话框并行排期（05-roadmap-execution.md）。

---

## 3. Finder 集成

Windows Shell 集成（右键菜单、拖放、文件关联）的完整盘点见 03-explorer-agent.md §1。本节给出 macOS 等价实现的选型结论与落地要点。**业务规则层（命令枚举、Verb、扩展名启发式、档名生成）是纯逻辑，整体抽出复用**（03 §1.9 结论），mac 只重写"宿主壳"。

### 3.1 文件关联：UTType 声明（Info.plist）

Windows 经注册表 `Software\Classes\.<ext>` → ProgID（RegistryAssociations.cpp:93-165）。macOS 用 Info.plist 静态声明 + `LSSetDefaultRoleHandlerForContentType` 动态设默认（05-platform-layer.md §4.1-G）。

**格式↔扩展名权威来源**：各 handler 的 `REGISTER_ARC` 注册表（本章从源码完整抽取，与 dylib 实测 60 格式一致）。下表是写入 Info.plist 的依据，覆盖**全部支持格式**：

**角色/rank 总规则（覆盖全表，安装时不得抢占任何系统默认）**：
- **`CFBundleTypeRole` 一律 `Viewer`，`LSHandlerRank` 一律 `Alternate`**（私有 7z 主类型可 `Owner`，因系统本无该类型不构成抢占）。**系统已有公共类型（zip/tar/gz/bz2/dmg/iso/xar，及 docx/xlsx/odt/ods/epub/jar/apk/ipa 等本质是 zip 但系统/第三方已声明专属 UTType 的扩展）绝不用 `Editor`/`Owner`**——否则安装即改变用户既有双击行为（zip 双击不再用"归档实用工具"而进 7-Zip）、与磁盘工具/Office 抢占类型，属侵入性副作用。
- "可压缩/可读写"语义不靠 `CFBundleTypeRole=Editor` 体现，而由**应用内功能**承担（在 7-Zip 面板里能改写该档）。`Editor` 仅决定 Launch Services 把谁当默认处理器——这正是必须避免静默抢占的点。
- **"设为默认应用"完全交给 FM 设置页运行期按用户逐项勾选执行**（`LSSetDefaultRoleHandlerForContentType`，与 Windows SystemPage 逐扩展名勾选语义对齐，§3.1 末、05 §4.1-G）。**安装时不得静默把任何系统公共类型的默认处理器改成本 App。**
- 下表"角色"列因此统一标 **Viewer/Alternate**（仅 7z 私有主类型 Owner）；旧版把 zip/gzip/tar 等标 Editor 的写法已撤销。

| 格式 | 扩展名（源自 REGISTER_ARC） | 建议 UTType identifier | 角色/rank |
|---|---|---|---|
| 7z | 7z | org.7-zip.7z-archive（私有 Exported） | **Viewer/Owner**（系统本无此类型，Owner 不抢占） |
| zip | zip z01 zipx xpi appx（**docx/xlsx/odt/ods/epub/jar/apk/ipa 见下方"勿重复声明"注**） | zip 主类型 conform `public.zip-archive`（Imported）；z01/zipx/xpi/appx 无系统 UTType 者建 `org.7-zip.*`（Exported） | **Viewer/Alternate** |
| gzip | gz gzip tgz tpz apk（`apk` 同时被 zip/gzip handler 注册，`GzHandler.cpp:1193`） | `org.gnu.gnu-zip-archive`(系统已有 .gz，Imported) / `org.7-zip.tgz`(Exported)；`apk`→`com.android.package-archive`(Imported，与 zip 行同一系统类型，去重) | **Viewer/Alternate** |
| bzip2 | bz2 bzip2 tbz2 tbz | `public.bzip2-archive`(系统已有，Imported) / `org.7-zip.tbz2`(Exported) | **Viewer/Alternate** |
| xz | xz txz | org.tukaani.xz-archive（无系统类型则 Exported） | **Viewer/Alternate** |
| zstd | zst tzst | org.7-zip.zstd-archive（Exported） | **Viewer/Alternate** |
| tar | tar ova | `public.tar-archive`(系统已有，Imported) | **Viewer/Alternate** |
| wim | wim swm esd ppkg | org.7-zip.wim-archive（Exported） | Viewer/Alternate |
| Rar/Rar5 | rar r00 | com.rarlab.rar-archive(系统/通用) | Viewer（仅解，unRAR 许可，见 02-core-bridge.md R） |
| Arj | arj | org.7-zip.arj-archive | Viewer |
| Lzh | lzh lha | org.7-zip.lzh-archive | Viewer |
| Cab | cab | com.microsoft.cab-archive | Viewer |
| Chm | chm chi chq chw | org.7-zip.chm-archive | Viewer |
| Cpio | cpio | public.cpio-archive | Viewer |
| Z | z taz | org.7-zip.compress-z | Viewer |
| Xar | xar pkg xip | com.apple.xar-archive(系统已有，Imported) | Viewer/Alternate |
| Dmg | dmg | com.apple.disk-image-udif(系统已有，Imported) | Viewer/Alternate |
| Iso/Udf | iso img udf | public.iso-image(系统已有，Imported) | Viewer/Alternate |
| Compound | msi msp msm doc xls ppt aaf | com.microsoft.*（系统/Office 已有，Imported） | Viewer/Alternate |
| Rpm | rpm | org.7-zip.rpm-archive（Exported） | Viewer/Alternate |
| Ar | ar a deb udeb lib | org.debian.deb-archive 等（已有则 Imported） | Viewer/Alternate |
| 其余磁盘/固件镜像（APFS/APM/AVB/Ext/FAT/GPT/HFS/NTFS/QCOW/VDI/VHD(X)/VMDK/SquashFS/CramFS/LVM/Sparse/MBR/Split…） | apfs ext ntfs fat hfs vhd vhdx vmdk vdi qcow qcow2 squashfs cramfs 001 等 | org.7-zip.<fmt>-archive（Exported） | Viewer/Alternate |
| 可执行/目标文件（PE/ELF/MachO/COFF/TE/Mub/Nsis/SWF/FLV…） | exe dll sys elf macho obj te nsis swf flv | 已有系统类型（如 com.microsoft.windows-executable / public.unix-executable）用 Imported，其余 org.7-zip.\<fmt\>（Exported） | Viewer/Alternate |

> **勿重复声明系统已拥有的 UTType（Imported vs Exported 判定规则，避免归属冲突）**：以下扩展名"本质是 zip 容器但系统/第三方已声明专属 UTType"，**一律 `conform` 到既有系统 UTType（写入 `UTImportedTypeDeclarations`），不得新建 `org.7-zip.*` 的 `UTExportedTypeDeclarations`**——重复声明系统已拥有的类型会触发归属冲突、图标与默认应用行为不确定：
> - `docx`/`xlsx` → `org.openxmlformats.wordprocessingml.document` / `org.openxmlformats.spreadsheetml.sheet`（系统/Office 拥有）；`pptx` → `org.openxmlformats.presentationml.presentation`。
> - `odt`/`ods` → `org.oasis-open.opendocument.text` / `...spreadsheet`。
> - `epub` → `org.idpf.epub-container`（系统已有）。
> - `jar` → `com.sun.java-archive`；`apk` → `com.android.package-archive`（公认类型）；`ipa` → `com.apple.itunes.ipa`（或 `com.apple.iphone.application`，按系统现状查表）。
>
> **仅对真正无系统 UTType 的 7-Zip 私有/不常见格式（如 z01/zipx/xpi、tgz/tbz2、zstd、wim、各磁盘/固件镜像）才建 `org.7-zip.*` Exported。** 系统已有公共归档 UTType（zip/tar/gz/bz2/dmg/iso/xar）也走 Imported conform，不重复 Exported。
>
> 完整扩展名清单（每格式逐 ext）见本仓库 `CPP/7zip/Archive/*/` 各 handler 的 `REGISTER_ARC` 行（zip 行：`CPP/7zip/Archive/Zip/ZipRegister.cpp:19-20` = `zip z01 zipx jar xpi odt ods docx xlsx epub ipa apk appx`），本章 §3.1 表已逐格式列全。

**Info.plist 片段（示意，注意：7z 私有类型用 Owner，所有系统公共类型一律 Viewer/Alternate，不静默抢占）**：

```xml
<key>CFBundleDocumentTypes</key>
<array>
  <dict>
    <key>CFBundleTypeName</key><string>7z Archive</string>
    <key>LSItemContentTypes</key><array><string>org.7-zip.7z-archive</string></array>
    <key>CFBundleTypeRole</key><string>Viewer</string>      <!-- 写改能力由 App 内功能承担，不靠 Editor 角色 -->
    <key>LSHandlerRank</key><string>Owner</string>          <!-- 仅私有 7z 类型可 Owner：系统本无此类型，不抢占 -->
    <key>CFBundleTypeIconFile</key><string>archive-7z</string>
  </dict>
  <dict>
    <key>CFBundleTypeName</key><string>ZIP Archive</string>
    <key>LSItemContentTypes</key><array><string>public.zip-archive</string></array>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Alternate</string>      <!-- 系统公共类型：绝不 Owner/Editor，安装不抢占归档实用工具 -->
  </dict>
  <dict>
    <key>CFBundleTypeName</key><string>RAR Archive</string>
    <key>LSItemContentTypes</key><array><string>com.rarlab.rar-archive</string></array>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Alternate</string>
  </dict>
  <!-- 其余每格式一条 dict；系统公共类型(zip/tar/gz/bz2/dmg/iso/xar/docx/xlsx/epub/jar/apk/ipa…)统一 Viewer+Alternate -->
</array>
<key>UTExportedTypeDeclarations</key>   <!-- 仅放真正无系统 UTType 的 7-Zip 私有/不常见格式 -->
<array>
  <dict>
    <key>UTTypeIdentifier</key><string>org.7-zip.7z-archive</string>
    <key>UTTypeDescription</key><string>7z Archive</string>
    <key>UTTypeConformsTo</key><array><string>public.data</string><string>public.archive</string></array>
    <key>UTTypeTagSpecification</key>
    <dict>
      <key>public.filename-extension</key><array><string>7z</string></array>
      <key>public.mime-type</key><array><string>application/x-7z-compressed</string></array>
    </dict>
  </dict>
  <!-- zstd/wim/各磁盘镜像等同此；NOT here: docx/xlsx/odt/ods/epub/jar/apk/ipa(系统已有，下方 Imported) -->
</array>
<key>UTImportedTypeDeclarations</key>   <!-- 系统/第三方已拥有的类型在此 conform，绝不重复 Exported -->
<array>
  <dict>
    <key>UTTypeIdentifier</key><string>public.zip-archive</string>
    <key>UTTypeConformsTo</key><array><string>public.data</string><string>public.archive</string></array>
    <key>UTTypeTagSpecification</key>
    <dict><key>public.filename-extension</key><array><string>zip</string></array></dict>
  </dict>
  <!-- gzip/bz2/tar/dmg/iso/xar 同此；docx→org.openxmlformats.* / epub→org.idpf.epub-container /
       jar→com.sun.java-archive / apk→com.android.package-archive / ipa→com.apple.itunes.ipa 等亦在此 Imported -->
</array>
```

图标：Windows 经 `CArchiveFolderManager::GetIconPath`（DLL 路径+图标索引，ArchiveFolderOpen.cpp:175）。mac 用 AssetCatalog，每格式一个图标（`CFBundleTypeIconFile` 或 UTType 的 `UTTypeIconFile`）—— 这是 03 风险#3 的落地：以静态表 + AssetCatalog 重建图标/扩展名数据库。

**设默认应用（仅运行期、用户逐项勾选触发，安装时不执行）**：FM 设置页（对应 Windows SystemPage 逐扩展名勾选）→ 用户勾选某类型后才调 `LSSetDefaultRoleHandlerForContentType(utType, kLSRolesAll, bundleID)`（按 UTType 而非扩展名，05 §4.1-G）。**这是唯一允许把系统公共类型默认处理器改成本 App 的路径**——与 Windows SystemPage 逐项勾选语义对齐；Info.plist 静态声明阶段一律 Viewer/Alternate，绝不静默抢占（与 §3.1 角色规则呼应）。

### 3.2 右键菜单：FinderSync vs Services vs App Intents 选型

Windows 的 `CZipContextMenu`（双协议 IContextMenu + IExplorerCommand，命令全集 24 项见 03 §1.2）在 macOS 没有单一等价物。三种机制能力对比：

| 维度 | FinderSync Extension（FIFinderSync + menu(for:)） | Services（NSServices / Info.plist NSMessage） | App Intents（macOS 13+） |
|---|---|---|---|
| 触发位置 | Finder 右键"快捷操作"上方/子菜单、工具栏 | 右键"服务"子菜单（用户常找不到） | Shortcuts.app、Spotlight、快捷操作、`focal filter` |
| 是否需独立扩展进程 | 是（Finder 加载的 app extension，独立沙盒进程） | 否（主 App 注册即可，按需启动） | 否（主 App 提供 intent） |
| 选中多文件传递 | `selectedItemURLs`（直接拿到全部选中 URL，无 16 项截断） | 经 NSPasteboard 传 fileURL 数组 | `@Parameter` 文件数组 |
| 动态子菜单/级联 | 支持 `menu(for: .contextualMenu)` 构建任意 NSMenu（可级联，对应 Windows "7-Zip"级联子菜单 + CRC 子菜单） | 扁平，每服务一项，**无动态子菜单** | 由系统编排，开发者不完全控制菜单层级 |
| 状态/按选中类型显隐 | 完全可控（在 menu(for:) 里按 selectedItemURLs 判断，复刻 QueryContextMenu 启发式） | 仅能按 `NSSendTypes` 粗粒度过滤 | 按参数类型匹配 |
| 拖放到目标文件夹（右键拖放） | FinderSync 不直接处理拖放；目标目录用 `targetedURL`（当前浏览目录）近似 | 否 | 否 |
| 沙盒/权限 | 强沙盒；访问选中文件经系统授予的临时权限 | 主 App 权限 | 主 App 权限 |
| 与主 App 通信 | XPC / App Group / 打开主 App（URL scheme） | 直接在主 App 进程执行 | 直接在主 App 进程执行 |
| 用户可发现性 | 高（右键直达，最接近 Windows 体验） | 低 | 中（偏自动化场景） |

**选型结论**：

1. **主选 FinderSync Extension** 复刻 Windows 右键菜单——它是唯一能在 Finder 右键提供**动态、可级联、按选中内容显隐**菜单的机制，最接近一对一目标。把 03 §1.2-1.3 的命令模型（`g_Commands`/`g_HashCommands`/kOpenTypes、`kExtractExcludeExtensions` 白名单、`GetSubFolderNameForExtract`、`CreateArchiveName`）整体抽为共享框架 `SevenZipCommandModel`，FinderSync 扩展与主 App 菜单共用（与 Windows "7zFM 进程内复用同一菜单类"完全同构，03 §1.8）。
2. **补充 App Intents** 提供 Shortcuts/Spotlight 自动化入口（Compress/Extract/Test/Hash），覆盖 Windows 没有但 mac 用户期待的自动化场景。
3. **Services 仅作降级兜底**（不做动态菜单，只注册 "Compress with 7-Zip"/"Extract here" 等少数固定项），用于 FinderSync 扩展未启用时。

**FinderSync 的硬约束（必须正面处理，不是实现细节）**：

`FIFinderSyncController` 只在用户当前**浏览/选中的项位于扩展通过 `setDirectoryURLs:` 注册的目录子树内**时，才会被 Finder 回调 `menu(for:)` 与 `selectedItemURLs()`。这与 Windows `IContextMenu`"对任意选中项即时可用、即装即用"**不是 1:1**。落地约束：

1. **注册策略——按卷动态注册，不静态写死 `/`**。设 `setDirectoryURLs:[file:///]`（名义全盘）虽可让菜单"全盘出现"，但代价是 Finder 每次目录切换都唤醒扩展进程（Apple 文档明确不鼓励，资源开销大）。本方案采用：启动时枚举 `FileManager.default.mountedVolumeURLs(...)`（含 `/`、`/Volumes/*`）调 `setDirectoryURLs:`；监听 `NSWorkspace.didMountNotification` / `didUnmountNotification`（或 `NSWorkspace.shared.notificationCenter` 的 `.NSWorkspaceDidMount`），卷挂载/卸载后**重新调 `setDirectoryURLs:` 重注册**。外接盘/网络卷/可移动盘挂载后若不重注册，其内右键无 7-Zip 菜单。
2. **沙箱 URL 约束**：扩展是强沙箱进程，对**注册目录子树之外**的项拿不到 URL；`selectedItemURLs()` 仅返回授予访问的项。设计上不依赖跨子树的选中项。
3. **可观测验收**（"扩展未被调用"必须可检测）：(a) 在已注册卷内右键，1 秒内出现"7-Zip"菜单；(b) 挂载一个新外接卷后右键，菜单出现（验证重注册生效）；(c) 用 `pluginkit -m -i <extBundleID>` 确认扩展已 enabled；(d) `log stream --predicate 'subsystem == "<extBundleID>"'` 能看到 `menu(for:)` 被调用的日志——若无日志则判定"扩展未被调用"，触发 OQ-9 的 Services 兜底降级。

**FinderSync 实现要点**：
- 扩展 target，Info.plist 声明 `FIFinderSyncController`；`directoryURLs` **不在 Info.plist 静态声明全盘**，而由扩展运行期按上述"按卷动态注册 + 挂载监听重注册"调 `setDirectoryURLs:`。
- `override func menu(for menuKind: FIMenuKind) -> NSMenu`：读 `FIFinderSyncController.default().selectedItemURLs()` → 喂 `SevenZipCommandModel` → 生成 NSMenu（级联用 NSMenuItem.submenu）。**无 16 项截断协议**（03 §1.3-3：Windows 特化逻辑，mac 直接拿全量 selectedItemURLs，剥离）。
- 菜单项 action → 经 XPC/`NSWorkspace.open(url:configuration:)` 用 URL scheme 唤起主 App（§3.4），或经 App Group 共享操作描述后启动主 App。**不在扩展进程内跑压缩/解压**（扩展沙盒受限、生命周期短）——对应 Windows "右键→7zG 子进程"，mac 改为"右键→主 App 执行"。
- 命令决策（哪些项显示、档名、子目录名）全部来自共享 `SevenZipCommandModel`，扩展不重新实现启发式。
- 菜单配置（级联/图标/ElimDup/启用项掩码 `NContextMenuFlags`，对应 Windows MenuPage）存 **App Group UserDefaults**，主 App 设置页写、扩展读（03 §1.6、05 §4.2 末"App Group 共享给 extension 进程"）。

命令全集（FinderSync 菜单需复刻，源自 03 §1.2）：Open / Extract / Extract Here / Extract to "<sub>"/ / Test / Compress / Compress to "<name>.7z" / Compress to "<name>.zip" / CRC 子菜单(CRC32/CRC64/XXH64/MD5/SHA1/SHA256/SHA384/SHA512/SHA3-256/BLAKE2SP/全部) / "SHA-256 -> file.sha256" / Checksum:Test / "Open >" 打开方式子菜单（"" * # #:e 7z zip cab rar）。Email 系列（依赖 MAPI）见 §3.5。

> **哈希命令集差异交叉注解（移植勿遗漏）**：FM File→CRC 子菜单 = **10 算法 + "*"** 共 11 项（`resource.rc:56-69`，无 Generate/TestArc）；FinderSync/右键 = **多出 "SHA-256 -> file.sha256" 与 "Checksum : Test"** 两项，共 **13 项**（`g_HashCommands[]`，`CPP/7zip/UI/Explorer/ContextMenu.cpp:294-308`，已逐项核实）。二者命令模型同源（共享 `SevenZipCommandModel`），但呈现集合不同——移植 FinderSync 菜单时务必含这两项扩展哈希命令（`kHash_Generate_SHA256`/`kHash_TestArc`），FM File 菜单则不含（与 03 §1.1 CRC 子菜单 10 算法+"*" 口径一致）。

### 3.3 拖拽到 Dock / 应用图标

Windows 经 `DragDropHandlers` shellex（Directory/Drive，RegistryContextMenu.cpp:28-48）+ 右键拖放（`_dropMode`/`_dropPath`，ContextMenu.cpp:201-231）。macOS：

- **拖到 Dock 图标 / App 图标**：实现 `-[NSApplicationDelegate application:openURLs:]`（macOS 10.13+，替代旧 `application:openFiles:`）。拖入的文件 URL 数组 → 默认行为按文件类型决策：
  - 拖入档案文件 → 等价 "Open"（在 FM 打开）或可配置为 "Extract Here"。
  - 拖入非档案文件/文件夹 → 等价 "Compress"（弹压缩对话框，输入即拖入项）。
  - 此决策复用 `SevenZipCommandModel` 的扩展名启发式（与右键菜单同源）。
- **拖入主窗口面板**：FM 面板自身拖放属 03-feature-map-filemanager.md 范围（PanelDrag.cpp → NSDraggingDestination）。
- **右键拖放的"放到目标文件夹"**：mac 无精确等价；FinderSync 用 `targetedURL()`（当前浏览目录）近似 Windows `_dropPath`。这是能力差异项（§5）。

> **澄清（避免混述）**：本节"拖到 Dock"是**拖入**方向（Finder/桌面 → 本 App）。下面 §3.3.1 的"拖出归档项"（延迟解压、`NSFilePromiseProvider`）只发生在 **SevenZipFM.app 主面板内**，**Finder 内不提供从归档拖出**——FinderSync 没有拖放释放点回调（§5 #3/#4），所以 Windows"在 Explorer 内把压缩包里的项拖到桌面/文件夹"在 mac 由"在 7-Zip 主面板内把归档项拖到 Finder"承担，二者不要混为一谈。

### 3.3.1 从主面板拖出归档项（延迟解压 NSFilePromiseProvider）

仅 **SevenZipFM.app 主面板**提供；Finder 内不存在此能力（见上）。延迟解压（拖到落点才解）用 `NSFilePromiseProvider`，但其无内建进度 UI，且回调若在主队列或同步解大档会让 Finder 长时间转圈，必须按下列约束实现：

- **独立后台队列**：`NSFilePromiseProviderDelegate` 实现 `-operationQueueForFilePromiseProvider:` 返回一个**专用 background `NSOperationQueue`**（QoS `.utility`，`maxConcurrentOperationCount` 受控），绝不返回 `NSOperationQueue.mainQueue`。`writePromiseToURL:` 回调在该队列上**才**调 `-[SZArchiver extractItem:toURL:]`（§1.7/§2.4 执行入口），解压全程在后台。
- **进度展示**：`NSFilePromise` 自身无进度 UI——拖出大档时复用主 App 的 `SZProgressWindowController`（§2.4/§2.5）显示进度：在 `writePromiseToURL:` 起一个 `SZOperation`（独立 `CProgressSync` + 进度窗），把 promise 的解压挂到该 operation 的进度回调上。短任务受 500ms 创建延迟（§2.4 kCreateDelay）保护不闪窗。
- **取消与残留清理**（对齐 03 §5.3 验收"取消后落点无残留半成品"）：promise 失败/取消（用户中途取消拖放、`SZOperation.cancel`、解压报错）时，回调必须在 `completionHandler(error)` 返回前**删除已部分写入的落点文件/目录**（`FileManager.removeItem(at:)`），不留半成品。取消路径与 §2.4 `IDCANCEL`→`Set_Stopped`→`E_ABORT` 统一：`E_ABORT` 静默回 promise 错误并清理。
- **多项拖出**：每个被拖出的归档项一个 `NSFilePromiseProvider`，共享同一后台队列与同一 `SZOperation`（同一档案的引擎实例不可跨线程并发，§2.5 #2），落点解压串行排队。

### 3.4 URL scheme 与 Apple Events 自动化接口

Windows 无对应物（7zG 经命令行/IPC）。mac 提供两条自动化通道：

1. **URL scheme**（供 FinderSync 扩展 → 主 App 唤起，及第三方脚本）：Info.plist 注册 `CFBundleURLTypes`，scheme 如 `sevenzip://`。命令编码示例：
   - `sevenzip://compress?paths=<base64url-json-array>&format=7z&dialog=1`
   - `sevenzip://extract?archive=<url>&dest=<url>&dialog=0`
   - `sevenzip://test?archive=<url>` / `sevenzip://hash?paths=...&method=SHA256`
   - 主 App `application:openURLs:` 解析 → 映射到五个执行 API（CompressFiles/ExtractArchives/TestArchives/CalcChecksum/Benchmark，与 CompressCall2 同一组，02 §11.2）。**这正是 Windows `-ad`/命令行协议的 mac 等价物**（02 §1，`options.ShowDialog`=`dialog=1`）。
2. **App Intents / Shortcuts**（推荐主自动化）：定义 `CompressIntent`/`ExtractIntent`/`TestIntent`/`HashIntent`，参数为文件 URL 数组 + 选项。系统自动暴露到 Shortcuts.app、Spotlight、快捷操作。
3. **Apple Events / AppleScript**（可选传统通道）：提供 `.sdef` 脚本字典（compress/extract verbs），供老脚本与 Automator。优先级低于 App Intents，列为后续（开放问题）。

> 命令行兼容：Windows `SplitCommandLine(GetCommandLineW)` 在 mac 改 argv 直传（R12/02 §13），仅服务调试入口；面向用户的自动化走 URL scheme/App Intents。

### 3.5 Email 命令族（Compress to Email）

Windows 经 MAPI（ContextMenu.cpp:929-1004 共 3 项，03 风险#9）。mac：压缩完成后经 `NSSharingService`（`NSSharingServiceNameComposeEmail`）或 `NSSharingServicePicker` 分享附件。**v1 可裁剪**（拖放/Email 系列在 mac 习惯弱），列为开放问题。

### 3.6 文件关联/右键的设置页（对应 Windows MenuPage/SystemPage）

- **右键菜单设置**（级联/图标/ElimDup/各菜单项勾选/WriteZone）：mac 设置页写 App Group UserDefaults，FinderSync 扩展读（§3.2）。WriteZone（MOTW）→ macOS quarantine（§5、05 §5.8）。
- **文件关联**（逐扩展名设默认）：→ `LSSetDefaultRoleHandlerForContentType`（§3.1）。
- 注册/反注册（regsvr32、shellex 注册键，03 §1.6）→ **mac 无对应**：FinderSync 由系统在 App 安装后于"系统设置→扩展"启用，无显式注册代码。

### 3.7 签名/沙箱对 dylib 加载与扩展的硬约束（Hardened Runtime / Library Validation / App Sandbox）

01-architecture.md §8.4 与底料 04-core-dylib.md:183 的"hardened runtime 下 dlopen 同签名 dylib 无障碍"只在**同 Team ID 签名 + 主 App 进程**下成立。本节把隐含前提写死为约束，与 §3.2 FinderSync 决策、§3.1 LoadCodecs/NSBundle 路径解析交叉收口。

1. **Library Validation 是默认开启的硬前提**：Hardened Runtime 默认启用 Library Validation，要求被 `dlopen` 的 `lib7z.dylib`（及兼容符号链接 `7z.so`）与加载方**同 Team ID 签名**。`lib7z.dylib` 由上游 `make` 产出再单独 `codesign`（05-roadmap-execution.md §10.4 步骤1），其签名身份必须与主 App / framework / 扩展一致。**CI 强制校验**（非可选）：
   ```sh
   # 单独校验引擎 dylib 的 Team ID 与主 App 一致（任一不符 CI fail）
   APP_TEAM=$(codesign -dvvv SevenZipFM.app 2>&1 | sed -n 's/^TeamIdentifier=//p')
   DYLIB_TEAM=$(codesign -dvvv SevenZipFM.app/Contents/Frameworks/lib7z.dylib 2>&1 | sed -n 's/^TeamIdentifier=//p')
   test -n "$APP_TEAM" && test "$APP_TEAM" = "$DYLIB_TEAM" || { echo "Team ID mismatch: app=$APP_TEAM dylib=$DYLIB_TEAM"; exit 1; }
   codesign --verify --strict --verbose=2 SevenZipFM.app/Contents/Frameworks/lib7z.dylib
   ```
   这把 05 §10.4 已写的 `codesign --sign "Developer ID Application: <NAME> (<TEAMID>)"` 从"隐含"升级为"可验收"。
2. **FinderSync 扩展进程永不 dlopen 引擎（写死为约束，非默认）**：扩展是强沙箱进程，叠加沙箱 + Library Validation。当前 §3.2 决策——扩展只取 `selectedItemURLs` 生成菜单、经 XPC/URL scheme 把操作交主 App 执行，**不在扩展内跑压缩/解压**——同时消除了"扩展端需 dlopen `lib7z.dylib`"的需求。**约束**：FinderSync target 不链接、不 `dlopen` `lib7z.dylib`/`SevenZipKit`；其 entitlements 不需要 `com.apple.security.cs.disable-library-validation`。若未来确需扩展端跑引擎（不推荐），则扩展须与 dylib 同 Team 签名，否则要加 `disable-library-validation`（破坏加固承诺），此为范围外。
3. **App Sandbox 阶段（可选后续）的 entitlements 清单**：设计公约定分发主线为 Developer ID + 公证，App Sandbox 为可选后续（05 §10、Q7）。**App Sandbox 下 `dlopen` 仅允许 app bundle 内路径**，外部路径被拒——这与 §3.1/§4.1 决策（桥接层经 `NSBundle` 解析 `Contents/Frameworks/lib7z.dylib` 的 bundle 内绝对路径、不依赖外部路径）天然兼容，无需改动；但若沙盒化需评估的 entitlements 至少包括：
   - 主 App：`com.apple.security.app-sandbox`、`com.apple.security.files.user-selected.read-write`（NSOpenPanel/NSSavePanel 授予的档案与目标目录）、`com.apple.security.cs.disable-library-validation` **仅在确认无法同 Team 签名时才用，默认不加**。
   - FinderSync 扩展：`com.apple.security.app-sandbox` + 与主 App 共享的 App Group（§3.2 菜单配置读写、§3.4 操作描述传递）；扩展对选中文件的访问由系统经 Finder 授予的临时权限提供。
   - 引擎本身不需要 entitlements（dylib 不是可执行体）。

---

## 4. 附：格式 → UTType 映射数据来源与生成

### 4.1 权威来源

格式集 = lib7z.dylib 实测 60 格式（02-core-bridge.md §0），每格式的 name/extension 来自 `GetHandlerProperty2(formatIndex, kName/kExtension/kAddExtension)`（`CPP/7zip/Archive/ArchiveExports.cpp:94-135`）或源码 `REGISTER_ARC` 注册块（`CPP/7zip/Archive/*/`）。**建议构建期生成**：写一个小工具 dlopen `7z.so`，枚举 `GetNumberOfFormats` + `GetHandlerProperty2`，自动产出 Info.plist 的 UTType 片段与 AssetCatalog 索引——避免手工维护 60 格式 × 多扩展名的清单漂移。

**生成工具必做的"系统 UTType 查表"步骤（防归属冲突、防抢占）**：对每个抽出的扩展名，先用 `UTType(filenameExtension:)` / `UTTypeReferenceWithFilenameExtension`（UniformTypeIdentifiers，macOS 13+）查"系统是否已注册该扩展名的 UTType"：
1. **已注册系统/第三方类型**（如 zip→`public.zip-archive`、docx→`org.openxmlformats.*`、epub→`org.idpf.epub-container`、jar→`com.sun.java-archive`、apk/ipa 等）→ 生成 `UTImportedTypeDeclarations` conform 条目，`CFBundleDocumentTypes` 角色固定 **Viewer + Alternate**；**不得**为该扩展名再造 `org.7-zip.*` Exported。
2. **无系统类型的 7-Zip 私有/不常见格式** → 生成 `org.7-zip.*` `UTExportedTypeDeclarations`，角色 Viewer + Alternate（仅 7z 主类型 Owner）。
3. 工具把"扩展名→(类型 id, Imported/Exported, role, rank)"决策表落盘为构建产物，CI 比对防清单漂移；新增/变更系统类型时只改查表逻辑，不手改 plist。

### 4.2 格式↔扩展名完整表（源码抽取，本章已用于 §3.1）

本章 §3.1 表已含全部格式与其扩展名；逐 ext 的权威清单见各 handler 源码 `REGISTER_ARC` 行。可压缩（Editor 角色）的格式集与压缩对话框 `g_Formats`（02 §2.2）一致：7z/zip/gzip/bzip2/xz/tar/wim/zstd（+ Hash 伪格式）；其余 50+ 格式为只读（Viewer 角色，`CreateOutArchive` 为空，Agent.cpp:1589 的 UpdateEnabled 判定）。

---

## 5. Explorer 能力差异表（Windows Shell 扩展能做 / mac 受限）

逐项列出 Windows Shell 扩展的能力，及 mac"做不到/换法做"的结论与理由。证据指回 03-explorer-agent.md。

| # | Windows 能力 | mac 结论 | 换法 / 理由 |
|---|---|---|---|
| 1 | **资源管理器内嵌列**（Shell 可向 Explorer 报表视图注入自定义列，如显示压缩包内项数/CRC） | **做不到** | Finder 无第三方注入列的 API。换法：仅在 SevenZipFM.app 主窗口的列表视图提供这些列；Finder 内不显示 |
| 2 | **右键菜单动态级联**（IContextMenu/IExplorerCommand 任意层级，03 §1.1-1.3） | **换法做（FinderSync，能力受限、需配合卷挂载监听）** | FinderSync `menu(for:)` 可建任意 NSMenu 级联，菜单结构能力足够；**但菜单仅在 `setDirectoryURLs:` 注册的目录子树内出现**——必须按卷动态注册 + 监听 `NSWorkspace` 挂载/卸载通知重注册（§3.2"硬约束"），否则外接/网络卷内右键无菜单。另需独立扩展进程、用户须在系统设置启用（不如 Windows 即装即用、不如 IContextMenu 对任意选中项即时可用）。未被调用时走 OQ-9 的 Services 兜底 |
| 3 | **右键拖放到精确目标文件夹**（`_dropPath` = 拖放释放点目录，03 §1.5） | **部分做不到** | FinderSync 无"拖放释放目标"回调；只能用 `targetedURL()`（当前浏览目录）近似。理由：Finder 拖放语义不暴露释放点给扩展 |
| 4 | **DragDropHandlers**（对 Directory/Drive 注册拖放处理，03 §1.5） | **换法做** | 拖到 App/Dock 图标（`application:openURLs:`，§3.3）+ 拖入主窗口面板（NSDraggingDestination）。Finder 文件夹上的拖放扩展无等价 |
| 5 | **16 项截断协议**（Explorer 对 >16 选中项只传前 16，invoke 时重建，03 §1.3） | **不需要** | FinderSync `selectedItemURLs()` 直接给全量。理由：mac 无此限制，相关特化逻辑剥离 |
| 6 | **Shell 图标 overlay/缩略图提供器**（Windows 可为档案提供自定义缩略图） | **换法做（QuickLook）** | macOS 用 QuickLook Thumbnail Extension 提供档案缩略图/预览；非右键扩展范畴，列为增强（开放问题） |
| 7 | **regsvr32 自注册 / shellex 注册键**（03 §1.6） | **不需要/做不到** | mac 扩展无注册表，系统按 Info.plist 声明 + 用户在"系统设置→扩展"启用。无等价注册代码 |
| 8 | **MOTW / Zone.Identifier ADS**（WriteZoneIdExtract，解压时写来源标记，03 §1.5/§2.3） | **换法做（quarantine）** | macOS 用 `com.apple.quarantine` xattr（NSURL quarantinePropertiesKey）。语义需重设计而非直译（05 §5.8、风险#4）：解压网络来源档案应传播 quarantine |
| 9 | **NTFS ADS 浏览/写**（AltStreams 文件夹，压缩 AltStreams 复选） | **做不到/隐藏** | macOS 无 NTFS ADS；编译期排除（05 §5.7）。档内 ADS 条目仍按普通名解出 |
| 10 | **NT 安全描述符还原**（NtSecurity 复选） | **做不到/隐藏** | mac 无对应（05 §5.7、§6.7），编译期排除，对话框复选隐藏 |
| 11 | **大页内存 / -slp**（CompressCall.cpp:100） | **做不到/隐藏** | macOS 无用户态大页特权（05 §2.2 MemoryLock stub）；设置项与 `-slp` 开关隐藏 |
| 12 | **Email 子菜单（MAPI）**（03 §1.2/§3.5） | **换法做（NSSharingService）** | 无 MAPI；用分享服务发邮件。v1 可裁剪 |
| 13 | **网络邻居虚拟文件夹**（Net.cpp，03 §2.2/05 §2.2） | **做不到/砍掉** | Windows 专属；mac 浏览 `/Volumes` 挂载点近似 |
| 14 | **"Open >" 打开方式子菜单**（强制以特定类型打开，kOpenTypes，03 §1.2） | **换法做** | FinderSync 子菜单 → URL scheme 带 `-t<type>` 参数唤起主 App。能力等价 |
| 15 | **多进程崩溃隔离**（右键→独立 7zG 进程，崩溃不影响 Explorer/FM，03 §6/02 §11.3） | **部分丧失** | 进程内化后操作在主 App 进程；核心稳定性由 7zz 实测背书。超大任务可保留 XPC 子进程（开放问题） |

---

## 6. 本章涉及的 Windows 专属功能项 mac 取舍汇总

| 功能项 | Windows 落点 | mac 取舍 | 实现钩子 |
|---|---|---|---|
| SFX 自解压（.exe + 7z.sfx 模块） | `options.SfxMode`，默认模块 `<dir>/7z.sfx`（UpdateGUI.cpp:561-565，`kDefaultSfxModule="7z.sfx"`，cpp:31） | **隐藏复选**（无 Windows PE 自解压模块；mac 自解压需另造 shell 脚本/可执行壳，非一对一范围） | `g_Formats[].kFF_SFX` 视作 false，FormatChanged 现有显隐逻辑自动隐藏（R8/02 §13） |
| 共享文件压缩（-ssw） | `options.OpenShareForWrite` | 保留键，语义弱化（mac 无强制锁） | 复选保留 |
| NTFS AltStreams/NtSecurity | 压缩选项 + 解压 NtSecurity 复选 | 隐藏（编译期排除） | Supported=false |
| 大页（-slp） | LargePages 设置/MemoryLock | 隐藏 | stub（05 §2.2） |
| Email（-seml/MAPI） | CompressCall email 模式 | NSSharingService 或裁剪 | 开放问题 |
| ZoneId（-snz/WriteZone） | 解压写 Zone.Identifier | com.apple.quarantine | 新增桥接（05 §5.8） |
| Help（HtmlHelp，CompressDialog.cpp:1254） | `fm/plugins/7-zip/add.htm` 等 | 帮助跳 web（NSWorkspace openURL 到在线文档） | Help 按钮 |
| 本地化（Z7_LANG, Lang/*.txt） | LoadLangOneTime | **可保留**（纯文件解析，05 §7）或换 NSLocalizedString | 二选一需评审（开放问题） |
| 符号链接/硬链接（压缩选项） | SymLinks/HardLinks 复选 | **保留可见**（POSIX 原生支持，已实测） | 复选保留 |

---

## 7. 开放问题（无法从源码定案，需评审/决策）

1. **本地化体系选择**：保留 7-Zip 自带 `Lang/*.txt`（LangUtils.cpp，纯文件解析，92 种语言可随 .app 分发，05 §7）还是改用 NSLocalizedString/`.strings`？前者一对一程度高、迁移成本低，后者更"原生"。两者对对话框字符串数量（39 个 .rc）影响相同，需产品/工程评审定调。
2. **多任务进度并行的"操作中心"**：§2.5 给出了"每操作独立窗口"的 v1 方案；是否额外提供类似 Safari 下载列表的汇总面板（统一暂停/取消/清理）？属增强，非一对一必需。
3. **超大任务的 XPC 子进程选项**：进程内化丧失崩溃隔离（§5-15、R/02 §11.3）。是否对超过某阈值（如 >50GB 或 >100k 文件）的操作保留 XPC 子进程模式以隔离崩溃？需性能/稳定性权衡。
4. **SFX 自解压在 mac 的形态**：是否要提供 mac 等价自解压（shell 脚本壳 / 可执行 stub + 附加 .7z）？Windows 的 `7z.sfx` 是 PE 模块，无法直接复用。若做属新功能（超出一对一），需范围决策。
5. **Email/分享系列是否进 v1**：拖放/Email 在 mac 用户习惯中较弱（§3.5、§5-12）。是否首版裁剪、后续以 NSSharingService 补齐？
6. **QuickLook 预览/缩略图扩展是否纳入范围**：§5-6 指出 Finder 内嵌列/缩略图需 QuickLook 扩展。这是 mac 特有增强（Windows 经 Shell 缩略图提供器），是否纳入一对一范围之外的"平台贴合"增强？
7. **Apple Events/AppleScript 字典（.sdef）是否提供**：§3.4 给出 URL scheme + App Intents 两条主通道；传统 AppleScript 通道是否需要（兼容老 Automator 工作流）？
8. **WriteZoneIdExtract 三档策略到 quarantine 的精确映射**：Windows 有"始终/仅可执行/从不"等档（ZipRegistry.cpp:544）。com.apple.quarantine 的传播规则（哪些来源、哪些文件类型打标）需安全评审定档（05 §5.8 标为"重设计而非直译"）。
9. **FinderSync 扩展未启用/未被调用时的体验降级**：两种"右键无 7-Zip 菜单"的情形——(a) 用户未在系统设置启用扩展；(b) 扩展已启用但当前项不在 `setDirectoryURLs:` 注册的目录子树内（如未重注册的新挂载卷，§3.2 硬约束）。是否需首启引导 + Services 兜底？§3.2 选型已建议 Services 兜底并给出"扩展未被调用"的可观测判定（pluginkit/log stream），但兜底覆盖到哪些命令、(b) 情形是否也回退 Services 需定。
