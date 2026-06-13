// test_zipregistry.cpp —— M1-T1/T2 ZipRegistry_mac（CFPreferences 后端）往返单测。
// 只链接字符串工具 .o（不碰 COM/handlers），故无需 INITGUID。
#include "7zip/UI/Common/ZipRegistry.h"
#include "Common/StringConvert.h"
#include <cstdio>

static int gFails = 0;
#define EXPECT(c, m) do { if (!(c)) { printf("  ✗ FAIL: %s\n", m); gFails++; } else printf("  ✓ %s\n", m); } while (0)

int main() {
  printf("== M1-T1 ZipRegistry_mac 往返测试 ==\n\n[NWorkDir]\n");
  {
    NWorkDir::CInfo w; w.SetDefault();
    w.Mode = NWorkDir::NMode::kSpecified;
    w.Path = us2fs(UString(L"/tmp/szwork"));
    w.ForRemovableOnly = false;
    w.Save();
    NWorkDir::CInfo r; r.Load();
    EXPECT(r.Mode == NWorkDir::NMode::kSpecified, "Mode 持久化");
    EXPECT(r.Path == us2fs(UString(L"/tmp/szwork")), "Path 持久化");
    EXPECT(r.ForRemovableOnly == false, "ForRemovableOnly 持久化");
  }

  printf("\n[NExtract + CBoolPair 三态 + 中文路径]\n");
  {
    NExtract::CInfo e; e.Load();
    e.PathMode = (NExtract::NPathMode::EEnum)2; e.PathMode_Force = true;
    e.ShowPassword.Val = true; e.ShowPassword.Def = true;
    e.ElimDup.Def = false;   // 未定义 → 不写键
    e.Paths.Clear(); e.Paths.Add(UString(L"/tmp/a")); e.Paths.Add(UString(L"中文路径"));
    e.Save();
    NExtract::CInfo r; r.Load();
    EXPECT(r.PathMode_Force && r.PathMode == (NExtract::NPathMode::EEnum)2, "PathMode 持久化");
    EXPECT(r.ShowPassword.Def && r.ShowPassword.Val, "CBoolPair 已定义=true 往返");
    EXPECT(!r.ElimDup.Def, "CBoolPair 未定义（键不存在）保持 Def=false");
    EXPECT(r.Paths.Size() == 2 && r.Paths[0] == UString(L"/tmp/a"), "路径历史持久化");
    EXPECT(r.Paths[1] == UString(L"中文路径"), "中文路径 UTF-8 往返无损");
  }

  printf("\n[CMemUse::Parse]\n");
  {
    NCompression::CMemUse mu;
    mu.Parse(UString(L"50%"));  EXPECT(mu.IsDefined && mu.IsPercent && mu.Val == 50, "50%% → 百分比 50");
    mu.Parse(UString(L"2g"));   EXPECT(mu.IsDefined && !mu.IsPercent && mu.Val == (2ULL << 30), "2g → 2GiB");
    mu.Parse(UString(L"xyz"));  EXPECT(!mu.IsDefined, "非法串 IsDefined=false");
  }

  printf("\n[CContextMenuInfo]\n");
  {
    CContextMenuInfo c; c.Load();
    c.Cascaded.Val = false; c.Cascaded.Def = true;
    c.Flags = 0x1234; c.Flags_Def = true;
    c.Save();
    CContextMenuInfo r; r.Load();
    EXPECT(r.Cascaded.Def && !r.Cascaded.Val, "Cascaded 三态往返");
    EXPECT(r.Flags_Def && r.Flags == 0x1234, "Flags 持久化");
  }

  printf("\n%s（%d 失败）\n",
         gFails == 0 ? "===== M1-T1 ZipRegistry_mac 通过 =====" : "===== 有失败 =====", gFails);
  return gFails ? 1 : 0;
}
