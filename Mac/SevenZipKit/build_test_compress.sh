#!/bin/bash
# M3-T4/T1 复现：SZCompressCore 压缩核心端到端 + roundtrip（7zz 解压回来对照）。
# 链接策略同 build_test_extract.sh（internal codecs，复用 Alone2 对象集，排除 console-only）。
# SZFolderCore.o 仍是唯一 INITGUID 单元。仅 macOS arm64。
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
CPP="$REPO/CPP"
KIT="$REPO/Mac/SevenZipKit"
ALONE="$CPP/7zip/Bundles/Alone2/b/m_arm64"
SHIM="$REPO/Mac/compat/win_compat_mac.h"
OUT=/tmp/szkit_m3t4; mkdir -p "$OUT"
cd "$CPP"

[ -d "$ALONE" ] || { echo "缺 Alone2 对象集"; exit 1; }

CXXFLAGS=(-arch arm64 -O2 -DNDEBUG -D_REENTRANT -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE -fPIC -std=c++11 -I . -include "$SHIM")

echo "==[1] Agent 闭环 + DLL/WorkDir/ZipRegistry =="
for f in Agent AgentProxy ArchiveFolder ArchiveFolderOpen UpdateCallbackAgent AgentOut ArchiveFolderOut; do
  clang++ "${CXXFLAGS[@]}" -c 7zip/UI/Agent/$f.cpp -o "$OUT/$f.o"
done
clang++ "${CXXFLAGS[@]}" -c Windows/DLL.cpp            -o "$OUT/DLL.o"
clang++ "${CXXFLAGS[@]}" -c 7zip/UI/Common/WorkDir.cpp -o "$OUT/WorkDir.o"
clang++ "${CXXFLAGS[@]}" -c "$REPO/Mac/SevenZipKit/platform/ZipRegistry_mac.cpp" -o "$OUT/ZipRegistry_mac.o"
echo "  ✓"

echo "==[2] 桥接核心 SZNaturalCompare + SZFolderCore(INITGUID) + SZCompressCore =="
clang++ "${CXXFLAGS[@]}" -I "$KIT/src" -c "$KIT/src/SZNaturalCompare.cpp" -o "$OUT/SZNaturalCompare.o"
clang++ "${CXXFLAGS[@]}" -I "$KIT/src" -c "$KIT/src/SZFolderCore.cpp"      -o "$OUT/SZFolderCore.o"
clang++ "${CXXFLAGS[@]}" -I "$KIT/src" -c "$KIT/src/SZCompressCore.cpp"    -o "$OUT/SZCompressCore.o"
echo "  ✓"

echo "==[3] 测试 driver =="
clang++ -arch arm64 -O2 -std=c++11 -I "$KIT/src" -c "$KIT/tests/test_compress.cpp" -o "$OUT/test_compress.o"
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
  "$OUT/test_compress.o" "$OUT/SZCompressCore.o" "$OUT/SZFolderCore.o" "$OUT/SZNaturalCompare.o" \
  "$OUT/Agent.o" "$OUT/AgentProxy.o" "$OUT/ArchiveFolder.o" "$OUT/ArchiveFolderOpen.o" \
  "$OUT/UpdateCallbackAgent.o" "$OUT/AgentOut.o" "$OUT/ArchiveFolderOut.o" \
  "$OUT/DLL.o" "$OUT/WorkDir.o" "$OUT/ZipRegistry_mac.o" \
  "${ALONE_OBJS[@]}" \
  -framework Foundation -framework CoreFoundation -lz \
  -o "$OUT/test_compress"
echo "  ✓ $OUT/test_compress"

