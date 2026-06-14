# M3-T4（+T1 基础）报告：压缩执行链桥接 + 参数合成

> 目标：把 7-Zip 压缩本体（`Common/Update.cpp` 的 `UpdateArchive()`，与 7zz `a` 命令同一函数）桥接到 macOS，纯 C++ `SZCompressDelegate` 替代 GUI 回调；并做基础压缩参数合成（等级/方法/字典/线程/固实/加密 → `CProperty`）。
> 结论：**通过。7z/zip/tar 压缩 roundtrip 字节一致；数据加密（错误密码解不开）、加密文件名头（-he）正确。**
> 复现：`Mac/SevenZipKit/build_test_compress.sh`（一键，压缩 + 7zz t 完整性 + 7zz x roundtrip 对照）。

## 机制

延续 Pimpl + internal codecs。`SZCompressCore`（纯 C++）：
- `SZUpdateCallback` 实现 `IUpdateCallbackUI2`（= `IUpdateCallbackUI` + `IDirItemsCallback` + 归档/扫描/MoveArc 方法）+ `IOpenCallbackUI`。**非 COM 虚接口**，故回调对象**栈分配安全**（UpdateArchive 不 AddRef，与 M2-T1 解压回调须堆分配相反）。
- `run()` 构造 `CUpdateOptions`：`SetActionCommand_Add()` + `MethodMode.Properties`（参数）+ `MethodMode.Type`（格式）+ 输入 censor → `UpdateArchive()`。

## 参数合成（对齐 7-Zip -m 开关名）

| 请求字段 | CProperty | 说明 |
|---|---|---|
| level | `x`=N | 等级 0–9 |
| method | `0`=名 | 主方法槽（如 LZMA2） |
| dictSize | `d`=Nb | 字典字节 |
| threads | `mt`=N | 线程 |
| solid（7z） | `s`=on/off | 固实 |
| encryptHeader（7z） | `he`=on | 加密文件名 |
| extraProperties | name=value | 透传，覆盖以上 |

`solid`/`he` 仅在格式为 7z 时下发（避免对 zip/tar 报错）。格式经 `FindFormatForArchiveType(format)` 显式设，或留空由 `UpdateArchive` 按 arcPath 扩展名 `FindFormatForArchiveName` 推断（同 7zz `a out.7z`）。密码经 `CryptoGetTextPassword2`（预设或 delegate 询问）。暂停/取消同解压（`Break()` nanosleep 轮询 + isCancelled）。

## 验收证据（实测）

```
A) 7z   roundtrip 字节一致 + 7zz t 完整性
B) zip  roundtrip 字节一致 + 7zz t
C) tar  roundtrip 字节一致 + 7zz t
D) 加密7z  正确密码 roundtrip 一致；错误密码无法解（确实加密）
E) -he 加密文件名  无密码无法列表；正确密码 roundtrip 一致
```

`CDirItems`（输入扫描）实现在 `EnumDirItems.o`（已在 Alone2 对象集，DirItem.o 无需）。

## 边界（T1 完整 ParamsModel 待补）

本轮做了 **T1 的参数→属性合成**部分。**T1 的 UI 算法**（g_Formats 能力表、各等级 auto 字典/Order/Solid/线程默认值表、`GetMemoryUsage_*` 内存估算）随 **M3-T2 压缩对话框**接入时做——它们是对话框显示"自动"档位与内存提示所需，压缩本体不依赖（引擎按 level 内部自选）。

## 产物

- 新增：`Mac/SevenZipKit/src/SZCompressCore.{h,cpp}`、`tests/test_compress.cpp`、`build_test_compress.sh`（一键，A–E 用例）。
