#!/bin/bash
# M1-T5（下半场）复现：SZFolderSession ObjC++ 封装的只读浏览端到端测试。
# 链接策略同 Mac/poc/build_agent_browse.sh（internal codecs，复用 Alone2 对象集），
# 额外编译 SevenZipKit 的 .mm（ObjC++ + ARC）与纯 ObjC 测试 driver。仅 macOS arm64。
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
CPP="$REPO/CPP"
KIT="$REPO/Mac/SevenZipKit"
ALONE="$CPP/7zip/Bundles/Alone2/b/m_arm64"
SHIM="$REPO/Mac/compat/win_compat_mac.h"
OUT=/tmp/szkit_t5; mkdir -p "$OUT"
cd "$CPP"

[ -d "$ALONE" ] || { echo "缺 Alone2 对象集：cd CPP/7zip/Bundles/Alone2 && make -f ../../cmpl_mac_arm64.mak -j8"; exit 1; }

# internal 模式（与 Alone2 ABI 对齐）。
# CXXFLAGS：含 7-Zip 头的纯 C++（Agent + SZFolderCore），-include shim。
# SZOBJCPP：ObjC++ 外观/测试，绝不含 -I CPP / shim（避 MyWindows.h `int BOOL` 撞 ObjC `bool BOOL`）。
CXXFLAGS=(-arch arm64 -O2 -DNDEBUG -D_REENTRANT -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE -fPIC -std=c++11 -I . -include "$SHIM")
SZOBJCPP=(-arch arm64 -O2 -fobjc-arc -std=c++11 -I "$KIT/include" -I "$KIT/src")

echo "==[1] 编译 Agent 7 + DLL/WorkDir + 链接桩（internal）=="
for f in Agent AgentProxy ArchiveFolder ArchiveFolderOpen UpdateCallbackAgent AgentOut ArchiveFolderOut; do
  clang++ "${CXXFLAGS[@]}" -c 7zip/UI/Agent/$f.cpp -o "$OUT/$f.o"
done
clang++ "${CXXFLAGS[@]}" -c Windows/DLL.cpp            -o "$OUT/DLL.o"
clang++ "${CXXFLAGS[@]}" -c 7zip/UI/Common/WorkDir.cpp -o "$OUT/WorkDir.o"
clang++ "${CXXFLAGS[@]}" -c "$REPO/Mac/poc/m1t5_link_stubs.cpp" -o "$OUT/m1t5_link_stubs.o"
echo "  ✓ Agent 闭环对象就绪"

echo "==[2] 编译 SevenZipKit 桥接核心 SZFolderCore.cpp（纯 C++，唯一 INITGUID 单元）=="
clang++ "${CXXFLAGS[@]}" -I "$KIT/src" -c "$KIT/src/SZFolderCore.cpp" -o "$OUT/SZFolderCore.o"
echo "  ✓ SZFolderCore.o"

echo "==[3] 编译 ObjC 外观 + 测试 driver（ObjC++/ARC，不碰 7-Zip 头）=="
clang++ "${SZOBJCPP[@]}" -x objective-c++ -c "$KIT/src/SZFolderSession.mm"  -o "$OUT/SZFolderSession.o"
clang++ "${SZOBJCPP[@]}" -x objective-c++ -c "$KIT/tests/test_szfolder.mm" -o "$OUT/test_szfolder.o"
echo "  ✓ SZFolderSession.o + test_szfolder.o"

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
  "$OUT/test_szfolder.o" "$OUT/SZFolderSession.o" "$OUT/SZFolderCore.o" \
  "$OUT/Agent.o" "$OUT/AgentProxy.o" "$OUT/ArchiveFolder.o" "$OUT/ArchiveFolderOpen.o" \
  "$OUT/UpdateCallbackAgent.o" "$OUT/AgentOut.o" "$OUT/ArchiveFolderOut.o" \
  "$OUT/DLL.o" "$OUT/WorkDir.o" "$OUT/m1t5_link_stubs.o" \
  "${ALONE_OBJS[@]}" \
  -framework Foundation -framework CoreFoundation -lz \
  -o "$OUT/test_szfolder"
echo "  ✓ $OUT/test_szfolder"

echo "==[5] 准备测试归档（复用/现造带子目录 + 中文名）=="
ARC=/tmp/agent_t5/test.7z
if [ ! -f "$ARC" ]; then
  clang++ -arch arm64 "$ALONE"/*.o -framework CoreFoundation -lz -o "$OUT/7zz"
  S="$OUT/src"; rm -rf "$S"; mkdir -p "$S/sub/deep"
  echo top > "$S/top.txt"; printf '中文内容\n' > "$S/中文.txt"
  echo inner > "$S/sub/inner.txt"; head -c 4096 /dev/urandom > "$S/sub/deep/leaf.bin"
  ( cd "$OUT" && ./7zz a test.7z src >/dev/null ); ARC="$OUT/test.7z"
fi

echo "==[6] 运行 =="
env -u DYLD_PRINT_LIBRARIES "$OUT/test_szfolder" "$ARC"
