// M1-T5 端到端：经 Agent 层 CArchiveFolderManager::OpenFolderFile 验证归档"文件夹化"导航。
//
// 这是 docs/02-core-bridge.md §4.6 SZFolderSession 的底层路径，把 docs/M1-T3-agent-gate-report.md
// 延后到 M1-T5 的端到端验收（"OpenFolderFile 返回 IFolderFolder + 绑定子目录枚举属性"）落地：
//   CInFileStream(磁盘.7z) → CArchiveFolderManager::OpenFolderFile → CAgent::Open → CProxyArc::Load
//     → BindToRootFolder(CAgentFolder/IFolderFolder)
//   → LoadItems / GetNumberOfItems / GetProperty(kpidPath/Size/MTime/IsDir/Attrib)
//   → BindToFolder(子目录) / BindToParentFolder
//   → IGetFolderArcProps::GetFolderArcProps → GetArcProp(kpidPhySize/kpidErrorFlags) 归档级属性
//
// codecs 模式：internal（静态复用 7zz/Alone2 全格式对象集，CCodecs::Load 走 g_Arcs 静态注册表）。
// external + dlopen lib7z.dylib 的 codec 加载链由 M0 段B(poc_bridge) 独立验证；二者 Agent 导航代码一致、
// codec 来源正交（详见 docs/M1-T5-agent-browse-report.md 取舍说明）。
//
// 本编译单元是唯一 INITGUID 单元（Alone2 的 IID 实体在被排除的 Main.o 内）。

#include "Common/MyInitGuid.h"               // 实体化所有被 include 接口头的 IID（含 Folder 族）

#include <stdio.h>
#include <locale.h>

#include "Common/MyCom.h"
#include "Common/StringConvert.h"
#include "Windows/PropVariant.h"
#include "Windows/PropVariantConv.h"
#include "7zip/Common/FileStreams.h"          // CInFileStream
#include "7zip/UI/FileManager/IFolder.h"      // IFolderFolder / IFolderManager / IFolderArcProps
#include "7zip/UI/Agent/Agent.h"              // CArchiveFolderManager / CAgent

using namespace NWindows;

#define CHECK(cond, msg) do { if (!(cond)) { printf("FAIL: %s\n", msg); return 1; } } while (0)

static unsigned long long PropToU64(const PROPVARIANT &p)
{
  switch (p.vt) {
    case VT_UI8: return (unsigned long long)p.uhVal.QuadPart;
    case VT_UI4: return p.ulVal;
    case VT_UI2: return p.uiVal;
    default:     return 0;
  }
}

// 枚举一个 IFolderFolder 当前层的条目（不下钻），打印一对一映射 FM 面板会用的列。
static HRESULT DumpFolder(IFolderFolder *folder, int indent)
{
  RINOK(folder->LoadItems())
  UInt32 n = 0;
  RINOK(folder->GetNumberOfItems(&n))
  char pad[64]; int k = 0; while (k < indent * 2 && k < 62) pad[k++] = ' '; pad[k] = 0;
  printf("%s(%u 项)\n", pad, n);
  for (UInt32 i = 0; i < n; i++) {
    NCOM::CPropVariant path, size, mtime, isDir, attrib;
    folder->GetProperty(i, kpidPath,   &path);
    folder->GetProperty(i, kpidSize,   &size);
    folder->GetProperty(i, kpidMTime,  &mtime);
    folder->GetProperty(i, kpidIsDir,  &isDir);
    folder->GetProperty(i, kpidAttrib, &attrib);
    const bool dir = (isDir.vt == VT_BOOL && isDir.boolVal != VARIANT_FALSE);
    char ftime[32] = "-";
    if (mtime.vt == VT_FILETIME) {
      // 仅证明 FILETIME 字段可读取/非零（NSDate 换算在桥接层 §5）；此处打印原始 64 位
      unsigned long long ft = ((unsigned long long)mtime.filetime.dwHighDateTime << 32)
                            | mtime.filetime.dwLowDateTime;
      snprintf(ftime, sizeof ftime, "ft=%llu", ft);
    }
    printf("%s  [%u] %-22ls %s size=%-8llu attrib=0x%llx %s\n",
           pad, i,
           path.vt == VT_BSTR ? path.bstrVal : L"(?)",
           dir ? "<DIR>" : "     ",
           PropToU64(size),
           PropToU64(attrib),
           ftime);
  }
  return S_OK;
}

