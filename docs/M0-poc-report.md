# M0 PoC 实测验收报告

> 目标：实跑验证 `02-core-bridge.md §8` 的方案 B 基础路径——"核心 dylib + ObjC++ 桥接"是否真的成立。
> 结论：**核心可行性全部通过**。一键复现见 `Mac/poc/verify_m0.sh`。

## 环境

- 机器：macOS（Darwin 25.5.0），Apple Silicon **arm64**，Apple clang。
- 仓库：main @ `8c63d71`（7-Zip 26.01）。
- 产物：`CPP/7zip/Bundles/Format7zF/b/m_arm64/7z.so` → 改名 `lib7z.dylib`。

## 验收对照（docs/02 §8.2 的 AC 表）

| AC | 检查项 | 期望 | 实测 | 结果 |
|----|--------|------|------|------|
| AC-1 | 构建 + 符号收敛 | Mach-O DYLIB；`nm -gU \| grep -c ' T '` 精确 == 19，集合匹配 `exports7z.txt` | 19，集合精确匹配；体积 2.4M→2.1M（dead_strip 生效） | ✅ |
| AC-2 | install_name / 版本 | `@rpath/lib7z.dylib`，current/compat 已设 | `otool -D` = `@rpath/lib7z.dylib`，current=26.1 | ✅ |
| AC-3 | 段A roundtrip | Client7z 压缩→列表→解压 `diff` 全一致 | 3 文件（文本/8KB 随机二进制/中文名）逐字节一致，SHA256 一致 | ✅ |
| AC-4 | dlopen + ABI 闸门 | dlopen 成功，`interfaceType == 0` | dlopen 改名后的 `lib7z.dylib` 成功；`interfaceType=0`、`version=0x1A0001` | ✅ |
| AC-5 | 列表（含中文 UTF-8） | 正确打印归档内全部条目路径 | 裸 dlopen 路径正确列出 3 条目，中文名 UTF-8 正确，大小正确 | ✅ |
| AC-6 | 解压 | 解压输出与原文件 `diff` 一致 | 段A Client7z 解压逐字节一致（AC-3 覆盖） | ✅ |
| AC-7 | universal（x86_64+arm64） | `lipo -info` = `x86_64 arm64`，两切片均能 dlopen | **未做**：本机仅构建 arm64 切片 | ⏸ 待办 |
| — | 签名 / 公证 | Developer ID + hardened runtime | **未做**：分发阶段事项（自用可省） | ⏸ 待办 |

## 关键实测结论（独立于方案文档，现场取证）

1. **引擎可零改动 dylib 化**：`Format7zF` 用 stock makefile 直接产出 Mach-O DYLIB，仅依赖 libSystem + libc++。
2. **符号收敛方案可行**：文档 §1.3 的"零侵入挂接点 `LDFLAGS_STATIC_3`" + `exported_symbols_list` 实测把 3329 个全局 text 符号精确收敛到 19 个 C ABI 入口，且收敛后仍可正常 dlopen/Open/列表。
3. **桥接路径成立（不经 LoadCodecs）**：裸 `dlopen("lib7z.dylib") + dlsym + CreateObject` 能拿到 `IInArchive` 并完成真实 `Open` + 列表——这正是 `SevenZipKit.SZLibrary`（§4.1）将走的路径。
4. **ABI 闸门有效**：`GetModuleProp(kInterfaceType)=0`、`GetModuleProp(kVersion)=0x1A0001`，可作为加载期硬校验（§6.1）。
5. **编码路径通**：中文文件名在压缩/列表/解压三处均 UTF-8 正确（验证了 wchar_t(UTF-32)↔UTF-8 转换基线，§5.1）。

## 复现

```sh
bash Mac/poc/verify_m0.sh    # 1.dylib构建+符号收敛 2.段A roundtrip 3.段B 裸dlopen桥接
```

## 尚未验证（M0 剩余 / 后续里程碑）

- **AC-7 universal**：需补 x86_64 切片（`var_mac_x64.mak`，`USE_ASM=` 关闭 arm 汇编）后 `lipo -create`。Intel Mac 支持需要时再做；纯自用 Apple Silicon 可跳过。
- **段B 解压闭环**：当前裸 PoC 只做到 Open+列表；完整 `Extract` 回调（`IArchiveExtractCallback`）留待 SevenZipKit M2 实现（段A 已用 Client7z 证明引擎解压能力）。
- **签名 / 公证**：分发阶段事项，自用不触发。
