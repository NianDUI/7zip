#!/bin/bash
# M5-T2：SZShellCommand 命令模型单测（纯 Foundation，无引擎依赖）。
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
FM="$REPO/Mac/SevenZipFM"
OUT=/tmp/szfm_shellcmd; mkdir -p "$OUT"

clang -arch arm64 -O2 -fobjc-arc -I "$FM/Shell" \
  -c "$FM/Shell/SZShellCommand.m" -o "$OUT/SZShellCommand.o"
clang -arch arm64 -O2 -fobjc-arc -I "$FM/Shell" \
  -c "$FM/tests/test_shellcmd.m" -o "$OUT/test_shellcmd.o"
clang++ -arch arm64 "$OUT/test_shellcmd.o" "$OUT/SZShellCommand.o" \
  -framework Foundation -o "$OUT/test_shellcmd"
echo "==[run]=="
"$OUT/test_shellcmd"
