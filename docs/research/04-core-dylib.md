# 04 核心动态库与 ABI 报告（lib7z.dylib / 7z.so）

> 7-Zip 26.01 源码盘点 · macOS 移植方案B（核心 dylib + ObjC++ 桥接 + AppKit）工作底料
> 所有结论均核对真实源码，证据格式 `文件路径:行号`。仓库根：`/Users/lyd/WorkSpace/MyProjects/7zip`。
> 本报告含**本机实测**（macOS arm64 / clang，2026-06-13）：Format7zF 用 stock makefile 一次编译通过产出 Mach-O dylib，Client7z dlopen 完成压缩/列表/解压 roundtrip。

---

## 0. 实测结论速览（本机验证，非推断）

| 项目 | 实测结果 |
|---|---|
| 构建命令 | `cd CPP/7zip/Bundles/Format7zF && make -f ../../cmpl_mac_arm64.mak -j8`（零改动，一次通过） |
| 产物 | `b/m_arm64/7z.so`，`file` 判定 **Mach-O 64-bit dynamically linked shared library arm64**，`otool -hv` filetype=**DYLIB**，约 2.51 MB |
| 外部依赖 | 仅 `/usr/lib/libSystem.B.dylib` 与 `/usr/lib/libc++.1.dylib`（`otool -L`），自包含 |
| install_name | 默认为构建输出路径 `b/m_arm64/7z.so`（`otool -D`）→ 嵌入 app 前需修正（§3.4） |
| 导出符号 | `nm -gU` 共 **4041** 个（包括全部 C++ 符号）；19 个 C ABI 入口全部在列（§1） |
| 运行时探测 | dlopen 后调用：`GetNumberOfFormats=60`、`GetNumberOfMethods=25`、`GetModuleProp(kInterfaceType)=0`（无虚析构约定）、`kVersion=0x1A0001`（26.01） |
| 端到端 | Client7z(7zcl) dlopen `7z.so` → 压缩 2 个文件成 .7z → 列表 → 解压 → `diff` 全部一致（ROUNDTRIP OK）；把 `7z.so` 改名 `lib7z.dylib` 后 dlopen 同样成功 |
| 平台基线 | `sizeof(wchar_t)=4`、自定义 `PROPVARIANT` `sizeof=16`（实测与 `CPP/Common/MyWindows.h:227-250` 一致） |

---

## 1. lib7z.dylib 应导出的全部 C 函数

### 1.1 官方 ABI（Windows 上由 `Archive2.def` 定义的导出集）

`CPP/7zip/Archive/Archive2.def:1-23` 列出 15 个导出名（7z.dll 的全部官方入口）。非 Windows 链接不使用 .def（`CPP/7zip/7zip_gcc.mak:102-109`：仅 MinGW 分支用 `-DEF`），因此 mac 上这些符号天然导出（带下划线前缀）。所有函数均为 `STDAPI`，即 `extern "C" HRESULT`（POSIX 上无 `__stdcall`，`CPP/Common/MyWindows.h:104-113`）。

| # | 函数 | 签名 | 定义位置 | 语义与备注 |
|---|---|---|---|---|
| 1 | `CreateObject` | `HRESULT CreateObject(const GUID *clsid, const GUID *iid, void **outObject)` | `CPP/7zip/Archive/DllExports2.cpp:93-106` | 万能工厂。按 `*iid` 分流：`IID_ICompressCoder/ICompressCoder2/ICompressFilter`→`CreateCoder`；`IID_IHasher`→`CreateHasher`；其余交给 `CreateArchiver`（接受 `IID_IInArchive`/`IID_IOutArchive`）。出参先置 NULL。 |
| 2 | `GetNumberOfFormats` | `HRESULT (UINT32 *numFormats)` | `CPP/7zip/Archive/ArchiveExports.cpp:143-148` | 返回静态注册表 `g_Arcs` 数量（本机实测 60）。 |
| 3 | `GetHandlerProperty2` | `HRESULT (UInt32 formatIndex, PROPID propID, PROPVARIANT *value)` | `CPP/7zip/Archive/ArchiveExports.cpp:94-135` | 按格式索引查询格式元数据。propID 枚举 `NArchive::NHandlerPropID`（`CPP/7zip/Archive/IArchive.h:99-117`）：kName(VT_BSTR)、kClassID(二进制 BSTR=16 字节 GUID)、kExtension/kAddExtension(VT_BSTR)、kUpdate(VT_BOOL)、kFlags/kTimeFlags/kSignatureOffset(VT_UI4)、kSignature/kMultiSignature(二进制 BSTR)。越界返回 `E_INVALIDARG`。 |
| 4 | `GetHandlerProperty` | `HRESULT (PROPID, PROPVARIANT*)` | `CPP/7zip/Archive/ArchiveExports.cpp:137-141` | 旧版单格式接口 = `GetHandlerProperty2(默认7z索引, …)`。仅为兼容保留。 |
| 5 | `GetIsArc` | `HRESULT (UInt32 formatIndex, Func_IsArc *isArc)` | `CPP/7zip/Archive/ArchiveExports.cpp:150-158` | 取出格式的快速签名探测函数指针 `typedef UInt32 (WINAPI *Func_IsArc)(const Byte *p, size_t size)`（`CPP/7zip/Archive/IArchive.h:708`），返回 `k_IsArc_Res_NO/YES/NEED_MORE`（`IArchive.h:696-698`）。 |
| 6 | `GetNumberOfMethods` | `HRESULT (UInt32 *numCodecs)` | `CPP/7zip/Compress/CodecExports.cpp:260-265` | 编解码器数量（本机实测 25）。 |
| 7 | `GetMethodProperty` | `HRESULT (UInt32 codecIndex, PROPID propID, PROPVARIANT *value)` | `CPP/7zip/Compress/CodecExports.cpp:198-257` | propID 枚举 `NMethodPropID`（`CPP/7zip/ICoder.h:405-421`）：kID(VT_UI8 方法ID)、kName(VT_BSTR)、kDecoder/kEncoder(16 字节 GUID 的二进制 BSTR)、kDecoderIsAssigned/kEncoderIsAssigned(VT_BOOL)、kPackStreams(VT_UI4，仅多流)、kIsFilter(VT_BOOL)。 |
| 8 | `CreateDecoder` | `HRESULT (UInt32 index, const GUID *iid, void **outObject)` | `CPP/7zip/Compress/CodecExports.cpp:153-157` | 按索引建解码器；iid 必须与编码器形态匹配（filter→`IID_ICompressFilter`、多流→`IID_ICompressCoder2`、单流→`IID_ICompressCoder`，`CodecExports.cpp:127-150`），否则 `E_NOINTERFACE`。 |
| 9 | `CreateEncoder` | 同上 | `CPP/7zip/Compress/CodecExports.cpp:160-164` | 同上（编码方向）。 |
| 10 | `GetHashers` | `HRESULT (IHashers **hashers)` | `CPP/7zip/Compress/CodecExports.cpp:333-342` | 返回 `IHashers` COM 集合对象（`new CHashers` 后 AddRef），经其 `GetNumHashers/GetHasherProp/CreateHasher` 枚举（`CodecExports.cpp:344-357`）。 |
| 11 | `SetCodecs` | `HRESULT (ICompressCodecsInfo *compressCodecsInfo)` | `CPP/7zip/Archive/DllExports2.cpp:156-185` | 客户端把自己的 `CCodecs`（实现 `ICompressCodecsInfo`）注入 dylib，使 dylib 内 handler 能用外部编解码器（`Z7_EXTERNAL_CODECS` 时存入 `g_ExternalCodecs` 并 Load）。**传 NULL 用于卸载前打破循环引用**。Format7zF 定义了 `-DZ7_EXTERNAL_CODECS`（`CPP/7zip/Bundles/Format7zF/makefile.gcc:36-39`）。 |
| 12 | `SetLargePageMode` | `HRESULT (void)` | `CPP/7zip/Archive/DllExports2.cpp:123-127` | = `SetLargePageMode2(0,0,0)`。 |
| 13 | `SetLargePageMode2` | `HRESULT (UInt32 flags, size_t pageSize, size_t threshold)` | `CPP/7zip/Archive/DllExports2.cpp:108-121` | 仅当编译期 `Z7_LARGE_PAGES` 才有实际行为；mac 构建未定义 → 恒返回 `S_OK`，可不调用。 |
| 14 | `SetCaseSensitive` | `HRESULT (Int32 caseSensitive)` | `CPP/7zip/Archive/DllExports2.cpp:131-136` | 写进程级全局 `g_CaseSensitive`（定义在 `CPP/Common/Wildcard.cpp:8-20`；**macOS 桌面默认 false**，Linux 默认 true，iOS true）。影响通配符/路径比较，全局生效、非每会话。 |
| 15 | `GetModuleProp` | `HRESULT (PROPID propID, PROPVARIANT *value)` | `CPP/7zip/Compress/CodecExports.cpp:360-378` | `NModulePropID::kInterfaceType`(VT_UI4)：IUnknown 是否带虚析构（`CPP/7zip/ICoder.h:423-441`，本模块默认 `k_IUnknown_VirtDestructor_No=0`，实测 0）；`kVersion`(VT_UI4) = `major<<16|minor`（实测 0x1A0001=26.01）。**LoadCodecs 用它做 ABI 兼容性闸门**（见 §4.1）。 |

