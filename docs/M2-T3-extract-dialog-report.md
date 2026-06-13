# M2-T3 报告：解压对话框 CExtractDialog

> 目标：把现在最简的「选目录」NSOpenPanel 入口替换为完整解压对话框（对应 Windows `CExtractDialog`，`04 §3`）——目标目录（含历史）、路径模式、覆盖模式、密码、消除重复路径，字段映射 `SZArchiveExtractOptions`。
> 结论：**编译链接通过，解压对话框接入「解压」按钮/菜单。GUI 交互需桌面确认。**
> 复现：`Mac/SevenZipFM/build_app.sh`。

## 已实现（控件 → SZArchiveExtractOptions 映射）

| 控件 | 类型 | 映射 |
|---|---|---|
| 解压到 | NSComboBox（可编辑 + 历史下拉）+ 浏览… | `outputDirectory`；历史 ≤16（NSUserDefaults `SZExtractDestHistory`） |
| 路径模式 | NSPopUpButton：完整路径/无路径（铺平）/绝对路径 | `pathMode`（顺序对齐 `SZExtractPathMode`） |
| 覆盖方式 | NSPopUpButton：询问/直接覆盖/跳过已存在/自动重命名/重命名已有文件 | `overwriteMode`（顺序对齐 `SZExtractOverwriteMode`） |
| 密码 | NSSecureTextField | `password`（空=不设，加密档按需弹密码框） |
| 消除重复的根目录 | 复选框 | `eliminateDuplicatePaths` |

以 **sheet** 附在主窗口；确定→存历史+产出 options→进度窗解压；取消→completion(nil)。「解压」默认按钮（Return），取消（Esc）。`SZAppDelegate.extractTo:` 改走对话框，进度窗接口同步改为接受 `SZArchiveExtractOptions`。

## 自用裁剪 / 后续

- **NtSecurity 复选**：隐藏（mac 无 NTFS 安全描述符语义，`01 §1.2` 不做项）——对话框本就不含。
- **路径模式无 Relative**：与 Windows `CExtractDialog` 一致（仅 Full/No/Abs）。
- **SplitDest 子目录名**（解压到归档同名子目录）：未做，标注后续——它与 `OutDirMode` k_AddArcName 相关，常用度低，M2 收尾或 M4 补。
- **目标历史后端**：首版用 NSUserDefaults 独立 key；与 `ZipRegistry_mac` 的 `NExtract::CInfo.Paths`（CFPreferences，M1-T1）统一留 **M4 选项页**（届时双源合并，对齐 `04 §3` 注册表偏好）。

## 验证

- **映射逻辑**：popup `indexOfSelectedItem` 直接对齐枚举值；options 经已验证的 `SZArchiveExtractor` 路径（M2-T2）解压。
- **GUI**（需桌面）：
  ```bash
  bash Mac/SevenZipFM/build_app.sh
  osascript -e 'quit app "7-Zip"' 2>/dev/null
  open "/tmp/szfm_app/7-Zip.app" --args /tmp/szkit_m2t1/enc.7z
  # 点「解压」→ 对话框选目标/模式/密码 → 进度窗
  ```

## 产物

- 新增：`Mac/SevenZipFM/Dialogs/SZExtractDialogController.{h,m}`。
- 改动：`Progress/SZProgressWindowController.{h,m}`（接口改 `beginExtractArchive:options:`）、`App/SZAppDelegate.m`（extractTo 走对话框）、`build_app.sh`。
