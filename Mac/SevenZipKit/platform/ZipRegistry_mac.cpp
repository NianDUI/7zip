// ZipRegistry_mac.cpp —— UI/Common/ZipRegistry.cpp 的 macOS 替身（NRegistry::CKey → CFPreferences）。
//
// 替换上游 Windows 注册表后端，保留 ZipRegistry.h 全部结构与 Save/Load 接口（调用方零改动）。
// 用 CFPreferences（CoreFoundation 纯 C API，**非** NSUserDefaults）以避免 7-Zip `int BOOL` 撞 ObjC `bool BOOL`
// ——本文件可安全 include 7-Zip C++ 头。偏好域 = 自有 Bundle ID（com.niandui.SevenZipFM）。
//
// CBoolPair 三态：Def=键是否存在；Save 时 Def 才写 Val（NCompression 下 !Def 删键），Load 时键在则 Def=true。
// 对应 M1-T1/T2，替换 Mac/poc/m1t5_link_stubs.cpp 的 NWorkDir 桩。

#include "Common/MyWindows.h"
#include "Common/MyString.h"
#include "Common/StringConvert.h"
#include "Common/StringToInt.h"          // ConvertStringToUInt64
#include "7zip/UI/Common/ZipRegistry.h"

#include <CoreFoundation/CoreFoundation.h>

static CFStringRef kAppID = CFSTR("com.niandui.SevenZipFM");

