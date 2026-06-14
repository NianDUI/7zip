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
OBJC=(-arch arm64 -O2 -fobjc-arc -I "$KIT/include" -I "$KIT/src" -I "$FM/Panel" -I "$FM/App" -I "$FM/Progress" -I "$FM/Dialogs" -I "$FM/Util" -I "$FM/Shell")

echo "==[1] Agent 闭环 + SevenZipKit C++ 核心 =="
for f in Agent AgentProxy ArchiveFolder ArchiveFolderOpen UpdateCallbackAgent AgentOut ArchiveFolderOut; do
  clang++ "${CXXFLAGS[@]}" -c 7zip/UI/Agent/$f.cpp -o "$OUT/$f.o"
done
clang++ "${CXXFLAGS[@]}" -c Windows/DLL.cpp -o "$OUT/DLL.o"
clang++ "${CXXFLAGS[@]}" -c 7zip/UI/Common/WorkDir.cpp -o "$OUT/WorkDir.o"
clang++ "${CXXFLAGS[@]}" -c "$REPO/Mac/SevenZipKit/platform/ZipRegistry_mac.cpp" -o "$OUT/ZipRegistry_mac.o"
clang++ "${CXXFLAGS[@]}" -I "$KIT/src" -c "$KIT/src/SZNaturalCompare.cpp" -o "$OUT/SZNaturalCompare.o"
clang++ "${CXXFLAGS[@]}" -I "$KIT/src" -c "$KIT/src/SZFolderCore.cpp"     -o "$OUT/SZFolderCore.o"
clang++ "${CXXFLAGS[@]}" -I "$KIT/src" -c "$KIT/src/SZExtractCore.cpp"    -o "$OUT/SZExtractCore.o"
clang++ "${CXXFLAGS[@]}" -I "$KIT/src" -c "$KIT/src/SZCompressCore.cpp"   -o "$OUT/SZCompressCore.o"
clang++ "${CXXFLAGS[@]}" -I "$KIT/src" -c "$KIT/src/SZHashCore.cpp"       -o "$OUT/SZHashCore.o"
echo "  ✓"

echo "==[2] SevenZipKit ObjC + SevenZipFM（AppKit）=="
clang "${OBJC[@]}" -x objective-c++ -c "$KIT/src/SZFolderSession.mm"   -o "$OUT/SZFolderSession.o"
clang "${OBJC[@]}" -x objective-c++ -c "$KIT/src/SZPanelModel.mm"      -o "$OUT/SZPanelModel.o"
clang "${OBJC[@]}" -c "$KIT/src/SZFolderItem.m"                        -o "$OUT/SZFolderItem.o"
clang "${OBJC[@]}" -c "$KIT/src/SZFSDataSource.m"                      -o "$OUT/SZFSDataSource.o"
clang "${OBJC[@]}" -std=c++11 -x objective-c++ -c "$KIT/src/SZArchiveExtractor.mm" -o "$OUT/SZArchiveExtractor.o"
clang "${OBJC[@]}" -std=c++11 -x objective-c++ -c "$KIT/src/SZArchiveCompressor.mm" -o "$OUT/SZArchiveCompressor.o"
clang "${OBJC[@]}" -std=c++11 -x objective-c++ -c "$KIT/src/SZHashCalculator.mm" -o "$OUT/SZHashCalculator.o"
clang "${OBJC[@]}" -c "$FM/Panel/SZPanelController.m"            -o "$OUT/SZPanelController.o"
clang "${OBJC[@]}" -c "$FM/Progress/SZProgressWindowController.m" -o "$OUT/SZProgressWindowController.o"
clang "${OBJC[@]}" -c "$FM/Dialogs/SZExtractDialogController.m"   -o "$OUT/SZExtractDialogController.o"
clang "${OBJC[@]}" -c "$FM/Dialogs/SZCompressDialogController.m"  -o "$OUT/SZCompressDialogController.o"
clang "${OBJC[@]}" -c "$FM/Dialogs/SZHashResultController.m"     -o "$OUT/SZHashResultController.o"
clang "${OBJC[@]}" -c "$FM/Shell/SZShellCommand.m"              -o "$OUT/SZShellCommand.o"
clang "${OBJC[@]}" -c "$FM/Finder/SZFinderSync.m"              -o "$OUT/SZFinderSync.o"
clang "${OBJC[@]}" -c "$FM/Util/SZQuarantine.m"                  -o "$OUT/SZQuarantine.o"
clang "${OBJC[@]}" -c "$FM/App/SZAppDelegate.m"                  -o "$OUT/SZAppDelegate.o"
clang "${OBJC[@]}" -c "$FM/App/main.m"                           -o "$OUT/main.o"
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
  "$OUT/main.o" "$OUT/SZAppDelegate.o" "$OUT/SZPanelController.o" "$OUT/SZProgressWindowController.o" \
  "$OUT/SZExtractDialogController.o" "$OUT/SZCompressDialogController.o" "$OUT/SZHashResultController.o" "$OUT/SZShellCommand.o" "$OUT/SZQuarantine.o" \
  "$OUT/SZPanelModel.o" "$OUT/SZFSDataSource.o" "$OUT/SZFolderItem.o" "$OUT/SZFolderSession.o" "$OUT/SZFolderCore.o" "$OUT/SZNaturalCompare.o" \
  "$OUT/SZArchiveExtractor.o" "$OUT/SZExtractCore.o" \
  "$OUT/SZArchiveCompressor.o" "$OUT/SZCompressCore.o" \
  "$OUT/SZHashCalculator.o" "$OUT/SZHashCore.o" \
  "$OUT/Agent.o" "$OUT/AgentProxy.o" "$OUT/ArchiveFolder.o" "$OUT/ArchiveFolderOpen.o" \
  "$OUT/UpdateCallbackAgent.o" "$OUT/AgentOut.o" "$OUT/ArchiveFolderOut.o" \
  "$OUT/DLL.o" "$OUT/WorkDir.o" "$OUT/ZipRegistry_mac.o" \
  "${ALONE_OBJS[@]}" \
  -framework AppKit -framework Foundation -framework CoreFoundation \
  -framework UniformTypeIdentifiers -lz \
  -o "$OUT/SevenZipFM.bin"
