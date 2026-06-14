#!/bin/bash
# M5：SZHashCore 哈希核心回归。链接策略同 build_test_szfolder.sh（internal codecs，复用 Alone2 对象集）。
# HashCalc.o / EnumDirItems.o 已在 Alone2，无需补编译；SZFolderCore.o 提供 IID（唯一 INITGUID 单元）。
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
CPP="$REPO/CPP"
KIT="$REPO/Mac/SevenZipKit"
ALONE="$CPP/7zip/Bundles/Alone2/b/m_arm64"
SHIM="$REPO/Mac/compat/win_compat_mac.h"
OUT=/tmp/szkit_hash; mkdir -p "$OUT"
cd "$CPP"

[ -d "$ALONE" ] || { echo "缺 Alone2 对象集：cd CPP/7zip/Bundles/Alone2 && make -f ../../cmpl_mac_arm64.mak -j8"; exit 1; }

CXXFLAGS=(-arch arm64 -O2 -DNDEBUG -D_REENTRANT -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE -fPIC -std=c++11 -I . -include "$SHIM")
SZOBJCPP=(-arch arm64 -O2 -fobjc-arc -std=c++11 -I "$KIT/include" -I "$KIT/src")

echo "==[1] Agent 闭环 + DLL/WorkDir + IID 提供者（SZFolderCore）=="
for f in Agent AgentProxy ArchiveFolder ArchiveFolderOpen UpdateCallbackAgent AgentOut ArchiveFolderOut; do
  clang++ "${CXXFLAGS[@]}" -c 7zip/UI/Agent/$f.cpp -o "$OUT/$f.o"
done
clang++ "${CXXFLAGS[@]}" -c Windows/DLL.cpp            -o "$OUT/DLL.o"
clang++ "${CXXFLAGS[@]}" -c 7zip/UI/Common/WorkDir.cpp -o "$OUT/WorkDir.o"
clang++ "${CXXFLAGS[@]}" -c "$REPO/Mac/SevenZipKit/platform/ZipRegistry_mac.cpp" -o "$OUT/ZipRegistry_mac.o"
clang++ "${CXXFLAGS[@]}" -I "$KIT/src" -c "$KIT/src/SZNaturalCompare.cpp" -o "$OUT/SZNaturalCompare.o"
clang++ "${CXXFLAGS[@]}" -I "$KIT/src" -c "$KIT/src/SZFolderCore.cpp"     -o "$OUT/SZFolderCore.o"
echo "  ✓"

echo "==[2] 编译 SZHashCore（含 7-Zip 头）=="
clang++ "${CXXFLAGS[@]}" -I "$KIT/src" -c "$KIT/src/SZHashCore.cpp" -o "$OUT/SZHashCore.o"
echo "  ✓ SZHashCore.o"

echo "==[3] 编译测试 driver（ObjC++/ARC，不碰 7-Zip 头）=="
clang++ "${SZOBJCPP[@]}" -x objective-c++ -c "$KIT/tests/test_hash.mm" -o "$OUT/test_hash.o"
echo "  ✓ test_hash.o"

echo "==[4] 链接（排除 console-only Alone2 对象）=="
CONSOLE_ONLY="Main.o MainAr.o List.o BenchCon.o HashCon.o ConsoleClose.o ExtractCallbackConsole.o OpenCallbackConsole.o UpdateCallbackConsole.o PercentPrinter.o UserInputUtils.o"
ALONE_OBJS=()
for o in "$ALONE"/*.o; do
  b="$(basename "$o")"; skip=0
  for c in $CONSOLE_ONLY; do [ "$b" = "$c" ] && { skip=1; break; }; done
  [ "$skip" = 1 ] && continue
  ALONE_OBJS+=("$o")
done
clang++ -arch arm64 \
  "$OUT/test_hash.o" "$OUT/SZHashCore.o" "$OUT/SZFolderCore.o" "$OUT/SZNaturalCompare.o" \
  "$OUT/Agent.o" "$OUT/AgentProxy.o" "$OUT/ArchiveFolder.o" "$OUT/ArchiveFolderOpen.o" \
  "$OUT/UpdateCallbackAgent.o" "$OUT/AgentOut.o" "$OUT/ArchiveFolderOut.o" \
  "$OUT/DLL.o" "$OUT/WorkDir.o" "$OUT/ZipRegistry_mac.o" \
  "${ALONE_OBJS[@]}" \
  -framework Foundation -framework CoreFoundation -lz \
  -o "$OUT/test_hash"
echo "  ✓ $OUT/test_hash"

echo "==[5] 运行 =="
env -u DYLD_PRINT_LIBRARIES "$OUT/test_hash"

echo ""
echo "==[6] 与 7zz h 交叉对照（CRC32 + SHA256，\"hello\"）=="
if [ ! -x "$OUT/7zz" ]; then clang++ -arch arm64 "$ALONE"/*.o -framework CoreFoundation -lz -o "$OUT/7zz" 2>/dev/null; fi
printf 'hello' > /tmp/szhash_test/hello.txt
echo "  [7zz] CRC32:"; "$OUT/7zz" h -scrcCRC32   /tmp/szhash_test/hello.txt 2>/dev/null | grep -iE "for data|CRC32 " | head -2 | sed 's/^/    /'
echo "  [7zz] SHA256:"; "$OUT/7zz" h -scrcSHA256 /tmp/szhash_test/hello.txt 2>/dev/null | grep -iE "for data" | head -1 | sed 's/^/    /'

echo ""
echo "==[7] ObjC 桥接端到端（SZHashCalculator：后台队列 + completion + runloop）=="
clang -arch arm64 -O2 -fobjc-arc -std=c++11 -I "$KIT/include" -I "$KIT/src" \
  -x objective-c++ -c "$KIT/src/SZHashCalculator.mm" -o "$OUT/SZHashCalculator.o"
clang -arch arm64 -O2 -fobjc-arc -I "$KIT/include" \
  -c "$KIT/tests/test_hash_bridge.m" -o "$OUT/test_hash_bridge.o"
clang++ -arch arm64 \
  "$OUT/test_hash_bridge.o" "$OUT/SZHashCalculator.o" "$OUT/SZHashCore.o" "$OUT/SZFolderCore.o" "$OUT/SZNaturalCompare.o" \
  "$OUT/Agent.o" "$OUT/AgentProxy.o" "$OUT/ArchiveFolder.o" "$OUT/ArchiveFolderOpen.o" \
  "$OUT/UpdateCallbackAgent.o" "$OUT/AgentOut.o" "$OUT/ArchiveFolderOut.o" \
  "$OUT/DLL.o" "$OUT/WorkDir.o" "$OUT/ZipRegistry_mac.o" \
  "${ALONE_OBJS[@]}" \
  -framework Foundation -framework CoreFoundation -lz \
  -o "$OUT/test_hash_bridge"
env -u DYLD_PRINT_LIBRARIES "$OUT/test_hash_bridge"
