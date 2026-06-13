# 02 核心动态库与桥接层

> 7-Zip Windows GUI 一对一移植 macOS · 方案 B（核心 dylib + ObjC++ 桥接 + AppKit）
> 本章是全方案技术含量最高的一章，描述 **lib7z.dylib（核心动态库）→ SevenZipKit.framework（ObjC++ 桥接层）** 两层的可执行落地方案。
> 总体架构与三层职责划分见 01-architecture.md；GUI 功能映射见 03-feature-map-filemanager.md / 04-feature-map-dialogs-finder.md；任务排期与里程碑见 05-roadmap-execution.md。
> 仓库根：`/Users/lyd/WorkSpace/MyProjects/7zip`。引用源码一律 `路径:行号`。
> 本章所述构建/ABI/线程事实均经底料 04（核心 dylib 实测）、底料 03（Explorer/Agent）、底料 05（平台层）核实。

---

## 0. 本章定位与已落地事实

方案 B 的核心边界：**引擎全部格式 handler / 编解码 / 加密 / 汇编优化** 已由 7zz 26.01 在本机（macOS arm64 / clang）编译并自测通过，且 Format7zF 全格式 bundle 用 stock makefile 一次编译产出 Mach-O dylib，参考客户端 dlopen 完成压缩/列表/解压 roundtrip（底料 04 §0、§8）。因此本章不再讨论"引擎是否可移植"，而是回答四个工程问题：

1. 如何把 Format7zF 构建为可分发、可签名、universal 的 `lib7z.dylib`（§1）；
2. dylib 对外暴露的 C ABI 到底是哪 19 个函数、各自语义（§2）；
3. 归档"文件夹化"的 Agent 层在 macOS 上复用到什么程度（§3）；
4. ObjC++ 桥接层 SevenZipKit 的类设计、类型映射、内存/线程/取消规则（§4–§7），以及 M0 里程碑的可执行验收（§8）。

**关键决策一句话版：** dylib 边界只走 C 风格 `CreateObject` 工厂 + COM 接口指针（不跨边界传 C++ 异常）；Agent 层 7 个 `.cpp` 在 macOS 全部可编译复用（仅 1.5 处需动手）；桥接层用 ObjC++ 包装 `CMyComPtr` + 串行 dispatch queue；**进度采用与 Windows 一致的 pull（拉取）模型**——引擎回调仅原子写入共享进度结构、绝不 `dispatch_async`，由桥接层持有的 200ms main-queue 定时器周期性合并送达 delegate；取消经 `E_ABORT` 回传。

---

## 1. lib7z.dylib 构建方案

### 1.1 现状基线（实测，零改动可用）

构建入口已存在且验证通过（底料 04 §0、§3.1）：

```sh
cd CPP/7zip/Bundles/Format7zF
make -f ../../cmpl_mac_arm64.mak -j8
# 产出 b/m_arm64/7z.so，file 判定 Mach-O 64-bit dynamically linked shared library arm64
# otool -hv filetype=DYLIB，约 2.51 MB，仅依赖 libSystem + libc++
```

链条：`cmpl_mac_arm64.mak`（`CPP/7zip/cmpl_mac_arm64.mak:1-3`）= `include ../../var_mac_arm64.mak` + `warn_clang_mac.mak` + bundle 内 `makefile.gcc`。`var_mac_arm64.mak` 设 `O=b/m_arm64, IS_ARM64=1, MY_ARCH=-arch arm64, USE_ASM=1, CC=clang, CXX=clang++`（实测文件 `CPP/7zip/var_mac_arm64.mak:1-13`）。`Format7zF/makefile.gcc:1-2` 设 `PROG=7z`、`DEF_FILE=../../Archive/Archive2.def`；`DEF_FILE` 非空 + 非 MinGW → 触发共享库分支 `SHARED_EXT=.so; LDFLAGS=-shared -fPIC $(LDFLAGS_STATIC); CC_SHARED=-fPIC`（`CPP/7zip/7zip_gcc.mak:99-110`，**.def 文件本身在非 Windows 不参与链接**）。`makefile.gcc:36-39` 已定义 `-DZ7_EXTERNAL_CODECS`（外部编解码器注入能力）。

**实测产物的四个待修问题**（底料 04 §3.4，逐个有处置）：

| 问题（`otool` 实测） | 处置 |
|---|---|
| `LC_ID_DYLIB`（install_name）= `b/m_arm64/7z.so`（构建相对路径） | `-Wl,-install_name,@rpath/lib7z.dylib` |
| 导出 4041 个符号（含全部 C++ 内部符号） | `-Wl,-exported_symbols_list,exports7z.txt`（19 个 C 入口加下划线前缀）+ `-Wl,-dead_strip` |
| 无版本号（compatibility/current = 0.0.0） | `-Wl,-compatibility_version,1 -Wl,-current_version,26.1` |
| 未签名 | 分发前 `codesign --options runtime`（hardened runtime） |

> 注意 Mach-O `current_version` 字段为 `X[.Y[.Z]]`，X≤65535，Y/Z≤255，**不能写 `26.01`（前导零会被吞且语义为 26.1）**，统一写 `26.1`（对应 §2 `GetModuleProp(kVersion)=0x1A0001`）。

### 1.2 命名决策：`lib7z.dylib`，同时保留 `7z.so` 兼容名

- `dlopen` 不关心扩展名（底料 04 §0 实测：把 `7z.so` 改名 `lib7z.dylib` 后 dlopen 成功）。
- 但 `CPP/7zip/UI/Common/LoadCodecs.cpp:72-77` 把主模块名硬编码为 `kMainDll`（非 `_WIN32` 分支为 `FTEXT("7z.so")`，已核实源码）。本方案桥接层 **不复用 LoadCodecs**（桥接层自己 `dlopen` 绝对路径，见 §4.2），故文件名可自由取 `lib7z.dylib`。
- 但 03-feature-map-filemanager.md 的 FM 移植**会复用 Agent → LoadGlobalCodecs → CCodecs::Load → kMainDll**（底料 03 §2.7）。为同时满足两条消费路径，决策：**产物文件名定为 `lib7z.dylib`，并在 .app 的 `Contents/Frameworks/` 内对它建一个符号链接 `7z.so → lib7z.dylib`**（构建脚本一行 `ln -sf`），LoadCodecs 零改动即能命中。若不愿带符号链接，备选是改 `LoadCodecs.cpp:72-77` 一行为 `FTEXT("lib7z.dylib")`（侵入一行，已知精确位置）。

### 1.3 新增构建文件：`var_mac_arm64_dylib.mak` 与导出符号清单

采用**零侵入挂接点** `LDFLAGS_STATIC_3`——该变量已被 `7zip_gcc.mak:88`（`LDFLAGS_STATIC = $(CFLAGS_DEBUG) $(LDFLAGS_STATIC_2) $(LDFLAGS_STATIC_3)`）纳入最终链接参数，且 stock makefile 从不赋值，专为下游追加链接选项预留。

新增 `CPP/7zip/var_mac_arm64_dylib.mak`（草案，与现有 `var_mac_arm64.mak` 并列）：

```make
# var_mac_arm64_dylib.mak —— 在标准 arm64 变量基础上叠加 dylib 化链接选项
include var_mac_arm64.mak

# 把 4041 个全量导出收敛到 19 个 C ABI 入口；版本号与 install_name；死代码剔除
LDFLAGS_STATIC_3 = \
  -Wl,-exported_symbols_list,$(EXPORTS_LIST) \
  -Wl,-install_name,@rpath/lib7z.dylib \
  -Wl,-compatibility_version,1 \
  -Wl,-current_version,26.1 \
  -Wl,-dead_strip

EXPORTS_LIST = $(MAKEFILE_DIR)/exports7z.txt
```

> `cmpl_mac_arm64.mak` 第一行改 `include ../../var_mac_arm64_dylib.mak` 即可，或新增并列的 `cmpl_mac_arm64_dylib.mak`（推荐后者，保留原 stock 入口不动）：
>
> ```make
> # CPP/7zip/cmpl_mac_arm64_dylib.mak
> include ../../var_mac_arm64_dylib.mak
> include ../../warn_clang_mac.mak
> include makefile.gcc
> ```
>
> （`EXPORTS_LIST` 在 bundle 目录内执行 make 时按相对路径解析，路径以实际构建脚本工作目录为准——见开放问题 Q1。）

导出符号清单 `CPP/7zip/Bundles/Format7zF/exports7z.txt`（Mach-O 符号名带前导下划线，19 个 = 底料 04 §1.1 的 15 个官方 ABI + §1.2 的 4 个辅助符号；按需可只留官方 15 个）：

```
_CreateObject
_GetNumberOfFormats
_GetHandlerProperty2
_GetHandlerProperty
_GetIsArc
_GetNumberOfMethods
_GetMethodProperty
_CreateDecoder
_CreateEncoder
_GetHashers
_SetCodecs
_SetLargePageMode
_SetLargePageMode2
_SetCaseSensitive
_GetModuleProp
_CreateArchiver
_CreateCoder
_CreateHasher
_GetHasherProp
```

> 桥接层只 `dlsym` 这 19 个（§4.2），但 `Init_ForceToUTF8` 是 dylib 加载时自动执行的 `__attribute__((constructor))`（`CPP/7zip/Archive/DllExports2.cpp:73-78`），**不是导出符号、无需列入**，加载即生效。

### 1.4 universal 合并、签名、嵌入布局

```sh
# 1) 两切片分别构建（x64 切片 USE_ASM= 关闭 arm64 汇编，见 var_mac_x64.mak）
cd CPP/7zip/Bundles/Format7zF
make -f ../../cmpl_mac_arm64_dylib.mak -j8       # → b/m_arm64/7z.so（已带 dylib 链接选项）
make -f ../../cmpl_mac_x64_dylib.mak   -j8       # → b/m_x64/7z.so  （需同样新增 x64 变体）

# 2) lipo 合 universal
lipo -create b/m_arm64/7z.so b/m_x64/7z.so -output lib7z.dylib
lipo -info lib7z.dylib            # → Architectures: x86_64 arm64

# 3) 签名（Developer ID + hardened runtime；公证主线见 05-roadmap-execution.md）
codesign --force --timestamp --options runtime \
  --sign "Developer ID Application: <TEAM>" lib7z.dylib
codesign --verify --verbose lib7z.dylib
```

> 需同时新增 `var_mac_x64_dylib.mak` / `cmpl_mac_x64_dylib.mak`（内容与 arm64 版对称，`include var_mac_x64.mak`），底料 04 §3.2 已给 x64 切片命令模板。

**嵌入 .app 布局**（与 01-architecture.md 的 bundle 结构一致）：

