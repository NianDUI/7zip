# M4-T3 报告：完整菜单栏 + 快捷键体系

把散落的功能整理进对照 Windows 7zFM 的完整菜单栏（自用裁剪 Bookmarks/Tools 大部），补齐键盘操作。

## 菜单栏

| 菜单 | 项（快捷键） |
|---|---|
| **7-Zip** | 关于 / 隐藏(⌘H) / 隐藏其他(⌥⌘H) / 显示全部 / 退出(⌘Q) |
| **文件** | 打开…(⌘O) ／ 新建归档…(⌘N) · 新建文件夹(⇧⌘N) ／ 解压到…(⌘E) · 测试(⌘T) ／ 在 Finder 中显示(⇧⌘R) ／ 关闭窗口(⌘W) |
| **编辑** | 撤销(⌘Z) · 重做(⇧⌘Z) ／ 剪切 · 复制 · 粘贴 · 全选(⌘A) · 反选(⇧⌘A) |
| **显示** | 刷新(⌘R) · 上级目录(⌘↑) ／ 按名称(⌘1) · 按大小(⌘2) · 按修改时间(⌘3) 排序 |

外加面板内导航键（M4-T1/T2 已有）：Enter 进入/打开、Backspace 上级（逐层退回栈）、双击。

## 新增

- 协议 `SZPanelSource` 加 `@optional createDirectoryNamed:error:`（仅 FS 实现）。
- `SZPanelController` 三个便利方法：
  - `createFolderInteractive`：弹输入框新建文件夹（`respondsToSelector` 判定，仅 FS 启用）。
  - `revealSelectionInFinder`：`activateFileViewerSelectingURLs` 显示选中项（归档模式显示归档本身，无选中显示当前目录）。
  - `invertSelectionInPanel`：反选并同步 NSTableView 高亮。
- `SZAppDelegate` 对应动作：`newFolder:` / `revealInFinder:` / `invertSelection:` / `sortByName:` / `sortBySize:` / `sortByDate:`；`validateMenuItem:` 让「新建文件夹」仅 FS 启用、解压/测试需有目标归档。
- `main.m` 重建菜单栏（`AddItem`/`SetMods` 辅助）。

## 设计取舍

- **不做 FAR 风格 F5/F6 复制/移动**：那是双面板「从活动面板复制到另一面板」语义，依赖 T5；单面板下无目标面板。留 T5（或 T4 的「复制到…」弹目录选择）。
- 全选用系统 `selectAll:`（焦点在表格时 NSTableView 选所有行 → 经 `tableViewSelectionDidChange` 同步到数据源），不另造。

## 验证

- `build_app.sh` 编译链接通过，app 启动正常。

## 待桌面验证点

1. 菜单四组齐全；⌘O 打开、⇧⌘N 新建文件夹（仅 FS）、⇧⌘R Finder 显示、⌘↑ 上级。
2. ⌘1/2/3 切换排序；⌘R 刷新；⇧⌘A 反选。
3. 归档内时「新建文件夹」置灰；FS 选中归档时解压/测试可用。
