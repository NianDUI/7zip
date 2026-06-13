#!/bin/bash
# M0 PoC 一键复现：dylib 构建 + 符号收敛 + 段A(Client7z roundtrip) + 段B(裸 dlopen 桥接)
# 对应 docs/02-core-bridge.md §8 与 docs/M0-poc-report.md。仅 macOS arm64，需 clang/make。
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
CPP="$REPO/CPP"
POC=/tmp/poc7z
rm -rf "$POC"; mkdir -p "$POC/out"

echo "==[1/5] 构建收敛版 lib7z.dylib（LDFLAGS_STATIC_3 零侵入挂接点）=="
cp "$REPO/Mac/poc/exports7z.txt" "$CPP/7zip/Bundles/Format7zF/exports7z.txt"
cd "$CPP/7zip/Bundles/Format7zF"
rm -f b/m_arm64/7z.so
make -f ../../cmpl_mac_arm64.mak -j8 \
  LDFLAGS_STATIC_3="-Wl,-exported_symbols_list,$PWD/exports7z.txt -Wl,-dead_strip -Wl,-install_name,@rpath/lib7z.dylib -Wl,-compatibility_version,1 -Wl,-current_version,26.1" >/dev/null
cp b/m_arm64/7z.so "$POC/lib7z.dylib"
cp "$POC/lib7z.dylib" "$POC/7z.so"   # Client7z 走 LoadCodecs 需 7z.so 名

echo "==[2/5] 符号收敛校验（期望精确 19）=="
N=$(nm -gU b/m_arm64/7z.so | grep -c ' T ')
echo "全局 text 符号数 = $N"; [ "$N" = "19" ] || { echo "FAIL: 符号未收敛到 19"; exit 1; }
nm -gU b/m_arm64/7z.so | awk '$2=="T"{sub(/^_/,"",$3);print $3}' | sort \
  | diff - <(sed 's/^_//' exports7z.txt | sort) >/dev/null && echo "符号集合精确匹配 ✓"

echo "==[3/5] 构建官方 Client7z（dlopen 客户端范例）=="
cd "$CPP/7zip/UI/Client7z"; make -f ../../cmpl_mac_arm64.mak -j8 >/dev/null
cp b/m_arm64/7zcl "$POC/7zcl"

echo "==[4/5] 段A：Client7z 压缩→列表→解压 roundtrip（含中文/二进制）=="
cd "$POC"
echo "hello 7zip dylib on mac" > f1.txt
printf '中文内容测试\n' > "中文文件.txt"
head -c 8192 /dev/urandom > f2.bin
./7zcl a test.7z f1.txt f2.bin "中文文件.txt" >/dev/null
( cd out && ../7zcl x ../test.7z >/dev/null )
diff f1.txt out/f1.txt && diff f2.bin out/f2.bin && diff "中文文件.txt" "out/中文文件.txt" \
  && echo "段A roundtrip 逐字节一致 ✓"

echo "==[5/5] 段B：裸 dlopen 桥接（不经 LoadCodecs）=="
cd "$CPP"
OBJ=7zip/UI/Client7z/b/m_arm64
clang++ -arch arm64 -std=c++17 -I . "$REPO/Mac/poc/poc_bridge.cpp" \
  $OBJ/MyWindows.o $OBJ/PropVariant.o $OBJ/FileStreams.o $OBJ/FileIO.o $OBJ/FileDir.o \
  $OBJ/FileFind.o $OBJ/FileName.o $OBJ/MyString.o $OBJ/StringConvert.o $OBJ/UTFConvert.o \
  $OBJ/IntToString.o $OBJ/PropVariantConv.o $OBJ/Alloc.o $OBJ/NewHandler.o $OBJ/TimeUtils.o \
  $OBJ/Wildcard.o $OBJ/DLL.o $OBJ/MyVector.o $OBJ/StringToInt.o \
  -framework CoreFoundation -ldl -o "$POC/poc_bridge"
env -u DYLD_PRINT_LIBRARIES "$POC/poc_bridge"
echo; echo "===== M0 PoC 全部通过 ====="
