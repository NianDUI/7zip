// test_normalize.cpp —— M1-T8 NFC/NFD 规范化专项用例（变音符/中文/韩文）。
#include "SZNormalize.h"
#include "Common/StringConvert.h"
#include <cstdio>
#include <initializer_list>

static int gFails = 0;
#define EXPECT(c, m) do { if (!(c)) { printf("  ✗ FAIL: %s\n", m); gFails++; } else printf("  ✓ %s\n", m); } while (0)

// 由码点构造 UString
static UString U(std::initializer_list<wchar_t> cps) {
  UString s; for (wchar_t c : cps) s += c; return s;
}

int main() {
  printf("== M1-T8 NFC/NFD 规范化 ==\n\n[变音符 café]\n");
  {
    const UString nfc = U({'c','a','f', (wchar_t)0x00E9});            // café：é = U+00E9
    const UString nfd = U({'c','a','f','e', (wchar_t)0x0301});        // café：e + 组合尖音 U+0301
    EXPECT(nfc != nfd, "NFC/NFD 原始字节不同（直接比较会失配）");
    EXPECT(SZNorm::NamesEqual(nfc, nfd), "NamesEqual 规范化后相等");
    EXPECT(SZNorm::ToNFC(nfd) == nfc, "ToNFC(NFD) == NFC");
    EXPECT(SZNorm::ToNFD(nfc) == nfd, "ToNFD(NFC) == NFD");
  }

  printf("\n[韩文 가 (U+AC00)]\n");
  {
    const UString nfc = U({(wchar_t)0xAC00});                         // 가 预组合
    const UString nfd = U({(wchar_t)0x1100, (wchar_t)0x1161});        // ᄀ + ᅡ 分解
    EXPECT(nfc != nfd, "韩文 NFC/NFD 字节不同");
    EXPECT(SZNorm::NamesEqual(nfc, nfd), "韩文 NamesEqual 规范化后相等");
    EXPECT(SZNorm::ToNFC(nfd) == nfc, "韩文 ToNFC(NFD) == NFC");
  }

  printf("\n[中文（无组合，NFC==NFD）]\n");
  {
    const UString zh = U({(wchar_t)0x4E2D, (wchar_t)0x6587});         // 中文
    EXPECT(SZNorm::ToNFC(zh) == zh && SZNorm::ToNFD(zh) == zh, "中文规范化不变");
    EXPECT(SZNorm::NamesEqual(zh, zh), "中文自比相等");
  }

  printf("\n[模拟：NFD 磁盘名 vs NFC 档内名（更新/覆盖检测场景）]\n");
  {
    const UString diskNFD = U({'u', (wchar_t)0x0308});               // ü 分解：u + 组合分音符 U+0308
    const UString arcNFC  = U({(wchar_t)0x00FC});                     // ü 预组合 U+00FC
    EXPECT(SZNorm::NamesEqual(diskNFD, arcNFC), "NFD 磁盘名与 NFC 档内名比较不失配");
  }

  printf("\n%s（%d 失败）\n",
         gFails == 0 ? "===== M1-T8 NFC/NFD 通过 =====" : "===== 有失败 =====", gFails);
  return gFails ? 1 : 0;
}