```
SevenZipFM.app/Contents/
├── MacOS/SevenZipFM                        # 主可执行（@rpath = @loader_path/../Frameworks）
└── Frameworks/
    ├── SevenZipKit.framework/...           # ObjC++ 桥接层
    └── lib7z.dylib                         # 核心动态库（install_name=@rpath/lib7z.dylib）
        + 7z.so -> lib7z.dylib              # 兼容符号链接（仅 LoadCodecs 复用路径需要，§1.2）
```

桥接层 `dlopen` 时用 `NSBundle` 解析绝对路径（§4.2），故 install_name 仅在"被静态链接器引用"时关键；本方案桥接层只 dlopen 不链接，`@rpath/lib7z.dylib` 是稳妥默认。

### 1.5 编译期裁剪开关（按分发形态选用）

| 开关 | 来源 | 效果 | 何时用 |
|---|---|---|---|
| `DISABLE_RAR=1` | `Format7zF/Arc_gcc.mak:200-205,283-296,311-317` | 去 Rar 解码 | App Store 分发（unRAR 许可评估，底料 04 §7） |
| `ST_MODE=1` | `Format7zF/Arc_gcc.mak:15-25` | 全单线程版（去 MtCoder/MtDec/LzFindMt） | 仅诊断/对照，正式版**不用**（损性能） |

默认保留全格式 + 多线程，与 7zz 实测集合一致。

---

## 2. 导出 ABI 清单（lib7z.dylib 的 19 个 C 入口）

全部为 `STDAPI`（即 `extern "C" HRESULT`，POSIX 上无 `__stdcall`，`CPP/Common/MyWindows.h:104-113`）。函数指针 typedef 全集在 `CPP/7zip/Archive/IArchive.h:704-722` 与 `CPP/7zip/ICoder.h:466-477`，桥接层照此声明并 `dlsym`（**dlsym 符号名不带下划线**，`CPP/Windows/DLL.cpp:119-125`）。

### 2.1 官方 ABI（15 个，等价 Windows 7z.dll 的 Archive2.def 导出集）

| # | 函数 | 签名 | 定义 | 语义 |
|---|---|---|---|---|
| 1 | `CreateObject` | `HRESULT(const GUID *clsid, const GUID *iid, void **out)` | `Archive/DllExports2.cpp:93-106` | **万能工厂**。按 `*iid` 分流：`ICompressCoder/Coder2/Filter`→编解码；`IHasher`→哈希；其余→归档（`IID_IInArchive`/`IID_IOutArchive`）。出参先置 NULL，返回对象计数=1。 |
| 2 | `GetNumberOfFormats` | `HRESULT(UInt32 *n)` | `Archive/ArchiveExports.cpp:143-148` | 静态注册表 `g_Arcs` 数量（实测 60）。 |
| 3 | `GetHandlerProperty2` | `HRESULT(UInt32 fmtIdx, PROPID, PROPVARIANT*)` | `Archive/ArchiveExports.cpp:94-135` | 按格式索引查元数据。propID = `NArchive::NHandlerPropID`（`IArchive.h:99-117`）：kName(BSTR)、kClassID(16 字节 GUID 二进制 BSTR)、kExtension/kAddExtension(BSTR)、kUpdate(BOOL)、kFlags/kTimeFlags/kSignatureOffset(UI4)、kSignature/kMultiSignature(二进制 BSTR)。越界→`E_INVALIDARG`。 |
| 4 | `GetHandlerProperty` | `HRESULT(PROPID, PROPVARIANT*)` | `Archive/ArchiveExports.cpp:137-141` | 旧版单格式（默认 7z 索引）；仅兼容保留，桥接层不用。 |
| 5 | `GetIsArc` | `HRESULT(UInt32 fmtIdx, Func_IsArc *isArc)` | `Archive/ArchiveExports.cpp:150-158` | 取格式快速签名探测函数指针（`Func_IsArc`，`IArchive.h:708`），返回 `k_IsArc_Res_NO/YES/NEED_MORE`。桥接层做"按内容嗅探格式"时用。 |
| 6 | `GetNumberOfMethods` | `HRESULT(UInt32 *n)` | `Compress/CodecExports.cpp:260-265` | 编解码器数量（实测 25）。 |
| 7 | `GetMethodProperty` | `HRESULT(UInt32 codecIdx, PROPID, PROPVARIANT*)` | `Compress/CodecExports.cpp:198-257` | propID = `NMethodPropID`（`ICoder.h:405-421`）：kID(UI8)、kName(BSTR)、kDecoder/kEncoder(16 字节 GUID)、kDecoderIsAssigned/kEncoderIsAssigned(BOOL)、kPackStreams(UI4)、kIsFilter(BOOL)。 |
| 8 | `CreateDecoder` | `HRESULT(UInt32 idx, const GUID *iid, void **out)` | `Compress/CodecExports.cpp:153-157` | 按索引建解码器；iid 须匹配形态（filter/多流/单流），否则 `E_NOINTERFACE`。 |
| 9 | `CreateEncoder` | 同上 | `Compress/CodecExports.cpp:160-164` | 编码方向。 |
| 10 | `GetHashers` | `HRESULT(IHashers **)` | `Compress/CodecExports.cpp:333-342` | 返回 `IHashers` 集合对象（已 AddRef）；经其 `GetNumHashers/GetHasherProp/CreateHasher` 枚举。CRC/SHA 校验用。 |
| 11 | `SetCodecs` | `HRESULT(ICompressCodecsInfo *)` | `Archive/DllExports2.cpp:156-185` | 把客户端 `CCodecs` 注入 dylib（`Z7_EXTERNAL_CODECS` 下存 `g_ExternalCodecs` 并 Load）。**桥接层若不走 LoadCodecs 可不调用**；走 LoadCodecs 时卸载前须 `SetCodecs(NULL)` 打破循环引用（§7）。 |
| 12 | `SetLargePageMode` | `HRESULT(void)` | `Archive/DllExports2.cpp:123-127` | = `SetLargePageMode2(0,0,0)`。 |
| 13 | `SetLargePageMode2` | `HRESULT(UInt32 flags, size_t pageSize, size_t threshold)` | `Archive/DllExports2.cpp:108-121` | macOS 未定义 `Z7_LARGE_PAGES` → 恒 `S_OK`，桥接层可不调用。 |
| 14 | `SetCaseSensitive` | `HRESULT(Int32)` | `Archive/DllExports2.cpp:131-136` | 写**进程级全局** `g_CaseSensitive`（`Wildcard.cpp:8-20`，macOS 桌面默认 false）。影响通配符/路径比较，**全局生效、非每会话**。APFS 区分大小写卷上桥接层可探测后调用。 |
| 15 | `GetModuleProp` | `HRESULT(PROPID, PROPVARIANT*)` | `Compress/CodecExports.cpp:360-378` | `kInterfaceType`(UI4)：IUnknown 是否带虚析构（本模块 `k_IUnknown_VirtDestructor_No=0`，实测 0）；`kVersion`(UI4)=`major<<16\|minor`（实测 `0x1A0001`=26.01）。**ABI 兼容性闸门**（§6.1）。 |

### 2.2 辅助 extern "C" 符号（4 个，非 .def 内，桥接层可直调更简）

| 函数 | 定义 | 说明 |
|---|---|---|
| `CreateArchiver(const GUID*, const GUID*, void**)` | `Archive/ArchiveExports.cpp:63-92` | `CreateObject` 的归档分支实体，直接调更省一次分流。 |
| `CreateCoder(const GUID*, const GUID*, void**)` | `Compress/CodecExports.cpp:167-195` | 按 CLSID 建编解码器。 |
| `CreateHasher(const GUID*, IHasher**)` | `Compress/CodecExports.cpp:293-303` | 按 CLSID 建哈希器。 |
| `GetHasherProp(UInt32, PROPID, PROPVARIANT*)` | `Compress/CodecExports.cpp:305-329` | Windows 不导出此名；正式途径是 `IHashers`。 |

### 2.3 GUID 编码（桥接层构造 CLSID/IID 的规则）

公共常量 `k_7zip_GUID_Data1=0x23170F69, Data2=0x40C1`（`CPP/7zip/IDecl.h:9-16`）。`GUID::operator==` 为逐字节比较（`CPP/Common/MyGuidDef.h:12-39`）。

| 类别 | 形态 | 证据 |
|---|---|---|
| 接口 IID | `{23170F69-40C1-278A-0000-00 gg 00 ss 0000}`，Data4[3]=组号 gg、Data4[5]=子号 ss | `IDecl.h:18-27` |
| 格式 CLSID | `{23170F69-40C1-278A-1000-000110 xx 0000}`，Data4[5]=格式 Id | `ArchiveExports.cpp:30-36`；常用 Id：zip=1、bzip2=2、7z=7、xz=0x0C、tar=0xEE、gzip=0xEF（`UI/Client7z/Client7z.cpp:45-64`），全表 `DOC/Guid.txt` |
| 编解码 CLSID | Data3=0x2790(解码)/0x2791(编码)/0x2792(哈希)，Data4=8 字节 MethodId 小端 | `CodecExports.cpp:44-52`；`IDecl.h:14-16` |

桥接层**恰好一个**编译单元在包含接口头之前 `#include "Common/MyInitGuid.h"`（定义 INITGUID，落实 IID_IUnknown，`CPP/Common/MyInitGuid.h:6-55`；Client7z 范例 `Client7z.cpp:8`）。建议放在 `SZLibrary.mm`（§4.1）。

---

## 3. Agent 层处置决策

03-feature-map-filemanager.md 的 FM 浏览/更新功能依赖 Agent 层把 `IInArchive` 适配成"文件夹树"（`IFolderFolder` 导航族）。本节定结论：**哪些复用、哪些改造、哪些重写**，给精确文件列表。

### 3.1 总结论

| 子层 | 处置 | 依据 |
|---|---|---|
| **UI/Agent（7 个 .cpp + 5 个 .h）** | **复用**（POSIX 全部可编译，仅 1.5 处动手） | 底料 03 §3.1：`7zip_gcc.mak:933-945` 已为全部 Agent 源提供 clang 规则，当前只是无 bundle 把它们入 OBJS |
| **UI/Explorer（ContextMenu 等）** | **业务规则复用 + 宿主壳重写**：命令模型抽出，IContextMenu/IExplorerCommand → FinderSync/NSMenu | 底料 03 §3.2、§1.9；详见 04-feature-map-dialogs-finder.md |
| **设置后端（ZipRegistry.cpp）** | **重写后端、保留 CInfo 结构体 API**（CKey → NSUserDefaults） | 底料 03 §3.3、底料 05 §4；属平台层工作，详见 01-architecture.md |

