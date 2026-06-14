# M4-T2 报告：FS↔归档无缝进出（数据源栈）

把 T1 在 app 层的单层进出 hack（`_archiveURL` + `_fsReturnPath`）重构为 `SZPanelController`
自包含的**数据源栈**，导航逻辑内聚到面板自身，为双面板（T5）每面板独立持栈铺路。

## 数据源栈

`SZPanelController` 内部持两个平行数组：
- `_stack`：`id<SZPanelSource>` 栈，栈底恒为 FS 数据源，每进入一个归档 push 一层（SZPanelModel）。
- `_archivePaths`：与 `_stack` 平行，FS 层占位 `@""`，归档层存归档磁盘路径。
- `_source` = `_stack.lastObject`（当前数据源缓存）。

导航：
- `activateRow:` 遇 FS 归档文件 → `pushArchiveAtFSPath:`（push 归档层），普通文件系统打开，目录进入。
- `goToParent`：当前数据源 `enterParentFolder` 成功即返回；否则若栈深 > 1 → **pop 回下层**
  （归档根再上溯 → 回到归档所在 FS 目录，且**该 FS 数据源连同其选择/排序原样保留**，不再像 T1 重建）。

派生属性（全部 computed，app 不再手工同步）：
- `archivePath`：栈顶若归档则其磁盘路径（拖出延迟解压源），否则 nil。
- `inArchive`：栈顶是否归档。
- `currentArchiveFSPath`：栈顶归档→其路径；FS→选中的归档文件（供工具栏解压/测试）。

## 地址栏面包屑

`addressText` 遍历整个栈拼接：FS 层显示绝对路径，归档层追加 ` › 归档名/内部路径`。
例：`/Users/x/Downloads › report.7z/子目录`。标题同步显示。

## app 层简化

`SZAppDelegate` 删除 `_archiveURL` / `_fsReturnPath` / `_source` 与 `onActivateArchive` /
`onParentBeyondRoot` 回调；只保留布局 + chrome 刷新。双击归档不再重建 controller，由面板内部 push。
`openArchiveURL:` = 以归档所在目录建 FS 栈底，再 push 归档层。

## 本阶段顺带完成的 FS 增量（用户驱动）

- **刷新**：`refresh`（协议方法）——FS 重读磁盘、归档空操作；Cmd+R + app 重新激活自动刷新（仅 FS），按 name 保留选中。
- **动态右键菜单**（`menuNeedsUpdate:`）：按上下文变化——
  - FS 选中归档：打开 / 解压… / **解压到「名/」** / 测试 / 压缩… / 删除 / 重命名 / 属性
  - FS 普通项：打开 / 压缩… / 删除 / 重命名 / 属性
  - 归档内：打开 / 解压… / 测试 / 删除 / 重命名 / 属性
- **解压到「名/」**（`ctxExtractToFolder:`）：解压到以归档名命名的子文件夹；**若已存在自动用「名 1」「名 2」…，绝不覆盖**；菜单项标题直接显示实际目标名；完成后自动刷新。
- **压缩…**（`ctxCompress:`）：FS 右键选中文件/文件夹 → 压缩对话框（默认名 = 单选项名 / 多选父目录名 `.7z`）→ 完成刷新。

> 这些属于 T3（菜单）/ T4（FS 操作）的提前落地；完整菜单栏 + F5/F6/F7 快捷键、复制/移动留各自任务。

## 嵌套归档（留后）

归档内的归档需先解压到临时再 push（归档内文件无磁盘路径）。自用极少，暂不实现；
栈结构已为其预留（push 任意 FS 路径即可）。

## 验证

- `build_app.sh` 编译链接通过，app 启动正常。
- 归档面板回归 `build_test_panelmodel.sh` 0 失败（SZPanelModel 行为未变）。

## 待桌面验证点

1. FS 双击 `.7z` → 进入；归档内进子目录；连按 Backspace 逐层退回到归档根、再退回**原 FS 目录**（且 FS 选择/位置保留）。
2. 地址栏显示 `FS路径 › 归档名/内部`。
3. 工具栏「解压/测试」：在归档内对当前归档；在 FS 选中归档文件时对该文件。
