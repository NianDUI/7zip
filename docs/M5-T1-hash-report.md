# M5-T1 报告：CRC/SHA 校验和（哈希计算）

> M5（Finder 集成与打磨）启动。先做**哈希能力**——原属 M4-T9（PanelCrc），M4 阶段裁剪未做；它独立、纯计算、可与 `7zz h` 字节对照回归，且是 FinderSync「CRC 子菜单」（M5-T2）的前置依赖，故先落地。

## 做了什么

把 Windows 7-Zip 的「CRC SHA」校验和功能移植到 macOS 版：选中文件/文件夹 → 右键「校验和」子菜单或「文件 → 校验和」→ 弹结果窗，流式列出每文件每算法哈希 + 数据总和，可复制。

支持算法（与 `7zz i` 的 Hashers 段一致）：**CRC32 / CRC64 / SHA1 / SHA256 / SHA384 / SHA512 / SHA3-256 / BLAKE2sp / XXH64 / MD5**。

## 三层落点（延续方案 B Pimpl）

| 层 | 文件 | 职责 |
|---|---|---|
| 纯 C++ 核心 | `SZHashCore.{h,cpp}` | 封装 7-Zip `HashCalc()` 顶层函数 + 实现 `IHashCallbackUI` 回调；多文件/目录递归、流式、多算法；输出每文件每算法哈希 + 数据总和。公开头 BOOL 隔离（只 std/标量） |
| ObjC 桥接 | `SZHashCalculator.{h,mm}` + `SZHashItem`/`SZHashSummary` | 后台串行队列跑核心；进度/每文件结果/错误 hop 主队列；完成回主队列。无阻塞式询问（哈希无覆盖/密码） |
| AppKit | `SZHashResultController.{h,m}` | 结果窗（等宽 `NSTextView` 流式输出 + 进度条 + 复制/取消）；右键 CRC 子菜单（`SZPanelController`）+ 文件菜单「校验和」子菜单（`main.m` / `SZAppDelegate calcChecksum:`） |

## 关键技术点

- **internal-codecs-only → `HashCalc()` 零 codecs 参数**：`nm` 验证 Alone2 的 `CreateCoder.o` 无 `g_ExternalCodecs` 符号、`CHashBundle::SetMethods` 签名无 codecs 参数（`Z7_EXTERNAL_CODECS` 未定义），故 `HashCalc(censor, options, errorInfo, callback)` 直接调，无须像有些移植那样准备 `CExternalCodecs`。与 SZExtractCore/SZCompressCore 同构（调 UI/Common 顶层函数 + 实现回调）。
- **零额外 .o**：`HashCalc.o` + `EnumDirItems.o`（含 `CDirItems`/`EnumerateItems`/`CCensor`）已在 Alone2 且已链接进 app（不在 console-only 排除列表），无需补编译 `Censor.o`/`DirItem.o`。
- **`OpenFileError` 必须返回 `S_FALSE`**：`HashCalc.cpp` 内 `if (res != S_FALSE) return res;`——返回 `S_OK` 会提前结束整个任务而非跳过该文件。
- **哈希字符串大小写/字节序**（`HashHexToString`）：`size ≤ 8`（CRC32/CRC64/XXH64）→ **大写 + 反序数值**（如 `3610A686`）；`size > 8`（SHA 系/BLAKE2sp）→ **小写 + 原序**（如 `2cf24dba…`）。与 `7zz h` 输出一致。
- **数据总和（DataSum）带 extra 后缀**：多文件 `for data` 行格式为 `EB4B4DB7-00000000`（哈希 + 处理字节数 extra），与 `7zz h` 字节一致；单文件无 extra。结果窗如实 1:1 显示。
- **目录项不回调 `onFileResult`**：「算文件校验和」语义只列文件；`numDirs` 仍在 `AfterLastFile` 统计。

## 验证

`build_test_hash.sh`（全绿）：
- **test 1-5**：单文件 CRC32/SHA256 对照标准值（`"hello"`→`3610A686` / `2cf24dba…`）、目录递归 3 文件计数、空文件 CRC32=`00000000`、取消→E_ABORT、supportedMethods。
- **与 `7zz h` 字节对照**：CRC32/SHA256 单文件 + 多文件 `for data` 完全一致。
- **ObjC 桥接端到端**（test_hash_bridge）：真实路径（后台队列 + completion block + 主 runloop）产出哈希全对，dataSum 与 `7zz` 一致。

`build_app.sh`：编译链接通过；app 启动稳定（headless 环境无法点击 UI，菜单/结果窗交互留桌面确认，符合既有验证模式）。

## 后续

- **M5-T2 FinderSync**：把右键「解压/压缩/校验和」做进 Finder（extension target + 与主 app 通信）。本次的 `SZHashCore` 即其 CRC 子菜单的计算后端。
- 可选：结果窗改表格化列展示（当前等宽文本）；进度窗集成 `SZProgressWindowController`（当前自带轻量进度条）。