Agent 层是否需要进 dylib？**不需要。** Agent 是"客户端侧"逻辑（与 Client7z 同侧），它通过 `IInArchive`/`IOutArchive` 接口指针使用引擎——这些指针由 dylib 的 `CreateObject` 给出。Agent 编入 **SevenZipKit.framework**（与桥接 ObjC++ 同一二进制、同一 clang/同一 C++ 运行时），不跨 dylib 边界传 C++ 异常（底料 03 §3 风险 6）。

### 3.2 UI/Agent 逐文件改造清单

| 文件 | 改造动作 | 精确点 |
|---|---|---|
| `Agent.cpp` | 删一行 include（`#include "../FileManager/RegistryUtils.h"`，仅被注释代码 `Read_ShowDeleted()` 引用） | `Agent.cpp:20`（引用点 `:1640-1649` 已注释）。ZoneId 读取已 `#if defined(_WIN32)` 包住（`:1515-1522`），mac 自动跳过 |
| `AgentProxy.cpp` | 无改动 | 零拷贝名字优化已限 `MY_CPU_LE && _WIN32`（`:274`），POSIX 自动走 BSTR 慢路径（wchar_t=4B 下本就该走） |
| `AgentOut.cpp` | 无改动 | FILETIME（MyWindows 模拟）+ `GetCurUtcFileTime`（POSIX 已实现 `TimeUtils.cpp:320-345`） |
| `ArchiveFolder.cpp` | 无改动 | 无 Windows 头 |
| `ArchiveFolderOut.cpp` | 间接依赖 `WorkDir.cpp → NWorkDir::CInfo::Load() → ZipRegistry`：需设置后端就绪，或让 `CWorkDirTempFile` 默认"同目录临时文件"短路设置读取 | `WorkDir.cpp:61-66`；归档内更新临时文件→回写流程，详见 03-feature-map-filemanager.md |
| `ArchiveFolderOpen.cpp` | **改造**：图标/扩展名表机制重写（原读 PE 字符串资源 ID=100 + DLL 图标索引），改静态表 / AssetCatalog | `ArchiveFolderOpen.cpp:13-80,175-206`；`extern HINSTANCE g_hInstance` + `MyLoadString(HMODULE,100)`。**`OpenFolderFile/GetExtensions` 逻辑本身无 Win 依赖** |
| `UpdateCallbackAgent.cpp` | 无改动 | `HRESULT_FROM_WIN32` + `MyFormatMessage` 均有 POSIX 路径 |
| `Agent.h` 等 5 个头 | `CCodecIcons` 类（`Agent.h:231,253,335` 用 `DWORD/INVALID_FILE_ATTRIBUTES/HMODULE`）可整段裁剪/重写 | 与 ArchiveFolderOpen 图标机制配套 |

**结论：Agent 层"动手量" = 1 处删 include + 1 处图标表重写（ArchiveFolderOpen）+ 1 个依赖（ZipRegistry 后端，属平台层共性工作）。** 把这 7 个 `.o` 加进 SevenZipKit 的 OBJS（参照 `7zip_gcc.mak:933-945` 现成规则）即可开编。

### 3.3 桥接层是否用 Agent？分层取舍

桥接层有两条可选实现路径，本方案**分阶段都用**：

- **直引擎层（M0–M2，§4 的 SZArchive/SZExtractor/SZCompressor）**：直接 `IInArchive`/`IOutArchive`（Client7z 模式），不经 Agent。压缩/解压/列表/测试用此路径，最简、最稳。
- **Agent 文件夹层（FM 浏览阶段，对应 SZFolderSession，§4.6）**：用 `CAgent`/`CAgentFolder`（`IFolderFolder` 导航）。FM 的"进入归档像进文件夹"、归档内增删改重命名走此路径（底料 03 §2.5–§2.6）。

两者非互斥：SZFolderSession 内部持 `CAgent`，SZExtractor/SZCompressor 内部持裸 `IInArchive`/`IOutArchive`。详见 §4。

### 3.4 不移植项（明确排除）

| 项 | 原因 | 证据 |
|---|---|---|
| 插件 DLL 枚举（GetPluginProperty 协议） | 26.x 已整体注释，FM 只有内置 CArchiveFolderManager 一个"插件" | `RegistryPlugins.cpp:5-80`、`PluginInterface.h:6-31` 全注释（底料 03 §2.8） |
| Far 插件 | 不在一对一范围 | 设计公约 |
| IFolderSetZoneIdMode/SetZoneIdFile（MOTW） | Win 专属，mac 对应 quarantine xattr，需重设计 | 底料 03 §2.3、底料 05 §5.8 |

---

## 4. SevenZipKit API 设计（ObjC 头文件草案）

设计原则（从底料 04 §6 硬约束导出）：

1. 每个会话型对象持 `CMyComPtr<...>` + **一个串行 dispatch queue**，所有引擎调用排队（同一 IInArchive 禁并发，`IArchive.h:305-308`）。
2. **进度走 pull 模型（硬契约）**：进度回调可发生在引擎 worker 线程（底料 04 §5 实证），桥接层回调内**只原子写入共享进度结构、绝不 `dispatch_async` 到主线程**；由桥接层持有的一个 200ms main-queue 定时器周期性读取并合并送达 delegate（对齐 Windows `kTimerElapse=200` 拉取模型，§7.2）。回调内不得重入同一 archive 对象。
3. 回调对象 catch-all（C++ 与 ObjC 异常）转 HRESULT；`E_ABORT` = 用户取消。在 dispatch block 内调用 Agent/CAgentFolder 顶层方法时同样必须整体 catch-all（`throw int` 不得逸出 block 进 libdispatch，§6.3）。
4. NSString↔UString 经 UTF-8；NSDate↔FILETIME 经 1601 纪元换算（§5）。

对外暴露 **ObjC API**（供 Swift 直接调用），实现 `.mm`（ObjC++）。以下为头文件草案（真实可编译风格）。

### 4.0 公共类型与错误域：`SZTypes.h` / `SZError.h`

```objc
// SZTypes.h
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

/// 归档格式标识（对应 dylib 内格式索引 / CLSID 格式 Id，见 02-core-bridge.md §2.3）
typedef NS_ENUM(NSInteger, SZFormat) {
    SZFormatAuto   = -1,   // 按内容/扩展名嗅探（GetIsArc）
    SZFormat7z     = 7,
    SZFormatZip    = 1,
    SZFormatBZip2  = 2,
    SZFormatXz     = 0x0C,
    SZFormatTar    = 0xEE,
    SZFormatGzip   = 0xEF,
    // 其余格式 Id 见 DOC/Guid.txt
};

/// 解压每项结果（一对一映射 NArchive::NExtract::NOperationResult，IArchive.h:132-148）
typedef NS_ENUM(NSInteger, SZOperationResult) {
    SZOperationResultOK = 0,
    SZOperationResultUnsupportedMethod,
    SZOperationResultDataError,
    SZOperationResultCRCError,
    SZOperationResultUnavailable,
    SZOperationResultUnexpectedEnd,
    SZOperationResultDataAfterEnd,
    SZOperationResultIsNotArc,
    SZOperationResultHeadersError,
    SZOperationResultWrongPassword,
};

/// 解压路径模式（对应 NExtract::NPathMode）
typedef NS_ENUM(NSInteger, SZPathMode) {
    SZPathModeFullPaths = 0,  // 保留完整相对路径
    SZPathModeCurrentPaths,
    SZPathModeNoPaths,        // 全部铺平到目标目录
    SZPathModeAbsolutePaths,
};

/// 覆盖策略（对应 NExtract::NOverwriteMode）
typedef NS_ENUM(NSInteger, SZOverwriteMode) {
    SZOverwriteModeAsk = 0,
    SZOverwriteModeOverwrite,
    SZOverwriteModeSkip,
    SZOverwriteModeRenameExisting,
    SZOverwriteModeRenameNew,
};

NS_ASSUME_NONNULL_END
```

```objc
// SZError.h —— 统一错误域；HRESULT/操作结果 → NSError
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

/// 错误域：HRESULT 失败码（< 0）原值放入 code，userInfo 附人读描述
extern NSErrorDomain const SZErrorDomain;

typedef NS_ERROR_ENUM(SZErrorDomain, SZErrorCode) {
    SZErrorUnknown            = 1,
    SZErrorLibraryNotLoaded   = 2,   // dlopen/dlsym 失败
    SZErrorAbiMismatch        = 3,   // GetModuleProp 闸门不匹配（§6.1）
    SZErrorNotArchive         = 4,   // Open 返回 S_FALSE（IArchive.h:223）
    SZErrorWrongPassword      = 5,   // kWrongPassword
    SZErrorDataError          = 6,   // kDataError/kCRCError/kHeadersError
    SZErrorUnsupportedMethod  = 7,
    SZErrorCancelled          = 8,   // E_ABORT（用户取消，§7）
    SZErrorIO                 = 9,   // HRESULT_FROM_WIN32(errno)
    SZErrorOutOfMemory        = 10,  // E_OUTOFMEMORY
    SZErrorHResult            = 100, // 其它原始 HRESULT，userInfo[@"hresult"] = @(hr)
};

/// 把引擎 HRESULT 翻成 NSError（nil 当 hr>=0），桥接层内部用
FOUNDATION_EXPORT NSError * _Nullable SZErrorFromHRESULT(int32_t hr);

NS_ASSUME_NONNULL_END
```

### 4.1 `SZLibrary` —— dlopen 管理、ABI 闸门、函数指针表

包装：dylib 加载 + 19 个 `dlsym` + `GetModuleProp` ABI 闸门（§6.1）。进程内单例，常驻不卸载（底料 04 §5 dlclose 风险）。

```objc
// SZLibrary.h
#import <Foundation/Foundation.h>
#import "SZError.h"
NS_ASSUME_NONNULL_BEGIN

@interface SZLibrary : NSObject

/// 进程级单例；首次访问触发 dlopen + dlsym + ABI 闸门校验。
/// 失败时 error 填 SZErrorLibraryNotLoaded / SZErrorAbiMismatch。
+ (nullable instancetype)sharedLibraryWithError:(NSError **)error;

/// dylib 报告的版本（来自 GetModuleProp(kVersion)，如 0x1A0001 = 26.01）。
@property (nonatomic, readonly) uint32_t engineVersion;

/// 注册格式数 / 编解码器数（GetNumberOfFormats / GetNumberOfMethods）。
@property (nonatomic, readonly) NSUInteger formatCount;
@property (nonatomic, readonly) NSUInteger methodCount;

/// 进程级全局：大小写敏感（SetCaseSensitive，§2.1 #14）。
/// 注意全局生效、非每会话；APFS 区分大小写卷上由 App 探测后设置。
- (void)setCaseSensitive:(BOOL)caseSensitive;

@end
NS_ASSUME_NONNULL_END
```