### 1.2 辅助 extern "C" 符号（不在 .def 中，mac 上因全量导出也可见）

| 函数 | 定义 | 说明 |
|---|---|---|
| `CreateArchiver(const GUID*, const GUID*, void**)` | `CPP/7zip/Archive/ArchiveExports.cpp:63-92` | `CreateObject` 的归档分支实体；直接调用亦可。 |
| `CreateCoder(const GUID*, const GUID*, void**)` | `CPP/7zip/Compress/CodecExports.cpp:167-195` | 按 CLSID 建编解码器。 |
| `CreateHasher(const GUID*, IHasher**)` | `CPP/7zip/Compress/CodecExports.cpp:293-303` | 按 CLSID 建哈希器。 |
| `GetHasherProp(UInt32, PROPID, PROPVARIANT*)` | `CPP/7zip/Compress/CodecExports.cpp:305-329` | Windows 不导出此名；正式途径是 `IHashers` 接口。 |
| `Init_ForceToUTF8`（构造函数，无需调用） | `CPP/7zip/Archive/DllExports2.cpp:73-78` | 非 Windows 专属：dylib 加载即执行 `__attribute__((constructor))`，设 `g_ForceToUTF8 = IsNativeUTF8()`（`CPP/Common/StringConvert.cpp:260,554-576`）。 |

客户端侧的函数指针 typedef 全集：`Func_CreateObject/Func_IsArc/Func_GetIsArc/Func_GetNumberOfFormats/Func_GetHandlerProperty(2)/Func_SetCaseSensitive/Func_SetLargePageMode(2)` 在 `CPP/7zip/Archive/IArchive.h:704-722`；`Func_GetNumberOfMethods/Func_GetMethodProperty/Func_CreateDecoder/Func_CreateEncoder/Func_GetHashers/Func_SetCodecs/Func_GetModuleProp` 在 `CPP/7zip/ICoder.h:466-477`。一律用 `Z7_GET_PROC_ADDRESS`（`CPP/Common/Common0.h:265-266`）→ POSIX `dlsym` 包装 `GetProcAddress`（`CPP/Windows/DLL.cpp:119-125`，**dlsym 时符号名不带下划线**）。

### 1.3 GUID 编码方案（构造 CLSID/IID 的规则）

公共常量 `k_7zip_GUID_Data1=0x23170F69, Data2=0x40C1, Data3_Common=0x278A`（`CPP/7zip/IDecl.h:9-16`）。

| 类别 | 形态 | 证据 |
|---|---|---|
| 接口 IID | `{23170F69-40C1-278A-0000-00 gg 00 ss 0000}`，Data4[3]=组号、Data4[5]=子号 | `CPP/7zip/IDecl.h:18-27` |
| 格式 CLSID | `{23170F69-40C1-278A-1000-000110 xx 0000}`，`Data4[5]`=格式 Id（`CLS_ARC_ID_ITEM` 宏） | `CPP/7zip/Archive/ArchiveExports.cpp:30-36,106-110`；常用 Id：zip=1、bzip2=2、7z=7、xz=0xC、tar=0xEE、gzip=0xEF（`CPP/7zip/UI/Client7z/Client7z.cpp:45-64`）；全表见 `DOC/Guid.txt` |
| 编解码器 CLSID | Data3=0x2790(解码)/0x2791(编码)/0x2792(哈希)，Data4=8 字节 MethodId 小端 | `CPP/7zip/Compress/CodecExports.cpp:44-52,54-85,270-281`；`CPP/7zip/IDecl.h:14-16` |

