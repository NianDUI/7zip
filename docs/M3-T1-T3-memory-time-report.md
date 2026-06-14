# M3-T1 / T3 收尾报告：压缩内存估算 + 时间戳/精度选项

收口 M3 仅剩的两项增量，压缩对话框补齐到与 Windows CCompressDialog 对等的常用子集。

## T1 内存估算（压缩 / 解压所需内存，纯提示）

- **算法 1:1 移植** `CPP/7zip/UI/GUI/CompressDialog.cpp::GetMemoryUsage_Threads_Dict_DecompMem`
  的 LZMA2 / Deflate / 仅存储分支，落在 `SZArchiveCompressor.mm`（`namespace { SZEstimate(...) }`）。
- **等级→字典公式** 与引擎 `C/LzmaEnc.c::LzmaEncProps_Normalize` 完全同式
  （64 位：`L≤4 → 1<<(L*2+16)`；`L≤8 → 1<<(L+20)`；`L9 → 1<<28`）。
  因我们走 `-mx=N` 让引擎自选字典、不显式 `-md`，**显示值即实际压缩行为**。
- 接口：`+[SZArchiveCompressor memoryEstimateForFormat:level:threads:]` → `SZMemoryEstimate{compressBytes, decompressBytes}`；
  `threads<=0` 时按本机核数（`NSProcessInfo.activeProcessorCount`）估算，与 7-Zip GUI 默认一致。
- 对话框新增「需要内存」实时标签，随 格式 / 等级 / 线程 变化刷新；字节格式化对齐 `AddMemUsage` 的向上取整。
- 复算抽样（18 线程本机）：解压侧 = 字典+2MB（L5=34MB、L9=258MB，准确）；
  压缩侧单线程 L5≈370MB（即著名「字典×11.5」），多线程按块线程放大，与 7-Zip 同量级。

## T3 时间戳 / 精度（二级选项内联进主对话框，对齐 Windows 单对话框设计）

- 新增 `SZCompressOptions`：`storeMTime`(默认 YES) / `storeCTime` / `storeATime` / `timePrecision`。
- 经 `extraProperties` 透传引擎属性 `tm` / `tc` / `ta`（on/off）、`tpN`（精度）；
  **仅下发偏离默认者**（引擎默认 `tm=on`、`tc/ta=off`），避免对 tar 触发不支持属性。
- **格式门控**：时间戳组在 7z/zip 可用、tar 禁用；时间精度仅 7z。
- **精度档位**：默认 / 100 纳秒(`tp23`) / 纳秒最高(`tp3`)。
  7z 引擎仅接受 `{−1, 0, 3, 23}`（`7zHandlerOut.cpp:1031`），故**不提供秒级**（`tp1` 会被引擎拒）。

## 验证

- 引擎属性接受性（7zz 实测）：`-mtm=on -mtc=on -mta=on -mtp3` 压缩成功，`l -slt`
  显示 Modified / Created / Accessed 三时间均已存储；`-mtp23` 接受、`-mtp1` 被拒 ✓
- 内存公式独立复算无溢出，解压侧逐档与字典+2MB 吻合 ✓
- `build_app.sh` 全量编译链接通过，app 正常启动 ✓

## 待桌面验证点

1. 选中文件 → 压缩对话框：切换 **等级 / 线程**，「需要内存」标签实时变化。
2. 切到 **tar**：时间戳三复选 + 精度均置灰；切回 **7z**：精度可选。
3. 勾「创建时间 / 访问时间」+ 精度「纳秒」压缩 7z → 用 `7zz l -slt` 确认时间已写入。

M3 至此全部任务（T1–T7 + 右键菜单 + 拖入添加）完成。
