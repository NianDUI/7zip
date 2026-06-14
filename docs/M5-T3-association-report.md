# M5-T3 报告：文件关联（双击归档用本 app 打开）

> 把归档文件类型关联到 7-Zip.app，双击 `.7z`/`.zip` 等直接用本 app 浏览/解压。对齐 docs/05 §4.1-G（LaunchServices/UTType 替代 Windows `Software\Classes` 注册表）。

## 做了什么

| 部分 | 内容 |
|---|---|
| `Resources/Info.plist` `CFBundleDocumentTypes` | 声明本 app 能打开的归档类型，分两组 rank |
| `Resources/Info.plist` `UTImportedTypeDeclarations` | 为无系统 UTType 的格式（7z/xz/zst）补声明，关联扩展名 |
| `SZAppDelegate application:openURLs:` | 加 file URL 分支 → `openFileURL:`（归档进浏览 / 目录进入 / 其他文件开所在目录）|

### 类型分组与 HandlerRank

- **Owner**（本 app 是该类型拥有者，双击默认用本 app）：`org.7-zip.7-zip-archive`(7z)、`org.tukaani.xz-archive`(xz)、`org.7-zip.zstd-archive`(zst)——这三个无系统 UTType，由本 app 经 `UTImportedTypeDeclarations` 声明。
- **Alternate**（系统已有默认处理器，本 app 仅作可选项，不抢默认）：`public.zip-archive`(zip)、`public.tar-archive`(tar)、`org.gnu.gnu-zip-archive`(gz)、`public.bzip2-archive`(bz2)、`com.rarlab.rar-archive`(rar)。

> 设计取舍：自定义格式（7z 等）抢默认合理；系统格式（zip 等 macOS 自带「归档实用工具」）不强抢，避免改变用户既有习惯——用户可在 Finder「显示简介 → 打开方式」手动设本 app 为默认。

## 验证（headless）

- `lsregister -dump`：`claimed UTIs` 含全部 8 个声明类型；`bindings` 正确分两组（7z/xz/zst 一组、zip/tar/gz/bz2/rar 一组）。
- `open -a ~/Applications/7-Zip.app clean.7z`：成功，app 进归档浏览不崩。
- `build_app.sh` 通过。

## 桌面验证（需用户）

1. **双击 `.7z`**：应直接用 7-Zip.app 打开并进入归档浏览（7z 是 Owner，默认即本 app）。
2. **双击 `.zip`**：默认仍是系统「归档实用工具」（解压到当前目录）；要用本 app，右键 →「打开方式 → 7-Zip」，或「显示简介 → 打开方式 → 7-Zip → 全部更改」设为默认。
3. 若双击无反应：app 须在 `~/Applications` 或 `/Applications`（已部署），`lsregister -f` 已注册。

## 已知点

- macOS 可能对首次设默认弹「是否更改默认 app」确认——正常。
- 双击启动时 app 先进 home 再跳归档（openURLs 在 didFinishLaunching 后到达），一闪而过，可接受；后续可优化为启动即定位。
