# M2-T6 报告：Finder 拖出（延迟解压）

> 目标：从归档面板把文件/文件夹拖到 Finder/桌面，落点接收时才解压（延迟解压语义），对应 Windows OLE HDROP + 7zE 临时目录（`03 §6` 拖拽源）。
> 结论：**实现完成，核心解压逻辑（selectedPaths 目录递归）命令行验证通过。拖拽交互需桌面确认。**
> 复现：`bash Mac/SevenZipFM/build_app.sh` → 打开 sample.7z → 拖 `sample_src` 到桌面。

## 机制（NSFilePromiseProvider）

| 环节 | 实现 |
|---|---|
| 拖拽源 | `SZPanelController` `tableView:pasteboardWriterForRow:` 每行返回一个 `NSFilePromiseProvider`（fileType 按目录/扩展名 UTI），`userInfo` 存 **完整档内路径 + 项名** |
| 落点解压 | `NSFilePromiseProviderDelegate writePromiseToURL:`：在后台队列把该项解压到临时目录（`SZArchiveExtractor extractArchiveSync`，pathMode=Full）→ 移动到落点 URL → 清临时 |
| 后台队列 | `operationQueueForFilePromiseProvider:` 返回专用队列（QoS userInitiated，`maxConcurrentOperationCount=1`，同一归档引擎不可并发，`§2.5`），**绝不返回 mainQueue** |
| 同步解压 | 新增 `SZArchiveExtractor -extractArchiveSync:options:`（调用线程同步跑 `SZExtractCore::run`，无 delegate），供 promise 后台队列直接调用 |

## 两个关键正确性点

### 1. 完整档内路径（currentPath + 项名）

`SZFolderCore`：`currentPath()` 是导航栈累积的**完整档内路径**，但 `item.path` 在子层是**相对当前 folder**（CAgentFolder kpidPath 语义）。而解压走 `Common/Extract.cpp` 的 censor 匹配的是**从根的完整路径**。故拖出构造 `fullPath = currentPath + "/" + name`，否则子目录层拖出 censor 匹配不到 → 解不出。

### 2. selectedPaths 对目录递归解压（已验证）

拖出文件夹时 `selectedPaths=[目录完整路径]`，需递归解出整棵子树。命令行实测：
```
test_extract test.7z out -s src  →  解出 src/中文.txt, src/top.txt, src/sub/inner.txt, src/sub/deep/leaf.bin
```
→ censor 对目录名递归包含内容成立，拖出文件夹得到完整目录树。解压到临时（pathMode=Full 保留结构）后 `tmp/fullPath` 即项本体，移动到落点。

## 后续

- **拖拽交互**（NSDragOperationCopy、多项拖出、拖出进度）需桌面验证。
- **多项拖出**：每选中项一个 provider，共享串行队列；落点逐个解压。
- **拖出进度反馈**：当前 promise 解压无进度窗（Finder 自带 promise 进度）；大文件拖出体验后续评估。
- quarantine 传播（M2-T7）将接在 promise 落点与进度窗解压完成处。

## 产物

- 新增方法：`SZArchiveExtractor -extractArchiveSync:options:`（`.h/.mm`，提取 `MakeRequest` 共用）。
- 改动：`SZPanelController.{h,m}`（拖拽源 + file promise delegate + archivePath 属性）、`SZAppDelegate.m`（设 archivePath）、`test_extract.cpp`（-s 选项验证递归）。