# 参照 7zz（完整 Alone2，验证 roundtrip）
clang++ -arch arm64 "$ALONE"/*.o -framework CoreFoundation -lz -o "$OUT/7zz" 2>/dev/null

echo "==[5] 造测试源树 =="
S="$OUT/src"; rm -rf "$S"; mkdir -p "$S/sub/deep"
echo "顶层" > "$S/top.txt"; printf '中文内容\n面包\n' > "$S/中文.txt"
echo "inner" > "$S/sub/inner.txt"; head -c 50000 /dev/urandom > "$S/sub/deep/leaf.bin"

FAIL=0
roundtrip() {  # $1=fmt $2=extra-args
  local fmt="$1"; shift
  rm -f "$OUT/out.$fmt"; rm -rf "$OUT/back_$fmt"
  ( cd "$OUT" && "$OUT/test_compress" "out.$fmt" src "$@" )
  ( cd "$OUT" && "$OUT/7zz" t "out.$fmt" "$@" >/dev/null 2>&1 ) && echo "  ✓ $fmt 7zz t 完整性通过" || { echo "  ✗ $fmt 完整性失败"; FAIL=1; return; }
  ( cd "$OUT" && "$OUT/7zz" x -y -o"back_$fmt" "out.$fmt" "$@" >/dev/null 2>&1 )
  if diff -r "$OUT/src" "$OUT/back_$fmt/src" >/dev/null 2>&1; then echo "  ✓ $fmt roundtrip 字节一致"; else echo "  ✗ $fmt roundtrip 不一致"; FAIL=1; fi
}

echo ""
echo "===== A) 7z 压缩 roundtrip ====="; roundtrip 7z
echo "===== B) zip 压缩 roundtrip ====="; roundtrip zip
echo "===== C) tar 压缩 roundtrip ====="; roundtrip tar
echo "===== D) 加密 7z（数据加密，错误密码应解不开）====="
rm -f "$OUT/enc.7z"; rm -rf "$OUT/back_enc" "$OUT/bad_enc"
( cd "$OUT" && "$OUT/test_compress" enc.7z src -p pw )
( cd "$OUT" && "$OUT/7zz" x -y -ppw -o"back_enc" enc.7z >/dev/null 2>&1 )
if diff -r "$OUT/src" "$OUT/back_enc/src" >/dev/null 2>&1; then echo "  ✓ 正确密码 roundtrip 一致"; else echo "  ✗ 不一致"; FAIL=1; fi
if ( cd "$OUT" && "$OUT/7zz" x -y -pwrong -o"bad_enc" enc.7z >/dev/null 2>&1 ); then echo "  ✗ 错误密码竟解出（未真加密）"; FAIL=1; else echo "  ✓ 错误密码无法解（确实加密）"; fi
echo "===== E) 加密文件名 7z（-he）====="
rm -f "$OUT/he.7z"; rm -rf "$OUT/back_he"
( cd "$OUT" && "$OUT/test_compress" he.7z src -p pw -he )
( cd "$OUT" && "$OUT/7zz" l he.7z >/dev/null 2>&1 ) && echo "  ✗ -he 应使列表需密码" || echo "  ✓ -he 加密头（无密码无法列表）"
( cd "$OUT" && "$OUT/7zz" x -y -ppw -o"back_he" he.7z >/dev/null 2>&1 )
if diff -r "$OUT/src" "$OUT/back_he/src" >/dev/null 2>&1; then echo "  ✓ -he roundtrip 字节一致"; else echo "  ✗ -he 不一致"; FAIL=1; fi

echo "===== F) 分卷压缩（每卷 20000B → .7z.001/.002…）+ 合并解压 ====="
rm -f "$OUT"/vol.7z.*; rm -rf "$OUT/back_vol"
( cd "$OUT" && "$OUT/test_compress" vol.7z src -v 20000 )
NVOL=$(ls "$OUT"/vol.7z.* 2>/dev/null | wc -l | tr -d ' ')
echo "  生成卷数：$NVOL"
if [ "$NVOL" -ge 2 ]; then echo "  ✓ 已分卷（≥2 卷）"; else echo "  ✗ 未分卷"; FAIL=1; fi
( cd "$OUT" && "$OUT/7zz" x -y -o"back_vol" vol.7z.001 >/dev/null 2>&1 )
if diff -r "$OUT/src" "$OUT/back_vol/src" >/dev/null 2>&1; then echo "  ✓ 从 .001 合并解压字节一致"; else echo "  ✗ 合并解压不一致"; FAIL=1; fi

echo "===== G) 符号链接保留（storeSymlinks 默认，T3）====="
rm -rf "$OUT/lnksrc" "$OUT/back_lnk"; mkdir -p "$OUT/lnksrc"
echo "real content" > "$OUT/lnksrc/real.txt"
( cd "$OUT/lnksrc" && ln -s real.txt link.txt )
rm -f "$OUT/lnk.7z"
( cd "$OUT" && "$OUT/test_compress" lnk.7z lnksrc >/dev/null )
( cd "$OUT" && "$OUT/7zz" x -y -snl -o"back_lnk" lnk.7z >/dev/null 2>&1 )
if [ -L "$OUT/back_lnk/lnksrc/link.txt" ]; then echo "  ✓ 符号链接保留为链接（未解引用）"; else echo "  ✗ 符号链接被解引用成普通文件"; FAIL=1; fi

echo ""
[ "$FAIL" = 0 ] && echo "===== M3-T4 压缩核心全部通过 =====" || { echo "===== 有用例失败 ====="; exit 1; }
