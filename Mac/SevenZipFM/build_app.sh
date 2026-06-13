#!/bin/bash
# M1-T7：构建 SevenZipFM.app（单面板只读壳）。internal codecs（复用 Alone2），arm64。
# 产出可双击的 .app（窗口/双击/键盘交互需在桌面运行确认；本环境只验证编译链接 + bundle 结构）。
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
CPP="$REPO/CPP"
KIT="$REPO/Mac/SevenZipKit"
FM="$REPO/Mac/SevenZipFM"
ALONE="$CPP/7zip/Bundles/Alone2/b/m_arm64"
SHIM="$REPO/Mac/compat/win_compat_mac.h"
OUT=/tmp/szfm_app; mkdir -p "$OUT"
# .app bundle 名 = 「7-Zip」（mac 版 FM+G 合并为单一应用，整体统一此名）；可执行/Bundle ID 保持 SevenZipFM（内部）
APP="$OUT/7-Zip.app"
rm -rf "$OUT/SevenZipFM.app" "$OUT/7-Zip File Manager.app"   # 清理旧名
cd "$CPP"
[ -d "$ALONE" ] || { echo "缺 Alone2 对象集：cd CPP/7zip/Bundles/Alone2 && make -f ../../cmpl_mac_arm64.mak -j8"; exit 1; }

CXXFLAGS=(-arch arm64 -O2 -DNDEBUG -D_REENTRANT -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE -fPIC -std=c++11 -I . -include "$SHIM")
OBJC=(-arch arm64 -O2 -fobjc-arc -I "$KIT/include" -I "$KIT/src" -I "$FM/Panel" -I "$FM/App")

echo "==[1] Agent 闭环 + SevenZipKit C++ 核心 =="
for f in Agent AgentProxy ArchiveFolder ArchiveFolderOpen UpdateCallbackAgent AgentOut ArchiveFolderOut; do
  clang++ "${CXXFLAGS[@]}" -c 7zip/UI/Agent/$f.cpp -o "$OUT/$f.o"
done
clang++ "${CXXFLAGS[@]}" -c Windows/DLL.cpp -o "$OUT/DLL.o"
clang++ "${CXXFLAGS[@]}" -c 7zip/UI/Common/WorkDir.cpp -o "$OUT/WorkDir.o"
clang++ "${CXXFLAGS[@]}" -c "$REPO/Mac/SevenZipKit/platform/ZipRegistry_mac.cpp" -o "$OUT/ZipRegistry_mac.o"
clang++ "${CXXFLAGS[@]}" -I "$KIT/src" -c "$KIT/src/SZNaturalCompare.cpp" -o "$OUT/SZNaturalCompare.o"
clang++ "${CXXFLAGS[@]}" -I "$KIT/src" -c "$KIT/src/SZFolderCore.cpp"     -o "$OUT/SZFolderCore.o"
echo "  ✓"

echo "==[2] SevenZipKit ObjC + SevenZipFM（AppKit）=="
clang "${OBJC[@]}" -x objective-c++ -c "$KIT/src/SZFolderSession.mm" -o "$OUT/SZFolderSession.o"
clang "${OBJC[@]}" -x objective-c++ -c "$KIT/src/SZPanelModel.mm"    -o "$OUT/SZPanelModel.o"
clang "${OBJC[@]}" -c "$FM/Panel/SZPanelController.m" -o "$OUT/SZPanelController.o"
clang "${OBJC[@]}" -c "$FM/App/SZAppDelegate.m"       -o "$OUT/SZAppDelegate.o"
clang "${OBJC[@]}" -c "$FM/App/main.m"                -o "$OUT/main.o"
echo "  ✓"

echo "==[3] 链接可执行 =="
CONSOLE_ONLY="Main.o MainAr.o List.o BenchCon.o HashCon.o ConsoleClose.o ExtractCallbackConsole.o OpenCallbackConsole.o UpdateCallbackConsole.o PercentPrinter.o UserInputUtils.o"
ALONE_OBJS=()
for o in "$ALONE"/*.o; do
  b="$(basename "$o")"; skip=0
  for cc in $CONSOLE_ONLY; do [ "$b" = "$cc" ] && { skip=1; break; }; done
  [ "$skip" = 1 ] && continue
  ALONE_OBJS+=("$o")
done
clang++ -arch arm64 \
  "$OUT/main.o" "$OUT/SZAppDelegate.o" "$OUT/SZPanelController.o" \
  "$OUT/SZPanelModel.o" "$OUT/SZFolderSession.o" "$OUT/SZFolderCore.o" "$OUT/SZNaturalCompare.o" \
  "$OUT/Agent.o" "$OUT/AgentProxy.o" "$OUT/ArchiveFolder.o" "$OUT/ArchiveFolderOpen.o" \
  "$OUT/UpdateCallbackAgent.o" "$OUT/AgentOut.o" "$OUT/ArchiveFolderOut.o" \
  "$OUT/DLL.o" "$OUT/WorkDir.o" "$OUT/ZipRegistry_mac.o" \
  "${ALONE_OBJS[@]}" \
  -framework AppKit -framework Foundation -framework CoreFoundation \
  -framework UniformTypeIdentifiers -lz \
  -o "$OUT/SevenZipFM.bin"
echo "  ✓"

echo "==[4] 组装 .app bundle =="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$FM/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$OUT/SevenZipFM.bin" "$APP/Contents/MacOS/SevenZipFM"
chmod +x "$APP/Contents/MacOS/SevenZipFM"
codesign --force --sign - "$APP" 2>/dev/null || echo "  (ad-hoc 签名跳过)"
echo "  ✓ $APP"

echo ""
echo "===== M1-T7 构建完成 ====="
echo "结构验证："
file "$APP/Contents/MacOS/SevenZipFM" | sed 's/^/  /'
/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist" | sed 's/^/  BundleID: /'
echo ""
echo "桌面运行（需图形会话）：open \"$APP\" --args /tmp/szsort_t6/test.7z"
echo "或：\"$APP/Contents/MacOS/SevenZipFM\" /tmp/szsort_t6/test.7z"