实现要点（`SZLibrary.mm`）：
- dylib 路径用 **`privateFrameworksURL`** 定位（→ `Contents/Frameworks`），**不要用 `URLForResource:…subdirectory:@"../Frameworks"`**——`subdirectory` 是相对 `Resources` 目录的子路径查找，`..` 上跳属未定义/不稳定行为（不同 macOS 版本与 bundle 类型表现不一，常返回 nil，nil.path → `dlopen(NULL)` 加载失败甚至崩）：
  ```objc
  NSURL *fw = NSBundle.mainBundle.privateFrameworksURL;            // Contents/Frameworks
  NSURL *dylib = [fw URLByAppendingPathComponent:@"lib7z.dylib"];
  void *h = dlopen(dylib.path.UTF8String, RTLD_NOW | RTLD_LOCAL);  // 等价 DLL.cpp:141-164 CLibrary::Load
  if (!h) { /* → SZErrorLibraryNotLoaded，dlerror() 入 userInfo */ }
  ```
  此基址须与 01 §3.3 的 `GetModuleDirPrefix(NSBundle)`（供 LoadCodecs 命中 `7z.so` 软链）**复用同一 `privateFrameworksURL`**，保证桥接层 dlopen 与 LoadCodecs 路径解析落在同一目录，消除两套路径不一致风险。
- `Func_CreateObject` 等 typedef 取自 `IArchive.h:704-722` / `ICoder.h:466-477`，逐个 `dlsym`（不带下划线）。
- 加载后立即 `GetModuleProp(kInterfaceType)` 校验 = `k_IUnknown_VirtDestructor_No`（§6.1）。
- 此单例是唯一 `#include "Common/MyInitGuid.h"` 的 .mm（§2.3）。

### 4.2 `SZArchive` —— 打开归档 + 列表（包装 IInArchive 的读路径）

```objc
// SZArchive.h
#import <Foundation/Foundation.h>
#import "SZTypes.h"
#import "SZArchiveEntry.h"
#import "SZProgressDelegate.h"
NS_ASSUME_NONNULL_BEGIN

@class SZExtractor;

/// 包装 IInArchive（读路径）。每实例持独立 IInStream + 串行队列；
/// 同一实例禁止并发使用（IArchive.h:305-308）—— 所有方法内部串行化。
@interface SZArchive : NSObject

/// 打开归档。format=SZFormatAuto 时按内容/扩展名嗅探（GetIsArc + maxCheckStartPosition）。
/// 加密头归档会触发 passwordHandler（同步阻塞，§7）。
/// 失败：S_FALSE → SZErrorNotArchive；加密头无密码 → SZErrorWrongPassword。
+ (nullable instancetype)archiveWithURL:(NSURL *)url
                                 format:(SZFormat)format
                        passwordHandler:(nullable SZPasswordHandler)passwordHandler
                                  error:(NSError **)error;

@property (nonatomic, readonly) SZFormat format;
@property (nonatomic, readonly) NSUInteger entryCount;   // GetNumberOfItems

/// 归档级属性（GetArchiveProperty：kpidPhySize/kpidOffset/kpidErrorFlags/kpidComment…）。
/// 键为 PROPID（见 PropID.h），值按 §5 类型映射表转 ObjC。
- (NSDictionary<NSNumber *, id> *)archiveProperties;

/// 列出全部条目（GetProperty 逐项；目录在前由调用方排序）。
/// 大归档建议用 enumerateEntriesUsingBlock: 避免一次性建数组。
@property (nonatomic, readonly) NSArray<SZArchiveEntry *> *entries;
- (void)enumerateEntriesUsingBlock:(void (^)(SZArchiveEntry *entry, BOOL *stop))block;

/// 取单条目元数据（不解压）。index = IInArchive 条目号。
- (nullable SZArchiveEntry *)entryAtIndex:(NSUInteger)index;

/// 创建一次解压会话（§4.4）。indices=nil 表示全部。
- (SZExtractor *)extractorForIndices:(nullable NSArray<NSNumber *> *)indices;

/// 预览/读取单条目内容。**注意接口语义：顺序读（前向只读），非随机读（不可 seek）。**
/// 实现两条路径（QI 探测决定）：
///   (1) 快路径——QI `IInArchiveGetStream`（IArchive.h:268-270，产出 ISequentialInStream）成功时直接顺序读；
///       但 **7z（含 solid）与 zip（compressed）handler 不实现该接口**（实测 `grep -rln IInArchiveGetStream
///       CPP/7zip/Archive/7z/ CPP/7zip/Archive/Zip/` 为空，仅 CHandlerCont 基类 HandlerCont.h:28-42 及
///       tar/iso/fat/ntfs/squashfs/dmg/xar/cpio 等容器型 handler 实现），QI 此时返回 E_NOINTERFACE。
///   (2) fallback——QI 失败时退化为对单条目 index 调 `archive->Extract(&idx,1,0,memCallback)` 写入
///       内存/临时流（对应 OQ-4 CVirtFileSystem 内存优化）。**solid 7z 取单文件会触发整段 solid block 解码**，
///       须受 maxBytes 阈值约束（见下）。
/// 大小阈值与流式回退：内容 ≤ maxBytes（且解码确可入内存）时返回 NSData；超阈值返回 nil（error=SZErrorIO）
/// 并应改调下方 extractEntryAtIndex:toFileURL: 写入临时文件（避免大条目 OOM），阈值算法参考
/// PanelItemOpen.cpp:1590-1591（g_RAM_Size >> max(层数+1,8)）。
- (nullable NSData *)dataForEntryAtIndex:(NSUInteger)index
                               maxBytes:(uint64_t)maxBytes
                                  error:(NSError **)error;

/// 超阈值/大文件预览：解压单条目到临时文件 URL（不入内存），FM/QuickLook 大文件预览走此路径。
/// maxBytes==0 表示不限大小（始终落临时文件）。
- (nullable NSURL *)extractEntryAtIndex:(NSUInteger)index
                            toFileURL:(NSURL *)fileURL
                                error:(NSError **)error;

- (void)close;   // archive->Close()；之后可对同对象重新 open

@end
NS_ASSUME_NONNULL_END
```

包装的底层时序：`CreateObject(&CLSID, &IID_IInArchive)` → `new CInFileStream` → `archive->Open(file, &maxCheckStart, openCallback)`（底料 04 §4.2）。`openCallback` 实现 `IArchiveOpenCallback + ICryptoGetTextPassword + IArchiveOpenVolumeCallback`（多卷）。

### 4.3 `SZArchiveEntry` —— 单条目元数据（PROPVARIANT → ObjC）

```objc
// SZArchiveEntry.h
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

/// 不可变快照；属性值在创建时从 IInArchive::GetProperty 一次性读出并转 ObjC（§5）。
@interface SZArchiveEntry : NSObject

@property (nonatomic, readonly) NSUInteger index;        // IInArchive 条目号
@property (nonatomic, readonly, copy) NSString *path;    // kpidPath（档内相对路径，分隔符已归一）
@property (nonatomic, readonly, copy) NSString *name;    // 末级名（kpidName / path lastComponent）
@property (nonatomic, readonly) BOOL isDirectory;        // kpidIsDir
@property (nonatomic, readonly) BOOL isEncrypted;        // kpidEncrypted
@property (nonatomic, readonly) uint64_t size;           // kpidSize（VT_UI8）
@property (nonatomic, readonly) uint64_t packedSize;     // kpidPackSize
@property (nonatomic, readonly, nullable) NSNumber *crc; // kpidCRC（VT_UI4，可能缺失→nil）
@property (nonatomic, readonly, nullable) NSDate *modificationDate;  // kpidMTime（§5 FILETIME 换算）
@property (nonatomic, readonly, nullable) NSDate *creationDate;      // kpidCTime
@property (nonatomic, readonly, nullable) NSDate *accessDate;        // kpidATime
@property (nonatomic, readonly) uint32_t attributes;     // kpidAttrib（含 FILE_ATTRIBUTE_UNIX_EXTENSION 高 16 位 st_mode）
@property (nonatomic, readonly, nullable) NSString *symlinkTarget;   // kpidSymLink（tar/7z）

/// 任意 PROPID 的原始值（按 §5 映射），用于 FM 自定义列。
- (nullable id)valueForPropID:(uint32_t)propID;

@end
NS_ASSUME_NONNULL_END
```

### 4.4 `SZExtractor` —— 解压会话（包装 IInArchive::Extract 写路径）

```objc
// SZExtractor.h
#import <Foundation/Foundation.h>
#import "SZTypes.h"
#import "SZProgressDelegate.h"
NS_ASSUME_NONNULL_BEGIN

@interface SZExtractor : NSObject

@property (nonatomic) SZPathMode pathMode;            // 默认 FullPaths
@property (nonatomic) SZOverwriteMode overwriteMode;  // 默认 Ask（经 delegate 询问）
@property (nonatomic) BOOL testMode;                  // YES = 只测试不写盘（testMode!=0）
@property (nonatomic) BOOL writeQuarantine;           // 网络来源档案写 com.apple.quarantine（底料 05 §5.8）

@property (nonatomic, weak, nullable) id<SZProgressDelegate> progressDelegate;
@property (nonatomic, copy, nullable) SZPasswordHandler passwordHandler;

/// 异步解压到目标目录。在私有串行队列执行引擎 Extract；
/// 进度经 200ms 定时器 pull 后在主线程批量送达 delegate（§7.2）；覆盖询问/密码同步阻塞回调经
/// delegate（信号量 + 主线程对话框，§7.3）；完成回调在主线程；用户取消 → error.code == SZErrorCancelled。
- (void)extractToDirectory:(NSURL *)directory
                completion:(void (^)(NSError * _Nullable error))completion;

/// 同步取消：置中止标志，下一次引擎进度回调返回 E_ABORT（§7.4）。
/// 取消后清理契约见 §7.5：已完成文件保留（对齐 7zG），正在写的文件由引擎删除。
- (void)cancel;

@end
NS_ASSUME_NONNULL_END
```

包装时序：构造引擎级 `extractCallback`（实现 `IArchiveExtractCallback + ICryptoGetTextPassword`）→ `archive->Extract(indices, numItems, testMode, extractCallback)`（底料 04 §4.2）。每项回调序列 `GetStream → PrepareOperation → SetOperationResult(opRes∈NExtract::NOperationResult)`，桥接把 opRes 翻成 `SZOperationResult` 并在出错时聚合成 `NSError`。

### 4.5 `SZCompressor` —— 压缩/更新（包装 IOutArchive 写路径）

```objc
// SZCompressor.h
#import <Foundation/Foundation.h>
#import "SZTypes.h"
#import "SZProgressDelegate.h"
NS_ASSUME_NONNULL_BEGIN

/// 一个压缩条目源（磁盘文件 → 档内路径）
@interface SZCompressItem : NSObject
@property (nonatomic, copy) NSURL *sourceURL;       // 磁盘路径
@property (nonatomic, copy) NSString *archivePath;  // 档内相对路径（分隔符归一）
+ (instancetype)itemWithSourceURL:(NSURL *)url archivePath:(NSString *)path;
@end