int main(int argc, char **argv)
{
  setlocale(LC_ALL, "");
  const char *arcPath = (argc > 1) ? argv[1] : "/tmp/agent_t5/test.7z";
  printf("== M1-T5 Agent 导航端到端：%s ==\n\n", arcPath);

  // 1) 磁盘归档 → IInStream
  CInFileStream *fileSpec = new CInFileStream;
  CMyComPtr<IInStream> file = fileSpec;
  CHECK(fileSpec->Open(arcPath), "打开磁盘 .7z 失败");

  // 2) CArchiveFolderManager（Agent 层"归档→文件夹"工厂）→ IFolderManager
  CMyComPtr<IFolderManager> mgr = new CArchiveFolderManager;
  const UString arcPathW = GetUnicodeString(AString(arcPath));   // 仅供按扩展名嗅探格式

  // 3) OpenFolderFile → 根 IFolderFolder（内部完成 CAgent::Open + proxy 树构建 + BindToRootFolder）
  //    arcFormat 传空串 L""（=自动嗅探所有格式），不可传 NULL：CAgent::Open→ParseOpenTypes 会
  //    隐式 UString(arcFormat)，NULL 触发 UString(NULL) 崩溃（Windows FM 同样传空串而非 NULL）。
  CMyComPtr<IFolderFolder> root;
  HRESULT hr = mgr->OpenFolderFile(file, arcPathW.Ptr(), L"", &root, NULL);
  printf("[1] OpenFolderFile hr=0x%08X  root=%p\n", (unsigned)hr, (void *)root.Interface());
  CHECK(hr == S_OK && root, "OpenFolderFile 未返回 IFolderFolder");

  // 4) 枚举根层
  printf("\n[2] 根目录枚举：\n");
  CHECK(DumpFolder(root, 0) == S_OK, "枚举根目录失败");

  // 5) 找首个目录项，BindToFolder 下钻，再 BindToParentFolder 回到上级
  UInt32 n = 0; root->GetNumberOfItems(&n);
  bool descended = false;
  for (UInt32 i = 0; i < n; i++) {
    NCOM::CPropVariant isDir;
    root->GetProperty(i, kpidIsDir, &isDir);
    if (isDir.vt == VT_BOOL && isDir.boolVal != VARIANT_FALSE) {
      NCOM::CPropVariant nm;
      root->GetProperty(i, kpidPath, &nm);
      printf("\n[3] BindToFolder([%u] %ls) 下钻：\n", i, nm.vt == VT_BSTR ? nm.bstrVal : L"?");
      CMyComPtr<IFolderFolder> sub;
      CHECK(root->BindToFolder(i, &sub) == S_OK && sub, "BindToFolder 失败");
      CHECK(DumpFolder(sub, 1) == S_OK, "枚举子目录失败");

      // 再下钻一层（sub/deep），证明多层导航
      UInt32 sn = 0; sub->GetNumberOfItems(&sn);
      for (UInt32 j = 0; j < sn; j++) {
        NCOM::CPropVariant sd;
        sub->GetProperty(j, kpidIsDir, &sd);
        if (sd.vt == VT_BOOL && sd.boolVal != VARIANT_FALSE) {
          CMyComPtr<IFolderFolder> deep;
          if (sub->BindToFolder(j, &deep) == S_OK && deep) {
            printf("\n[4] 二级下钻 BindToFolder([%u]) ：\n", j);
            DumpFolder(deep, 2);
          }
          break;
        }
      }

      // BindToParentFolder 回到根
      CMyComPtr<IFolderFolder> parent;
      CHECK(sub->BindToParentFolder(&parent) == S_OK && parent, "BindToParentFolder 失败");
      UInt32 pn = 0; parent->LoadItems(); parent->GetNumberOfItems(&pn);
      printf("\n[5] BindToParentFolder 回到上级：%u 项（应=根层 %u 项）\n", pn, n);
      CHECK(pn == n, "BindToParentFolder 返回层级不一致");
      descended = true;
      break;
    }
  }
  CHECK(descended, "归档内未找到可下钻目录（测试归档应含 sub/）");

  // 6) 归档级属性（含错误旗标）：root QI IGetFolderArcProps → GetArcProp
  printf("\n[6] 归档级属性（IFolderArcProps）：\n");
  CMyComPtr<IGetFolderArcProps> getArc;
  root.QueryInterface(IID_IGetFolderArcProps, &getArc);
  CHECK(getArc, "root 未实现 IGetFolderArcProps");
  CMyComPtr<IFolderArcProps> arcProps;
  CHECK(getArc->GetFolderArcProps(&arcProps) == S_OK && arcProps, "GetFolderArcProps 失败");
  UInt32 levels = 0; arcProps->GetArcNumLevels(&levels);
  printf("    归档层数 levels=%u\n", levels);
  for (UInt32 lv = 0; lv < levels; lv++) {
    NCOM::CPropVariant phySize, errFlags, warnFlags;
    arcProps->GetArcProp(lv, kpidPhySize,    &phySize);
    arcProps->GetArcProp(lv, kpidErrorFlags, &errFlags);
    arcProps->GetArcProp(lv, kpidWarningFlags, &warnFlags);
    printf("    level[%u] phySize=%llu errorFlags=0x%llx warningFlags=0x%llx\n",
           lv, PropToU64(phySize), PropToU64(errFlags), PropToU64(warnFlags));
  }

  printf("\n===== M1-T5 通过：Agent 导航(打开/枚举/下钻/上溯/归档属性) 端到端全绿 =====\n");
  return 0;
}
