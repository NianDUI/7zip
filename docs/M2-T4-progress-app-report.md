# M2-T4（+T2 UI）报告：进度窗 + 解压接入 app

> 目标：把已验证的解压桥接层（M2-T1/T2）接到 `7-Zip.app`，让应用真正能解压——主进度窗（`ProgressDialog2` 对应物，`04 §4`）+ 覆盖/密码阻塞弹框（M2-T2 的 NSAlert UI 落地）+ 菜单解压入口。
> 结论：**编译链接通过，解压功能接入 app（文件→解压到…）。GUI 交互需桌面运行确认（同 M1-T7 模式）。**
> 复现构建：`Mac/SevenZipFM/build_app.sh` → `/tmp/szfm_app/7-Zip.app`。

## 已实现

| 部件 | 文件 | 说明 |
|---|---|---|
| 进度窗 | `Mac/SevenZipFM/Progress/SZProgressWindowController.{h,m}` | 独立窗口（每操作一个，§2.5）；NSTimer 0.2s 拉取刷 UI（对齐 CProgressSync 轮询，非推送）；进度条 + 当前文件名 + 统计行（Elapsed/Processed/Speed/Files/Errors）+ 取消；窗口标题含百分比 |
| 覆盖弹框 | 同上 `askOverwriteExisting:` | NSAlert 全 6 档（替换/全部替换/跳过/全部跳过/自动重命名/取消），按钮序与 `SZOverwriteResponse` 对齐 |
| 密码弹框 | 同上 `extractorAskPassword:` | NSAlert + NSSecureTextField，取消返回 nil |
| 解压入口 | `App/SZAppDelegate.m` `extractTo:` + `App/main.m` 文件菜单 | Cmd+E「解压到…」→ NSOpenPanel 选目录 → 进度窗解压整档；`validateMenuItem:` 仅打开归档时启用 |

阻塞弹框在主线程同步 `runModal`（引擎工作线程经信号量等返回，M2-T2 机制），不阻塞主 runloop（解压在后台队列）。

## 完成度与后续（T4 剩余项）

本轮交付**可用核心**，对照 `04 §4` 仍有迭代项（均标注，不阻断 app 解压）：

- **9 项统计**：已做 Elapsed/Processed/Speed/Files/Errors（+ 标题百分比）；缺 Remaining/Total/Packed/Ratio——Packed/Ratio 需引擎回调补压缩大小（SZArchiveExtractor 当前未透传），随该回调一并补。
- **暂停/后台**：未做。暂停=Set_Paused 工作线程 sleep 轮询；后台=工作线程 QoS 降级（§4.4 / R6）。下一轮补。
- **Dock NSProgress**：未做（§4 ITaskbarList3→NSProgress dock 进度）。
- **取消确认**：当前取消即静默中止；Windows 是「先暂停→YESNOCANCEL 确认」。待暂停做完后补确认流程。

## 验证方式

- **逻辑路径**：已由 `build_test_extractor.sh` 5 用例（含 100 次阻塞往返压测）完整验证——app 走同一 `SZArchiveExtractor` 路径。
- **GUI 交互**（需桌面图形会话）：
  ```bash
  bash Mac/SevenZipFM/build_app.sh
  open "/tmp/szfm_app/7-Zip.app" --args /tmp/szkit_m2t1/enc.7z   # 加密档可验密码框
  # 菜单 文件 → 解压到…（Cmd+E）→ 选目录 → 观察进度窗 / 覆盖框 / 密码框
  ```

## 产物

- 新增：`Mac/SevenZipFM/Progress/SZProgressWindowController.{h,m}`。
- 改动：`App/SZAppDelegate.m`（extractTo: + validateMenuItem:）、`App/main.m`（文件菜单）、`build_app.sh`（编译链接 SZExtractCore/SZArchiveExtractor/SZProgressWindowController）。
