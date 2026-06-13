// M1-T5 链接桩 —— 满足 Agent 写路径栈（CAgentFolder vtable 完整性）的链接，使只读浏览端到端可运行。
//
// 背景（M1-T5 报告"重要修正"）：CAgentFolder 读写一体（单一类 vtable 含 IFolderFolder 读 + IFolderOperations
// 写全部虚方法），`new CAgent` 实例化强制要求写路径符号在链接期存在。写路径栈
// ArchiveFolderOut.o → WorkDir.o → ZipRegistry(NWorkDir::CInfo) 因此被拖入。这些符号在 M1-T5 只读运行路径
// 不被触达（CommonUpdateOperation 未执行），仅需"链接存在"。
//
// 归属（正式实现接管点）：
//   - NWorkDir::CInfo::Load/Save → M1-T1 ZipRegistry_mac.mm（NSUserDefaults，域 com.7zip.SevenZipFM）。
//       此处 Load 用 SetDefault()（POSIX 默认 System 工作目录，即"同目录临时文件"语义），是合理过渡而非纯空桩。
//
// 注：CompareFileNames_ForFolderList 原为 M1-T5 wcscmp 桩，M1-T6 已由 SZNaturalCompare.cpp 提供
//     真实自然排序（同源移植 PanelSort.cpp:14），此处不再定义。

#include "Common/MyWindows.h"
#include "7zip/UI/Common/ZipRegistry.h"

namespace NWorkDir {
  void CInfo::Load() { SetDefault(); }   // POSIX 默认 System 工作目录；M1-T1 改读 NSUserDefaults
  void CInfo::Save() const {}            // M1-T1 写 NSUserDefaults
}
