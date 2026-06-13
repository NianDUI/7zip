// M0 段 B：裸 dlopen 桥接 PoC —— 不经 LoadCodecs，直接 dlopen 改名后的 lib7z.dylib，
// 验证 ABI 闸门 + CreateObject 工厂 + 真实 Open + 列表（含中文 UTF-8）。
// 这正是 SevenZipKit(SZLibrary) 将走的路径（02-core-bridge.md §4.1/§8.2）。
#include <dlfcn.h>
#include <stdio.h>
#include <locale.h>

#include "Common/MyInitGuid.h"          // 唯一 INITGUID 编译单元 -> 实体化所有 7-zip IID
#include "7zip/Archive/IArchive.h"
#include "7zip/IStream.h"
#include "7zip/PropID.h"
#include "7zip/ICoder.h"                 // NModulePropID
#include "7zip/Common/FileStreams.h"    // CInFileStream
#include "Windows/PropVariant.h"        // NWindows::NCOM::CPropVariant
#include "Common/MyCom.h"

// Func_CreateObject / Func_GetNumberOfFormats 已在 IArchive.h 定义，直接复用。
typedef HRESULT (WINAPI *PFn_GetModuleProp)(PROPID, PROPVARIANT *);

// 7z 格式 CLSID：{23170F69-40C1-278A-1000-000110070000}（§2.3，格式 Id=7）
static const GUID CLSID_7z =
  { 0x23170F69, 0x40C1, 0x278A, { 0x10,0x00,0x00,0x01,0x10,0x07,0x00,0x00 } };

#define CHECK(cond, msg) do { if (!(cond)) { printf("FAIL: %s\n", msg); return 1; } } while(0)

int main(int argc, char **argv) {
  setlocale(LC_ALL, "");
  const char *dylib = "/tmp/poc7z/lib7z.dylib";       // 改名后的文件（非 7z.so）
  const char *arc   = (argc > 1) ? argv[1] : "/tmp/poc7z/test.7z";

  // B1) dlopen 绝对路径，RTLD_LOCAL（桥接层约定，D2）
  void *h = dlopen(dylib, RTLD_NOW | RTLD_LOCAL);
  CHECK(h, dlerror());
  printf("B1 dlopen OK         : %s\n", dylib);

  auto getProp   = (PFn_GetModuleProp)dlsym(h, "GetModuleProp");
  auto getNFmt   = (Func_GetNumberOfFormats)dlsym(h, "GetNumberOfFormats");
  auto createObj = (Func_CreateObject)dlsym(h, "CreateObject");
  CHECK(getProp && getNFmt && createObj, "dlsym one of GetModuleProp/GetNumberOfFormats/CreateObject");
  printf("B1 dlsym OK          : GetModuleProp / GetNumberOfFormats / CreateObject\n");

  // B2) ABI 闸门（§6.1）：interfaceType 应 == 0；version 应 == 0x1A0001(26.01)
  PROPVARIANT it; it.vt = VT_EMPTY; getProp(NModulePropID::kInterfaceType, &it);
  PROPVARIANT ver; ver.vt = VT_EMPTY; getProp(NModulePropID::kVersion, &ver);
  printf("B2 ABI gate          : interfaceType=%u (期望0)  version=0x%X (期望0x1A0001)\n",
         it.ulVal, ver.ulVal);
  CHECK(it.vt == VT_UI4 && it.ulVal == 0, "ABI interfaceType != 0");

  // B3) 格式表活着
  UInt32 nFmt = 0; getNFmt(&nFmt);
  printf("B3 GetNumberOfFormats: %u 种格式 handler\n", nFmt);
  CHECK(nFmt > 50, "format count too low");

  // B4) CreateObject -> IInArchive（7z 工厂）
  CMyComPtr<IInArchive> archive;
  HRESULT hr = createObj(&CLSID_7z, &IID_IInArchive, (void **)&archive);
  CHECK(hr == S_OK && archive, "CreateObject(7z, IInArchive)");
  printf("B4 CreateObject OK   : IInArchive non-null\n");

  // B5) 真实 Open + 列表（CInFileStream 打开磁盘 .7z）
  CInFileStream *fileSpec = new CInFileStream;
  CMyComPtr<IInStream> file = fileSpec;
  CHECK(fileSpec->Open(arc), "open .7z file on disk");
  CHECK(archive->Open(file, NULL, NULL) == S_OK, "IInArchive::Open");
  UInt32 n = 0; archive->GetNumberOfItems(&n);
  printf("B5 Open OK           : %u 个条目\n", n);
  for (UInt32 i = 0; i < n; i++) {
    NWindows::NCOM::CPropVariant path, size;
    archive->GetProperty(i, kpidPath, &path);
    archive->GetProperty(i, kpidSize, &size);
    unsigned long long sz = (size.vt == VT_UI8) ? size.uhVal.QuadPart
                          : (size.vt == VT_UI4) ? size.ulVal : 0;
    printf("   [%u] %-20ls %llu bytes\n", i,
           path.vt == VT_BSTR ? path.bstrVal : L"(?)", sz);
  }
  archive->Close();
  printf("M0 段B 全绿: dlopen+dlsym+ABI闸门+CreateObject+Open+列表(UTF-8) 全通过\n");
  return 0;
}
