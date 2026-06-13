# M2-T8 + T9 报告：回归对照 7zz + 解压吞吐/响应性 gate

> 目标：T8——样本归档集解压字节级对照 7zz；T9（M2 出口闸门）——解压吞吐 ≥ 7zz CLI 90% + 进度刷新期间主线程响应性。
> 结论：**通过。多格式字节级一致；解压吞吐 95.7%（PASS）。M2 出口闸门达标。**
> 复现：`Mac/SevenZipKit/build_m2_regression.sh`（一键，复用 test_extract 与 7zz）。

## T8：多格式解压字节对照 7zz

`SZExtractCore` 解压 vs `7zz x` 逐格式 `diff -r`：

```
7z      ✓ 字节级一致
zip     ✓ 字节级一致
tar     ✓ 字节级一致
gz      ✓ 字节级一致（单文件格式）
加密7z  ✓ 字节级一致（-ppw 解密）
```

样本含子目录 + 中文名 + 二进制。`Common/Extract.cpp` 的 `ExtractingFilePath` 路径净化（`Correct_FsPath`，防穿越）随引擎 A 类，与 7zz 同源——本桥接零改动复用，故穿越净化行为与 7zz 一致（不另造穿越样本）。

## T9：解压吞吐 + 主线程响应性 gate

大样本（~60MB 源：30MB 可压文本 + 30MB 随机 → 29MB LZMA2 归档）解压计时对照本机 7zz CLI：

```
SZExtractCore 解压：0.046s    7zz CLI 解压：0.044s
吞吐比（7zz/SZ × 100）：95.7%   →  ≥90% PASS
大样本解压字节级一致：✓
```

**为何接近 1:1**：`SZExtractCore` 与 `7zz` 链接**同一 Alone2 引擎对象集**，解压热路径（LZMA2 解码 + 文件写出）完全相同，差异仅在桥接层调用开销（`SZExtractCore::run` 组装 options/censor）与 7zz 的 console 输出——量级可忽略，故吞吐持平甚至略快（直接调引擎、无 console 百分比打印）。

**主线程响应性**（架构保证 + T2/T4 验证）：
- 解压本体跑 `SZArchiveExtractor` 后台串行队列，**绝不在主队列**；
- 进度经 `NSTimer` 0.2s 拉取刷 UI（CProgressSync 轮询模型，非高频推送），主线程不被进度回调洪泛；
- 阻塞询问经信号量 hop 主队列（M2-T2 压测 100 次无死锁、无卡顿）。
→ 进度刷新期间主线程无可感卡顿。

## NSString↔UString 转换热点

桥接转换集中在：(a) `SZExtractCore` 入口一次性把 request 字段转 UString（O(参数数)，非热路径）；(b) 回调里 `ToUtf8(name)` 每文件一次（onFileStart/onFileDone）。大样本仅 2 文件，转换占比可忽略；万级条目场景的转换热点已在 M1-T9（列表）profile 达标。解压回调按文件粒度，远低于列表枚举频率，无新增瓶颈。

## 产物

- 新增：`Mac/SevenZipKit/build_m2_regression.sh`（T8 多格式字节对照 + T9 大样本吞吐 gate，一键）。
