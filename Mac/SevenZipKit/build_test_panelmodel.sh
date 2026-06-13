#!/bin/bash
# M1-T6 复现：SZPanelModel 排序/选择/列单测。internal codecs（复用 Alone2），仅 macOS arm64。
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
CPP="$REPO/CPP"
KIT="$REPO/Mac/SevenZipKit"
ALONE="$CPP/7zip/Bundles/Alone2/b/m_arm64"
SHIM="$REPO/Mac/compat/win_compat_mac.h"
OUT=/tmp/szsort_t6; mkdir -p "$OUT"
cd "$CPP"

[ -d "$ALONE" ] || { echo "缺 Alone2 对象集：cd CPP/7zip/Bundles/Alone2 && make -f ../../cmpl_mac_arm64.mak -j8"; exit 1; }

CXXFLAGS=(-arch arm64 -O2 -DNDEBUG -D_REENTRANT -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE -fPIC -std=c++11 -I . -include "$SHIM")
SZOBJCPP=(-arch arm64 -O2 -fobjc-arc -std=c++11 -I "$KIT/include" -I "$KIT/src")

echo "==[1] Agent 闭环对象（internal）=="
for f in Agent AgentProxy ArchiveFolder ArchiveFolderOpen UpdateCallbackAgent AgentOut ArchiveFolderOut; do
  clang++ "${CXXFLAGS[@]}" -c 7zip/UI/Agent/$f.cpp -o "$OUT/$f.o"
done
clang++ "${CXXFLAGS[@]}" -c Windows/DLL.cpp            -o "$OUT/DLL.o"
clang++ "${CXXFLAGS[@]}" -c 7zip/UI/Common/WorkDir.cpp -o "$OUT/WorkDir.o"
clang++ "${CXXFLAGS[@]}" -c "$REPO/Mac/SevenZipKit/platform/ZipRegistry_mac.cpp" -o "$OUT/ZipRegistry_mac.o"
echo "  ✓"

echo "==[2] SevenZipKit C++ 核心（SZNaturalCompare + SZFolderCore，唯一 INITGUID）=="
clang++ "${CXXFLAGS[@]}" -I "$KIT/src" -c "$KIT/src/SZNaturalCompare.cpp" -o "$OUT/SZNaturalCompare.o"
clang++ "${CXXFLAGS[@]}" -I "$KIT/src" -c "$KIT/src/SZFolderCore.cpp"     -o "$OUT/SZFolderCore.o"
echo "  ✓"

echo "==[3] SevenZipKit ObjC 外观 + 测试（ObjC++/ARC，不碰 7-Zip）=="
clang++ "${SZOBJCPP[@]}" -x objective-c++ -c "$KIT/src/SZFolderSession.mm"   -o "$OUT/SZFolderSession.o"
clang++ "${SZOBJCPP[@]}" -x objective-c++ -c "$KIT/src/SZPanelModel.mm"      -o "$OUT/SZPanelModel.o"
clang++ "${SZOBJCPP[@]}" -x objective-c++ -c "$KIT/tests/test_panelmodel.mm" -o "$OUT/test_panelmodel.o"
echo "  ✓"

echo "==[4] 链接 =="
CONSOLE_ONLY="Main.o MainAr.o List.o BenchCon.o HashCon.o ConsoleClose.o ExtractCallbackConsole.o OpenCallbackConsole.o UpdateCallbackConsole.o PercentPrinter.o UserInputUtils.o"
ALONE_OBJS=()
for o in "$ALONE"/*.o; do
  b="$(basename "$o")"; skip=0
  for c in $CONSOLE_ONLY; do [ "$b" = "$c" ] && { skip=1; break; }; done
  [ "$skip" = 1 ] && continue
  ALONE_OBJS+=("$o")
done
clang++ -arch arm64 \
  "$OUT/test_panelmodel.o" "$OUT/SZPanelModel.o" "$OUT/SZFolderSession.o" \
  "$OUT/SZFolderCore.o" "$OUT/SZNaturalCompare.o" \
  "$OUT/Agent.o" "$OUT/AgentProxy.o" "$OUT/ArchiveFolder.o" "$OUT/ArchiveFolderOpen.o" \
  "$OUT/UpdateCallbackAgent.o" "$OUT/AgentOut.o" "$OUT/ArchiveFolderOut.o" \
  "$OUT/DLL.o" "$OUT/WorkDir.o" "$OUT/ZipRegistry_mac.o" \
  "${ALONE_OBJS[@]}" \
  -framework Foundation -framework CoreFoundation -lz \
  -o "$OUT/test_panelmodel"
echo "  ✓ $OUT/test_panelmodel"

echo "==[5] 造排序测试归档（数字命名 + 不同大小 + 目录）=="
if [ ! -f "$OUT/test.7z" ]; then
  clang++ -arch arm64 "$ALONE"/*.o -framework CoreFoundation -lz -o "$OUT/7zz"
  S="$OUT/src"; rm -rf "$S"; mkdir -p "$S/dir1" "$S/dir2"
  printf '%100s' '' > "$S/a.txt"        # 100 B
  printf '%5s'   '' > "$S/file2.txt"    #   5 B
  printf '%50s'  '' > "$S/file10.txt"   #  50 B
  printf '%1s'   '' > "$S/zebra.txt"    #   1 B
  echo x > "$S/dir1/x"; echo y > "$S/dir2/y"
  ( cd "$OUT" && ./7zz a test.7z src >/dev/null )
  echo "  ✓ $OUT/test.7z"
fi

echo "==[6] 运行 =="
env -u DYLD_PRINT_LIBRARIES "$OUT/test_panelmodel" "$OUT/test.7z"
