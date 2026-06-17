# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目性质

把 Windows 版「7-Zip 文件管理器 + 图形界面」一对一移植到 macOS。方案 B：复用上游 7-Zip 的 C/C++ 核心引擎，用原生 AppKit 重写 UI。仅自用，arm64，遵循原 7-Zip 许可证（`Mac/LICENSE`）。

**重要**：仓库根的 `C/`、`CPP/`、`Asm/`、`DOC/` 是**上游 7-Zip 源码**（基本不改）。本项目的移植代码全部在 `Mac/`，设计/路线图文档在 `docs/`。根目录 `README.md` 只是上游占位文件。

## 架构（big picture）

三层，自底向上：

1. **上游 C/C++ 引擎**（`CPP/7zip`）——通过 `Alone2` bundle 编译成对象集（`.o`）复用，不重写。`7zip/UI/Agent/*` 是枚举/解压/压缩的闭环入口。

2. **`Mac/SevenZipKit/`** —— 核心库，两类文件：
   - **C++ 核心逻辑**（`src/SZ*Core.cpp`：Folder/Extract/Compress/Hash + `SZNaturalCompare`）：直接驱动上游 Agent/引擎。
   - **ObjC++ 桥接**（`src/*.mm`：`SZArchiveExtractor`/`SZArchiveCompressor`/`SZHashCalculator`/`SZFolderSession`/`SZPanelModel`）：把 C++ 能力包成 ObjC/AppKit 友好接口。
   - `platform/ZipRegistry_mac.cpp`：Windows 注册表 API 的 mac 替代（记最近路径/配置）。

3. **`Mac/SevenZipFM/`** —— AppKit App。`App/`（`main.m` + `SZAppDelegate`）、`Panel/`（文件列表面板）、`Dialogs/`（解压/压缩/哈希结果/文件关联对话框）、`Progress/`（进度窗 + Dock 进度）、`Shell/`、`Finder/`（FinderSync 右键扩展，编译成 `.appex` 嵌入）、`Util/`（quarantine 隔离属性、编辑回写监听）。

**桥接关键**：所有 Windows API 调用经 `Mac/compat/win_compat_mac.h` 垫片，编译时用 `-include` 强制注入。C++ 用 `-std=c++11`，ObjC++ 用 `-fobjc-arc`。`.app` bundle 对外名统一叫「7-Zip」，但内部可执行名与 BundleID 仍是 `SevenZipFM` / `com.niandui.SevenZipFM`（扩展为 `com.niandui.SevenZipFM.FinderExt`）。

## 构建

前置（只在改了 `CPP` 核心后才需重跑）——编译上游对象集：
```
cd CPP/7zip/Bundles/Alone2 && make -f ../../cmpl_mac_arm64.mak -j8
# 产物：CPP/7zip/Bundles/Alone2/b/m_arm64/*.o
```

构建 App：
```
bash Mac/SevenZipFM/build_app.sh
# 产物：/tmp/szfm_app/7-Zip.app（含 FinderSync 扩展、图标、ad-hoc 签名 + 样本归档供桌面验证）
```

打 Release dmg（**纯产物，无副作用**，发版用这个）：
```
bash Mac/SevenZipFM/build_dmg.sh
# 产物：dist/7-Zip-<版本>-arm64.dmg
# 版本号取自 Mac/SevenZipFM/Resources/Info.plist 的 CFBundleShortVersionString
```

⚠️ `Mac/SevenZipFM/build_release.sh` 是「自用全家桶」：除打 dmg 外还会把 app 装到 `/Applications`、杀并重启 Finder/Dock、自动打开 app。**发版不要用它**，用 `build_dmg.sh`。

## 测试

每个测试目标对应一个脚本，脚本内部完成「编译 + 运行」。**跑单个测试 = 跑对应脚本**：
```
bash Mac/SevenZipKit/build_test_<名>.sh   # extract / extractor / compress / hash / panelmodel / szfolder / fsdatasource / normalize / navloop / zipregistry / edit
bash Mac/SevenZipFM/build_test_<名>.sh    # panelview / shellcmd
```
回归集：`bash Mac/SevenZipKit/build_m2_regression.sh`；性能：`bash Mac/SevenZipKit/build_perf_test.sh`。

## 发布（GitHub Release）

发版 tag 用 **`mac-vX.Y`** 前缀，和上游 7-Zip 的版本 tag（`23.01`…`26.01`）区分开——**别用裸 `vX.Y`**：
```
git tag mac-vX.Y && git push origin mac-vX.Y              # git 走 SSH
gh release create mac-vX.Y dist/7-Zip-*.dmg \
    --title "7-Zip for macOS vX.Y (Apple Silicon)" \
    --notes-file <说明文件> --latest -R NianDUI/7zip
# 如需先审：加 --draft，验证 asset 后再 gh release edit mac-vX.Y --draft=false --latest
```
- dmg 文件名里的版本号（`7-Zip-0.1-arm64.dmg`）= Info.plist 的「产品版本」，和 tag 前缀是**两条独立的版本线**。
- `gh` 命令 **Claude 的 Bash 进程可直接跑**（2026-06-17 验证：`gh auth token` 拿得到、能 create release）。仅当某次 `gh auth token` 返回空时（多见于 harness 输出异常期），才退回让用户用 `!` 前缀执行。`git` 的 commit/tag/push 走 SSH，不受影响。
- 加 `-R NianDUI/7zip` 显式指定 fork，避免多 remote 时 gh 解析到上游。

## 约束

- **arm64 only**（`-arch arm64`），Intel Mac 不支持；dmg 命名与 Release 标题都标 `arm64`。
- dmg 为 **ad-hoc 签名、未公证**：下载者首次打开会被 Gatekeeper 拦，需 `xattr -dr com.apple.quarantine /Applications/7-Zip.app` 或右键→打开。
- **FinderSync 右键扩展**要求 app 位于 `/Applications` 或 `~/Applications` 才能启用（首次还需到 系统设置 → 隐私与安全性 → 扩展 勾选）。
- `dist/` 应在 `.gitignore`，dmg 不进 git，只作 Release 附件。
- 仓库目前**无 CI**（无 `.github`），推 tag 不会触发任何 workflow。

## 文档导航（docs/）

- `00-overview` / `01-architecture` / `02-core-bridge` —— 总览、架构、核心桥接机制
- `03-feature-map-filemanager` / `04-feature-map-dialogs-finder` —— Windows→mac 功能映射
- `05-roadmap-execution` —— 路线图与里程碑（M0–M5）执行记录
- `06-adversarial-review-record` —— 对抗性评审记录
- `07-release` —— 发版方案与已发布版本记录（build_dmg.sh/release.sh、mac-vX.Y、gh release）
- `M*-report.md` —— 各里程碑/任务的验收报告
