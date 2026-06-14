# M3-T5（+T6）报告：归档内增删改 + 分卷

> 目标：T5 归档内增删改（Agent 更新事务，CAgentFolder IFolderOperations + CommonUpdateOperation 重写归档）；T6 分卷压缩/合并。
> 结论：**通过。删除/添加/新建文件夹/重命名 + 改后完整性正确；分卷压缩 + 从 .001 合并解压字节一致。**
> 复现：`build_test_edit.sh`（T5）、`build_test_compress.sh` 用例 F（T6）。

## T5 归档内增删改

`SZFolderCore` 加写方法，QI `CAgentFolder` 到 `IFolderOperations`：

| API | IFolderOperations | 说明 |
|---|---|---|
| `deleteItems(coreIndices)` | `Delete` | 核心索引→folderIndex（不随排序漂移） |
| `createFolder(name)` | `CreateFolder` | 当前层新建文件夹 |
| `renameItem(index, newName)` | `Rename` | |
| `addFile(fsPath)` | `CopyFrom` | 外部文件加入当前层 |
| `canUpdate()` | QI 成功=可更新 | 格式只读则 -1 |

回调 `SZUpdateProgress`（最小 `IFolderArchiveUpdateCallback`，COM 堆分配）。写后 `reload()` 重读 folder（`CommonUpdateOperation` 内部 WorkDir 临时文件 + MoveToOriginal + ReOpen 已持久化到磁盘）。

**关键**：`SZCoreItem` 加 `folderIndex`（folder 原始序号）——排序后 items 顺序变，但删除/重命名须用原始 folder index 定位，故快照时记下，排序随条目移动不失指。

验收（build_test_edit.sh）：删 top.txt（剩余项正确）、add newfile.txt、mkdir newdir、rename 中文.txt→renamed.txt，每步 `7zz l` 验证 + 改后 `7zz t` 完整。

## T6 分卷

`SZCompressCore` 加 `volumeSize` → `options.VolumesSizes`（.7z.001/.002…）；解压侧引擎自动探测 .001 序列合并。验收：3 卷分卷 + 从 .001 合并解压字节一致。

## 顺带修复：压缩密码框误弹（T2 bug）

`CryptoGetTextPassword2` 被引擎在压缩**任何**格式时调用以查询"是否加密"。原实现未预设密码时仍调 delegate 询问 → 未勾加密也弹密码框。修：未预设密码 → `passwordIsDefined=0`（不加密），绝不弹框。

## 边界（GUI 接入后续）

T5 桥接核心通；**面板内右键删除/重命名/拖入添加**的 GUI 接入待后续（需面板右键菜单 + 拖入目标）。分卷的对话框选项、独立 Split/Combine 工具同。

## 产物

- 新增：`tests/test_edit.cpp`、`build_test_edit.sh`。
- 改动：`SZFolderCore.{h,cpp}`（写方法 + folderIndex）、`SZCompressCore.{h,cpp}`（volumeSize + 密码修复）、`tests/test_compress.cpp`、`build_test_compress.sh`（分卷用例）。
