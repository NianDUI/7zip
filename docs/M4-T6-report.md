# M4-T6 报告：工具栏 + 地址栏 + 收尾（M4 完结）

## 本次

- **地址栏可输入**：每个面板地址栏从只读 label 改为可编辑 `NSTextField`（方框 + placeholder「输入路径回车跳转」）。回车 `addressEntered:`：输入目录→进入；输入归档文件→打开归档；无效→`NSBeep` 并恢复原显示。`sendsActionOnEndEditing=NO`（仅回车触发，失焦不跳）。
- **工具栏图标化**：文字按钮换 SF Symbols 图标 + 文字（`toolButton:title:action:` helper）。上级=`arrow.up`、复制=`doc.on.doc`、移动=`arrow.right`、解压=`arrow.down.doc`、测试=`checkmark.circle`、单/双=`rectangle.split.2x1`；带 toolTip。
- **状态栏修复**：选中全是文件夹（合计 0 字节）时不再显示「Zero KB」，只报「选中 N」；选中含文件才附带合计大小。

## M4 全部完成总结

把 macOS 版从「单面板归档浏览壳」升级为对照 Windows 7zFM 的**双面板文件管理器**：

| 子任务 | 内容 |
|---|---|
| T1 | 文件系统数据源 + 统一 `SZPanelSource` 协议（FS/归档共用面板交互）|
| T2 | FS↔归档无缝进出（`SZPanelController` 数据源栈，逐层退回）|
| T3 | 完整菜单栏 + 快捷键（文件/编辑/显示，⌘O/N/E/T/R/⌫/↑/1-3、⇧⌘N/R/A 等）|
| T5 | 双面板（左右独立栈 + Tab 切焦点 + 活动高亮 + 单/双切换 + 跨面板 F5/F6 复制移动）|
| T6 | 工具栏图标 + 地址栏可输入 + 状态栏收尾 |

期间还修复了一个 **P0 崩溃**（归档子目录写操作后上级野指针，`reopenAndRebind`）。

T4（FS 文件操作）的内容已分散落地：删除（右键/⌘⌫，进废纸篓）、重命名、新建文件夹（⇧⌘N）、压缩（右键）、复制/移动（跨面板 F5/F6）。单面板「复制到…」弹目录选择被跨面板覆盖，不再单做。

## 验证

- `build_app.sh` 编译链接通过，app 启动正常；P0 崩溃回归（test_navloop / edit / szfolder）全过。

## 后续可选（非 M4）

- 工具栏改 NSToolbar（系统标题栏集成）；地址栏面包屑可点；列显隐持久化；Dock 进度。
- 用户重点：访达右键集成（FinderSync）+ CRC/SHA 哈希。
