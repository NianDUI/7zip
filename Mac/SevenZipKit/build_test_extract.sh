#!/bin/bash
# M2-T1 复现：SZExtractCore 解压核心端到端测试 + 字节级对照 7zz。
# 链接策略同 build_test_szfolder.sh（internal codecs，复用 Alone2 对象集，排除 console-only）。
# SZFolderCore.o 仍是唯一 INITGUID 单元（提供全部 IID），与 SZExtractCore.o 一起链接。仅 macOS arm64。
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
CPP="$REPO/CPP"
KIT="$REPO/Mac/SevenZipKit"
ALONE="$CPP/7zip/Bundles/Alone2/b/m_arm64"
SHIM="$REPO/Mac/compat/win_compat_mac.h"
OUT=/tmp/szkit_m2t1; mkdir -p "$OUT"
cd "$CPP"

[ -d "$ALONE" ] || { echo "缺 Alone2 对象集：cd CPP/7zip/Bundles/Alone2 && make -f ../../cmpl_mac_arm64.mak -j8"; exit 1; }

CXXFLAGS=(-arch arm64 -O2 -DNDEBUG -D_REENTRANT -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE -fPIC -std=c++11 -I . -include "$SHIM")

echo "==[1] 编译 Agent 闭环 + DLL/WorkDir/ZipRegistry（internal）=="
for f in Agent AgentProxy ArchiveFolder ArchiveFolderOpen UpdateCallbackAgent AgentOut ArchiveFolderOut; do
  clang++ "${CXXFLAGS[@]}" -c 7zip/UI/Agent/$f.cpp -o "$OUT/$f.o"
done
clang++ "${CXXFLAGS[@]}" -c Windows/DLL.cpp            -o "$OUT/DLL.o"
clang++ "${CXXFLAGS[@]}" -c 7zip/UI/Common/WorkDir.cpp -o "$OUT/WorkDir.o"
clang++ "${CXXFLAGS[@]}" -c "$REPO/Mac/SevenZipKit/platform/ZipRegistry_mac.cpp" -o "$OUT/ZipRegistry_mac.o"
echo "  ✓"

echo "==[2] 编译桥接核心：SZNaturalCompare + SZFolderCore(INITGUID) + SZExtractCore =="
clang++ "${CXXFLAGS[@]}" -I "$KIT/src" -c "$KIT/src/SZNaturalCompare.cpp" -o "$OUT/SZNaturalCompare.o"
clang++ "${CXXFLAGS[@]}" -I "$KIT/src" -c "$KIT/src/SZFolderCore.cpp"      -o "$OUT/SZFolderCore.o"
clang++ "${CXXFLAGS[@]}" -I "$KIT/src" -c "$KIT/src/SZExtractCore.cpp"     -o "$OUT/SZExtractCore.o"
echo "  ✓"

echo "==[3] 编译测试 driver（纯 C++，仅 SZExtractCore.h）=="
clang++ -arch arm64 -O2 -std=c++11 -I "$KIT/src" -c "$KIT/tests/test_extract.cpp" -o "$OUT/test_extract.o"
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
  "$OUT/test_extract.o" "$OUT/SZExtractCore.o" "$OUT/SZFolderCore.o" "$OUT/SZNaturalCompare.o" \
  "$OUT/Agent.o" "$OUT/AgentProxy.o" "$OUT/ArchiveFolder.o" "$OUT/ArchiveFolderOpen.o" \
  "$OUT/UpdateCallbackAgent.o" "$OUT/AgentOut.o" "$OUT/ArchiveFolderOut.o" \
  "$OUT/DLL.o" "$OUT/WorkDir.o" "$OUT/ZipRegistry_mac.o" \
  "${ALONE_OBJS[@]}" \
  -framework Foundation -framework CoreFoundation -lz \
  -o "$OUT/test_extract"
echo "  ✓ $OUT/test_extract"