@interface SZCompressor : NSObject

@property (nonatomic) SZFormat format;              // 目标格式（默认 7z）
@property (nonatomic) NSInteger level;              // 压缩等级 0..9（"x" 属性，默认 5）
@property (nonatomic, nullable, copy) NSString *method;        // "m"（如 LZMA2）
@property (nonatomic) BOOL solid;                   // "s"（固实）
@property (nonatomic) NSInteger threadCount;        // "mt"（0=自动）
@property (nonatomic, nullable, copy) NSString *password;      // 设则加密
@property (nonatomic) BOOL encryptHeaders;          // 7z 加密头（"he"）
@property (nonatomic) BOOL deleteSourceAfterArchiving;          // "移到压缩包"

@property (nonatomic, weak, nullable) id<SZProgressDelegate> progressDelegate;

/// 设置任意 IOutArchive 属性（"m"/"s"/"x"/"mt"/格式专属），值限 VT_EMPTY/BOOL/UI4/UI8/BSTR
/// （ISetProperties::SetProperties，IArchive.h:537-550）。覆盖上面便捷属性之外的高级项。
- (void)setArchiveProperty:(NSString *)name value:(nullable id)value;

/// 异步创建新归档。
- (void)compressItems:(NSArray<SZCompressItem *> *)items
              toURL:(NSURL *)outputURL
         completion:(void (^)(NSError * _Nullable error))completion;

/// 异步更新已有归档（归档内增删改的引擎层；FM 文件夹层走 SZFolderSession §4.6）。
- (void)updateArchiveAtURL:(NSURL *)archiveURL
                   addItems:(NSArray<SZCompressItem *> *)addItems
              removeEntries:(nullable NSArray<NSNumber *> *)removeIndices
                 completion:(void (^)(NSError * _Nullable error))completion;

- (void)cancel;

@end
NS_ASSUME_NONNULL_END
```

包装时序：`CreateObject(&CLSID, &IID_IOutArchive)` → `QI IID_ISetProperties` → `SetProperties(names[], values[], n)` → `GetFileTimeType` → `UpdateItems(outStream, n, updateCallback)`（底料 04 §4.3）。`updateCallback` 实现 `IArchiveUpdateCallback(2) + ICryptoGetTextPassword2`（密码 BSTR 客户端 `SysAllocString` 分配、引擎 `SysFreeString` 释放，跨边界安全见 §6.2）。

### 4.6 `SZFolderSession` —— 归档"文件夹化"导航（包装 CAgent / IFolderFolder）

仅 FM 浏览阶段需要（底料 03 §2）。包装 `CAgent::Open → BindToRootFolder → CAgentFolder`，把"进入归档像进文件夹"、归档内增删改/重命名/新建文件夹暴露为 ObjC。

```objc
// SZFolderSession.h
#import <Foundation/Foundation.h>
#import "SZTypes.h"
#import "SZArchiveEntry.h"
NS_ASSUME_NONNULL_BEGIN

/// 当前文件夹内一项（index 为"当前文件夹内序号"，非 IInArchive 条目号，底料 03 §2.4）
@interface SZFolderItem : SZArchiveEntry
@property (nonatomic, readonly) BOOL isLeafDirectory;  // 可下钻
@end

/// 包装 CAgent + CAgentFolder（IFolderFolder 导航）。一个 session 对应一个打开的归档。
@interface SZFolderSession : NSObject

+ (nullable instancetype)sessionWithURL:(NSURL *)url
                        passwordHandler:(nullable SZPasswordHandler)passwordHandler
                                  error:(NSError **)error;

/// 当前文件夹内的条目（CAgentFolder::LoadItems → GetNumberOfItems/GetProperty）。
@property (nonatomic, readonly) NSArray<SZFolderItem *> *items;
@property (nonatomic, readonly, copy) NSString *currentPath;   // 文件夹前缀

- (BOOL)enterFolderAtIndex:(NSUInteger)index error:(NSError **)error;   // BindToFolder(index)
- (BOOL)enterParentFolder:(NSError **)error;                           // BindToParentFolder
- (void)setFlatMode:(BOOL)flat;                                        // IFolderSetFlatMode

/// 提取当前文件夹内选中项到磁盘（IFolderOperations::CopyTo → CAgentFolder::Extract）。
- (void)extractIndices:(NSArray<NSNumber *> *)indices
           toDirectory:(NSURL *)directory
          progressDelegate:(nullable id<SZProgressDelegate>)delegate
            completion:(void (^)(NSError * _Nullable error))completion;

/// 归档内更新（IFolderOperations，走 CommonUpdateOperation 事务，底料 03 §2.6）。
/// 可更新性先经 canUpdate 判定（CAgent::CanUpdate：多层嵌套/尾部垃圾/只读格式→不可）。
@property (nonatomic, readonly) BOOL canUpdate;
- (void)addFiles:(NSArray<NSURL *> *)urls completion:(void (^)(NSError * _Nullable))completion;
- (void)deleteIndices:(NSArray<NSNumber *> *)indices completion:(void (^)(NSError * _Nullable))completion;
- (void)renameIndex:(NSUInteger)index toName:(NSString *)newName completion:(void (^)(NSError * _Nullable))completion;
- (void)createFolderNamed:(NSString *)name completion:(void (^)(NSError * _Nullable))completion;

@end
NS_ASSUME_NONNULL_END
```

> 更新功能矩阵的禁用态须如实呈现给 UI（底料 03 §5 风险 11）：CreateFile 不支持（`ArchiveFolderOut.cpp:439-442` E_NOTIMPL）、CopyTo 的 moveMode 不支持、Comment 仅 zip、多层嵌套/带尾部数据归档只读（`Agent.cpp:1589-1601`）。详见 03-feature-map-filemanager.md。

### 4.7 `SZProgressDelegate` 与密码回调

```objc
// SZProgressDelegate.h
#import <Foundation/Foundation.h>
#import "SZTypes.h"
NS_ASSUME_NONNULL_BEGIN

/// 密码回调：引擎需要密码时同步阻塞调用线程（§7）。
/// 返回 nil = 用户取消（桥接转 E_ABORT）；返回字符串 = 密码。
/// 桥接层内部用信号量把此调用 hop 到主线程弹 NSAlert，再唤醒引擎线程。
typedef NSString * _Nullable (^SZPasswordHandler)(void);

/// 协议契约（必读）：进度回调按 **节流间隔（默认 200ms，对齐 Windows kTimerElapse）批量合并送达**，
/// 不是每字节/每块一次。所有方法均在**主线程**调用（由桥接层 200ms 定时器投递，§7.2），可直接刷 UI。
/// 引擎 worker 线程只原子写入共享进度结构，绝不直接调用本协议——避免每秒数千次回调造成主线程派发风暴。
@protocol SZProgressDelegate <NSObject>
@optional
/// 总量已知（SetTotal）。bytes 可能为 0（仅文件数已知）。
- (void)szTaskDidSetTotal:(uint64_t)totalBytes files:(uint64_t)totalFiles;
/// 进度推进（节流后单次送达最新累计值，非每次 SetCompleted）。在主线程，可直接刷 UI。
- (void)szTaskDidProgress:(uint64_t)completedBytes;
/// 当前处理文件（解压/压缩每项 PrepareOperation）。
- (void)szTaskDidStartFile:(NSString *)path;
/// 覆盖询问（解压时目标已存在；对应 AskOverwrite）。同步返回策略。
- (SZOverwriteMode)szTaskAskOverwriteFor:(NSString *)existingPath
                                  newSize:(uint64_t)newSize
                                  newDate:(nullable NSDate *)newDate;
/// 每项结果（SetOperationResult），出错项上报。
- (void)szTaskDidFinishFile:(NSString *)path result:(SZOperationResult)result;
@end
NS_ASSUME_NONNULL_END
```

---

## 5. 类型映射总表（PROPVARIANT VT_* ↔ ObjC/Swift）

POSIX 自定义 PROPVARIANT 布局 16 字节（`CPP/Common/MyWindows.h:222-254`，实测）。引擎实际产生/消费的 VT 类型见下；`kpid → VARTYPE` 官方表 `CPP/7zip/Common/PropId.cpp:10-117`（仅 EMPTY/BSTR/BOOL/UI4/UI8/FILETIME 六种）。

| VT_* 常量 | 值 | C union 成员 | ObjC 类型 | Swift 类型 | 换算/编码路径 |
|---|---|---|---|---|---|
| `VT_EMPTY` | 0 | — | `nil` | `nil` | 属性不存在；调用前出参须置 VT_EMPTY（`IArchive.h:20-41`） |
| `VT_BOOL` | 11 | `boolVal`(short, TRUE=-1) | `NSNumber(BOOL)` | `Bool` | `boolVal == VARIANT_TRUE(-1)` → YES |
| `VT_UI1` | 17 | `bVal`(Byte) | `NSNumber(uint8)` | `UInt8` | 直映射 |
| `VT_UI2` | 18 | `uiVal` | `NSNumber(uint16)` | `UInt16` | 直映射 |
| `VT_UI4` | 19 | `ulVal` | `NSNumber(uint32)` | `UInt32` | kpidAttrib/CRC/kFlags/kVersion 等 |
| `VT_UI8` | 21 | `uhVal`(ULARGE_INTEGER) | `NSNumber(uint64)` | `UInt64` | kpidSize/PackSize/PhySize、方法 kID |
| `VT_I4` | 3 | `lVal` | `NSNumber(int32)` | `Int32` | kpidOffset/Position 有符号场景 |
| `VT_I8` | 20 | `hVal`(LARGE_INTEGER) | `NSNumber(int64)` | `Int64` | 允许负值 |
| `VT_R4`/`VT_R8` | 4/5 | `fltVal`/`dblVal` | `NSNumber(double)` | `Double` | 罕见，浮点属性 |
| `VT_BSTR`（字符串） | 8 | `bstrVal`(OLECHAR* = wchar_t* = UTF-32) | `NSString` | `String` | **见下文 BSTR 编码路径** |
| `VT_BSTR`（二进制 blob） | 8 | `bstrVal` | `NSData` | `Data` | kClassID(GUID)/kSignature/kpidNtSecure/kpidSha1/Sha256：**必须用 `SysStringByteLen` 按字节读**（`MyWindows.cpp:94-106`），不可当宽字符串（byteLen 非 4 倍数会越界，底料 04 §7） |
| `VT_FILETIME` | 64 | `filetime`(FILETIME{lo,hi}) | `NSDate` | `Date` | **见下文 FILETIME 换算** |
| `VT_ERROR` | 10 | `scode` | `NSError` | — | BSTR 分配失败时 `vt=VT_ERROR; scode=E_OUTOFMEMORY`（`PropVariant.cpp:26-50`） |

### 5.1 BSTR/UString → NSString 编码路径

`BSTR = OLECHAR* = wchar_t*`，macOS 上 wchar_t 为 4 字节即 **UTF-32 指针**（底料 04 §2.3）。**不可 `memcpy` 当 UTF-16**（底料 05 §5.2 风险）。映射两步：

1. 读：`SysStringLen(bstr)` 取字符数（= 字节数 / 4），得到 `const wchar_t *`（UTF-32 码元）。
2. 转：经 `UString → UTF-8`（`CPP/Common/StringConvert/UTFConvert`，dylib 加载时 `g_ForceToUTF8=IsNativeUTF8()` 已为 true，`DllExports2.cpp:73-78`）→ `[NSString stringWithUTF8String:]`。

反向（NSString → BSTR/UString）：`[s UTF8String]` → `ConvertUTF8ToUnicode` → `StringToBstr`（签名 `HRESULT StringToBstr(LPCOLESTR src, BSTR *bstr)`，`CPP/Common/MyCom.h:184-188`，返回 HRESULT、出参 BSTR**，不可把 NSString\* 直传 wchar_t\* 接口）。**统一走 UTF-8 中转**，避免 UTF-16/UTF-32 宽度陷阱（底料 04 §6.4）。**密码回调（§7.3）的 BSTR 构造是此路径的标准用例，照该片段复制，勿写 `*password = StringToBstr(pw)`。**

> 文件名规范化：HFS+ 强制 NFD、APFS 保留原样，档内多为 NFC。桥接层在"档内名 ↔ 磁盘名"比较/落盘处须做 NFC/NFD 规范化（底料 05 §5.3，全仓无现成代码，是新增工作项）。建议入档统一 NFC，比较时双向规范化。

### 5.2 VT_FILETIME → NSDate 换算（含精度字段保真）

FILETIME 是 **1601-01-01 00:00:00 UTC 纪元的 100ns 计数**（即使在 macOS 上，`CPP/7zip/PropID.h:136-170`）。

**换算一律复用引擎现成的整数互转函数，桥接层不手写算术**——`TimeUtils.cpp:22-23` 的 `kUnixTimeOffset` 是编译期表达式 `(UInt64)60*60*24*(89 + 365*(kUnixTimeStartYear - kFileTimeStartYear))`（其值 = 11644473600，但源码无此字面量），用整数运算避免 `/1e7` double 丢 100ns 精度、大时间戳精度退化：

```objc
// 正向 FILETIME → NSDate：用整数函数取秒+100ns 量子，最外层才转 NSTimeInterval
UInt32 quantums = 0;                                   // 100ns 余数
Int64 unixSec = NWindows::NTime::FileTime_To_UnixTime64_and_Quantums(ft, quantums); // TimeUtils.cpp:170-...
NSTimeInterval t = (NSTimeInterval)unixSec + quantums * 1e-7;   // 仅最外层一次浮点
NSDate *date = [NSDate dateWithTimeIntervalSince1970:t];