namespace {

// ---- 基础读写（key 用 "Sub.Field" 命名，对应 Windows 子键+值名）----

CFStringRef MakeCF(const char *utf8) { return CFStringCreateWithCString(NULL, utf8, kCFStringEncodingUTF8); }

void SetU32(const char *key, UInt32 v) {
  CFStringRef k = MakeCF(key);
  int64_t v64 = v;
  CFNumberRef n = CFNumberCreate(NULL, kCFNumberSInt64Type, &v64);
  CFPreferencesSetAppValue(k, n, kAppID);
  CFRelease(n); CFRelease(k);
}

bool GetU32(const char *key, UInt32 &out) {
  CFStringRef k = MakeCF(key);
  CFPropertyListRef v = CFPreferencesCopyAppValue(k, kAppID);
  CFRelease(k);
  if (!v) return false;
  bool ok = false;
  if (CFGetTypeID(v) == CFNumberGetTypeID()) {
    int64_t n = 0; CFNumberGetValue((CFNumberRef)v, kCFNumberSInt64Type, &n);
    out = (UInt32)n; ok = true;
  }
  CFRelease(v); return ok;
}

void SetBool(const char *key, bool v) {
  CFStringRef k = MakeCF(key);
  CFPreferencesSetAppValue(k, v ? kCFBooleanTrue : kCFBooleanFalse, kAppID);
  CFRelease(k);
}

bool GetBool(const char *key, bool &out) {
  CFStringRef k = MakeCF(key);
  CFPropertyListRef v = CFPreferencesCopyAppValue(k, kAppID);
  CFRelease(k);
  if (!v) return false;
  bool ok = false;
  if (CFGetTypeID(v) == CFBooleanGetTypeID()) { out = CFBooleanGetValue((CFBooleanRef)v); ok = true; }
  else if (CFGetTypeID(v) == CFNumberGetTypeID()) { int n=0; CFNumberGetValue((CFNumberRef)v,kCFNumberIntType,&n); out=(n!=0); ok=true; }
  CFRelease(v); return ok;
}

void SetString(const char *key, const UString &s) {
  const AString a = UnicodeStringToMultiByte(s, CP_UTF8);
  CFStringRef k = MakeCF(key);
  CFStringRef val = CFStringCreateWithCString(NULL, a.Ptr(), kCFStringEncodingUTF8);
  CFPreferencesSetAppValue(k, val ? (CFPropertyListRef)val : (CFPropertyListRef)CFSTR(""), kAppID);
  if (val) CFRelease(val);
  CFRelease(k);
}

bool GetString(const char *key, UString &out) {
  CFStringRef k = MakeCF(key);
  CFPropertyListRef v = CFPreferencesCopyAppValue(k, kAppID);
  CFRelease(k);
  if (!v) return false;
  bool ok = false;
  if (CFGetTypeID(v) == CFStringGetTypeID()) {
    const CFIndex len = CFStringGetMaximumSizeForEncoding(CFStringGetLength((CFStringRef)v), kCFStringEncodingUTF8) + 1;
    char *buf = (char *)malloc((size_t)len);
    if (buf && CFStringGetCString((CFStringRef)v, buf, len, kCFStringEncodingUTF8)) {
      out = MultiByteToUnicodeString(AString(buf), CP_UTF8); ok = true;
    }
    free(buf);
  }
  CFRelease(v); return ok;
}

void DeleteKey(const char *key) {
  CFStringRef k = MakeCF(key);
  CFPreferencesSetAppValue(k, NULL, kAppID);
  CFRelease(k);
}

void Sync() { CFPreferencesAppSynchronize(kAppID); }

// 字符串列表（路径历史）：存为 CFArray of CFString
void SetStringList(const char *key, const UStringVector &list) {
  CFMutableArrayRef arr = CFArrayCreateMutable(NULL, (CFIndex)list.Size(), &kCFTypeArrayCallBacks);
  FOR_VECTOR (i, list) {
    const AString a = UnicodeStringToMultiByte(list[i], CP_UTF8);
    CFStringRef s = CFStringCreateWithCString(NULL, a.Ptr(), kCFStringEncodingUTF8);
    if (s) { CFArrayAppendValue(arr, s); CFRelease(s); }
  }
  CFStringRef k = MakeCF(key);
  CFPreferencesSetAppValue(k, arr, kAppID);
  CFRelease(k); CFRelease(arr);
}

void GetStringList(const char *key, UStringVector &out) {
  out.Clear();
  CFStringRef k = MakeCF(key);
  CFPropertyListRef v = CFPreferencesCopyAppValue(k, kAppID);
  CFRelease(k);
  if (!v) return;
  if (CFGetTypeID(v) == CFArrayGetTypeID()) {
    const CFIndex n = CFArrayGetCount((CFArrayRef)v);
    for (CFIndex i = 0; i < n; i++) {
      CFStringRef s = (CFStringRef)CFArrayGetValueAtIndex((CFArrayRef)v, i);
      if (s && CFGetTypeID(s) == CFStringGetTypeID()) {
        const CFIndex len = CFStringGetMaximumSizeForEncoding(CFStringGetLength(s), kCFStringEncodingUTF8) + 1;
        char *buf = (char *)malloc((size_t)len);
        if (buf && CFStringGetCString(s, buf, len, kCFStringEncodingUTF8))
          out.Add(MultiByteToUnicodeString(AString(buf), CP_UTF8));
        free(buf);
      }
    }
  }
  CFRelease(v);
}

// CBoolPair：Save 时 Def 才写、否则按 deleteIfUndef 删；Load 时键在则 Def=true
void SetBoolPair(const char *key, const CBoolPair &bp, bool deleteIfUndef) {
  if (bp.Def) SetBool(key, bp.Val);
  else if (deleteIfUndef) DeleteKey(key);
}
void GetBoolPair(const char *key, CBoolPair &bp) {
  bool v = false;
  if (GetBool(key, v)) { bp.Val = v; bp.Def = true; }
}

} // namespace