echo "  ✓"

echo "==[4] 组装 .app bundle + 嵌入 FinderSync 扩展 =="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$FM/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$OUT/SevenZipFM.bin" "$APP/Contents/MacOS/SevenZipFM"
chmod +x "$APP/Contents/MacOS/SevenZipFM"

# FinderSync 扩展（.appex 嵌入 Contents/PlugIns/）。入口 _NSExtensionMain（Foundation 提供，PlugInKit 加载 principal class）。
EXT="$APP/Contents/PlugIns/SevenZipFinder.appex"
mkdir -p "$EXT/Contents/MacOS"
cp "$FM/Finder/Ext-Info.plist" "$EXT/Contents/Info.plist"
clang -arch arm64 -e _NSExtensionMain \
  "$OUT/SZFinderSync.o" "$OUT/SZShellCommand.o" \
  -framework Cocoa -framework FinderSync -framework Foundation \
  -o "$EXT/Contents/MacOS/SevenZipFinder"
chmod +x "$EXT/Contents/MacOS/SevenZipFinder"
# 嵌套签名（从内到外）：先扩展（带沙箱 entitlements），再主 app
codesign --force --sign - --entitlements "$FM/Finder/Ext.entitlements" "$EXT" 2>/dev/null || echo "  (扩展 ad-hoc 签名跳过)"
codesign --force --sign - "$APP" 2>/dev/null || echo "  (app ad-hoc 签名跳过)"
echo "  ✓ ${APP}（含 PlugIns/SevenZipFinder.appex）"

echo "==[5] 生成样本归档（/tmp 清理后随构建重建，供桌面验证）=="
SAMPLE="$OUT/sample.7z"
if [ ! -f "$SAMPLE" ] || [ ! -f "$OUT/sample-enc.7z" ]; then
  clang++ -arch arm64 "$ALONE"/*.o -framework CoreFoundation -lz -o "$OUT/7zz" 2>/dev/null
  S="$OUT/sample_src"; rm -rf "$S"; mkdir -p "$S/子目录/深层"
  echo "顶层文件内容" > "$S/readme.txt"
  printf '中文内容测试\n' > "$S/中文.txt"
  echo "inner file" > "$S/子目录/inner.txt"
  head -c 120000 /dev/urandom > "$S/子目录/深层/data.bin"
  ( cd "$OUT" && rm -f sample.7z sample-enc.7z sample.zip
    ./7zz a sample.7z sample_src >/dev/null
    ./7zz a -ppass123 sample-enc.7z sample_src >/dev/null
    ./7zz a sample.zip sample_src >/dev/null )
fi
echo "  ✓ $OUT/sample.7z / sample-enc.7z（密码 pass123）/ sample.zip"

echo ""
echo "===== 构建完成（M1 浏览 + M2 解压接入）====="
echo "结构验证："
file "$APP/Contents/MacOS/SevenZipFM" | sed 's/^/  /'
/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist" | sed 's/^/  BundleID: /'
echo ""
echo "桌面运行（需图形会话）：open \"$APP\" --args \"$OUT/sample.7z\""
echo "加密档（密码 pass123）：open \"$APP\" --args \"$OUT/sample-enc.7z\""
