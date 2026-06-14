# M4-T1 报告：文件系统数据源 + 统一面板协议（FM 地基）

把 app 从「单面板**归档浏览**壳」升级为能浏览**真实文件系统**的文件管理器地基。
这是 M4（7zFM 双面板 FM）的根基：后续 FS↔归档无缝进出（T2）、菜单/快捷键（T3）、
FS 文件操作（T4）、双面板（T5）全部建立在本协议之上。

## 架构：统一数据源协议

新增 `SZPanelSource` 协议（纯 Foundation 公开头），抽出面板控制器所需的全部统一能力
（列表 / 地址 / 排序 / 导航 / 选择 / 写）。两个实现：

| 实现 | 后端 | representsArchive | 用途 |
|---|---|---|---|
| `SZFSDataSource`（新增） | `NSFileManager` | NO | 浏览真实磁盘目录 |
| `SZPanelModel`（adopt） | `SZFolderSession` → 7-Zip Agent | YES | 浏览归档内部 |

`SZPanelController` 不再硬绑 `SZPanelModel`，改持 `id<SZPanelSource>`，按 `representsArchive` 分流：
- **拖出**：FS 项直接给 `NSURL` 文件；归档项走 `NSFilePromiseProvider` 延迟解压（M2-T6 不变）。
- **打开**：FS 普通文件 → `NSWorkspace` 系统打开；FS 归档文件 → 进入归档；归档内文件 → 解压临时 + 打开。
- **解压 / 测试**：FS 下作用于右键 / 选中的归档文件；归档下作用于当前归档（含选中项）。
- **删除 / 重命名**：FS 下走 `SZFSDataSource`（删到废纸篓 / `moveItem`）；归档下走 M3-T5 重写归档。

## SZFolderItem 归位（架构副产物）

面板项数据类 `SZFolderItem` 原寄生在 `SZFolderSession.mm`（→ 链接即拉整个引擎）。
本次拆为独立 `SZFolderItem.m`（纯 Foundation）+ `SZFolderItem_Private.h`（readwrite 私有接口）：
- 归档项：`SZFolderSession.mm` 内静态 `SZItemFromCore()` 经私有接口填充。
- 磁盘项：`SZFolderItem.m` 的 `+itemWithName:...`。

收益：`SZFSDataSource` 对 7-Zip 引擎**零依赖**，headless 单测可仅链接 Foundation。

## app 行为（M4-T1）

- 启动：命令行参数 = 归档→归档面板 / = 目录→该目录 / = 普通文件→其所在目录 / 无参→**home 目录**。
  （不再强制弹「选择归档」面板。）
- 文件菜单加「打开…」（Cmd+O，可选目录或归档）；工具栏加「↑ 上级」。
- 双击：目录进入 / 普通文件系统打开 / 归档文件进入归档面板。
- Backspace / ↑上级：逐层上溯；归档根再上溯 → 回到归档所在 FS 目录（**单层简单闭环**，
  完整数据源栈 + 嵌套归档留 T2）。
- 标题 / 地址栏：FS = 绝对路径；归档 = `归档路径 › 内部路径`。

## 验证

- **`build_test_fsdatasource.sh`（新增，纯 Foundation 零引擎）全绿**：打开 / 基本属性 / 默认排序
  （目录恒前 + 隐藏点文件 + 自然序）/ Size 排序方向 / 选择按 name 跟随排序 / 全选反选 /
  进子目录与上溯 / `fileSystemPathForIndex` / 新建夹 / 重命名 / 添加外部文件 / 删除到废纸篓。
- **归档回归 `build_test_panelmodel.sh` 0 失败**：`SZFolderItem` 拆分未破坏归档项填充。
- `build_app.sh` 全量编译链接通过，app 正常启动。

## 待桌面验证点

1. 启动进 home 目录，能上下导航；双击普通文件用默认程序打开。
2. 双击 `.7z/.zip` → 进入归档浏览（标题变 `归档 › 内部`）；归档根连按 Backspace → 回到 FS 目录。
3. FS 里右键一个归档文件 → 解压… / 测试 可用；右键普通文件 → 删除（进废纸篓）/ 重命名 / 属性。
4. 从面板拖文件到 Finder（FS 项直接拷贝）；从 Finder 拖文件进面板（拷入当前目录）。

## 下一步（M4-T2）

把 app delegate 里的单层进出抽象为 `SZPanelController` 自包含的**数据源栈**：
支持任意深度 FS→归档→子目录逐层退回、嵌套归档，并为双面板（T5）让每个面板独立持栈。