// ============================ NExtract ============================
namespace NExtract {

void CInfo::Save() const {
  SetU32("Extraction.ExtractMode", (UInt32)PathMode);
  SetU32("Extraction.OverwriteMode", (UInt32)OverwriteMode);
  SetStringList("Extraction.PathHistory", Paths);
  SetBoolPair("Extraction.SplitDest", SplitDest, false);
  SetBoolPair("Extraction.ElimDup", ElimDup, false);
  SetBoolPair("Extraction.Security", NtSecurity, false);
  SetBoolPair("Extraction.ShowPassword", ShowPassword, false);
  Sync();
}

void CInfo::Load() {
  PathMode = NPathMode::kCurPaths; PathMode_Force = false;
  OverwriteMode = NOverwriteMode::kAsk; OverwriteMode_Force = false;
  SplitDest.Val = true; SplitDest.Def = false;
  ElimDup.Val = false; ElimDup.Def = false;
  NtSecurity.Val = false; NtSecurity.Def = false;
  ShowPassword.Val = false; ShowPassword.Def = false;
  Paths.Clear();

  UInt32 v;
  if (GetU32("Extraction.ExtractMode", v)) { PathMode = (NPathMode::EEnum)v; PathMode_Force = true; }
  if (GetU32("Extraction.OverwriteMode", v)) { OverwriteMode = (NOverwriteMode::EEnum)v; OverwriteMode_Force = true; }
  GetStringList("Extraction.PathHistory", Paths);
  GetBoolPair("Extraction.SplitDest", SplitDest);
  GetBoolPair("Extraction.ElimDup", ElimDup);
  GetBoolPair("Extraction.Security", NtSecurity);
  GetBoolPair("Extraction.ShowPassword", ShowPassword);
}

void Save_ShowPassword(bool showPassword) { SetBool("Extraction.ShowPassword", showPassword); Sync(); }
bool Read_ShowPassword() { bool v = false; GetBool("Extraction.ShowPassword", v); return v; }
void Save_LimitGB(UInt32 limit_GB) { SetU32("Extraction.MemLimit", limit_GB); Sync(); }
UInt32 Read_LimitGB() { UInt32 v = (UInt32)(Int32)-1; GetU32("Extraction.MemLimit", v); return v; }

}

// ============================ NCompression ============================
namespace NCompression {

// 同源移植 ZipRegistry.cpp:377 ParseMemUse（平台无关解析，原为文件内 static）。升版核对点：ZipRegistry.cpp:377。
static bool ParseMemUse(const wchar_t *s, CMemUse &mu) {
  mu.Clear();
  bool percentMode = false;
  if (MyCharLower_Ascii(*s) == 'p') { percentMode = true; s++; }
  const wchar_t *end;
  const UInt64 number = ConvertStringToUInt64(s, &end);
  if (end == s) return false;
  wchar_t c = *end;
  if (percentMode) { if (c != 0) return false; mu.IsPercent = true; mu.Val = number; return true; }
  if (c == 0) { mu.Val = number; return true; }
  c = MyCharLower_Ascii(c);
  const wchar_t c1 = end[1];
  if (c == '%') { if (c1 != 0) return false; mu.IsPercent = true; mu.Val = number; return true; }
  if (c == 'b') { if (c1 != 0) return false; mu.Val = number; return true; }
  if (c1 != 0) if (MyCharLower_Ascii(c1) != 'b' || end[2] != 0) return false;
  unsigned numBits;
  switch (c) {
    case 'k': numBits = 10; break; case 'm': numBits = 20; break;
    case 'g': numBits = 30; break; case 't': numBits = 40; break;
    default: return false;
  }
  if (number >= ((UInt64)1 << (64 - numBits))) return false;
  mu.Val = number << numBits;
  return true;
}

void CMemUse::Parse(const UString &s) { IsDefined = ParseMemUse(s.Ptr(), *this); }

void CInfo::Save() const {
  SetU32("Compression.Level", Level);
  SetBool("Compression.ShowPassword", ShowPassword);
  SetBool("Compression.EncryptHeaders", EncryptHeaders);
  SetString("Compression.ArcType", ArcType);
  SetStringList("Compression.ArcHistory", ArcPaths);
  SetBoolPair("Compression.Security", NtSecurity, true);
  SetBoolPair("Compression.AltStreams", AltStreams, true);
  SetBoolPair("Compression.HardLinks", HardLinks, true);
  SetBoolPair("Compression.SymLinks", SymLinks, true);
  SetBoolPair("Compression.PreserveATime", PreserveATime, true);
  // 各格式选项：按 FormatID 前缀存核心字段（M3 压缩对话框完善其余字段）
  FOR_VECTOR (i, Formats) {
    const CFormatOptions &fo = Formats[i];
    AString idA; for (unsigned j = 0; j < fo.FormatID.Len(); j++) idA += (char)fo.FormatID[j];
    AString p = AString("Compression.Fmt.") + idA + ".";
    SetU32((p + "Level").Ptr(),   fo.Level);
    SetU32((p + "Dict").Ptr(),    fo.Dictionary);
    SetU32((p + "Order").Ptr(),   fo.Order);
    SetU32((p + "Threads").Ptr(), fo.NumThreads);
    SetString((p + "Method").Ptr(),  fo.Method);
    SetString((p + "Options").Ptr(), fo.Options);
  }
  Sync();
}

void CInfo::Load() {
  Level = (UInt32)(Int32)-1; ShowPassword = false; EncryptHeaders = false;
  NtSecurity.Val = NtSecurity.Def = false;
  AltStreams.Val = AltStreams.Def = false;
  HardLinks.Val = HardLinks.Def = false;
  SymLinks.Val = SymLinks.Def = false;
  PreserveATime.Val = PreserveATime.Def = false;
  ArcType.Empty(); ArcPaths.Clear(); Formats.Clear();

  GetU32("Compression.Level", Level);
  GetBool("Compression.ShowPassword", ShowPassword);
  GetBool("Compression.EncryptHeaders", EncryptHeaders);
  GetString("Compression.ArcType", ArcType);
  GetStringList("Compression.ArcHistory", ArcPaths);
  GetBoolPair("Compression.Security", NtSecurity);
  GetBoolPair("Compression.AltStreams", AltStreams);
  GetBoolPair("Compression.HardLinks", HardLinks);
  GetBoolPair("Compression.SymLinks", SymLinks);
  GetBoolPair("Compression.PreserveATime", PreserveATime);
  // 格式选项的回读由压缩对话框按当前 FormatID 按需取（M3）；此处保持 Formats 空集即可。
}

}

