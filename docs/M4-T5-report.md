# M4-T5 报告：双面板（FAR 风格）

把单面板升级为左右**双面板**，每个面板各持独立的 `SZPanelController` + 数据源栈（M4-T2 的栈化为此铺路）。这是 M4 的标志特性，也让面板间复制/移动有了「目标面板」。

## 布局与焦点

- `NSSplitView`（vertical=YES 左右分栏）放两个面板视图，各 = 地址栏 + 列表。
- 顶部工具栏：↑上级 / 复制→ / 移动→ / 解压 / 测试。底部状态栏（显示活动面板）。
- **活动面板**：`_activeSide`（0/1）。`SZTableView` 重写 `becomeFirstResponder` → 点击即激活；**Tab 键**切换到另一面板（`keyDown` 拦截 keyCode 48）。活动面板地址栏高亮（`selectedTextBackgroundColor`）。
- 所有菜单/工具栏动作走 `activePanel`（goUp/extract/test/refresh/newFolder/delete/sort/reveal/invert/openLocation…）。
- 启动：命令行参数装左面板，右面板进 home；两面板各自独立导航。

## 跨面板传输（F5 复制 / F6 移动）

`-[SZPanelController transferSelectionToPanel:move:parent:]`，按源/目标类型分流：

| 源 → 目标 | 行为 |
|---|---|
| FS → FS | `NSFileManager` 复制 / 移动（move 真移动，目标同名覆盖）|
| FS → 归档 | 选中文件 `addFileAtPath` 添加到目标归档当前层（move 暂等同 copy）|
| 归档 → FS | 解压选中档内项到目标目录（进度窗；move 暂等同 copy）|
| 归档 → 归档 | 暂不支持（提示「先解压再压缩」）|

入口：工具栏「复制→ / 移动→」按钮 + 文件菜单「复制/移动到另一面板」(F5/F6)。
> mac 上 F5/F6 可能需 Fn；工具栏按钮是稳妥入口。涉及归档的 move 暂不删源（避免跨类型删除复杂度），留后完善。

## 验证

- `build_app.sh` 编译链接通过，app 启动正常。

## 待桌面验证点

1. 左右双面板各自独立浏览（双击进目录/归档、Backspace 上级）。
2. 点击或 Tab 切换活动面板（地址栏高亮跟随）；菜单/工具栏作用于活动面板。
3. 选中文件 → 「复制→」到另一面板目录；「移动→」真移动。
4. 一侧归档、一侧 FS：归档→FS「复制→」=解压；FS→归档=添加。
