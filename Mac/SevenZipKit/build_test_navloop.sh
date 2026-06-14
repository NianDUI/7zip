#!/bin/bash
# 重现崩溃：归档进/退反复 + 反复 open/release（崩溃栈 SZFolderCore::enterParentFolder→reload→GetNumberOfItems）。
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
CPP="$REPO/CPP"; KIT="$REPO/Mac/SevenZipKit"; ALONE="$CPP/7zip/Bundles/Alone2/b/m_arm64"
SHIM="$REPO/Mac/compat/win_compat_mac.h"; OUT=/tmp/szkit_navloop; mkdir -p "$OUT"
cd "$CPP"
[ -d "$ALONE" ] || { echo "缺 Alone2 对象集"; exit 1; }
CXXFLAGS=(-arch arm64 -O2 -DNDEBUG -D_REENTRANT -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE -fPIC -std=c++11 -I . -include "$SHIM")
SZOBJCPP=(-arch arm64 -O2 -fobjc-arc -std=c++11 -I "$KIT/include" -I "$KIT/src")

echo "==[1] Agent + DLL/WorkDir/ZipRegistry =="
for f in Agent AgentProxy ArchiveFolder ArchiveFolderOpen UpdateCallbackAgent AgentOut ArchiveFolderOut; do
  clang++ "${CXXFLAGS[@]}" -c 7zip/UI/Agent/$f.cpp -o "$OUT/$f.o"
done
clang++ "${CXXFLAGS[@]}" -c Windows/DLL.cpp            -o "$OUT/DLL.o"
clang++ "${CXXFLAGS[@]}" -c 7zip/UI/Common/WorkDir.cpp -o "$OUT/WorkDir.o"
clang++ "${CXXFLAGS[@]}" -c "$KIT/platform/ZipRegistry_mac.cpp" -o "$OUT/ZipRegistry_mac.o"

echo "==[2] core =="
clang++ "${CXXFLAGS[@]}" -I "$KIT/src" -c "$KIT/src/SZNaturalCompare.cpp" -o "$OUT/SZNaturalCompare.o"
clang++ "${CXXFLAGS[@]}" -I "$KIT/src" -c "$KIT/src/SZFolderCore.cpp"     -o "$OUT/SZFolderCore.o"

echo "==[3] ObjC 外观 + 测试 =="
clang++ "${SZOBJCPP[@]}" -x objective-c++ -c "$KIT/src/SZFolderSession.mm" -o "$OUT/SZFolderSession.o"
clang++ "${SZOBJCPP[@]}" -x objective-c++ -c "$KIT/src/SZFolderItem.m"     -o "$OUT/SZFolderItem.o"
clang++ "${SZOBJCPP[@]}" -x objective-c++ -c "$KIT/tests/test_navloop.mm"  -o "$OUT/test_navloop.o"

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
  "$OUT/test_navloop.o" "$OUT/SZFolderSession.o" "$OUT/SZFolderItem.o" "$OUT/SZFolderCore.o" "$OUT/SZNaturalCompare.o" \
  "$OUT/Agent.o" "$OUT/AgentProxy.o" "$OUT/ArchiveFolder.o" "$OUT/ArchiveFolderOpen.o" \
  "$OUT/UpdateCallbackAgent.o" "$OUT/AgentOut.o" "$OUT/ArchiveFolderOut.o" \
  "$OUT/DLL.o" "$OUT/WorkDir.o" "$OUT/ZipRegistry_mac.o" \
  "${ALONE_OBJS[@]}" \
  -framework Foundation -framework CoreFoundation -lz \
  -o "$OUT/test_navloop"

echo "==[5] 造测试归档（src/sub/deep 两层）=="
ARC="$OUT/test.7z"
if [ ! -f "$ARC" ]; then
  clang++ -arch arm64 "$ALONE"/*.o -framework CoreFoundation -lz -o "$OUT/7zz" 2>/dev/null
  S="$OUT/src"; rm -rf "$S"; mkdir -p "$S/sub/deep"
  echo top > "$S/top.txt"; echo inner > "$S/sub/inner.txt"; head -c 4096 /dev/urandom > "$S/sub/deep/leaf.bin"
  ( cd "$OUT" && ./7zz a test.7z src >/dev/null )
fi

echo "==[6] 运行 =="
env -u DYLD_PRINT_LIBRARIES "$OUT/test_navloop" "$ARC"
echo "exit=$?"
