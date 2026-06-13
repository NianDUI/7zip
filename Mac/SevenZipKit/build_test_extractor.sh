#!/bin/bash
# M2-T2 复现：SZExtractor ObjC 外观 + 阻塞式询问（覆盖/密码经 dispatch_semaphore 主队列往返）。
# 链接策略同 build_test_extract.sh。SZExtractor.mm 走 ObjC++/ARC flags（不碰 7-Zip 头）。仅 macOS arm64。
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
CPP="$REPO/CPP"
KIT="$REPO/Mac/SevenZipKit"
ALONE="$CPP/7zip/Bundles/Alone2/b/m_arm64"
SHIM="$REPO/Mac/compat/win_compat_mac.h"
OUT=/tmp/szkit_m2t2; mkdir -p "$OUT"
cd "$CPP"

[ -d "$ALONE" ] || { echo "缺 Alone2 对象集：cd CPP/7zip/Bundles/Alone2 && make -f ../../cmpl_mac_arm64.mak -j8"; exit 1; }

CXXFLAGS=(-arch arm64 -O2 -DNDEBUG -D_REENTRANT -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE -fPIC -std=c++11 -I . -include "$SHIM")
SZOBJCPP=(-arch arm64 -O2 -fobjc-arc -std=c++11 -I "$KIT/include" -I "$KIT/src")

echo "==[1] Agent 闭环 + DLL/WorkDir/ZipRegistry =="
for f in Agent AgentProxy ArchiveFolder ArchiveFolderOpen UpdateCallbackAgent AgentOut ArchiveFolderOut; do
  clang++ "${CXXFLAGS[@]}" -c 7zip/UI/Agent/$f.cpp -o "$OUT/$f.o"
done
clang++ "${CXXFLAGS[@]}" -c Windows/DLL.cpp            -o "$OUT/DLL.o"
clang++ "${CXXFLAGS[@]}" -c 7zip/UI/Common/WorkDir.cpp -o "$OUT/WorkDir.o"
clang++ "${CXXFLAGS[@]}" -c "$REPO/Mac/SevenZipKit/platform/ZipRegistry_mac.cpp" -o "$OUT/ZipRegistry_mac.o"
echo "  ✓"

echo "==[2] 桥接核心 SZNaturalCompare + SZFolderCore(INITGUID) + SZExtractCore =="
clang++ "${CXXFLAGS[@]}" -I "$KIT/src" -c "$KIT/src/SZNaturalCompare.cpp" -o "$OUT/SZNaturalCompare.o"
clang++ "${CXXFLAGS[@]}" -I "$KIT/src" -c "$KIT/src/SZFolderCore.cpp"      -o "$OUT/SZFolderCore.o"
clang++ "${CXXFLAGS[@]}" -I "$KIT/src" -c "$KIT/src/SZExtractCore.cpp"     -o "$OUT/SZExtractCore.o"
echo "  ✓"

echo "==[3] ObjC 外观 SZExtractor + 测试 driver（ObjC++/ARC，不碰 7-Zip 头）=="
clang++ "${SZOBJCPP[@]}" -x objective-c++ -c "$KIT/src/SZArchiveExtractor.mm"     -o "$OUT/SZArchiveExtractor.o"
clang++ "${SZOBJCPP[@]}" -x objective-c++ -c "$KIT/tests/test_extractor.mm" -o "$OUT/test_extractor.o"
echo "  ✓"

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
  "$OUT/test_extractor.o" "$OUT/SZArchiveExtractor.o" "$OUT/SZExtractCore.o" \
  "$OUT/SZFolderCore.o" "$OUT/SZNaturalCompare.o" \
  "$OUT/Agent.o" "$OUT/AgentProxy.o" "$OUT/ArchiveFolder.o" "$OUT/ArchiveFolderOpen.o" \
  "$OUT/UpdateCallbackAgent.o" "$OUT/AgentOut.o" "$OUT/ArchiveFolderOut.o" \
  "$OUT/DLL.o" "$OUT/WorkDir.o" "$OUT/ZipRegistry_mac.o" \
  "${ALONE_OBJS[@]}" \
  -framework Foundation -framework CoreFoundation -lz \
  -o "$OUT/test_extractor"
echo "  ✓ $OUT/test_extractor"

echo "==[5] 造测试归档（普通 + 加密）=="
clang++ -arch arm64 "$ALONE"/*.o -framework CoreFoundation -lz -o "$OUT/7zz" 2>/dev/null
S="$OUT/src"; rm -rf "$S"; mkdir -p "$S/sub"
echo top > "$S/top.txt"; printf '中文内容\n' > "$S/中文.txt"; echo inner > "$S/sub/inner.txt"
( cd "$OUT" && rm -f plain.7z enc.7z
  ./7zz a plain.7z src >/dev/null
  ./7zz a -ppass123 enc.7z src >/dev/null )
echo "  ✓ plain.7z / enc.7z"

echo ""
echo "==[6] 运行 =="
rm -rf "$OUT/out"
"$OUT/test_extractor" "$OUT/plain.7z" "$OUT/enc.7z" "$OUT/out"
