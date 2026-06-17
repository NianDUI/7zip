7-Zip 文件管理器 macOS 版（Apple Silicon / arm64）。

## 安装
打开 dmg，将 **7-Zip.app** 拖入 **Applications**。

## ⚠️ 首次打开（ad-hoc 签名、未公证）
被 Gatekeeper 拦截时，二选一解除：
- 右键 **7-Zip.app** → 打开 → 再点弹窗里的「打开」
- 终端运行：`xattr -dr com.apple.quarantine /Applications/7-Zip.app`

含 Finder 右键扩展（首次需到 系统设置 → 隐私与安全性 → 扩展 启用）。

---
基于 [7-Zip](https://7-zip.org)（© 1999–2026 Igor Pavlov，GNU LGPL-2.1，含 unRAR 限制）的**非官方** macOS 移植，与 7-zip.org 无关、未获背书。
源码与完整许可：https://github.com/NianDUI/7zip （`DOC/copying.txt`、`Mac/LICENSE`）。