接口组号实例（由各头文件的声明宏可直接读出）：IProgress=(0,0x05) `CPP/7zip/IProgress.h:16`；流类=组3：ISequentialInStream 0x01、ISequentialOutStream 0x02、IInStream 0x03、IOutStream 0x04、IStreamGetSize 0x06、IStreamGetProps 0x08、IStreamGetProp 0x0a、IStreamSetRestriction 0x10（`CPP/7zip/IStream.h:14-19,47-207`）；编解码=组4：ICompressProgressInfo 0x04、ICompressCoder 0x05、ICompressCoder2 0x18、ICompressSetCoderProperties 0x20、ICompressSetDecoderProperties2 0x22、ICompressSetCoderMt 0x25、ICompressFilter 0x40、ICompressCodecsInfo 0x60、ISetCompressCodecsInfo 0x61、IHasher 0xC0、IHashers 0xC1（`CPP/7zip/ICoder.h:10-12` 及各宏处）；密码=组5：ICryptoGetTextPassword 0x10、ICryptoGetTextPassword2 0x11（`CPP/7zip/IPassword.h:12-51`）；归档=组6：ISetProperties 0x03、IArchiveKeepModeForNextOpen 0x04、IArchiveAllowTail 0x05、IArchiveRequestMemoryUseCallback 0x09、IArchiveOpenCallback 0x10、IArchiveExtractCallback 0x20、IArchiveExtractCallbackMessage2 0x22、IArchiveOpenVolumeCallback 0x30、IInArchiveGetStream 0x40、IArchiveOpenSetSubArchiveName 0x50、IInArchive 0x60、IArchiveOpenSeq 0x61、IArchiveGetRawProps 0x70、IArchiveGetRootProps 0x71、IArchiveUpdateCallback 0x80、IArchiveUpdateCallback2 0x82、IArchiveUpdateCallbackFile 0x83、IArchiveGetDiskProperty 0x84、IOutArchive 0xA0（`CPP/7zip/Archive/IArchive.h:13-18` 各 `Z7_IFACE_CONSTR_ARCHIVE(...)` 调用处）。

GUID 存储初始化：客户端**恰好一个**编译单元在包含接口头之前 `#include "Common/MyInitGuid.h"`（定义 INITGUID 并落实 IID_IUnknown，`CPP/Common/MyInitGuid.h:6-55`；Client7z 范例 `CPP/7zip/UI/Client7z/Client7z.cpp:8`）。

---

## 2. COM 模拟层在 POSIX 的实际形态

### 2.1 基本类型与 HRESULT

| 项 | 定义 | 证据 |
|---|---|---|
| `HRESULT` | `#define HRESULT LONG`，`LONG=INT32`（32 位有符号） | `C/7zTypes.h:200,192` |
| 成功/失败 | `SUCCEEDED(hr)= hr>=0`；`S_OK=0, S_FALSE=1, E_NOTIMPL=0x80004001, E_NOINTERFACE=0x80004002, E_ABORT=0x80004004, E_FAIL=0x80004005, CLASS_E_CLASSNOTAVAILABLE=0x80040111` | `CPP/Common/MyWindows.h:88-101` |
| errno 映射 | POSIX 上 `HRESULT_FROM_WIN32(errno)` = `0x8000_0000 | (0x800<<16) | errno`（自定义 FACILITY_ERRNO=0x800）；`E_OUTOFMEMORY=0x8007000E、E_INVALIDARG=0x80070057` 沿用 Win32 编码 | `C/7zTypes.h:79-93,126-134` |
| `GetLastError` | 即 errno 封装 | `CPP/Common/MyWindows.cpp:144-152` |
| GUID | `{UInt32; UInt16; UInt16; Byte[8]}`；`operator==` 为**逐字节比较**（C++ 内联）；`REFGUID=const GUID&` | `CPP/Common/MyGuidDef.h:12-39` |
| `WINAPI/STDMETHODCALLTYPE/STDAPICALLTYPE` | 全部为空 → 默认 C/C++ 调用约定（AAPCS64） | `CPP/Common/MyWindows.h:33-34,104-113` |
| `BOOL=int`、`VARIANT_BOOL=short`（TRUE=-1）、`PROPID=ULONG=UInt32`、`FILETIME={DWORD lo,hi}` | | `CPP/Common/MyWindows.h:47-90,188-189` |

### 2.2 IUnknown 与引用计数约定

- `IUnknown`：仅 3 个纯虚方法 `QueryInterface/AddRef/Release`，**默认无虚析构**（v23 起为对齐 Windows ABI 去掉了 p7zip 时代的虚析构；宏 `Z7_USE_VIRTUAL_DESTRUCTOR_IN_IUNKNOWN` 默认未定义）——`CPP/Common/MyWindows.h:145-184`。`GetModuleProp(kInterfaceType)` 报告该约定（实测 0），且 `LoadCodecs::IsSupportedDll` 在加载外部 dll 时强校验之（`CPP/7zip/UI/Common/LoadCodecs.cpp:521-562`）：**客户端与 dylib 必须用同一设置编译**，否则模块被拒载/虚表错位。
- 引用计数：`CMyUnknownImp::_m_RefCount` 从 0 起（`CPP/Common/MyCom.h:305-317`）；工厂创建后显式 `AddRef()` 再交出（`CPP/7zip/Archive/ArchiveExports.cpp:77-88`、`CPP/7zip/Compress/CodecExports.cpp:107-121`）→ 客户端拿到的指针计数=1，用 `CMyComPtr` 的 `Attach` 或裸 `Release` 配平。
- **默认非原子**：`Z7_COM_USE_ATOMIC` 在全仓库无任何定义点（仅 `CPP/Common/MyCom.h:358-362` 注释），故 `AddRef/Release` 是 `++/--` 裸操作（`MyCom.h:380-391`）；原子版宏 `Z7_COM_ADDREF_RELEASE_MT` 存在（`MyCom.h:345-356`）但非 Windows 下需要自行提供 `InterlockedIncrement/Decrement`（`MyCom.h:362-373`）。
- `QueryInterface` 由 `Z7_COM_QI_BEGIN/ENTRY/END` 宏生成 if-else 链，只认显式登记的 IID，否则 `E_NOINTERFACE`（`CPP/Common/MyCom.h:321-356,395-482`）。
- 异常边界：所有导出函数和 handler 方法用 `COM_TRY_BEGIN/END` 包裹，`catch(...) → E_OUTOFMEMORY`（`CPP/Common/ComTry.h:10-11`）。C++/ObjC 异常**不会**穿出 C ABI；反向（客户端回调里抛异常进引擎）无人保护，桥接层必须自行 catch-all。
- 智能指针：`CMyComPtr/CMyComPtr2/CMyComBSTR`（`CPP/Common/MyCom.h:9-288`），注意 `operator&` 直接暴露内部指针（`MyCom.h:22`）。