// ============================ NWorkDir ============================
namespace NWorkDir {

void CInfo::Save() const {
  SetU32("Options.WorkDirType", (UInt32)Mode);
  SetString("Options.WorkDirPath", fs2us(Path));
  SetBool("Options.TempRemovableOnly", ForRemovableOnly);
  Sync();
}

void CInfo::Load() {
  SetDefault();
  UInt32 dirType;
  if (!GetU32("Options.WorkDirType", dirType)) return;
  switch (dirType) {
    case NMode::kSystem: case NMode::kCurrent: case NMode::kSpecified:
      Mode = (NMode::EEnum)dirType;
  }
  UString pathU;
  if (GetString("Options.WorkDirPath", pathU)) Path = us2fs(pathU);
  else { Path.Empty(); if (Mode == NMode::kSpecified) Mode = NMode::kSystem; }
  GetBool("Options.TempRemovableOnly", ForRemovableOnly);
}

}

// ============================ CContextMenuInfo ============================
void CContextMenuInfo::Save() const {
  SetBoolPair("Options.CascadedMenu", Cascaded, true);
  SetBoolPair("Options.MenuIcons", MenuIcons, true);
  SetBoolPair("Options.ElimDupExtract", ElimDup, true);
  if (Flags_Def) SetU32("Options.ContextMenu", Flags);
  SetU32("Options.WriteZoneIdExtract", WriteZone);
  Sync();
}

void CContextMenuInfo::Load() {
  Cascaded.Val = true;  Cascaded.Def = false;
  MenuIcons.Val = false; MenuIcons.Def = false;
  ElimDup.Val = false;  ElimDup.Def = false;
  Flags = 0; Flags_Def = false;
  WriteZone = (UInt32)(Int32)-1;

  GetBoolPair("Options.CascadedMenu", Cascaded);
  GetBoolPair("Options.MenuIcons", MenuIcons);
  GetBoolPair("Options.ElimDupExtract", ElimDup);
  if (GetU32("Options.ContextMenu", Flags)) Flags_Def = true;
  GetU32("Options.WriteZoneIdExtract", WriteZone);
}