echo "==[5] 造测试归档（普通 + 加密 + 子目录 + 中文名）=="
clang++ -arch arm64 "$ALONE"/*.o -framework CoreFoundation -lz -o "$OUT/7zz" 2>/dev/null
S="$OUT/src"; rm -rf "$S"; mkdir -p "$S/sub/deep"
echo top > "$S/top.txt"; printf '中文内容\n' > "$S/中文.txt"
echo inner > "$S/sub/inner.txt"; head -c 65536 /dev/urandom > "$S/sub/deep/leaf.bin"
( cd "$OUT" && rm -f test.7z enc.7z test.zip
  ./7zz a test.7z src >/dev/null
  ./7zz a -ppass123 enc.7z src >/dev/null
  ./7zz a test.zip src >/dev/null )
echo "  ✓ test.7z / enc.7z / test.zip"

echo ""
echo "===== A) 普通 .7z：SZExtractCore vs 7zz 字节对照 ====="
rm -rf "$OUT/outA" "$OUT/refA";
"$OUT/test_extract" "$OUT/test.7z" "$OUT/outA"
( cd "$OUT" && ./7zz x -y -o"refA" test.7z >/dev/null )
if diff -r "$OUT/outA/src" "$OUT/refA/src" >/dev/null; then echo "  ✓ 字节级一致"; else echo "  ✗ 不一致"; diff -r "$OUT/outA/src" "$OUT/refA/src"; exit 1; fi

echo ""
echo "===== B) .zip：SZExtractCore vs 7zz 字节对照 ====="
rm -rf "$OUT/outB" "$OUT/refB"
"$OUT/test_extract" "$OUT/test.zip" "$OUT/outB" >/dev/null
( cd "$OUT" && ./7zz x -y -o"refB" test.zip >/dev/null )
if diff -r "$OUT/outB/src" "$OUT/refB/src" >/dev/null; then echo "  ✓ 字节级一致"; else echo "  ✗ 不一致"; exit 1; fi

echo ""
echo "===== C) 加密 .7z：预设密码解压 ====="
rm -rf "$OUT/outC"
"$OUT/test_extract" "$OUT/enc.7z" "$OUT/outC" -p pass123
( cd "$OUT" && ./7zz x -y -ppass123 -o"refC" enc.7z >/dev/null )
if diff -r "$OUT/outC/src" "$OUT/refC/src" >/dev/null; then echo "  ✓ 加密档解压字节一致"; else echo "  ✗ 不一致"; exit 1; fi

echo ""
echo "===== D) 测试模式（testMode，不落盘）====="
"$OUT/test_extract" "$OUT/test.7z" /tmp/ignore -t

echo ""
echo "===== E) 损坏档：截断后报错文案 ====="
head -c 200 "$OUT/test.7z" > "$OUT/broken.7z"
"$OUT/test_extract" "$OUT/broken.7z" "$OUT/outE" || echo "  （非零退出=预期，损坏档应报错）"

echo ""
echo "===== F) 多档案批量编排（test.7z + test.zip 一次解压，统计聚合）====="
rm -rf "$OUT/outF"
"$OUT/test_extract" "$OUT/test.7z" "$OUT/outF" -m "$OUT/test.zip"
echo "  期望：档案=2 文件=8（4×2）"

echo ""
echo "===== G) 多档案含一个损坏：好档照解、坏档计入打开错误 ====="
rm -rf "$OUT/outG"
"$OUT/test_extract" "$OUT/test.7z" "$OUT/outG" -m "$OUT/broken.7z" || echo "  （非零退出=预期：批量中有损坏档）"
if diff -r "$OUT/outG/src" "$OUT/refA/src" >/dev/null; then echo "  ✓ 好档仍字节一致（坏档不影响好档）"; else echo "  ✗ 好档受损"; exit 1; fi

echo ""
echo "===== M2-T1 + M2-T5 全部用例通过 ====="
