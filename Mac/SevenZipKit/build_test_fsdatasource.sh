#!/bin/bash
# M4-T1 复现：SZFSDataSource 列目录/排序/选择/导航/写操作单测。纯 Foundation，零引擎依赖。
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
KIT="$REPO/Mac/SevenZipKit"
OUT=/tmp/szfs_test; mkdir -p "$OUT"
OBJC=(-arch arm64 -O2 -fobjc-arc -I "$KIT/include" -I "$KIT/src")

echo "==[1] 编译（纯 Foundation，不链接 7-Zip 引擎）=="
clang "${OBJC[@]}" -c "$KIT/src/SZFolderItem.m"        -o "$OUT/SZFolderItem.o"
clang "${OBJC[@]}" -c "$KIT/src/SZFSDataSource.m"      -o "$OUT/SZFSDataSource.o"
clang "${OBJC[@]}" -c "$KIT/tests/test_fsdatasource.m" -o "$OUT/test_fsdatasource.o"
echo "  ✓"

echo "==[2] 链接（仅 Foundation）=="
clang -arch arm64 \
  "$OUT/SZFolderItem.o" "$OUT/SZFSDataSource.o" "$OUT/test_fsdatasource.o" \
  -framework Foundation -o "$OUT/test_fsdatasource"
echo "  ✓ $OUT/test_fsdatasource"

echo "==[3] 运行 =="
"$OUT/test_fsdatasource"
