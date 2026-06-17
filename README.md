# 7-Zip for macOS（非官方移植 / unofficial macOS port）

把 Windows 版 7-Zip「文件管理器 + 图形界面」一对一移植到 macOS（复用 7-Zip 的 C/C++ 核心，原生 AppKit 重写 UI）。**非官方**，与 Igor Pavlov / 7-zip.org 无关、未获背书。

## 下载

[Releases](https://github.com/NianDUI/7zip/releases) — Apple Silicon (arm64) dmg。

ad-hoc 签名、未公证，首次打开会被 Gatekeeper 拦截，二选一放行：
- 右键 **7-Zip.app** → 打开 → 再点弹窗的「打开」
- 终端运行：`xattr -dr com.apple.quarantine /Applications/7-Zip.app`

## 文档

- `Mac/README.md` — 移植说明与目录结构
- `docs/` — 架构、路线图、发版方案（`docs/07-release.md`）

## 许可

基于 7-Zip（© 1999–2026 Igor Pavlov），主体 **GNU LGPL-2.1**，部分 BSD-2/3-clause，RAR 解码含 **unRAR 限制**。
- 根 `LICENSE` / `DOC/copying.txt` — LGPL-2.1 全文
- `DOC/License.txt` — 按文件的许可说明（含 BSD / unRAR 例外）
- `DOC/unRarLicense.txt` — unRAR 限制
- `Mac/LICENSE` — 移植代码（`Mac/`）的许可（LGPL-2.1-or-later）

上游 7-Zip 源码与官网：[7-zip.org](https://7-zip.org)
