# M2-T2 报告：阻塞式子对话框桥接（ObjC 外观 + 信号量机制）

> 目标：把 M2-T1 的纯 C++ 解压核心包成 ObjC API（`SZArchiveExtractor`），并实现 §3 R5 高风险点——**阻塞式询问桥接**：密码（`CryptoGetTextPassword`）、覆盖（`AskOverwrite`）、内存限额（`RequestMemoryUse`）回调发生在引擎工作线程，需弹**主线程对话框**并把答复同步回传，保持 Windows「工作线程阻塞等用户答复」语义（`02-core-bridge.md §5`）。核心难点是这套同步往返**不能死锁**。
> 结论：**通过。机制经信号量 + 主队列往返实现，5 用例全绿，含 100 次连续阻塞往返压测无死锁。**
> 基线：26.01 @ main。复现：`Mac/SevenZipKit/build_test_extractor.sh`（一键，纯 ObjC 测试经主 runloop 驱动）。

## 机制

延续 Pimpl：`SZArchiveExtractor.mm`（ObjC 外观，无 7-Zip 头）→ `SZExtractCore`（纯 C++）。内部 C++ 桥接 delegate `ObjCBridge : public SZExtractDelegate` 把引擎回调转 ObjC：

| 回调类型 | 线程往返 | 实现 |
|---|---|---|
| 进度 / 文件开始 / 错误 | 异步 hop 主队列 | `dispatch_async(main)`，不等返回 |
| 覆盖 / 密码 / 内存（阻塞询问） | **同步**：worker 阻塞等主线程答复 | `dispatch_async(main)` 弹询问 + `dispatch_semaphore_wait` 等结果回传 |

**防死锁的关键约束**：解压本体跑在 `SZArchiveExtractor` 自建的**后台串行队列**，绝不在主队列。否则 `askOverwrite` 的 `dispatch_async(main)` 会把任务排到正被 worker 等待者占用的主队列后面 → 死锁。delegate 的阻塞方法返回值即答案（`SZOverwriteResponse` / 密码 `NSString*`，nil=取消）。

线程安全取消：`SZArchiveExtractor` 持 `std::atomic<bool>`，C++ delegate 的 `isCancelled()` 读它，引擎在下一回调点返回 `E_ABORT`。

## 验收证据（实测）

```
用例1 异步解压         completion 回主队列，willStart/进度回调正常        ✓
用例2 覆盖询问         目标已存在 → askOverwrite 在主线程被调，YesToAll  ✓ 信号量往返无死锁
用例3 密码询问         加密档无预设 → extractorAskPassword 返回密码      ✓ 解压成功
用例4 密码取消         返回 nil → 解压不成功（ok=NO）                    ✓ 取消语义正确
用例5 压测 100 次      连续 100 次覆盖往返，询问累计=100                  ✓ 无死锁（坐实 R5）
```

每个阻塞 delegate 方法内断言 `[NSThread isMainThread]`——证明询问确在主线程发生（GUI 可安全弹 NSAlert）。

## 关键发现：ObjC 类名撞系统私有框架

首版类名 `SZExtractor` 触发运行时警告：
```
objc: Class SZExtractor is implemented in both StreamingZip.framework and (本测试).
This may cause spurious casting failures and mysterious crashes.
```
macOS 私有框架 `StreamingZip` 已占用 `SZExtractor`。**对外 ObjC 类/protocol/options 统一改名 `SZArchiveExtractor*`**（C++ 层 `SZExtract*` 不变）。副作用收益：消除了 C++ 抽象类 `SZExtractDelegate` 与 ObjC protocol 同名的潜在二义。

→ 教训：`SZ` 前缀 + 通用词（Extractor/Archiver…）易撞系统私有框架；对外 ObjC 符号宜用更具体复合名。现有 `SZFolderSession/SZPanelModel/SZFolderItem` 经核未撞，保留。

## 边界与后续

- **机制层完成**：阻塞桥接（R5 死锁风险）已闭环。**实际 NSAlert 覆盖框 / 密码输入框 / 内存框的 1:1 UI**（`04-feature-map-dialogs-finder.md §3` 控件对齐）属 app 层 delegate 实现，随 **M2-T3/T4 app 接线**落地——它们是常规 AppKit，调本机制即可，非桥接难点。压测已用 mock delegate 覆盖往返路径。
- **进度节流**：`onProgressBytes` 高频异步派发，UI 端节流（NSTimer 拉取，M2-T4）避免主队列洪泛。
- **无上游改动**：全为 `Mac/` 新增（`SZExtractCore.cpp` 增 `SZExtractErrorText` 导出供 ObjC 错误列表用）。

## 产物

- 新增：`Mac/SevenZipKit/include/SevenZipKit/SZArchiveExtractor.h`、`src/SZArchiveExtractor.mm`、`tests/test_extractor.mm`、`build_test_extractor.sh`（一键，含 5 用例）。
- `SZExtractCore.{h,cpp}` 增 `SZExtractErrorText(opResult, encrypted)`（错误码→文案）。
