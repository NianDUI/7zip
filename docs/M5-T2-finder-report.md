# M5-T2 报告：FinderSync 扩展（Finder 右键 7-Zip 菜单）

> 把 Windows 资源管理器的右键 7-Zip 菜单移植到 macOS Finder。对齐 docs/04 §1.9：FinderSync 扩展 + 共享命令模型 + `sevenzip://` URL 唤起主 app 执行（扩展沙箱不跑引擎，对应 Windows 右键→7zG 子进程）。

## 架构（三段，与 docs §3.2 一致）

```
Finder 右键选中项
   │ FIFinderSyncController.selectedItemURLs
   ▼
SZFinderSync（.appex，沙箱）  ── menuForMenuKind 按选中类型构建级联菜单
   │ 菜单项 action → NSWorkspace openURL
   ▼
sevenzip://<op>?paths=<b64url-JSON>&methods=<csv>   ← SZShellCommand 编码（与主 app 同源）
   │ LaunchServices 路由
   ▼
主 app SZAppDelegate application:openURLs:  ── SZShellCommand 解码 → 分发到 解压/压缩/测试/哈希
```

| 文件 | 角色 |
|---|---|
| `Shell/SZShellCommand.{h,m}` | **共享命令模型**（主 app + 扩展）：命令枚举 + `sevenzip://` URL 编解码（paths→base64url(JSON)、methods→csv）+ 启发式（解压子文件夹名/压缩名/归档判定）。纯 Foundation |
| `Finder/SZFinderSync.m` | FinderSync 扩展主体：`FIFinderSync` 子类，`menuForMenuKind` 动态菜单，action 经 `NSWorkspace openURL` 发命令 |
| `Finder/Ext-Info.plist` | 扩展 bundle 配置（`NSExtension` PointID=com.apple.FinderSync / Principal=SZFinderSync，PackageType=XPC!）|
| `Finder/Ext.entitlements` | 扩展沙箱（app-sandbox + files.user-selected.read-only）|
| `App/SZAppDelegate.m` | 主 app URL 入口 `application:openURLs:` + `executeShellCommand:` 分发 + 快速解压/压缩 helper |
| `Resources/Info.plist` | 主 app 注册 `CFBundleURLTypes`（scheme=sevenzip）|

## 菜单集（对齐 Windows，自用裁剪）

- **单选归档**：打开 / 解压… / 解压到「名/」/ 解压到当前位置 / 测试
- **任意选中**：添加到压缩包… / 添加到「名.7z」/ 添加到「名.zip」
- **校验和子菜单**：CRC-32 / CRC-64 / SHA-1 / SHA-256 / BLAKE2sp / 全部（CRC32·SHA1·SHA256）

裁剪：Email 系列（mac 无 MAPI，docs Q4 已定可裁剪）。快速压缩/解压目标不覆盖（名 1/名 2…）。

## URL 协议

`sevenzip://<host>?paths=<b64url>&methods=<csv>`，host ∈ {open, extract, extracthere, extractto, test, compress, compress7z, compresszip, hash}。`paths` = JSON 字符串数组经 base64url（`+/=`→`-_`去填充）编码——稳健承载中文/空格/多路径。`methods` 仅 hash 用。

## 验证（headless 能做到的全部）

- **命令模型** `build_test_shellcmd.sh` 全绿：8 op URL 往返、中文/空格/多路径往返、hash methods 往返、非法 URL→nil、op↔string、启发式（解压名/压缩名）。
- **主 app URL 入口端到端**：app 装到 `~/Applications`（`/tmp` 不注册 URL scheme）→ `lsregister` → `claimed schemes: sevenzip:` + `bindings: sevenzip:` 确认绑定 → `open "sevenzip://hash?..."` 成功路由、主 app 执行命令不崩。
- **扩展 bundle**：`.appex` 结构/Mach-O(arm64)/签名+沙箱 entitlements/`NSExtension` 配置全部正确；入口 `_NSExtensionMain`（LC_MAIN）；**系统 `pluginkit -m` 实际发现扩展 `com.niandui.SevenZipFM.FinderExt`**。
- `build_app.sh` 一键构建主 app + 编译嵌入 `.appex` + 嵌套签名（先扩展后 app）。

## 桌面验证步骤（需用户在图形会话完成，headless 无法替代）

1. **安装到正规位置**：`cp -R /tmp/szfm_app/7-Zip.app ~/Applications/`（或 /Applications）。**不能在 /tmp**——macOS 不为临时位置注册 URL scheme / 加载扩展。
2. **注册**：`open ~/Applications/7-Zip.app` 启动一次（触发 LaunchServices + PlugInKit 注册）。
3. **启用扩展**：系统设置 → 隐私与安全性 → 扩展 → 「访达扩展」→ 勾选 **7-Zip**（或命令行 `pluginkit -e use -i com.niandui.SevenZipFM.FinderExt`）。
4. **使用**：Finder 里右键任意文件/文件夹/压缩包 → 出现「7-Zip」级联菜单 → 点命令 → 主 app 弹对话框/进度窗/校验和窗执行。

## 已知限制 / 后续

- **ad-hoc 签名**：自用可用；分发需 Developer ID + 公证（M5-T7）。`pluginkit` 已识别说明 ad-hoc 足够本机加载。
- **FinderSync 注册范围**：扩展 `setDirectoryURLs` 监视 `/`（全盘），任意位置右键可用；Apple 建议按卷动态注册，自用全盘够用。
- **菜单图标**：用 SF Symbol `doc.zipper`；后续可换 app 专属图标。
- 若 Finder 不显示菜单：确认扩展已启用（步骤 3）、app 在正规位置、必要时 `killall Finder` 重启 Finder。
