# M3-T2 报告：压缩对话框 + 压缩 GUI 接入

> 目标：压缩对话框（对应 Windows CCompressDialog）+ ObjC 外观 + app「新建归档」入口，让压缩在 GUI 端到端可用。
> 结论：**核心可用，编译链接通过，压缩 GUI 接入。GUI 交互需桌面确认。完整 1:1（高级参数/联动矩阵/内存估算）后续迭代。**
> 复现：`bash Mac/SevenZipFM/build_app.sh` → 菜单 文件 → 新建归档…（Cmd+N）。

## 已实现

| 部件 | 文件 | 说明 |
|---|---|---|
| ObjC 外观 | `SevenZipKit/SZArchiveCompressor.{h,mm}` + `SZCompressOptions` | 异步压缩（后台串行队列）；进度/扫描异步 hop 主队列、密码询问信号量同步；暂停/取消。命名避开系统类 |
| 压缩对话框 | `Dialogs/SZCompressDialogController.{h,m}` | 归档名(+浏览 NSSavePanel)、格式(7z/zip/tar)、等级(仅存储…极限)、密码、加密文件名(仅7z)；格式变更联动扩展名+加密头可用性 |
| 进度窗复用 | `Progress/SZProgressWindowController` 加 `beginCompressToArchive:` | 复用进度条/统计/暂停/取消；实现 SZArchiveCompressDelegate；密码框提取 `askPassword` 共用 |
| app 入口 | `SZAppDelegate.newArchive:` + 文件菜单「新建归档…」(Cmd+N) | 选输入(多选文件/目录) → 对话框 → 进度窗压缩。不依赖已打开归档 |

## 边界（后续迭代）

对照 Windows CCompressDialog 1:1，本首版交付核心字段。**待补**（登记，非阻断）：
- **T1 完整 ParamsModel**：方法/字典/Order/Solid/线程的 auto 档默认值表 + `GetMemoryUsage_*` 内存估算显示（对话框「内存用量」提示）；
- **联动矩阵**：格式↔方法↔等级的 CBN_SELCHANGE 全联动（现仅格式↔扩展名/加密头）；
- **更新模式/路径模式**（Add/Update/Fresh/Sync；相对/绝对/完整）；
- **分卷**（T6）、**二级选项**（T3，时间精度/链接）、**SFX**（自用裁剪隐藏）。

引擎按 level 内部自选字典/方法，故首版压缩产物正确（M3-T4 已字节对照验证）；上述待补项主要影响"可调参数的丰富度"与"参数可视化"，不影响压缩正确性。

## 验证

- **压缩逻辑**：M3-T4 命令行 roundtrip 已验证（7z/zip/tar/加密/he）。
- **GUI**（需桌面）：Cmd+N → 选文件 → 对话框选格式/等级/密码 → 进度窗 → 产出归档可被 7zz/本 app 打开。

## 产物

- 新增：`SZArchiveCompressor.{h,mm}`、`SZCompressDialogController.{h,m}`。
- 改动：`SZProgressWindowController.{h,m}`（压缩支持）、`SZAppDelegate.m`、`main.m`、`build_app.sh`。
