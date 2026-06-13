#!/bin/bash
# M1-T7（逻辑部分）：SZPanelController headless 验证。internal codecs，macOS arm64。
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
CPP="$REPO/CPP"
KIT="$REPO/Mac/SevenZipKit"
FM="$REPO/Mac/SevenZipFM"
ALONE="$CPP/7zip/Bundles/Alone2/b/m_arm64"
SHIM="$REPO/Mac/compat/win_compat_mac.h"
OUT=/tmp/szfm_t7; mkdir -p "$OUT"
cd "$CPP"
[ -d "$ALONE" ] || { echo "缺 Alone2 对象集"; exit 1; }

CXXFLAGS=(-arch arm64 -O2 -DNDEBUG -D_REENTRANT -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE -fPIC -std=c++11 -I . -include "$SHIM")
OBJC=(-arch arm64 -O2 -fobjc-arc -I "$KIT/include" -I "$KIT/src" -I "$FM/Panel")

echo "==[1] Agent 闭环 + SevenZipKit C++ 核心 =="
for f in Agent AgentProxy ArchiveFolder ArchiveFolderOpen UpdateCallbackAgent AgentOut ArchiveFolderOut; do
  clang++ "${CXXFLAGS[@]}" -c 7zip/UI/Agent/$f.cpp -o "$OUT/$f.o"
done
clang++ "${CXXFLAGS[@]}" -c Windows/DLL.cpp -o "$OUT/DLL.o"
clang++ "${CXXFLAGS[@]}" -c 7zip/UI/Common/WorkDir.cpp -o "$OUT/WorkDir.o"
clang++ "${CXXFLAGS[@]}" -c "$REPO/Mac/SevenZipKit/platform/ZipRegistry_mac.cpp" -o "$OUT/ZipRegistry_mac.o"
clang++ "${CXXFLAGS[@]}" -I "$KIT/src" -c "$KIT/src/SZNaturalCompare.cpp" -o "$OUT/SZNaturalCompare.o"
clang++ "${CXXFLAGS[@]}" -I "$KIT/src" -c "$KIT/src/SZFolderCore.cpp"     -o "$OUT/SZFolderCore.o"
echo "  ✓"

echo "==[2] SevenZipKit ObjC + SevenZipFM Panel + 测试（AppKit）=="
clang "${OBJC[@]}" -x objective-c++ -c "$KIT/src/SZFolderSession.mm" -o "$OUT/SZFolderSession.o"
clang "${OBJC[@]}" -x objective-c++ -c "$KIT/src/SZPanelModel.mm"    -o "$OUT/SZPanelModel.o"
clang "${OBJC[@]}" -c "$FM/Panel/SZPanelController.m"   -o "$OUT/SZPanelController.o"
clang "${OBJC[@]}" -c "$FM/tests/test_panelview.m"      -o "$OUT/test_panelview.o"
echo "  ✓"

echo "==[3] 链接 =="
CONSOLE_ONLY="Main.o MainAr.o List.o BenchCon.o HashCon.o ConsoleClose.o ExtractCallbackConsole.o OpenCallbackConsole.o UpdateCallbackConsole.o PercentPrinter.o UserInputUtils.o"
ALONE_OBJS=()
for o in "$ALONE"/*.o; do
  b="$(basename "$o")"; skip=0
  for cc in $CONSOLE_ONLY; do [ "$b" = "$cc" ] && { skip=1; break; }; done
  [ "$skip" = 1 ] && continue
  ALONE_OBJS+=("$o")
done
clang++ -arch arm64 \
  "$OUT/test_panelview.o" "$OUT/SZPanelController.o" "$OUT/SZPanelModel.o" "$OUT/SZFolderSession.o" \
  "$OUT/SZFolderCore.o" "$OUT/SZNaturalCompare.o" \
  "$OUT/Agent.o" "$OUT/AgentProxy.o" "$OUT/ArchiveFolder.o" "$OUT/ArchiveFolderOpen.o" \
  "$OUT/UpdateCallbackAgent.o" "$OUT/AgentOut.o" "$OUT/ArchiveFolderOut.o" \
  "$OUT/DLL.o" "$OUT/WorkDir.o" "$OUT/ZipRegistry_mac.o" \
  "${ALONE_OBJS[@]}" \
  -framework AppKit -framework Foundation -framework CoreFoundation -lz \
  -o "$OUT/test_panelview"
echo "  ✓ $OUT/test_panelview"

echo "==[4] 运行（需 /tmp/szsort_t6/test.7z，由 M1-T6 脚本造）=="
ARC=/tmp/szsort_t6/test.7z
[ -f "$ARC" ] || { bash "$KIT/build_test_panelmodel.sh" >/dev/null 2>&1 || true; }
env -u DYLD_PRINT_LIBRARIES "$OUT/test_panelview" "$ARC"
