#!/bin/bash
# M1-T1/T2 复现：ZipRegistry_mac（CFPreferences 后端）往返单测。纯 C++，arm64。
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
CPP="$REPO/CPP"
KIT="$REPO/Mac/SevenZipKit"
ALONE="$CPP/7zip/Bundles/Alone2/b/m_arm64"
SHIM="$REPO/Mac/compat/win_compat_mac.h"
OUT=/tmp/zipreg_t1; mkdir -p "$OUT"
cd "$CPP"
[ -d "$ALONE" ] || { echo "缺 Alone2 对象集"; exit 1; }

CXXFLAGS=(-arch arm64 -O2 -DNDEBUG -fPIC -std=c++11 -I . -include "$SHIM")

echo "==[1] 编译 ZipRegistry_mac + test =="
clang++ "${CXXFLAGS[@]}" -c "$KIT/platform/ZipRegistry_mac.cpp" -o "$OUT/ZipRegistry_mac.o"
clang++ "${CXXFLAGS[@]}" -c "$KIT/tests/test_zipregistry.cpp"   -o "$OUT/test_zipregistry.o"
echo "  ✓"

echo "==[2] 链接（仅字符串工具 .o，不碰 COM/handlers，故无需 IID）=="
TOOLS=(MyString StringConvert UTFConvert StringToInt IntToString MyWindows NewHandler Alloc)
TOOL_OBJS=()
for t in "${TOOLS[@]}"; do [ -f "$ALONE/$t.o" ] && TOOL_OBJS+=("$ALONE/$t.o"); done
clang++ -arch arm64 "$OUT/test_zipregistry.o" "$OUT/ZipRegistry_mac.o" \
  "${TOOL_OBJS[@]}" -framework CoreFoundation -lz -o "$OUT/test_zipregistry"
echo "  ✓ $OUT/test_zipregistry"

echo "==[3] 运行 =="
# 清理上次测试残留偏好，确保 CBoolPair「未定义」用例可靠
defaults delete com.niandui.SevenZipFM >/dev/null 2>&1 || true
env -u DYLD_PRINT_LIBRARIES "$OUT/test_zipregistry"
