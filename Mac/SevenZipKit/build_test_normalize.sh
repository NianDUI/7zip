#!/bin/bash
# M1-T8 复现：NFC/NFD 规范化专项用例。纯 C++（CFStringNormalize），arm64。
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
CPP="$REPO/CPP"; KIT="$REPO/Mac/SevenZipKit"
ALONE="$CPP/7zip/Bundles/Alone2/b/m_arm64"
SHIM="$REPO/Mac/compat/win_compat_mac.h"
OUT=/tmp/norm_t8; mkdir -p "$OUT"
cd "$CPP"
[ -d "$ALONE" ] || { echo "缺 Alone2 对象集"; exit 1; }

CXXFLAGS=(-arch arm64 -O2 -DNDEBUG -fPIC -std=c++11 -I . -include "$SHIM" -I "$KIT/src")

echo "==[1] 编译 SZNormalize + test =="
clang++ "${CXXFLAGS[@]}" -c "$KIT/src/SZNormalize.cpp"        -o "$OUT/SZNormalize.o"
clang++ "${CXXFLAGS[@]}" -c "$KIT/tests/test_normalize.cpp"   -o "$OUT/test_normalize.o"

echo "==[2] 链接（最小字符串工具 .o，无 IID）=="
TOOLS=(MyString StringConvert UTFConvert StringToInt IntToString MyWindows NewHandler Alloc)
TOOL_OBJS=(); for t in "${TOOLS[@]}"; do [ -f "$ALONE/$t.o" ] && TOOL_OBJS+=("$ALONE/$t.o"); done
clang++ -arch arm64 "$OUT/test_normalize.o" "$OUT/SZNormalize.o" "${TOOL_OBJS[@]}" \
  -framework CoreFoundation -lz -o "$OUT/test_normalize"

echo "==[3] 运行 =="
env -u DYLD_PRINT_LIBRARIES "$OUT/test_normalize"
