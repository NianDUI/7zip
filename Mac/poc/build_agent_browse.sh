#!/bin/bash
# M1-T5 复现：经 Agent 层 CArchiveFolderManager::OpenFolderFile 做归档"文件夹化"导航端到端验证。
# 对应 docs/M1-T5-agent-browse-report.md。internal codecs（复用 7zz/Alone2 全格式对象集）。
# 需先有 Alone2 对象集（make -f cmpl_mac_arm64.mak 于 Bundles/Alone2）。仅 macOS arm64。
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
CPP="$REPO/CPP"
ALONE="$CPP/7zip/Bundles/Alone2/b/m_arm64"
SHIM="$REPO/Mac/compat/win_compat_mac.h"
OUT=/tmp/agent_t5; mkdir -p "$OUT"
cd "$CPP"

[ -d "$ALONE" ] || { echo "缺 Alone2 对象集：先 cd CPP/7zip/Bundles/Alone2 && make -f ../../cmpl_mac_arm64.mak -j8"; exit 1; }

# internal 模式编译标志（与 Alone2 ABI 对齐：不带 -DZ7_EXTERNAL_CODECS / 不带 -DZ7_ST）
FLAGS=(-arch arm64 -O2 -DNDEBUG -D_REENTRANT -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE -fPIC -std=c++11 -I . -include "$SHIM")

# Agent 全 7 文件：读路径 5 + 写路径 2（AgentOut/ArchiveFolderOut）。
# 写路径 2 文件虽 M1 只读不直接调用，但 CAgent/CAgentFolder 的 vtable 含其虚方法，
# `new CAgent` 实例化强制要求这些符号存在（链接期 vtable 完整性，见 M1-T5 报告"重要修正"）。
AGENT_SRCS=(Agent AgentProxy ArchiveFolder ArchiveFolderOpen UpdateCallbackAgent AgentOut ArchiveFolderOut)

echo "==[1/4] 编译 Agent 全 7 文件（internal，读5+写2）=="
for f in "${AGENT_SRCS[@]}"; do
  clang++ "${FLAGS[@]}" -c 7zip/UI/Agent/$f.cpp -o "$OUT/$f.o"
  echo "  ✓ $f.o"
done

# Agent 读路径还依赖两个非 console-Alone2 的 UI/Common/平台符号（端到端链接揭示）：
#   Windows/DLL.cpp        → NWindows::NDLL::MyGetModuleFileName（ArchiveFolderOpen 取图标路径用）
#   UI/Common/WorkDir.cpp  → CWorkDirTempFile（写路径，vtable 完整性）
echo "==[1b] 编译 Agent 链接闭环补充：DLL / WorkDir =="
clang++ "${FLAGS[@]}" -c Windows/DLL.cpp            -o "$OUT/DLL.o";     echo "  ✓ DLL.o"
clang++ "${FLAGS[@]}" -c 7zip/UI/Common/WorkDir.cpp -o "$OUT/WorkDir.o"; echo "  ✓ WorkDir.o"
echo "==[1c] 编译 M1-T5 链接桩（NWorkDir::CInfo / CompareFileNames，归属见文件头）=="
clang++ "${FLAGS[@]}" -c "$REPO/Mac/poc/m1t5_link_stubs.cpp" -o "$OUT/m1t5_link_stubs.o"; echo "  ✓ m1t5_link_stubs.o"

echo "==[2/4] 编译 agent_browse.cpp（唯一 INITGUID 单元）=="
clang++ "${FLAGS[@]}" -c "$REPO/Mac/poc/agent_browse.cpp" -o "$OUT/agent_browse.o"

echo "==[3/4] 链接（Agent 7 .o + Alone2 .o 排除 console-only）=="
# 排除 console-only 对象：它们引用 console 全局（g_ErrStream/g_StdStream 定义在 MainAr.o）
# 且非引擎/UI-Common/Agent 闭环所需。Main.o 另含重复 IID 实体（与 agent_browse 的 INITGUID 冲突）。
CONSOLE_ONLY="Main.o MainAr.o List.o BenchCon.o HashCon.o ConsoleClose.o \
ExtractCallbackConsole.o OpenCallbackConsole.o UpdateCallbackConsole.o PercentPrinter.o UserInputUtils.o"
ALONE_OBJS=()
for o in "$ALONE"/*.o; do
  b="$(basename "$o")"
  skip=0; for c in $CONSOLE_ONLY; do [ "$b" = "$c" ] && skip=1; done
  [ "$skip" = 1 ] && continue
  ALONE_OBJS+=("$o")
done
clang++ -arch arm64 \
  "$OUT/agent_browse.o" \
  "$OUT/Agent.o" "$OUT/AgentProxy.o" "$OUT/ArchiveFolder.o" "$OUT/ArchiveFolderOpen.o" \
  "$OUT/UpdateCallbackAgent.o" "$OUT/AgentOut.o" "$OUT/ArchiveFolderOut.o" \
  "$OUT/DLL.o" "$OUT/WorkDir.o" "$OUT/m1t5_link_stubs.o" \
  "${ALONE_OBJS[@]}" \
  -framework CoreFoundation -lz \
  -o "$OUT/agent_browse"
echo "  ✓ $OUT/agent_browse"

echo "==[3b] 准备带子目录测试归档（缺则链 7zz 现造）=="
if [ ! -f "$OUT/test.7z" ]; then
  # 全量 Alone2 .o 链 7zz（含 Main/MainAr），仅用于造测试归档
  clang++ -arch arm64 "$ALONE"/*.o -framework CoreFoundation -lz -o "$OUT/7zz"
  S="$OUT/src"; rm -rf "$S"; mkdir -p "$S/sub/deep"
  echo "顶层文件" > "$S/top.txt"
  printf '中文内容\n' > "$S/中文.txt"
  echo "子目录文件" > "$S/sub/inner.txt"
  head -c 4096 /dev/urandom > "$S/sub/deep/leaf.bin"
  ( cd "$OUT" && ./7zz a test.7z src >/dev/null )
  echo "  ✓ 造归档：$OUT/test.7z（sub/ + sub/deep/ + 中文名）"
fi

echo "==[4/4] 运行端到端验证 =="
env -u DYLD_PRINT_LIBRARIES "$OUT/agent_browse" "$OUT/test.7z"
