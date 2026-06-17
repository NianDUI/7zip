#!/bin/bash
# 构建 GitHub Release 用的 7-Zip.app dmg：release 构建（带图标）→ ad-hoc 重签 → 版本化 .dmg。
# 与 build_release.sh 的区别：纯产物，不装 /Applications、不重启 Finder/Dock、不启动 app。
# 注意：arm64-only；ad-hoc 签名未公证，下载者首次打开需：
#   xattr -dr com.apple.quarantine /Applications/7-Zip.app   （或右键→打开）
set -euo pipefail
FM="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$FM/../.." && pwd)"
APP=/tmp/szfm_app/7-Zip.app
ARCH=arm64   # build_app.sh 固定 -arch arm64

echo "==[1] 构建 app（release -O2，带图标）=="
bash "$FM/build_app.sh" >/tmp/szfm_build.log 2>&1 || { tail -25 /tmp/szfm_build.log; exit 1; }
[ -f "$APP/Contents/Resources/AppIcon.icns" ] && echo "  ✓ 图标已嵌入" || { echo "  ✗ 图标缺失"; exit 1; }

echo "==[2] ad-hoc 重签（扩展 + app，从内到外）=="
APPEX="$APP/Contents/PlugIns/SevenZipFinder.appex"
codesign --force --sign - --entitlements "$FM/Finder/Ext.entitlements" "$APPEX"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP" && echo "  ✓ 签名校验通过" || echo "  ⚠ 签名校验有告警（ad-hoc 可忽略）"

echo "==[3] 版本化 .dmg =="
VER="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMGSRC=/tmp/szfm_dmg; rm -rf "$DMGSRC"; mkdir -p "$DMGSRC"
cp -R "$APP" "$DMGSRC/"
ln -s /Applications "$DMGSRC/Applications"   # 拖拽安装的快捷方式
DIST="$REPO/dist"; mkdir -p "$DIST"
DMG="$DIST/7-Zip-$VER-$ARCH.dmg"; rm -f "$DMG"
hdiutil create -volname "7-Zip $VER" -srcfolder "$DMGSRC" -ov -format UDZO "$DMG" >/dev/null
echo "  ✓ $DMG"

echo ""
echo "===== Release dmg 构建完成 ====="
echo "  产物：  $DMG"
ls -lh "$DMG" | awk '{print "  大小：  "$5}'
shasum -a 256 "$DMG" | awk '{print "  SHA256："$1}'
echo "  下载者首次打开：xattr -dr com.apple.quarantine /Applications/7-Zip.app"
