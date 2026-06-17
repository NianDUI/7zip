#!/bin/bash
# 7-Zip mac 版一键发版：构建 dmg → 算 SHA → 取 annotated tag 的「本次更新」→ 组装 notes → gh release create。
# 这是 ghostty 那条 CI「Compose release body」步骤的本地等价物（本仓库无 CI，发版是手动的）。
#
# 用法：
#   git tag -a mac-v0.2 -m "本次更新：修了 XXX、加了 YYY"   # annotated tag，-m 写更新内容（可多个 -m 分段）
#   git push origin mac-v0.2
#   bash Mac/SevenZipFM/release.sh mac-v0.2
# 忘了 -m（或打的是 lightweight tag）也能发，只是 body 里没有「本次更新」段，不会误取 commit message。
set -euo pipefail
TAG="${1:?用法: release.sh <tag，如 mac-v0.2>}"
FM="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$FM/../.." && pwd)"
cd "$REPO"
REPO_SLUG="NianDUI/7zip"

echo "==[1] 构建 dmg =="
bash "$FM/build_dmg.sh"
DMG="$(ls -t dist/7-Zip-*-arm64.dmg 2>/dev/null | head -1)"
[ -f "$DMG" ] || { echo "✗ 没找到 dmg"; exit 1; }
SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
echo "  dmg = $DMG"
echo "  sha = $SHA"

# 版本一致性软检查：dmg 文件名里的产品版本 应 == tag 去掉 mac-v 前缀
DMG_VER="$(basename "$DMG" | sed -E 's/^7-Zip-(.*)-arm64\.dmg$/\1/')"
TAG_VER="${TAG#mac-v}"
[ "$DMG_VER" = "$TAG_VER" ] \
  || echo "  ⚠ dmg 版本($DMG_VER) ≠ tag 版本($TAG_VER)：记得改 Mac/SevenZipFM/Resources/Info.plist 的 CFBundleShortVersionString"

echo "==[2] 取 tag 的「本次更新」 =="
MSG=""
# 仅 annotated tag（cat-file 类型为 tag）才取 message；去掉可能的 PGP 签名段
if [ "$(git cat-file -t "$TAG" 2>/dev/null)" = "tag" ]; then
  MSG="$(git for-each-ref "refs/tags/$TAG" --format='%(contents)' | sed '/-----BEGIN PGP/,$d')"
fi
if [ -n "$(printf '%s' "$MSG" | tr -d '[:space:]')" ]; then echo "  ✓ 有更新说明"; else echo "  （无 annotated 更新说明，body 跳过该段）"; fi

echo "==[3] 组装 notes =="
NOTES="$(mktemp)"
{
  if [ -n "$(printf '%s' "$MSG" | tr -d '[:space:]')" ]; then
    printf '## 本次更新\n\n%s\n\n' "$MSG"
  fi
  cat "$FM/release-body.md"
  printf '\n## 校验\nSHA-256 (`%s`):\n`%s`\n' "$(basename "$DMG")" "$SHA"
} > "$NOTES"
echo "----- 预览 -----"; cat "$NOTES"; echo "----------------"

echo "==[4] gh release create $TAG =="
gh release create "$TAG" "$DMG" \
  --title "7-Zip for macOS v${TAG_VER} (Apple Silicon)" \
  --notes-file "$NOTES" --latest -R "$REPO_SLUG"
echo "✓ 发布完成：https://github.com/$REPO_SLUG/releases/tag/$TAG"