### 2.3 BSTR：非 Windows 下到底是什么

`BSTR = OLECHAR* = wchar_t*`（`CPP/Common/MyWindows.h:75-78`），mac 上 `wchar_t` 4 字节（实测），即**指向 UTF-32（平台 wchar_t 序列）的指针**。内存布局由 7-Zip 自带实现（`CPP/Common/MyWindows.cpp:15-106`）：

```
[ UInt32 字节长度 ][ payload ... ][ 对齐补零（含一个对齐的 0 结尾 OLECHAR）]
                   ^ BSTR 指针指向这里
```

- `SysAllocStringLen(s,len)`：前缀存 `len*sizeof(OLECHAR)` 字节，尾置 `bstr[len]=0`（`MyWindows.cpp:61-76`）；分配器是 `malloc/free`（`MyWindows.cpp:15-16`）。
- `SysAllocStringByteLen(s,len)`：**按字节**分配，用于二进制 blob（GUID、签名、NtSecure、SHA 摘要），byteLen 可以不是 4 的倍数（`MyWindows.cpp:40-59`；用例 `ArchiveExports.cpp:38-48`、`LoadCodecs.cpp:232-237,444-448`）。读取二进制 BSTR 必须用 `SysStringByteLen`（前缀原值），字符串才用 `SysStringLen=字节数/sizeof(OLECHAR)`（`MyWindows.cpp:94-106`）。
- 跨模块释放安全性：dylib 与客户端各自静态内嵌一份这些函数（Format7zF 含 `MyWindows.o`，`CPP/7zip/Bundles/Format7zF/makefile.gcc:29-33`；Client7z 同，`CPP/7zip/UI/Client7z/makefile.gcc:23-27`），双方底层都是 libSystem 同一 malloc zone → A 分配 B 释放在 macOS 安全（密码 BSTR 正是客户端分配、引擎释放，`CPP/7zip/IPassword.h:16-24`）。Mach-O 两级命名空间使同名符号互不干扰（实测 7z.so 头部 flags 含 `TWOLEVEL NOUNDEFS`）。
- 字符编码链：`UString(wchar_t)` ↔ UTF-8 由 `StringConvert/UTFConvert` 完成，dylib 加载时构造函数已把 `g_ForceToUTF8` 设为 `IsNativeUTF8()` 结果（mac UTF-8 locale 下为 true；`DllExports2.cpp:73-78`、`CPP/Common/StringConvert.cpp:260,554-576`）。桥接 NSString 时统一走 UTF-8 中转即可。

### 2.4 PROPVARIANT：布局与实际用到的全部 VT_*

布局（POSIX 自定义版，`CPP/Common/MyWindows.h:222-254`）：`{VARTYPE vt; WORD wReserved1,2,3; union{ CHAR/UCHAR/SHORT/USHORT/LONG/ULONG/INT/UINT/LARGE_INTEGER/ULARGE_INTEGER/VARIANT_BOOL/SCODE/FILETIME/BSTR };}`，**16 字节**（实测）；Windows 原生为 24 字节——二进制不互通，但本方案两侧都用此头编译，无问题。`VARIANT/VARIANTARG` 是同一结构的别名（`MyWindows.h:252-254`）。

清理/复制函数：`VariantClear` 只认 `VT_BSTR`（释放）其余直接置 `VT_EMPTY`（`CPP/Common/MyWindows.cpp:109-115`）；`VariantCopy` 仅深拷 BSTR（`MyWindows.cpp:117-133`）；上层 `NWindows::NCOM::PropVariant_Clear/CPropVariant::Clear/Copy/Attach/Detach` 对"简单类型集合"快速处理、未知类型回落系统函数（`CPP/Windows/PropVariant.cpp:220-331`，简单类型清单 `CASE_SIMPLE_VT_VALUES` 即 EMPTY/BOOL/FILETIME/UI8/UI4/UI2/UI1/I8/I4/I2/I1/UINT/INT/NULL/ERROR/R4/R8/CY/DATE）。

**枚举定义全集**（`CPP/Common/MyWindows.h:191-220`）：VT_EMPTY=0, VT_NULL=1, VT_I2=2, VT_I4=3, VT_R4=4, VT_R8=5, VT_CY=6, VT_DATE=7, VT_BSTR=8, VT_DISPATCH=9, VT_ERROR=10, VT_BOOL=11, VT_VARIANT=12, VT_UNKNOWN=13, VT_DECIMAL=14, VT_I1=16, VT_UI1=17, VT_UI2=18, VT_UI4=19, VT_I8=20, VT_UI8=21, VT_INT=22, VT_UINT=23, VT_VOID=24, VT_HRESULT=25, **VT_FILETIME=64**。

**实际由引擎产生/消费的 VT 类型**（逐个，附产生点）：

| VT | 用途 | 证据 |
|---|---|---|
| `VT_EMPTY` | "属性不存在/未知"；调用前出参必须先置 VT_EMPTY | `CPP/7zip/Archive/IArchive.h:20-41`；`PropVariant.h:60-68` |
| `VT_BOOL` | kpidIsDir/Encrypted/Solid… 及 kUpdate/kIsFilter 等；`VARIANT_TRUE=-1` | `CPP/Windows/PropVariant.cpp:168-177`；`PropId.cpp` 表 |
| `VT_UI1` | 少量字节型属性（CPropVariant(Byte)） | `CPP/Windows/PropVariant.h:119`、`PropVariant.cpp:212` |
| `VT_UI4` | kpidAttrib/CRC/kFlags/kVersion/接口类型等 32 位 | `PropVariant.cpp:215`；`CodecExports.cpp:228-233`；`ArchiveExports.cpp:118-120` |
| `VT_UI8` | kpidSize/PackSize/PhySize、方法 kID | `PropVariant.cpp:216`；`CodecExports.cpp:205-208` |
| `VT_I4` / `VT_I8` | 有符号场景：kpidOffset/kpidPosition 允许 VT_UI4/VT_UI8/VT_I8（负值允许）；写入用 `Set_Int32/Set_Int64` | `CPP/7zip/Archive/IArchive.h:290-294`；`PropVariant.h:156-157`、`PropVariant.cpp:198-206` |
| `VT_BSTR` | 字符串（kpidPath/Name/Method/Comment…）和**二进制 blob**（kClassID GUID、kSignature、kpidNtSecure、kpidSha1/Sha256） | `PropVariant.cpp:96-166`；`ArchiveExports.cpp:38-48,123-130`；`PropId.cpp:10-117` |
| `VT_FILETIME` | kpidCTime/ATime/MTime/ChangeTime；**1601-01-01 纪元 100ns 计数（即使在 mac 上）**；扩展精度协议：`wReserved1`=精度（0 基准/1 Unix 秒/2 DOS 2秒/3 1ns/16+n 小数位数），`wReserved2`=ns%100（8、9 位精度时），`wReserved3=0` | `CPP/7zip/PropID.h:136-170`；`CPP/Windows/PropVariant.h:32-40,71-111`；Unix 互转 `CPP/Windows/TimeUtils.h:94-105`；比较含 ns100 `PropVariant.cpp:362-391` |
| `VT_ERROR` | BSTR 分配失败时 `vt=VT_ERROR; scode=E_OUTOFMEMORY` | `CPP/Windows/PropVariant.cpp:26-50` |

