# 7-Zip for macOS 发版方案与记录

> 把 mac 移植版（`Mac/` 子树）打包成 dmg 并发布到本 fork（`NianDUI/7zip`）的 Releases。
> 仅自用，arm64，ad-hoc 签名、**未公证**。手动发版（**本仓库无 CI**）。
> 这是 ghostty `docs/plan/xghostty-release.md` 的 7zip 对应版——但 7zip 没有 self-hosted
> runner / GitHub Actions，所以等价能力做成**本地脚本**而非 CI 步骤。

---

## 0. 目标与边界

- **只发 mac 移植版**（`Mac/SevenZipFM` 的 `7-Zip.app`），上游 7-Zip 的 `C/`、`CPP/`、`Asm/` 不参与发布。
- 触发：**手动**跑 `release.sh`（无 CI，推 tag 不会自动构建）。
- 产物：`7-Zip-<产品版本>-arm64.dmg`（ad-hoc 签名、未公证）。
- tag 用 **`mac-vX.Y`** 前缀，和上游 7-Zip 的版本 tag（`23.01`…`26.01`）区分开。

## 1. 关键决策（附理由）

| 决策 | 取值 | 理由 |
|---|---|---|
| 发版方式 | **本地脚本**，非 CI | 构建是秒级 clang 构建（Alone2 `.o` 已缓存），本地一条命令即可；搭 runner+workflow 不划算 |
| tag 前缀 | **`mac-vX.Y`** | 仓库里有上游 7-Zip 的 `23.01`…`26.01` tag，裸 `vX.Y` 语义易混 |
| 签名 | **ad-hoc**（`codesign --sign -`） | 自用足够；Dev Cert / Developer ID 也救不了异机 Gatekeeper，真正免摩擦只有公证（不做） |
| 更新说明 | **annotated tag 的 message** | 打 tag 时 `-m` 写「本次更新」，`release.sh` 自动读出拼进 release body；贴合「tag = 发版」习惯 |
| 上传 | `gh release create`（Claude 进程可直接跑） | gh token 今日验证可由 Claude 的 Bash 进程直接读取；早先「必须用 `!`」是回传故障期误判 |

**两条版本线**（别混）：
1. **产品版本** = `Mac/SevenZipFM/Resources/Info.plist` 的 `CFBundleShortVersionString`（注入 app + dmg 文件名）
2. **发版 tag** = `mac-vX.Y`（GitHub Release 的标识）

## 2. 工具与文件

| 文件 | 作用 |
|---|---|
| `Mac/SevenZipFM/build_app.sh` | 编译 + 链接 + 组装 `7-Zip.app`（含 FinderSync 扩展、图标、ad-hoc 签名）→ `/tmp/szfm_app/7-Zip.app` |
| `Mac/SevenZipFM/build_dmg.sh` | 调 `build_app.sh` → 重签 → 版本化 dmg → `dist/7-Zip-<版本>-arm64.dmg`（**纯产物，无副作用**） |
| `Mac/SevenZipFM/release-body.md` | 固定的安装 + 解隔离说明（跨版本复用） |
| `Mac/SevenZipFM/release.sh` | **一键发版**：构建 dmg → 算 SHA → 读 annotated tag 的「本次更新」→ 组装 notes → `gh release create` |

> ⚠️ `Mac/SevenZipFM/build_release.sh` 是「自用全家桶」（装 `/Applications`、重启 Finder/Dock、自动打开 app）。**发版不要用它**。

## 3. 发版流程

```bash
git tag -a mac-v0.2 -m "本次更新：修了 XXX、加了 YYY"   # annotated tag，-m 写更新内容
git push origin mac-v0.2
bash Mac/SevenZipFM/release.sh mac-v0.2
```

`release.sh` 自动完成：构建 dmg → 算真实 SHA256 → 组装 body（`## 本次更新` + 固定安装/解隔离说明 + `## 校验`）→ `gh release create mac-v0.2 ... --latest`。

- 忘了 `-m`（或打 lightweight tag）也能发，只是 body 没有「本次更新」段，不会误取 commit message。
- 改产品版本：先改 `Info.plist` 的 `CFBundleShortVersionString`，`release.sh` 会软检查 dmg 版本与 tag 版本是否一致。

## 4. 约束

- **arm64 only**（`-arch arm64`），Intel Mac 不支持。
- **ad-hoc 签名、未公证**：下载者首次打开需 `xattr -dr com.apple.quarantine /Applications/7-Zip.app` 或右键→打开。
- **FinderSync 右键扩展**要求 app 位于 `/Applications` 或 `~/Applications` 才能启用。
- 仓库**无 CI**（无 `.github`），推 tag 不触发任何 workflow。

## 5. 已发布版本

| tag | 日期 | commit | 产品版本 | dmg | SHA-256 | 备注 |
|---|---|---|---|---|---|---|
| `mac-v0.1` | 2026-06-17 | `3ede792` | 0.1 | `7-Zip-0.1-arm64.dmg` | `c05b3144cf5efc5f4ade19f375e27c98eed5d857b35c8d29056313220c1328b5` | 首发（M5）。https://github.com/NianDUI/7zip/releases/tag/mac-v0.1 |

> 发新版后在此表追加一行。
