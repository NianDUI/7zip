#!/bin/bash
# 构建并打包 7-Zip.app 正式版：release 构建（带图标）→ 重签 → 制作 .dmg 安装包 → 安装到 /Applications。
# 自用 ad-hoc 签名（不公证）。FinderSync 扩展要求 app 位于 /Applications 或 ~/Applications。
set -euo pipefail
FM="$(cd "$(dirname "$0")" && pwd)"
APP=/tmp/szfm_app/7-Zip.app
BID=com.niandui.SevenZipFM.FinderExt

echo "==[1] 构建 app（release -O2，带图标）=="
bash "$FM/build_app.sh" >/tmp/szfm_build.log 2>&1 || { tail -25 /tmp/szfm_build.log; exit 1; }
[ -f "$APP/Contents/Resources/AppIcon.icns" ] && echo "  ✓ 图标已嵌入" || { echo "  ✗ 图标缺失"; exit 1; }

echo "==[2] 重签（扩展 + app）=="
APPEX="$APP/Contents/PlugIns/SevenZipFinder.appex"
codesign --force --sign - --entitlements "$FM/Finder/Ext.entitlements" "$APPEX" 2>/dev/null || true
codesign --force --sign - "$APP" 2>/dev/null || true
echo "  ✓"

echo "==[3] 制作 .dmg 安装包 =="
DMGSRC=/tmp/szfm_dmg; rm -rf "$DMGSRC"; mkdir -p "$DMGSRC"
cp -R "$APP" "$DMGSRC/"
ln -s /Applications "$DMGSRC/Applications"
DMG="$HOME/Desktop/7-Zip.dmg"; rm -f "$DMG"
hdiutil create -volname "7-Zip" -srcfolder "$DMGSRC" -ov -format UDZO "$DMG" >/dev/null
echo "  ✓ $DMG"

echo "==[4] 安装到 /Applications =="
DEST=/Applications/7-Zip.app
pkill -x SevenZipFM 2>/dev/null || true
killall -KILL SevenZipFinder 2>/dev/null || true
sleep 0.5
rm -rf "$HOME/Applications/7-Zip.app"     # 清理旧的用户级副本，避免 LaunchServices 双份
if rm -rf "$DEST" 2>/dev/null && cp -R "$APP" /Applications/ 2>/dev/null; then
  echo "  ✓ 已装到 /Applications"
else
  DEST="$HOME/Applications/7-Zip.app"; mkdir -p "$HOME/Applications"
  rm -rf "$DEST"; cp -R "$APP" "$HOME/Applications/"
  echo "  （/Applications 无写权限，已装到 ~/Applications）"
fi
DAPPEX="$DEST/Contents/PlugIns/SevenZipFinder.appex"
codesign --force --sign - --entitlements "$FM/Finder/Ext.entitlements" "$DAPPEX" 2>/dev/null || true
codesign --force --sign - "$DEST" 2>/dev/null || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
pluginkit -a "$DAPPEX" 2>/dev/null || true
pluginkit -e use -i "$BID" 2>/dev/null || true
echo "  ✓ $DEST"

echo "==[5] 刷新图标缓存 + 启动 =="
killall Finder 2>/dev/null || true
killall Dock 2>/dev/null || true
sleep 1
open "$DEST"
echo ""
echo "===== 正式版打包完成 ====="
echo "  安装位置：$DEST"
echo "  安装包：  $DMG"