`kpid → VARTYPE` 的官方完整映射表是 `k7z_PROPID_To_VARTYPE`（`CPP/7zip/Common/PropId.cpp:10-117`，仅含 EMPTY/BSTR/BOOL/UI4/UI8/FILETIME 六种）；kpid 全集（~110 个 + `kpidUserDefined=0x10000`）见 `CPP/7zip/PropID.h:8-119`。`ISetProperties::SetProperties` 只接受 VT_EMPTY/VT_BOOL/VT_UI4/VT_UI8/VT_BSTR（`CPP/7zip/Archive/IArchive.h:537-550`）。

**出参所有权协议**（必须写进桥接层规范，`CPP/7zip/Archive/IArchive.h:20-41`）：
1) 调用前：PROPVARIANT 置 `vt=VT_EMPTY`、BSTR 出参置 NULL、接口出参置 NULL；
2) 被调方可对传入的 PROPVARIANT 调 VariantClear；
3) 调用后：调用方负责 `VariantClear(&pv)` / `SysFreeString(bstr)` / `ptr->Release()`。

---

## 3. Format7zF → macOS dylib：构建事实与改造点

### 3.1 现状（已实测可用）

- 构建入口：`CPP/7zip/cmpl_mac_arm64.mak:1-3` = `include ../../var_mac_arm64.mak` + `warn_clang_mac.mak` + `makefile.gcc`（在 bundle 目录内执行）。`var_mac_arm64.mak`：`O=b/m_arm64, IS_ARM64=1, MY_ARCH=-arch arm64, USE_ASM=1, CC=clang, CXX=clang++`（`CPP/7zip/var_mac_arm64.mak:1-13`）；x64 对应 `var_mac_x64.mak`。
- `Format7zF/makefile.gcc:1-2`：`PROG=7z`、`DEF_FILE=../../Archive/Archive2.def`。`DEF_FILE` 非空触发共享库分支：非 MinGW 时 `SHARED_EXT=.so; LDFLAGS=-shared -fPIC; CC_SHARED=-fPIC`（`CPP/7zip/7zip_gcc.mak:99-110`），.def 文件本身在非 Windows **不参与链接**。
- 链接最终命令（实测日志）：`clang++ -o b/m_arm64/7z.so -arch arm64 -shared -fPIC -DNDEBUG <全部 .o> -lpthread -ldl`；mac 的 clang 把 `-shared` 视为 `-dynamiclib` → 直接产出 `MH_DYLIB`。
- 对象清单：`Format7zF/Arc_gcc.mak:1-395`（全格式 handler + 全编解码 + 加密 + MT 基建）+ `makefile.gcc:42-54` 追加 `CodecExports.o/ArchiveExports.o/DllExports2.o/MyWindows.o`。`LzmaDec_gcc.mak:1-14` 在 `USE_ASM&&IS_ARM64` 时启用 `LzmaDecOpt.o`（arm64 汇编 `Asm/arm64/LzmaDecOpt.S`，由 clang 直接汇编，`CPP/7zip/7zip_gcc.mak:1331-1334`）；arm64 的 SHA/AES 走 C 源 HW intrinsics（`7zip_gcc.mak:1293-1315` 非 x86 分支）。
- 可选开关：`ST_MODE=1` 单线程裁剪（`Arc_gcc.mak:15-25`）；`DISABLE_RAR=1` 去 Rar（`Arc_gcc.mak:200-205,283-296,311-317`）。默认多线程对象（LzFindMt/MtCoder/MtDec/VirtThread/StreamBinder/Synchronization 等，`Arc_gcc.mak:27-38`）全部包含。
- 编译期警告：mac 用 `-Weverything -Wfatal-errors -Wno-poison-system-directories`（`warn_clang_mac.mak`，实测日志），26.01 代码零警告通过。

### 3.2 推荐 make 命令（已验证 / 推荐变体）

```sh
# 已验证（产出 b/m_arm64/7z.so，MH_DYLIB）
cd CPP/7zip/Bundles/Format7zF
make -f ../../cmpl_mac_arm64.mak -j8

# x64 切片 + lipo 合 universal（建议）
make -f ../../cmpl_mac_x64.mak -j8
lipo -create b/m_arm64/7z.so b/m_x64/7z.so -output lib7z.dylib
```

### 3.3 命名决策：`7z.so` vs `lib7z.dylib`

- dlopen 不关心扩展名（实测改名 `lib7z.dylib` 后加载成功）。
- 但 `UI/Common/LoadCodecs.cpp:72-77` 把主模块名硬编码为 `kMainDll = "7z.so"`（非 Windows 分支）。**若复用 LoadCodecs（移植 7zFM/7zG 必然复用），最低成本是维持文件名 `7z.so`**；若坚持 `lib7z.dylib`，需同步改 `kMainDll`（一行）。
- LoadCodecs 的搜索根目录 = `NDLL::GetModuleDirPrefix()`；其 POSIX 实现返回全局 `g_ModuleDirPrefix`（`CPP/7zip/UI/Common/ArchiveCommandLine.cpp:1888-1909`），由 `Set_ModuleDirPrefix_From_ProgArg0(argv[0])` 填充（`ArchiveCommandLine.cpp:1880-1886`；console 在 `CPP/7zip/UI/Console/Main.cpp:877` 调用）。**AppKit 应用启动时必须用可执行文件路径（或改为 NSBundle 的 Frameworks 路径）调用它**，否则回落 `./`。
- 参考客户端形态：`UI/Console/makefile.gcc:1,67` 表明 POSIX 的 7z（瘦客户端）+ 7z.so 组合是上游官方支持的形态（`-DZ7_EXTERNAL_CODECS`）。

