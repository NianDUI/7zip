# 7-Zip GUI · macOS 移植（非官方）

> **独立的第三方 macOS 移植，非 Igor Pavlov / 7-zip.org 官方出品，亦未获其背书。**
> 基于 7-Zip 26.01 引擎（Copyright © 1999-2026 Igor Pavlov）。

把 7-Zip 的 Windows GUI（7zFM 文件管理器 / 7zG 压缩解压 / Explorer 右键集成）
一对一移植到 macOS。技术路线（方案 B）：

```
SevenZipFM.app  (AppKit 原生应用)
      ↓ 只调 ObjC/Swift API
SevenZipKit.framework  (Objective-C++ 桥接层 + 静态编入上游 UI/Common·Agent)
      ↓ dlopen + C ABI 工厂
lib7z.dylib  (Format7zF 全格式核心 = 60 种格式 handler + codec + 加密)
```

## 目录

| 路径 | 说明 |
|---|---|
| `Mac/poc/` | M0 概念验证：裸 dlopen 桥接程序、导出符号清单、一键复现脚本 |
| `Mac/SevenZipKit/` | （规划中）ObjC++ 桥接层 framework |
| `Mac/SevenZipFM/` | （规划中）AppKit 应用 |
| `docs/` | 完整设计与执行方案（`00-overview.md` 为入口）+ `M0-poc-report.md` 实测报告 |
| `docs/research/` | 源码盘点底料（路径:行号 级证据） |

## 构建状态

- ✅ **M0 已验证**：引擎可零改动编成 `lib7z.dylib`，符号收敛到 19 个 C ABI，
  裸 dlopen 桥接路径（不经 LoadCodecs）完成真实 Open + 列表。
  复现：
  ```sh
  bash Mac/poc/verify_m0.sh        # macOS arm64，需 clang/make
  ```
  详见 `docs/M0-poc-report.md`。
- ⏳ M1–M5：见 `docs/05-roadmap-execution.md`。

## 许可

- `Mac/` 新增代码：**LGPL-2.1-or-later**（派生自 7-Zip，见 `Mac/LICENSE`）。
- 上游 7-Zip：LGPL 2.1（`DOC/copying.txt`）+ BSD（`DOC/License.txt`）+ unRAR 限制（`DOC/unRarLicense.txt`）。
- unRAR 代码不得用于重建 RAR (WinRAR) 兼容的压缩算法。

> 各项分发义务仅在向第三方分发时具约束力；私有托管 / 纯自用不构成分发。
> public 发布前的合规 checklist 见 `docs/05-roadmap-execution.md §10.6`。