// 反向 NSDate → FILETIME：整数构造
FILETIME ft;
NWindows::NTime::UnixTime64_To_FileTime64((Int64)floor(t), /*→*/ ftValue);  // TimeUtils.cpp:170-...
NWindows::NTime::UnixTime_To_FileTime(...);                                  // 或 TimeUtils.h:94-95
```

互转函数声明在 `TimeUtils.h:94-105`（`UnixTime_To_FileTime` / `FileTime_To_UnixTime` / `FileTime_To_UnixTime64_and_Quantums`），实现在 `TimeUtils.cpp:158-...`。**只在最外层把整数秒/100ns 转 `NSTimeInterval`，换算环节全程整数**——与 §5.2 下文 `wReserved` 精度保真主张自洽。

**扩展精度协议必须保真**（底料 04 §2.4、§7）：`wReserved1`=精度（0 基准/1 Unix 秒/2 DOS 2秒/3 1ns/16+n 小数位数）、`wReserved2`=ns%100、`wReserved3=0`。桥接 NSDate 只有毫秒级精度，**写回归档时若用 NSDate 重建 PROPVARIANT 会抹掉 `wReserved1/2`，导致 tar/zip 时间戳精度退化**。处置：归档内更新（SZFolderSession/SZCompressor 的 update 路径）对"未改动条目"**原样拷贝原 PROPVARIANT**（保留精度字段），只对用户显式修改的时间用 NSDate 重建。

---

## 6. 内存与所有权规则

### 6.1 ABI 闸门（加载即校验，硬约束）

`IUnknown` 默认**无虚析构**（v23 起对齐 Windows ABI，`CPP/Common/MyWindows.h:145-184`，宏 `Z7_USE_VIRTUAL_DESTRUCTOR_IN_IUNKNOWN` 默认未定义）。`GetModuleProp(kInterfaceType)` 报告该约定（实测 0 = `k_IUnknown_VirtDestructor_No`）。**桥接层（SevenZipKit）与 dylib 必须用同一设置编译**，否则虚表错位。

`SZLibrary` 加载后立即校验：

校验期望值**必须取桥接层自身的编译期常量 `NModuleInterfaceType::k_IUnknown_VirtDestructor_ThisModule`**（`ICoder.h:435`：非 `_WIN32` 且未定义 `Z7_USE_VIRTUAL_DESTRUCTOR_IN_IUNKNOWN` 时 = `_No`(=0)，否则 = `_Yes`(=1)），**不可硬编码字面量 0**——这与上游正本 `LoadCodecs.cpp:558-560`(IsSupportedDll) 的判据 `flags != k_IUnknown_VirtDestructor_ThisModule` 一致。硬编码 0 只在双侧都按默认编译时成立；一旦未来某侧开了 `Z7_USE_VIRTUAL_DESTRUCTOR_IN_IUNKNOWN`，硬编码 0 会误判，而比较 ThisModule 能让闸门随双侧设置同步自动正确。

```objc
// SZLibrary.mm 加载序列尾部
PROPVARIANT v; PropVariant_Init(&v);
if (getModuleProp(NModulePropID::kInterfaceType, &v) != S_OK ||
    v.vt != VT_UI4 ||
    v.ulVal != NModuleInterfaceType::k_IUnknown_VirtDestructor_ThisModule) {  // 编译期常量，非字面量 0
    // → SZErrorAbiMismatch
}
```

> 缺 `GetModuleProp` 的库在非 Windows 默认被假定"有虚析构"(=1) → 会被判不兼容（`LoadCodecs.cpp:527-534`）。本方案 dylib 保留 GetModuleProp 导出（§1.3 exports7z.txt 含 `_GetModuleProp`），不触发该陷阱。

### 6.2 CMyComPtr 引用计数 ↔ ARC 边界

- 引用计数 `CMyUnknownImp::_m_RefCount` 从 0 起（`MyCom.h:305-317`）；工厂创建后显式 `AddRef` 再交出（`ArchiveExports.cpp:77-88`）→ 桥接层拿到的指针**计数=1**。
- 桥接层 ObjC 对象用 `CMyComPtr<IInArchive>` 成员持有引擎对象；ObjC 对象 `dealloc` 时 `CMyComPtr` 析构自动 `Release`（`MyCom.h`）。**ARC 管 ObjC 对象生命周期，CMyComPtr 管 COM 对象生命周期，两者在 `.mm` 的成员声明处对接。**
- 回调对象（OpenCallback/ExtractCallback/UpdateCallback）按 Client7z 模式用 `Z7_IFACES_IMP_UNK_2(...)` 实现（`Client7z.cpp:186-198,328-360,614-656` 是权威模板），它持 `__weak` 引用回 ObjC 包装对象（防循环，底料 04 §6.1）；其生命周期由调用栈（Extract/UpdateItems 同步返回前）覆盖，引擎不会在调用返回后再持有。
- **BSTR/PROPVARIANT 即 malloc 块**（底料 05 §9.3）：桥接层可安全持有，但释放**必须** `SysFreeString` / `VariantClear`（`MyWindows.cpp:109-115`），**不可 `free()`**。出参所有权协议（`IArchive.h:20-41`）：调用前置 VT_EMPTY/NULL，调用后调用方负责清理。
- 密码 BSTR 跨边界释放安全：客户端 `SysAllocString` 分配、引擎 `SysFreeString` 释放，双方底层同一 libSystem malloc zone（dylib 与桥接层各内嵌 `MyWindows.o`，Mach-O 两级命名空间隔离同名符号，底料 04 §2.3 实测安全）。

### 6.3 异常不得跨 ABI 边界

桥接层有**两类必守异常边界**，缺一即 UB：

**(A) 引擎↔回调边界**：
- 引擎→客户端方向：所有导出函数/handler 方法用 `COM_TRY_BEGIN/END` 包裹，`catch(...) → E_OUTOFMEMORY`（`CPP/Common/ComTry.h:10-11`）。C++ 异常**不穿出** C ABI。
- 客户端→引擎方向（回调里抛异常进引擎）**无人保护 = UB**（底料 04 §2.2、底料 03 §3 风险 6；代码内 `throw int` 常见，如 `ContextMenu.cpp:326`、实测 `AgentProxy.cpp:184` 为 `throw 20120228`）。**桥接层每个回调方法必须 catch-all**（注意 pull 模型下 SetCompleted 内只写共享结构、不派发 UI，见 §7.2）：

```objc
// 回调方法骨架（.mm 内 C++ 类方法）
STDMETHODIMP MyExtractCallback::SetCompleted(const UInt64 *completeValue) {
    try {
        @try {
            if (_cancelled) return E_ABORT;
            os_unfair_lock_lock(&_state->lock);
            if (completeValue) _state->completedBytes = *completeValue;
            os_unfair_lock_unlock(&_state->lock);   // 只写结构，UI 由 §7.2 定时器拉取
            return S_OK;
        } @catch (NSException *) { return E_FAIL; }
    } catch (...) { return E_FAIL; }
}
```

**(B) dispatch block ↔ libdispatch 边界**：所有**在私有串行 dispatch block 内对 `CAgent`/`CAgentFolder`/`IInArchive`/`IOutArchive` 顶层方法的调用**（尤其 SZFolderSession §4.6 把 Agent 调用包进 block 的场景）必须用 `try{...}catch(...){转 HRESULT/NSError}` **整体包裹**。原因：Agent 内部 `throw int`（`AgentProxy.cpp:184`）若逸出 block 边界进入 libdispatch 的 C 帧是未定义行为——libdispatch 不保证跨 block 的 C++ 异常透传。骨架：

```objc
// SZFolderSession 在私有串行队列内调用 Agent 顶层方法
dispatch_async(self.queue, ^{
    HRESULT hr;
    try {
        @try { hr = self.agentFolder->LoadItems(); }
        @catch (NSException *) { hr = E_FAIL; }
    } catch (...) { hr = E_FAIL; }   // 截住 throw 20120228，不让它进 libdispatch
    dispatch_async(dispatch_get_main_queue(), ^{ completion(SZErrorFromHRESULT(hr)); });
});
```

---

## 7. 线程约定与取消

### 7.1 串行队列（核心约定）

**同一 IInArchive 禁止并发**（官方注释 `IArchive.h:305-308`：不同线程同时调用同一对象的 Extract/GetProperty/Open 会导致部分 handler 行为错误）。落地：

- 每个 `SZArchive`/`SZExtractor`/`SZCompressor`/`SZFolderSession` 持**一个私有串行 `dispatch_queue`**，所有引擎调用 `dispatch_async` 到该队列；多个归档并行用多个实例（各自独立 IInStream + 队列）。
- FM 的"列表/预览/解压并行"场景天然冲突（底料 04 §7）：预览走**独立 `SZArchive` 实例**（不与解压共用同一 IInArchive）。其内部读路径见 §4.2 `dataForEntryAtIndex:maxBytes:`——优先 QI `IInArchiveGetStream`（顺序读），对不实现该接口的 7z/zip 则 fallback 到单条目 `Extract` 入内存/临时流。

### 7.2 进度回调：pull（拉取）模型——硬契约，对齐 Windows GUI

**进度回调可发生在引擎 worker 线程**（底料 04 §5 实证：ZIP 多线程压缩 worker `CoderThread → WaitAndCode → Progress->SetRatioInfo`，经 `CMtProgressMixer2::SetRatioInfo` 持锁调用客户端 `IProgress::SetCompleted`，`ZipUpdate.cpp:393-408`）。LZMA2 多线程压缩/大文件解压每完成一个块就回调一次 `SetRatioInfo`，**底料实测可达每秒数千次**。

**Windows 正本是 pull 模型**：引擎回调 `SetCompleted/SetRatioInfo` 只在临界区内写入 `CProgressSync` 结构（`ProgressDialog2.h:32-105`，字段全部 `_cs CCriticalSection` 保护——实测 `:53` `CCriticalSection _cs`、`:59/:64/:71/:77` 各 setter 持 `CCriticalSectionLock`），UI 由 **200ms 的 `WM_TIMER` 拉取**刷新（`ProgressDialog2.cpp:28` `kTimerID=3`、`:33-38` `kTimerElapse=200`、`:422` `SetTimer(kTimerID, kTimerElapse)`、`:1060` `KillTimer(kTimerID)`）。**引擎回调本身从不触碰 UI，也从不每次派发到 UI 线程。** 若桥接层每次回调都 `dispatch_async(main)`，大任务期间会在主 runloop 堆积上万 block → UI 卡顿乃至 beachball。

因此桥接层 **必须照搬 pull 模型作为硬契约**，三条铁律：

1. **引擎回调只原子写共享结构、绝不 `dispatch_async`**：回调实现内仅更新一个 `os_unfair_lock`（或全 `_Atomic`）保护的进度结构 `{completedBytes, inSize, outSize, curFilePath}`，引擎线程立即返回。
2. **由桥接层持有的 200ms main-queue 定时器统一拉取并合并送达 delegate**（对齐 `kTimerElapse=200`）：每个会话型对象在启动任务时创建一个 `dispatch_source_t`（`DISPATCH_SOURCE_TYPE_TIMER`，target=main queue，间隔 200ms），其 handler 读取共享结构、单次回调 `szTaskDidProgress:` 等；任务结束时 `dispatch_source_cancel`。无论引擎每秒回调多少次，UI 每 200ms 仅刷新一次。
3. **回调里禁止重入同一 archive 对象**：进度回调在引擎持锁状态下调用，重入 = 死锁/未定义（底料 04 §5）。

```objc
// 共享进度结构（桥接层会话对象成员）
struct SZProgressState {
    os_unfair_lock lock;
    uint64_t completedBytes, totalBytes, totalFiles;
    NSString *curFilePath;   // __strong，持锁下置换
};