### 3.4 dylib 化需要补的链接细节（新增 mak 片段要点）

实测默认产物的问题与对应处置：

| 问题（实测） | 处置 |
|---|---|
| `LC_ID_DYLIB`（install_name）= `b/m_arm64/7z.so`（构建相对路径） | 链接时加 `-Wl,-install_name,@rpath/7z.so`（或构建后 `install_name_tool -id`）。若只用 `dlopen(绝对路径)` 则无关紧要，但放进 .app `Contents/Frameworks/` 并被链接器引用时必须是 `@rpath` |
| 导出 4041 个符号（含全部 C++ 内部符号） | 加 `-Wl,-exported_symbols_list,exports7z.txt`，内容为 §1 列表加下划线前缀（`_CreateObject` 等 19 个）；可叠加 `-Wl,-dead_strip` 减体积 |
| 无版本号（compatibility/current 0.0.0） | `-Wl,-compatibility_version,1 -Wl,-current_version,26.01` |
| 未签名 | 分发前 `codesign --force --sign <id> --options runtime 7z.so`；公证（hardened runtime 下 dlopen 同签名 dylib 无障碍） |

建议落地方式：新增 `CPP/7zip/var_mac_arm64_dylib.mak`（或在 bundle makefile.gcc 里 `LDFLAGS_STATIC_3 += ...`，该变量已被 `7zip_gcc.mak:88` 纳入链接参数，**零侵入挂接点**）。

### 3.5 客户端（桥接层）需要自带编译的引擎源码

dylib 只提供 handler/codec；流对象、PropVariant 工具、路径/文件 API 客户端自备。最小集合即 Client7z 的对象表（`CPP/7zip/UI/Client7z/makefile.gcc:20-69`）：`MyWindows.o`（COM 模拟）、`FileStreams.o`（CInFileStream/COutFileStream）、`PropVariant.o/PropVariantConv.o`、`FileDir/FileFind/FileIO/FileName.o`、`MyString/StringConvert/UTFConvert/IntToString/Wildcard.o`、`DLL.o`、`Alloc.o`、`NewHandler.o`、`TimeUtils.o`。FM/GUI 移植则直接整包复用 UI/Common（已知大部分随 7zz 在 mac 编过）。

---

## 4. 客户端正确调用时序（dlopen → 解压 / 压缩）

### 4.1 加载与发现（LoadCodecs 全量路径）

```
dlopen("…/7z.so", RTLD_NOW|RTLD_LOCAL)            // DLL.cpp:141-164（CLibrary::Load）
└─ GetModuleProp(kInterfaceType/kVersion)          // ABI 闸门 IsSupportedDll：LoadCodecs.cpp:521-562
   ├─ 期望值 == k_IUnknown_VirtDestructor_ThisModule（双方编译设置一致）
   └─ 注意：若 dll 缺少 GetModuleProp，非 Windows 默认假定"有虚析构"(=1) → 会被判不兼容拒载（LoadCodecs.cpp:527-534）
└─ dlsym: CreateObject / CreateDecoder / CreateEncoder / GetMethodProperty   // LoadCodecs.cpp:279-281,682
└─ 枚举编解码器: GetNumberOfMethods + GetMethodProperty(kEncoder/kDecoder/kIsFilter)  // LoadCodecs.cpp:283-301
└─ 枚举哈希: GetHashers → IHashers                  // LoadCodecs.cpp:303-318
└─ 枚举格式: GetHandlerProperty2 × {kName,kClassID,kExtension,kAddExtension,kUpdate,kFlags,kTimeFlags,kSignature,kMultiSignature,kSignatureOffset} + GetIsArc  // LoadCodecs.cpp:407-500
└─ （多库时）SetCodecs(this) 注入外部编解码器表      // LoadCodecs.cpp:860-887
└─ 可选全局配置: SetCaseSensitive / SetLargePageMode2 // LoadCodecs.cpp:638-668
卸载: 释放所有 archive/coder 对象 → 对每个库 SetCodecs(NULL)（打破 dylib→CCodecs 循环引用）→ dlclose   // LoadCodecs.cpp:764-785 + CReleaser LoadCodecs.h:320-335
```

极简路径（Client7z 风格）：`dlopen → dlsym("CreateObject") → 直接用已知 CLSID`（`CPP/7zip/UI/Client7z/Client7z.cpp:850-873`）。

### 4.2 打开归档 + 枚举 + 解压（读路径）

```
CreateObject(&CLSID_Format, &IID_IInArchive, (void**)&archive)        // Client7z.cpp:1043-1048
file = new CInFileStream(实现 IInStream)                              // Client7z.cpp:1050-1057
archive->Open(file, &maxCheckStartPosition, openCallback)             // Client7z.cpp:1059-1071
   // maxCheckStartPosition：NULL=允许全文件搜索归档头；*p==0=只认流当前位置（IArchive.h:277-284）
   // openCallback 实现：IArchiveOpenCallback(SetTotal/SetCompleted, IArchive.h:177-181)
   //   + ICryptoGetTextPassword（加密头，Client7z.cpp:186-224）
   //   + IArchiveOpenVolumeCallback（多卷 GetProperty/GetStream(name,&IInStream)，IArchive.h:262-265）
   // 返回 S_FALSE = 不是该格式归档
GetNumberOfItems(&n)                                                  // Client7z.cpp:1076-1077
for i in 0..n-1: GetProperty(i, kpidPath/kpidIsDir/kpidSize/kpidMTime/kpidAttrib…, &pv)  // Client7z.cpp:1078-1099
   // 列名/类型自省：GetNumberOfProperties/GetPropertyInfo（IArchive.h:316-327）
   // 归档级属性：GetArchiveProperty(kpidPhySize/kpidOffset/kpidErrorFlags…)（IArchive.h:285-303）
archive->Extract(indices, numItems, testMode, extractCallback)        // Client7z.cpp:1134
   // indices 必须升序；numItems=0xFFFFFFFF 表示全部；testMode!=0 只测试不写盘（IArchive.h:285-288）
   // 每项回调序列（extractCallback 实现 IArchiveExtractCallback + ICryptoGetTextPassword）：
   //   GetStream(index, &outStream, askMode) → PrepareOperation(askMode) → [引擎写 outStream]
   //   → SetOperationResult(opRes∈NExtract::NOperationResult, IArchive.h:132-148)
   //   GetStream 出 *outStream==NULL && askMode==kExtract → 跳过该文件（IArchive.h:194-209）
   //   进度：SetTotal(total) / SetCompleted(&done)（继承 IProgress）
archive->Close()   // 之后可对同一对象再次 Open；释放：archive->Release()（或 CMyComPtr 析构）
```

