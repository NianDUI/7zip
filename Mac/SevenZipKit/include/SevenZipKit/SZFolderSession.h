// SZFolderSession.h —— 归档"文件夹化"导航会话（包装 CAgent / CAgentFolder / IFolderFolder）。
// 对应 02-core-bridge.md §4.6。M1-T5 实现只读浏览路径；写操作（增删改）留 M3。
// 公开头：纯 Foundation，不暴露 7-Zip C++ 类型（C++ 成员藏于 .mm 的 class extension）。
#import <Foundation/Foundation.h>
#import "SZFolderItem.h"
NS_ASSUME_NONNULL_BEGIN

/// 排序列（对应 7zFM 列）。默认方向：Size/Modified 降序，其余升序（PanelSort.cpp:264-272）。
typedef NS_ENUM(NSInteger, SZSortColumn) {
    SZSortColumnName = 0,
    SZSortColumnSize,
    SZSortColumnModified,
    SZSortColumnType,
    SZSortColumnAttributes,
};

/// 一个 session 对应一个打开的归档。所有方法须在创建它的线程串行使用
/// （同一 IInArchive 禁并发，IArchive.h:305-308；正式版每 session 持串行队列，本类先约定单线程）。
@interface SZFolderSession : NSObject

/// 打开归档并绑定根文件夹。失败时 error 填 SZError*（见 SZError.h）。
/// 注意：底层 arcFormat 传空串=自动嗅探（不可 NULL，见 M1-T5 报告发现 3）。
+ (nullable instancetype)sessionWithFileURL:(NSURL *)url error:(NSError * _Nullable * _Nullable)error;

/// 引擎支持的全部归档扩展名（小写无点，如 @"7z"/@"zip"）。替代 Windows PE 资源 ext 表（M1-T4），
/// 供 FM 判定"是否归档"、文件关联（M5-T3）。文件图标走 UTType（NSWorkspace iconForContentType）。
+ (NSArray<NSString *> *)supportedArchiveExtensions;

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

/// 设置排序（重排 items；目录恒在文件前不受方向影响，对齐 7zFM）。导航后保持当前排序。
- (void)setSortColumn:(SZSortColumn)column ascending:(BOOL)ascending;
@property (nonatomic, readonly) SZSortColumn sortColumn;
@property (nonatomic, readonly) BOOL sortAscending;

/// 归档级属性（IGetFolderArcProps → GetArcProp，第 0 层）。
@property (nonatomic, readonly) uint32_t archiveErrorFlags;      // kpidErrorFlags（0=无错误）
@property (nonatomic, readonly) uint64_t archivePhysicalSize;    // kpidPhySize

#pragma mark 写操作（M3-T5 归档内增删改；调 CAgentFolder + 重写归档，成功后 items 自动刷新）
/// 当前归档格式是否支持更新（只读格式如 rar 返回 NO）。
@property (nonatomic, readonly) BOOL canUpdate;
/// 删除当前层条目（indexes 相对当前 items 顺序）。
- (BOOL)deleteItemsAtIndexes:(NSIndexSet *)indexes error:(NSError * _Nullable * _Nullable)error;
/// 重命名当前层某条目。
- (BOOL)renameItemAtIndex:(NSUInteger)index toName:(NSString *)newName error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