// 引擎回调（worker 线程）：只写结构，不派发
STDMETHODIMP MyExtractCallback::SetCompleted(const UInt64 *completeValue) {
    if (_cancelled) return E_ABORT;          // 取消语义见 §7.4
    os_unfair_lock_lock(&_state->lock);
    if (completeValue) _state->completedBytes = *completeValue;
    os_unfair_lock_unlock(&_state->lock);
    return S_OK;                              // 立即返回，不触碰 UI
}

// 200ms main-queue 定时器 handler（桥接层，main 线程）：拉取并合并送达
dispatch_source_set_event_handler(self.progressTimer, ^{
    os_unfair_lock_lock(&state->lock);
    uint64_t done = state->completedBytes; NSString *cur = state->curFilePath;
    os_unfair_lock_unlock(&state->lock);
    [self.progressDelegate szTaskDidProgress:done];
    if (cur) [self.progressDelegate szTaskDidStartFile:cur];
});
```

`IProgress`/`ICompressProgressInfo` 可与 `GetStream/PrepareOperation/SetOperationResult`（这三者串行、不并发，`IArchive.h:183-191`）并发——所以共享结构的读写必须线程安全（`os_unfair_lock` 或全 `_Atomic`、`__weak delegate`）。

### 7.3 阻塞式回调（密码/覆盖/卷/内存限额）

密码（`CryptoGetTextPassword(2)`）、覆盖询问、卷请求、内存限额回调都**同步阻塞**引擎调用线程（协议本身同步，`IPassword.h:16-51`）。桥接层不能在回调线程做 UI。模式：**信号量 + 主线程对话框**：

```objc
// 密码回调（引擎 worker 线程上）：
__block NSString *pw = nil;
dispatch_semaphore_t sem = dispatch_semaphore_create(0);
dispatch_async(dispatch_get_main_queue(), ^{
    pw = self.passwordHandler ? self.passwordHandler() : nil;  // 弹 NSAlert，同步取输入
    dispatch_semaphore_signal(sem);
});
dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);  // 阻塞引擎线程等用户
if (!pw) return E_ABORT;                              // 取消
// 必经一步：NSString → UTF-8 → UString(UTF-32) → BSTR，不可把 NSString* 直传 wchar_t* 接口。
// StringToBstr 签名是 HRESULT StringToBstr(LPCOLESTR src, BSTR *bstr)（MyCom.h:184），
// 入参 LPCOLESTR=OLECHAR*=wchar_t*(macOS 下 UTF-32)，返回 HRESULT，内部 SysAllocString 真实分配。
UString us; ConvertUTF8ToUnicode(AString([pw UTF8String]), us);
BSTR b = NULL;
if (StringToBstr(us.Ptr(), &b) != S_OK) return E_OUTOFMEMORY;
*password = b;            // 客户端分配，引擎按 IPassword.h:16-24 用 SysFreeString 释放
return S_OK;
```

> 切忌写成 `*password = StringToBstr(pw);`——既赋值方向反了（StringToBstr 返回 HRESULT 不是 BSTR），又跳过了 NSString→UTF-8→`ConvertUTF8ToUnicode` 的宽度转换必经步骤，编译都过不了。§5.1 反向编码路径与此处统一。

> 注意死锁防范：若引擎调用本身是从主线程同步发起的（不应如此——§7.1 要求异步派发到私有队列），主线程等待主线程会死锁。**所有引擎任务必须在私有串行队列发起**，主线程只负责 UI 与回调应答。

### 7.4 取消链路（E_ABORT）

`E_ABORT = 0x80004004`（`MyWindows.h:98`）是引擎取消语义。链路：

```
[UI] 用户点取消 → [SZExtractor cancel] 置原子标志 _cancelled = YES
        ↓（下一次引擎回调）
[引擎 worker] 调 IProgress::SetCompleted / ICompressProgressInfo::SetRatioInfo
        ↓
[桥接回调] 读 _cancelled → return E_ABORT
        ↓
[引擎] 收到 E_ABORT → 中止当前操作，逐层返回 → Extract/UpdateItems 返回 E_ABORT
        ↓
[桥接 finally] 清理残留（解压正在写的文件由引擎删；归档更新临时文件由桥接层删，§7.5）
        ↓
[桥接 completion] SZErrorFromHRESULT(E_ABORT) → NSError(code=SZErrorCancelled) → 主线程 completion(error)
```

> 归档内更新（SZFolderSession 写路径）的取消有特殊性：`MoveToOriginal` 回写阶段 **E_ABORT 被刻意延迟**（`ArchiveFolderOut.cpp:192-233`，实测：回写返回 E_ABORT 后仍 `Before_ArcReopen()` 清用户中断状态、继续重开归档），否则可能损档。桥接层必须保真此延迟语义，不可在回写中途强行中断（底料 03 §5 风险 5）。

### 7.5 取消后的清理契约（半成品/临时文件归属）

取消不是"立即停"，磁盘上的残留必须由明确责任方清理。两条路径策略不同：

**(1) 解压取消（SZExtractor）——已完成文件保留，正在写的文件由引擎删除：**
- 引擎对 abort 时**正在写的当前文件**自带清理：`ArchiveExtractCallback.cpp:1265 RemoveDir`、`:1274/:2575 DeleteFileAlways`、`:1369 RemoveDir(_diskFilePath)`——但**只覆盖正在写的当前文件，已落盘的前序文件不回滚**。
- 本方案**对齐 Windows 7zG 行为：已完成文件保留（不全部回滚）**，与用户"取消=停在当前进度"的预期一致。若 04-feature-map 的预览/解压设计需要"全有或全无"语义，须在该文档**显式标注偏离**并由桥接层在 completion 后清空目标目录。

**(2) 归档内更新取消（SZFolderSession/SZCompressor 更新路径）——临时文件由桥接层 finally 清理：**
- 更新写到 `CWorkDirTempFile`（`WorkDir.h:14`、`WorkDir.cpp:61` `CreateTempFile`、`:77` `MoveToOriginal`），**原归档在 `MoveToOriginal` 成功前完好无损**。
- 取消若发生在 `MoveToOriginal` 之前：临时文件未覆盖原档，桥接层在会话 finally（dispatch block 的 `catch`/completion 收尾）**必须删除 `CWorkDirTempFile` 临时文件**，不得残留。
- 取消若发生在 `MoveToOriginal` 回写阶段：按 §7.4 延迟语义让其跑完，原档被新档替换，无临时残留。

**清理责任落点**：解压正在写的文件→引擎；归档更新临时文件→桥接层 finally；已完成解压文件→保留（对齐 7zG）。

**M2 验收（纳入 05-roadmap-execution.md 的 R5/R-MOVEARC 触发信号）**：取消一个大归档的解压/更新后，断言 **(a)** 目标目录除"已完成文件"外无意外残留；**(b)** 工作临时目录（`CWorkDirTempFile`）无残留；**(c)** 原归档完好——对原归档做 `CRC` 校验（`./7zcl t orig.7z`）通过。

---

## 8. PoC 验证步骤（里程碑 M0 验收依据）

目标：从零到 **"dlopen lib7z.dylib，列出某 .7z 内容并解压"** 的可执行序列。分两段：先复现底料 04 实测（证明引擎/dylib），再用最小 ObjC++ 程序证明桥接路径。M0 通过 = §8.2 全绿。

### 8.1 段 A：构建 dylib + 参考客户端 roundtrip（复现底料 04 §8）

```sh
# A1) 构建 dylib（带 dylib 化链接选项，§1.3）
cd CPP/7zip/Bundles/Format7zF
make -f ../../cmpl_mac_arm64_dylib.mak -j8
lipo -info b/m_arm64/7z.so 2>/dev/null || file b/m_arm64/7z.so   # Mach-O DYLIB arm64