随机读单项的替代：`QueryInterface(IID_IInArchiveGetStream)→GetStream(index,&ISequentialInStream)`（`IArchive.h:268-270`，FM 预览用）。

### 4.3 压缩 / 更新（写路径）

```
CreateObject(&CLSID_Format, &IID_IOutArchive, (void**)&outArchive)    // Client7z.cpp:961-966
outArchive->QueryInterface(IID_ISetProperties, &sp)
sp->SetProperties(names[], values[], n)   // 如 {"m","s","x","mt"}；值限 VT_EMPTY/BOOL/UI4/UI8/BSTR（IArchive.h:537-550；示例 Client7z.cpp:974-1002）
outArchive->GetFileTimeType(&t)           // 时间精度协商（IArchive.h:530-534, NFileTimeType IArchive.h:44-54）
outArchive->UpdateItems(outStream, numItems, updateCallback)          // Client7z.cpp:1004
   // updateCallback 实现 IArchiveUpdateCallback(2) + ICryptoGetTextPassword2：
   //   GetUpdateItemInfo(i,&newData,&newProps,&indexInArchive)   // 新增=1/1/-1；语义矩阵 IArchive.h:416-424
   //   GetProperty(i, kpidPath/kpidIsDir/kpidSize/kpidCTime/kpidATime/kpidMTime/kpidAttrib/kpidPosixAttrib/kpidIsAnti…)  // Client7z.cpp:680-707
   //   GetStream(i, &inStream)   // 返回 S_FALSE=跳过该文件；目录可出 NULL（IArchive.h:427-441; Client7z.cpp:727-758）
   //   SetOperationResult(opRes) // 每项收尾（Client7z.cpp:760-764）
   //   多卷：IArchiveUpdateCallback2::GetVolumeSize/GetVolumeStream（IArchive.h:454-458; Client7z.cpp:766-793）
   //   密码：CryptoGetTextPassword2(&defined,&bstr)（IPassword.h:31-51；BSTR 客户端 SysAllocString 分配、引擎 SysFreeString 释放）
   //   进度：SetTotal/SetCompleted（可能来自 worker 线程，见 §5）
// 更新已有归档：先 IInArchive::Open 原文件 → 同一 handler QI 出 IOutArchive → UpdateItems 写新流
// （GetUpdateItemInfo 返回 0/0 表示从原归档拷贝数据，indexInArchive 指向原条目）
```

错误上报增强：回调对象可实现 `IArchiveExtractCallbackMessage2::ReportExtractResult`（`IArchive.h:243-260`）、`IArchiveUpdateCallbackFile::GetStream2/ReportOperation`（`IArchive.h:479-490`）、内存限额协商 `IArchiveRequestMemoryUseCallback`（`IArchive.h:568-616`）。

---

## 5. 线程与重入约定（源码证据）

| 约定 | 内容 | 证据 |
|---|---|---|
| **同一 IInArchive 禁止并发** | 官方注释："Don't call IInArchive functions for same IInArchive object from different threads simultaneously. Some IInArchive handlers will work incorrectly in that case." → 同一实例上并发 Extract / GetProperty / Open 都不允许；并行任务用多个实例（每实例独立 IInStream）或串行队列 | `CPP/7zip/Archive/IArchive.h:305-308` |
| **解压回调串行性** | `GetStream/PrepareOperation/SetOperationResult` 不会被并发调用；**但 `IProgress`/`ICompressProgressInfo` 可与上述回调并发、且来自其它线程** | `CPP/7zip/Archive/IArchive.h:183-191` |
| **进度回调发生线程（实证）** | ZIP 多线程压缩：worker 线程函数 `CoderThread→WaitAndCode` 内直接调 `Progress->SetRatioInfo`（`ZipUpdate.cpp:289-315`）；经 `CMtCompressProgressMixer::SetRatioInfo`（临界区，`CPP/7zip/Common/ProgressMt.cpp:29-47`）→ `CMtProgressMixer2::SetRatioInfo` 在持锁状态下调用**客户端** `IProgress::SetCompleted`（`CPP/7zip/Archive/Zip/ZipUpdate.cpp:393-408`，updateCallback 即 Progress，`ZipUpdate.cpp:1236-1238`）。结论：**进度回调可发生在引擎 worker 线程上（互斥串行但非主线程）**；ObjC 桥接必须 dispatch 到 main queue，且回调内不得再调用同一 archive 对象（持锁重入=死锁/未定义） |
| **引擎内部自起线程** | mac 默认构建含 MT 对象（LzFindMt/MtCoder/MtDec/VirtThread/StreamBinder/Synchronization…，`Format7zF/Arc_gcc.mak:27-38`），bzip2/zip/xz/zstd 压缩与 lzma2/xz 解压会按 `mt` 参数自建 pthread；`ST_MODE=1` 可编全单线程版（`Arc_gcc.mak:15-25`）。链接 `-lpthread`（`7zip_gcc.mak:164-165`） |
| **引用计数非线程安全（默认）** | `AddRef/Release` 为裸 `++/--`；`Z7_COM_USE_ATOMIC` 全仓未定义（grep 实证，仅 `MyCom.h:358-392` 提供可选 MT 宏，非 Windows 还需自配 Interlocked 实现 `MyCom.h:362-373`）→ 跨线程并发 AddRef/Release 同一对象有竞态；对象生命周期收敛到单一线程，或构建时启用该宏并补实现 | `CPP/Common/MyCom.h:345-392` |
| **阻塞式回调** | 密码（`CryptoGetTextPassword(2)`）、卷请求、内存限额回调都同步阻塞引擎调用线程 → GUI 中须在回调里同步等待用户输入完成（7-Zip Windows GUI 即如此），不能在回调线程做 UI，需 semaphore + 主线程对话框 | `CPP/7zip/IPassword.h:16-51` 协议本身同步 |
| **进程级全局态** | `g_CaseSensitive`（`CPP/Common/Wildcard.cpp:8-20`，mac 默认 false）、`g_ForceToUTF8`（`StringConvert.cpp:260`）、格式注册表 `g_Arcs`（静态构造注册，`ArchiveExports.cpp:13-28` + `RegisterArc.h:44-50`，dlopen 即就绪、无显式 init）、`g_ExternalCodecs`（`DllExports2.cpp:156-175`）→ 配置是每进程一份，不能按任务定制 |
| **CCodecs 容器非线程安全** | 普通向量成员，加载阶段单线程完成后只读使用 | `CPP/7zip/UI/Common/LoadCodecs.h:294-366` |
| **dlclose 顺序** | 先 Release 全部来自 dylib 的对象 → `SetCodecs(NULL)` → dlclose；否则虚表悬空。常驻 GUI 进程建议不卸载 | `CPP/7zip/UI/Common/LoadCodecs.cpp:764-785`、`LoadCodecs.h:320-335` |

