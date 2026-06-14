#!/bin/bash
# M3-T5 复现：归档内增删改（SZFolderCore 写方法 → CAgentFolder IFolderOperations）。
# 链接同 build_test_szfolder.sh（含 Agent 写路径 AgentOut/ArchiveFolderOut）。仅 macOS arm64。
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
CPP="$REPO/CPP"; KIT="$REPO/Mac/SevenZipKit"
ALONE="$CPP/7zip/Bundles/Alone2/b/m_arm64"
SHIM="$REPO/Mac/compat/win_compat_mac.h"
OUT=/tmp/szkit_m3t5; mkdir -p "$OUT"; cd "$CPP"
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

echo "==[2] SZNaturalCompare + SZFolderCore(INITGUID, 含写方法) + driver =="
clang++ "${CXXFLAGS[@]}" -I "$KIT/src" -c "$KIT/src/SZNaturalCompare.cpp" -o "$OUT/SZNaturalCompare.o"
clang++ "${CXXFLAGS[@]}" -I "$KIT/src" -c "$KIT/src/SZFolderCore.cpp"      -o "$OUT/SZFolderCore.o"
clang++ -arch arm64 -O2 -std=c++11 -I "$KIT/src" -c "$KIT/tests/test_edit.cpp" -o "$OUT/test_edit.o"
echo "  ✓"

echo "==[3] 链接 =="
CONSOLE_ONLY="Main.o MainAr.o List.o BenchCon.o HashCon.o ConsoleClose.o ExtractCallbackConsole.o OpenCallbackConsole.o UpdateCallbackConsole.o PercentPrinter.o UserInputUtils.o"
ALONE_OBJS=()
for o in "$ALONE"/*.o; do
  b="$(basename "$o")"; skip=0
  for c in $CONSOLE_ONLY; do [ "$b" = "$c" ] && { skip=1; break; }; done
  [ "$skip" = 1 ] && continue
  ALONE_OBJS+=("$o")
done
clang++ -arch arm64 \
  "$OUT/test_edit.o" "$OUT/SZFolderCore.o" "$OUT/SZNaturalCompare.o" \
  "$OUT/Agent.o" "$OUT/AgentProxy.o" "$OUT/ArchiveFolder.o" "$OUT/ArchiveFolderOpen.o" \
  "$OUT/UpdateCallbackAgent.o" "$OUT/AgentOut.o" "$OUT/ArchiveFolderOut.o" \
  "$OUT/DLL.o" "$OUT/WorkDir.o" "$OUT/ZipRegistry_mac.o" \
  "${ALONE_OBJS[@]}" \
  -framework Foundation -framework CoreFoundation -lz \
  -o "$OUT/test_edit"
echo "  ✓ $OUT/test_edit"
clang++ -arch arm64 "$ALONE"/*.o -framework CoreFoundation -lz -o "$OUT/7zz" 2>/dev/null

echo "==[4] 造测试归档 =="
S="$OUT/src"; rm -rf "$S"; mkdir -p "$S/sub"
echo top > "$S/top.txt"; printf '中文\n' > "$S/中文.txt"; echo inner > "$S/sub/inner.txt"
echo "新文件内容" > "$OUT/newfile.txt"
mk() { rm -f "$OUT/t.7z"; ( cd "$OUT" && "$OUT/7zz" a t.7z src >/dev/null ); }

FAIL=0
inArc() { "$OUT/7zz" l "$OUT/t.7z" 2>/dev/null | grep -q "$1"; }

echo ""
echo "===== A) 删除：删 src/top.txt ====="
mk; "$OUT/test_edit" "$OUT/t.7z" list >/dev/null
# 进入 src 层删除——driver 在根层操作，故先把 top.txt 提到根：改测删根层项。重造扁平归档
rm -f "$OUT/t.7z"; ( cd "$OUT/src" && "$OUT/7zz" a "$OUT/t.7z" top.txt 中文.txt sub >/dev/null )
"$OUT/test_edit" "$OUT/t.7z" delete top.txt
if inArc "top.txt"; then echo "  ✗ top.txt 仍在"; FAIL=1; else echo "  ✓ top.txt 已删除"; fi
if inArc "中文.txt"; then echo "  ✓ 其它项保留"; else echo "  ✗ 误删其它"; FAIL=1; fi

echo "===== B) 添加：add newfile.txt ====="
"$OUT/test_edit" "$OUT/t.7z" add "$OUT/newfile.txt"
if inArc "newfile.txt"; then echo "  ✓ newfile.txt 已加入"; else echo "  ✗ 未加入"; FAIL=1; fi

echo "===== C) 新建文件夹：mkdir newdir ====="
"$OUT/test_edit" "$OUT/t.7z" mkdir newdir
if inArc "newdir"; then echo "  ✓ newdir 已创建"; else echo "  ✗ 未创建"; FAIL=1; fi

echo "===== D) 重命名：中文.txt → renamed.txt ====="
"$OUT/test_edit" "$OUT/t.7z" rename 中文.txt renamed.txt
if inArc "renamed.txt" && ! inArc "中文.txt"; then echo "  ✓ 重命名成功"; else echo "  ✗ 重命名失败"; FAIL=1; fi

echo "===== E) 改后归档完整性（7zz t）====="
( cd "$OUT" && "$OUT/7zz" t t.7z >/dev/null 2>&1 ) && echo "  ✓ 归档完整" || { echo "  ✗ 归档损坏"; FAIL=1; }

echo ""
[ "$FAIL" = 0 ] && echo "===== M3-T5 归档内增删改全部通过 =====" || { echo "===== 有用例失败 ====="; exit 1; }
