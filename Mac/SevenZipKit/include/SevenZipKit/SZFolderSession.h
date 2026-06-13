// SZFolderSession.h —— 归档"文件夹化"导航会话（包装 CAgent / CAgentFolder / IFolderFolder）。
// 对应 02-core-bridge.md §4.6。M1-T5 实现只读浏览路径；写操作（增删改）留 M3。
// 公开头：纯 Foundation，不暴露 7-Zip C++ 类型（C++ 成员藏于 .mm 的 class extension）。
#import <Foundation/Foundation.h>
#import "SZFolderItem.h"
NS_ASSUME_NONNULL_BEGIN

/// 一个 session 对应一个打开的归档。所有方法须在创建它的线程串行使用
/// （同一 IInArchive 禁并发，IArchive.h:305-308；正式版每 session 持串行队列，本类先约定单线程）。
@interface SZFolderSession : NSObject

/// 打开归档并绑定根文件夹。失败时 error 填 SZError*（见 SZError.h）。
/// 注意：底层 arcFormat 传空串=自动嗅探（不可 NULL，见 M1-T5 报告发现 3）。
+ (nullable instancetype)sessionWithFileURL:(NSURL *)url error:(NSError * _Nullable * _Nullable)error;

/// 当前文件夹的档内前缀路径（根为空串）。
@property (nonatomic, readonly, copy) NSString *currentPath;

/// 当前文件夹内的条目（CAgentFolder::LoadItems → GetNumberOfItems/GetProperty 的 ObjC 快照）。
/// M1-T5 为一次性快照；大归档懒加载策略见 02 §5.4，由 M1-T9 性能 gate 引入。
@property (nonatomic, readonly) NSArray<SZFolderItem *> *items;

/// 进入子文件夹（BindToFolder(index)）。index 为当前文件夹内序号；非目录项返回 NO。
- (BOOL)enterFolderAtIndex:(NSUInteger)index error:(NSError * _Nullable * _Nullable)error;

/// 返回上级文件夹（BindToParentFolder）。已在根则返回 NO。
- (BOOL)enterParentFolder:(NSError * _Nullable * _Nullable)error;

/// 是否可返回上级（非根）。
@property (nonatomic, readonly) BOOL canGoToParent;

/// 平铺模式（IFolderSetFlatMode）：YES = 递归展开为单层列表。
- (void)setFlatMode:(BOOL)flat;

/// 归档级属性（IGetFolderArcProps → GetArcProp，第 0 层）。
@property (nonatomic, readonly) uint32_t archiveErrorFlags;      // kpidErrorFlags（0=无错误）
@property (nonatomic, readonly) uint64_t archivePhysicalSize;    // kpidPhySize

@end

NS_ASSUME_NONNULL_END