---

## 6. 桥接层设计输入（从以上事实导出的硬约束）

1. ObjC++ 包装类持有 `CMyComPtr<IInArchive>` + 一个串行 dispatch queue，**所有**引擎调用排队执行；进度回调跨线程投递 main queue（弱引用防环）。
2. 回调对象（OpenCallback/ExtractCallback/UpdateCallback）按 Client7z 模式用 `Z7_IFACES_IMP_UNK_2(...)` 实现（`Client7z.cpp:186-198,328-360,614-656` 是最权威模板）。
3. 回调内 catch-all（C++ 与 ObjC 异常）并转换为 HRESULT 返回；`E_ABORT` 即用户取消（引擎语义，`MyWindows.h:98`）。
4. NSString↔UString 经 UTF-8；NSDate↔FILETIME 经 `TimeUtils`（1601 纪元），保留 `wReserved1/2` 精度字段（否则 tar/zip 回写时间戳精度退化）。
5. dylib 内存所有权按 §2.4 协议；密码用 `StringToBstr`（`CPP/Common/MyCom.h:184-188`）。

---

## 7. 移植风险清单

| 风险 | 说明 | 缓解 |
|---|---|---|
| 进度回调线程性 | 实证可发生在 worker 线程（§5），直接刷 UI 会崩 | 桥接层统一 hop 主线程；回调里禁止重入引擎 |
| 非原子引用计数 | 默认 `++/--`，跨线程 Release → UAF | 生命周期单线程化；或定义 `Z7_COM_USE_ATOMIC` 并提供 Interlocked 实现（需双侧一致重编） |
| ABI 闸门 | IUnknown 虚析构设置必须双侧一致；缺 `GetModuleProp` 的库在 POSIX 会被 LoadCodecs 拒载（`LoadCodecs.cpp:527-560`） | 双侧同仓同设置编译；保留 GetModuleProp 导出 |
| 全量符号导出（4041） | 与宿主 App / 第三方库潜在符号歧义、增大攻击面与体积（两级命名空间已缓解大半） | `-exported_symbols_list` 收敛到 19 个 C 入口 |
| install_name 默认指向构建路径 | 嵌入 .app 后加载失败或签名校验问题 | `-install_name @rpath/7z.so` + rpath `@loader_path/../Frameworks` |
| LoadCodecs 模块目录发现依赖 argv[0] | .app 启动不调用 `Set_ModuleDirPrefix_From_ProgArg0` 则在 `./` 找 7z.so | 启动时显式设置（指向 Frameworks 目录）或小补丁 |
| `kMainDll="7z.so"` 硬编码 | 改名 lib7z.dylib 需同步改 `LoadCodecs.cpp:72-77` | 决策：保持 7z.so 文件名最省 |
| C++ 异常穿越回调边界 | 引擎→客户端方向有 COM_TRY 保护；客户端回调抛异常进引擎 = UB | 桥接回调全部 catch-all |
| BSTR 二进制语义 | kClassID/kSignature 等是 byte-blob，按宽字符串处理会越界（byteLen 非 4 倍数） | 读取一律 `SysStringByteLen` |
| VT_FILETIME 精度协议 | `wReserved1/2` 扩展字段易被"干净的"重新构造 PROPVARIANT 抹掉 | 桥接保留原样拷贝 |
| 同一 IInArchive 并发使用 | FM 的列表/预览/解压并行场景天然冲突 | 实例池或串行队列；预览走 IInArchiveGetStream 单独实例 |
| 大小写敏感默认差异 | mac 默认 `g_CaseSensitive=false`，区分大小写 APFS 卷上行为偏差 | 暴露设置项，必要时按卷探测后调 SetCaseSensitive |
| 阻塞式密码/卷回调 | 回调同步等待 UI 输入会卡引擎线程（设计如此） | 信号量桥接主线程对话框；给队列加忙碌标记 |
| dlclose 悬空虚表 | 未 Release 完即卸载 → 崩溃 | 常驻进程不 dlclose；退出前按 §5 顺序 |
| Rar/unRAR 许可 | Format7zF 默认含 Rar 解码（unRAR 许可限制） | 商店分发评估；`DISABLE_RAR=1` 开关现成（`Arc_gcc.mak:200-205`） |
| 签名/公证 | hardened runtime 要求 dylib 签名 | 构建管线纳入 codesign |

---

## 8. 附：本次实测记录（可复现实验）

```sh
# 1) 构建 dylib（零改动）
cd CPP/7zip/Bundles/Format7zF && make -f ../../cmpl_mac_arm64.mak -j8
file b/m_arm64/7z.so          # Mach-O 64-bit dynamically linked shared library arm64
otool -D b/m_arm64/7z.so      # install_name = b/m_arm64/7z.so（待修正）
otool -L b/m_arm64/7z.so      # 仅 libSystem + libc++
nm -gU b/m_arm64/7z.so | wc -l            # 4041
nm -gU b/m_arm64/7z.so | grep _CreateObject   # 19 个 API 全在

# 2) 构建参考客户端
cd ../../UI/Client7z && make -f ../../cmpl_mac_arm64.mak -j8   # 产出 b/m_arm64/7zcl

# 3) dlopen 端到端
cp 7zcl 7z.so 同一目录
./7zcl a test.7z f1.txt f2.bin   # 压缩 OK
./7zcl l test.7z                 # 列表 OK
./7zcl x test.7z && diff ...     # 解压一致，ROUNDTRIP OK

# 4) 运行时探测（自写 probe，dlopen+dlsym）
# formats=60 methods=25 ifaceType=0 version=0x1A0001(26.01)
# sizeof(wchar_t)=4, PROPVARIANT 模型=16 字节；改名 lib7z.dylib 后 dlopen OK
```
