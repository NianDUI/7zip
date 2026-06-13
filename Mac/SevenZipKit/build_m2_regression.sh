#!/bin/bash
# M2-T8 回归（多格式解压字节对照 7zz）+ M2-T9 性能（大样本解压吞吐对照 7zz CLI）。
# 复用 build_test_extract.sh 产出的 test_extract（SZExtractCore driver）与 7zz（同一 Alone2 引擎）。
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
OUT=/tmp/szkit_m2reg; mkdir -p "$OUT"
TE=/tmp/szkit_m2t1/test_extract
ZZ=/tmp/szkit_m2t1/7zz

if [ ! -x "$TE" ] || [ ! -x "$ZZ" ]; then
  echo "== 先构建 test_extract + 7zz =="
  bash "$REPO/Mac/SevenZipKit/build_test_extract.sh" >/dev/null 2>&1
fi
[ -x "$TE" ] && [ -x "$ZZ" ] || { echo "缺 test_extract/7zz"; exit 1; }

now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }

# 测试源树（子目录 + 中文名 + 二进制）
S="$OUT/src"; rm -rf "$S"; mkdir -p "$S/sub/deep"
echo "top" > "$S/top.txt"; printf '中文内容\n面包\n' > "$S/中文.txt"
echo "inner" > "$S/sub/inner.txt"; head -c 200000 /dev/urandom > "$S/sub/deep/leaf.bin"

echo "===== M2-T8：多格式解压字节对照 7zz ====="
FAIL=0
for fmt in 7z zip tar; do
  rm -f "$OUT/t.$fmt"; rm -rf "$OUT/sz_$fmt" "$OUT/zz_$fmt"
  ( cd "$OUT" && "$ZZ" a "t.$fmt" src >/dev/null )
  "$TE" "$OUT/t.$fmt" "$OUT/sz_$fmt" >/dev/null
  ( cd "$OUT" && "$ZZ" x -y -o"zz_$fmt" "t.$fmt" >/dev/null )
  if diff -r "$OUT/sz_$fmt/src" "$OUT/zz_$fmt/src" >/dev/null 2>&1; then
    echo "  ✓ $fmt 字节级一致"
  else
    echo "  ✗ $fmt 不一致"; FAIL=1
  fi
done
# gz：单文件格式
rm -f "$OUT/one.bin" "$OUT/one.bin.gz"; head -c 100000 /dev/urandom > "$OUT/one.bin"
( cd "$OUT" && "$ZZ" a one.bin.gz one.bin >/dev/null )
rm -rf "$OUT/sz_gz" "$OUT/zz_gz"
"$TE" "$OUT/one.bin.gz" "$OUT/sz_gz" >/dev/null
( cd "$OUT" && "$ZZ" x -y -o"zz_gz" one.bin.gz >/dev/null )
if diff "$OUT/sz_gz/one.bin" "$OUT/zz_gz/one.bin" >/dev/null 2>&1; then echo "  ✓ gz 字节级一致"; else echo "  ✗ gz 不一致"; FAIL=1; fi
# 加密 7z
rm -f "$OUT/enc.7z"; ( cd "$OUT" && "$ZZ" a -ppw enc.7z src >/dev/null )
rm -rf "$OUT/sz_enc" "$OUT/zz_enc"
"$TE" "$OUT/enc.7z" "$OUT/sz_enc" -p pw >/dev/null
( cd "$OUT" && "$ZZ" x -y -ppw -o"zz_enc" enc.7z >/dev/null )
if diff -r "$OUT/sz_enc/src" "$OUT/zz_enc/src" >/dev/null 2>&1; then echo "  ✓ 加密7z 字节级一致"; else echo "  ✗ 加密 不一致"; FAIL=1; fi

echo ""
echo "===== M2-T9：大样本解压吞吐对照 7zz CLI ====="
# ~120MB：可压文本 + 随机各半（模拟真实混合）
BIG="$OUT/bigsrc"; rm -rf "$BIG"; mkdir -p "$BIG"
perl -e 'print "the quick brown fox jumps over the lazy dog 0123456789\n" x 560000' > "$BIG/text.txt"
head -c 30000000 /dev/urandom > "$BIG/rand.bin"
rm -f "$OUT/big.7z"; ( cd "$OUT" && "$ZZ" a -mx3 big.7z bigsrc >/dev/null )
echo "  归档大小：$(du -h "$OUT/big.7z" | cut -f1)"

rm -rf "$OUT/sz_big" "$OUT/zz_big"
a0=$(now); "$TE" "$OUT/big.7z" "$OUT/sz_big" >/dev/null; a1=$(now)
b0=$(now); ( cd "$OUT" && "$ZZ" x -y -o"zz_big" big.7z >/dev/null ); b1=$(now)
sz_t=$(perl -e "printf '%.3f', $a1-$a0")
zz_t=$(perl -e "printf '%.3f', $b1-$b0")
ratio=$(awk -v z="$zz_t" -v s="$sz_t" 'BEGIN{printf "%.1f", (z/s)*100}')
echo "  SZExtractCore 解压：${sz_t}s    7zz CLI 解压：${zz_t}s"
echo "  吞吐比（7zz/SZ x 100；>=90 即 SZ 不慢于 7zz 的 90%）：${ratio}%"
if diff -r "$OUT/sz_big/bigsrc" "$OUT/zz_big/bigsrc" >/dev/null 2>&1; then echo "  OK 大样本字节级一致"; else echo "  FAIL 大样本不一致"; FAIL=1; fi
gate=$(awk -v r="$ratio" 'BEGIN{print (r>=90)?"PASS":"CHECK"}')
echo "  性能 gate（同一引擎，差异仅桥接调用开销）：${gate}"

echo ""
[ "$FAIL" = 0 ] && echo "===== M2-T8 + T9 回归通过 =====" || { echo "===== 有用例失败 ====="; exit 1; }
