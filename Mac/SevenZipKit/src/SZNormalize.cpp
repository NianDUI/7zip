// SZNormalize.cpp —— NFC/NFD 规范化实现（CFStringNormalize，纯 C++ + CoreFoundation，无 ObjC）。
#include "SZNormalize.h"
#include "Common/StringConvert.h"   // UnicodeStringToMultiByte / MultiByteToUnicodeString / CP_UTF8
#include <CoreFoundation/CoreFoundation.h>

namespace {

CFStringRef ToCF(const UString &s) {
  const AString utf8 = UnicodeStringToMultiByte(s, CP_UTF8);
  return CFStringCreateWithCString(NULL, utf8.Ptr(), kCFStringEncodingUTF8);
}

UString FromCF(CFStringRef cf) {
  if (!cf) return UString();
  const CFIndex maxLen = CFStringGetMaximumSizeForEncoding(CFStringGetLength(cf), kCFStringEncodingUTF8) + 1;
  char *buf = (char *)malloc((size_t)maxLen);
  UString r;
  if (buf && CFStringGetCString(cf, buf, maxLen, kCFStringEncodingUTF8))
    r = MultiByteToUnicodeString(AString(buf), CP_UTF8);
  free(buf);
  return r;
}

UString Normalize(const UString &s, CFStringNormalizationForm form) {
  CFStringRef cf = ToCF(s);
  if (!cf) return s;
  CFMutableStringRef m = CFStringCreateMutableCopy(NULL, 0, cf);
  CFRelease(cf);
  if (!m) return s;
  CFStringNormalize(m, form);
  UString r = FromCF(m);
  CFRelease(m);
  return r;
}

} // namespace

namespace SZNorm {

UString ToNFC(const UString &s) { return Normalize(s, kCFStringNormalizationFormC); }
UString ToNFD(const UString &s) { return Normalize(s, kCFStringNormalizationFormD); }

bool NamesEqual(const UString &a, const UString &b) {
  if (a == b) return true;                 // 快路径：字节相等
  return ToNFC(a) == ToNFC(b);             // 双向规范化到 NFC 比较
}

int NamesCompare(const UString &a, const UString &b) {
  const UString na = ToNFC(a), nb = ToNFC(b);
  return na.Compare(nb);
}

} // namespace SZNorm