# A2) 验证导出收敛与 ABI（精确 19 个 T 符号，含 _GetModuleProp）
nm -gU b/m_arm64/7z.so | grep -c ' T '          # 必须 == 19（仅 text 全局符号，排除 weak/typeinfo）
# 逐一比对符号名集合与 exports7z.txt 一致（无多无少）：
nm -gU b/m_arm64/7z.so | awk '$2=="T"{print $3}' | sort | \
  diff - <(sed 's/^_//' exports7z.txt | sort)  # 期望无差异输出
nm -gU b/m_arm64/7z.so | grep -E '_CreateObject|_GetModuleProp'
otool -D b/m_arm64/7z.so                        # install_name = @rpath/lib7z.dylib
otool -l b/m_arm64/7z.so | grep -A3 LC_ID_DYLIB # current/compat version 已设

# A3) 改名 + 参考客户端 roundtrip（证明引擎可用）
cp b/m_arm64/7z.so /tmp/poc/lib7z.dylib
cd ../../UI/Client7z && make -f ../../cmpl_mac_arm64.mak -j8     # → b/m_arm64/7zcl
cp b/m_arm64/7zcl /tmp/poc/ && cp /tmp/poc/lib7z.dylib /tmp/poc/7z.so   # Client7z 走 LoadCodecs，需 7z.so 名
cd /tmp/poc
echo hello > f1.txt && head -c 4096 /dev/urandom > f2.bin
./7zcl a test.7z f1.txt f2.bin     # 压缩 OK
./7zcl l test.7z                   # 列表 OK
mkdir out && cd out && ../7zcl x ../test.7z
diff f1.txt ../f1.txt && diff f2.bin ../f2.bin   # ROUNDTRIP OK
```

### 8.2 段 B：最小 ObjC++ 桥接 PoC（M0 真正验收点）

写一个最小 `.mm`（不依赖 SevenZipKit 完整框架，只验证桥接路径），直接 dlopen + dlsym + CreateObject + 列表 + 解压：

```objc
// poc_bridge.mm —— 编译：clang++ -ObjC++ -std=c++17 poc_bridge.mm <引擎自带 .o> \
//   -framework Foundation -ldl -o poc_bridge   （.o 集合见底料 04 §3.5：MyWindows/FileStreams/
//   PropVariant/PropVariantConv/FileDir/FileFind/FileIO/FileName/MyString/StringConvert/
//   UTFConvert/IntToString/Wildcard/DLL/Alloc/NewHandler/TimeUtils）
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include "Common/MyInitGuid.h"            // 唯一 INITGUID 编译单元
#include "7zip/Archive/IArchive.h"
#include "7zip/IPassword.h"
#include "7zip/UI/Client7z/...或自实现的 InFileStream/ExtractCallback"

typedef HRESULT (*Func_CreateObject)(const GUID*, const GUID*, void**);
typedef HRESULT (*Func_GetModuleProp)(PROPID, PROPVARIANT*);

int main() { @autoreleasepool {
    // B1) dlopen 绝对路径（桥接层真实路径，不经 LoadCodecs）
    void *h = dlopen("/tmp/poc/lib7z.dylib", RTLD_NOW | RTLD_LOCAL);
    NSCAssert(h, @"dlopen failed: %s", dlerror());

    // B2) ABI 闸门（§6.1）
    auto getProp = (Func_GetModuleProp)dlsym(h, "GetModuleProp");
    PROPVARIANT pv; memset(&pv, 0, sizeof pv);
    getProp(NModulePropID::kInterfaceType, &pv);
    // 与桥接层自身编译期常量比对，不硬编码 0（§6.1）
    NSCAssert(pv.ulVal == NModuleInterfaceType::k_IUnknown_VirtDestructor_ThisModule,
              @"ABI mismatch: interfaceType=%u", pv.ulVal);

    // B3) CreateObject → IInArchive（7z 格式 CLSID，§2.3）
    auto createObject = (Func_CreateObject)dlsym(h, "CreateObject");
    CMyComPtr<IInArchive> archive;
    createObject(&CLSID_Format_7z, &IID_IInArchive, (void**)&archive);

    // B4) Open + 列表（IInArchive::Open → GetNumberOfItems → GetProperty(kpidPath)）
    CMyComPtr<IInStream> file = new CInFileStream(...);  // 打开 /tmp/poc/test.7z
    UInt64 maxCheck = 0;
    NSCAssert(archive->Open(file, &maxCheck, openCallback) == S_OK, @"open");
    UInt32 n = 0; archive->GetNumberOfItems(&n);
    for (UInt32 i = 0; i < n; i++) {
        NWindows::NCOM::CPropVariant path;
        archive->GetProperty(i, kpidPath, &path);
        NSLog(@"[%u] %@", i, /* path.bstrVal(UTF-32) → NSString via UTF-8，§5.1 */);
    }

    // B5) 解压全部到 /tmp/poc/out_bridge（IInArchive::Extract，§4.4）
    CMyComPtr<IArchiveExtractCallback> cb = new CMyExtractCallback(/*out dir*/);
    HRESULT hr = archive->Extract(NULL, (UInt32)-1, 0 /*not testMode*/, cb);
    NSCAssert(hr == S_OK, @"extract hr=0x%X", hr);

    archive->Close();
    return 0;
} }
```

**M0 验收标准（全部通过）：**

| 检查项 | 期望 | 对应 §  |
|---|---|---|
| AC-1 构建 | `make -f cmpl_mac_arm64_dylib.mak` 产出 Mach-O DYLIB；`nm -gU \| grep -c ' T '` **精确 == 19** 且符号名集合与 `exports7z.txt` 逐一一致（无 weak external/typeinfo/operator new 泄漏为 global text）；并跑一次 dlopen+CreateObject+roundtrip 确认无运行时 dlsym 失败（闭环开放问题 #2） | §1.3 |
| AC-2 install_name/版本 | `otool -D` = `@rpath/lib7z.dylib`，current/compat version 已设 | §1.4 |
| AC-3 段 A roundtrip | 7zcl 压缩→列表→解压 `diff` 全一致 | §8.1 |
| AC-4 dlopen + ABI 闸门 | poc_bridge dlopen 成功，`kInterfaceType == 0` | §6.1 |
| AC-5 列表 | poc_bridge 正确打印 .7z 内全部条目路径（含中文名 UTF-8 正确） | §5.1 |
| AC-6 解压 | poc_bridge 解压输出与原文件 `diff` 一致 | §4.4 |
| AC-7 universal | `lipo -create` 后 `lipo -info` = `x86_64 arm64`，两切片均能 dlopen | §1.4 |

M0 通过即证明"核心 dylib + ObjC++ 桥接"基础路径成立，可进入 SevenZipKit 完整框架开发（M1，见 05-roadmap-execution.md）。

---

## 9. 开放问题

以下问题源码无法直接定案，需在 M0/M1 期间实测或决策后回填：

1. **`EXPORTS_LIST` 相对路径解析**：`var_mac_arm64_dylib.mak` 中 `exports7z.txt` 的路径在"于 bundle 目录内执行 make"时如何稳定解析（make `$(MAKEFILE_DIR)` 在 GNU make 各版本行为不一）。需在 M0 构建脚本里确定是用绝对路径、还是 `$(CURDIR)`、还是把清单放进 bundle 目录用裸文件名。
2. **`-Wl,-exported_symbols_list` 与 `-dead_strip` 的交互**：收敛到 19 个导出后，`-dead_strip` 是否会误删被这些导出间接引用的内部符号，以及 libc++ 模板实例化/RTTI/typeinfo/operator new/delete 等 weak external 符号在收敛后是否仍以 global text 外部可见（4041→19 是否真落到精确 19）。**M0 由 AC-1 闭环**：`nm -gU | grep -c ' T ' == 19` + 符号名集合逐一比对 `exports7z.txt` + 一次完整 dlopen+CreateObject+roundtrip 确认无运行时 `dlsym` 失败；实跑通过后此问题关闭。
3. **x86_64 切片的汇编/HW intrinsics 路径**：`var_mac_x64.mak` 设 `USE_ASM=`（关闭），x64 的 SHA/AES/LZMA 走 C 还是 SSE intrinsics、性能差多少，需实测；是否值得为 x64 切片单独开 `USE_ASM=1`（涉及 x86 汇编 .asm 文件的 clang 兼容性）。
4. **`SetCodecs(NULL)` 卸载链路是否需要**：桥接层若全程不走 LoadCodecs（直接 dlopen + CreateObject），是否仍需在退出前 `SetCodecs(NULL)`；常驻进程不 dlclose 时此调用是否可省（底料 04 §5 建议常驻不卸载，但 FM 复用 Agent→CCodecs 路径时该链路会被触发）。
5. **NFC/NFD 规范化的精确插桩点**：底料 05 §5.3 指出全仓无现成代码，但"在桥接层统一规范化"具体插在哪一层（SZArchiveEntry.path 读出时？SZCompressItem.archivePath 入档时？覆盖检测比较时？）需结合 03-feature-map-filemanager.md 的覆盖/更新检测逻辑定案，避免双重规范化。
6. **VT_FILETIME 精度字段在 NSDate 往返中的最优保真策略**：§5.2 给出"未改动条目原样拷贝原 PROPVARIANT"的方向，但 SZCompressor 全新压缩时 NSDate（毫秒）→ FILETIME 的精度字段（`wReserved1`）应填什么值，需对照 tar/zip handler 对精度的期望（`PropID.h:136-170`）确定默认精度等级。
7. **`current_version` 与引擎版本号策略**：dylib `current_version` 写 `26.1`（对应引擎 26.01），但桥接层/框架自身的版本与引擎版本是否解耦（引擎升级时 lib7z.dylib 版本如何与 SevenZipKit.framework 版本对齐），属发布工程问题，待 05-roadmap-execution.md 的分发策略定案。
