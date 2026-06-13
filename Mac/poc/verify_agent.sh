#!/bin/bash
# M1-T3 复现：编译 Agent 层读路径 5 文件（macOS arm64）。对应 docs/M1-T3-agent-gate-report.md。
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO/CPP"
OUT=/tmp/agent_test; rm -rf "$OUT"; mkdir -p "$OUT"
SHIM="$REPO/Mac/compat/win_compat_mac.h"
FLAGS=(-arch arm64 -O2 -c -DNDEBUG -D_REENTRANT -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE -DZ7_EXTERNAL_CODECS -fPIC -std=c++11 -I . -include "$SHIM")

echo "== Agent 读路径 5 文件（M1 只读浏览必需）=="
ok=1
for f in Agent AgentProxy ArchiveFolder ArchiveFolderOpen UpdateCallbackAgent; do
  if clang++ "${FLAGS[@]}" 7zip/UI/Agent/$f.cpp -o "$OUT/$f.o" 2>"$OUT/$f.err"; then
    echo "  ✓ $f.o"
  else
    echo "  ✗ $f"; grep "error:" "$OUT/$f.err" | head -3; ok=0
  fi
done
[ "$ok" = 1 ] && echo "== M1-T3 通过：Agent 读路径全部编译通过 ==" || { echo "FAIL"; exit 1; }
