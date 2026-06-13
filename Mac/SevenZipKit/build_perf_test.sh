#!/bin/bash
# M1-T9 复现：SZFolderCore 大条目数性能压测（打开延迟/内存峰值/排序耗时）。纯 C++，arm64。
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
CPP="$REPO/CPP"
KIT="$REPO/Mac/SevenZipKit"
ALONE="$CPP/7zip/Bundles/Alone2/b/m_arm64"
SHIM="$REPO/Mac/compat/win_compat_mac.h"
OUT=/tmp/szperf_build; mkdir -p "$OUT"
cd "$CPP"
[ -d "$ALONE" ] || { echo "缺 Alone2 对象集"; exit 1; }

CXXFLAGS=(-arch arm64 -O2 -DNDEBUG -D_REENTRANT -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE -fPIC -std=c++11 -I . -include "$SHIM")

echo "==[1] 编译 Agent 闭环 + SevenZipKit C++ 核心 + perf_test =="
for f in Agent AgentProxy ArchiveFolder ArchiveFolderOpen UpdateCallbackAgent AgentOut ArchiveFolderOut; do
  clang++ "${CXXFLAGS[@]}" -c 7zip/UI/Agent/$f.cpp -o "$OUT/$f.o"
done
clang++ "${CXXFLAGS[@]}" -c Windows/DLL.cpp -o "$OUT/DLL.o"
clang++ "${CXXFLAGS[@]}" -c 7zip/UI/Common/WorkDir.cpp -o "$OUT/WorkDir.o"
clang++ "${CXXFLAGS[@]}" -c "$REPO/Mac/SevenZipKit/platform/ZipRegistry_mac.cpp" -o "$OUT/ZipRegistry_mac.o"
clang++ "${CXXFLAGS[@]}" -I "$KIT/src" -c "$KIT/src/SZNaturalCompare.cpp" -o "$OUT/SZNaturalCompare.o"
clang++ "${CXXFLAGS[@]}" -I "$KIT/src" -c "$KIT/src/SZFolderCore.cpp"     -o "$OUT/SZFolderCore.o"
clang++ "${CXXFLAGS[@]}" -I "$KIT/src" -c "$KIT/tests/perf_test.cpp"      -o "$OUT/perf_test.o"
echo "  ✓"

echo "==[2] 链接 =="
CONSOLE_ONLY="Main.o MainAr.o List.o BenchCon.o HashCon.o ConsoleClose.o ExtractCallbackConsole.o OpenCallbackConsole.o UpdateCallbackConsole.o PercentPrinter.o UserInputUtils.o"
ALONE_OBJS=()
for o in "$ALONE"/*.o; do
  b="$(basename "$o")"; skip=0
  for cc in $CONSOLE_ONLY; do [ "$b" = "$cc" ] && { skip=1; break; }; done
  [ "$skip" = 1 ] && continue
  ALONE_OBJS+=("$o")
done
clang++ -arch arm64 \
  "$OUT/perf_test.o" "$OUT/SZFolderCore.o" "$OUT/SZNaturalCompare.o" \
  "$OUT/Agent.o" "$OUT/AgentProxy.o" "$OUT/ArchiveFolder.o" "$OUT/ArchiveFolderOpen.o" \
  "$OUT/UpdateCallbackAgent.o" "$OUT/AgentOut.o" "$OUT/ArchiveFolderOut.o" \
  "$OUT/DLL.o" "$OUT/WorkDir.o" "$OUT/ZipRegistry_mac.o" \
  "${ALONE_OBJS[@]}" \
  -framework CoreFoundation -lz \
  -o "$OUT/perf_test"
echo "  ✓ $OUT/perf_test"

echo "==[3] 运行各档位（存在哪个测哪个）=="
for arc in /tmp/szperf/flat10000.7z /tmp/szperf/flat100000.7z /tmp/szperf/flat1000000.7z; do
  [ -f "$arc" ] && { env -u DYLD_PRINT_LIBRARIES "$OUT/perf_test" "$arc"; echo; }
done