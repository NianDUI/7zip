// SZPanelSource.h —— 面板数据源统一协议（M4-T1）。
// SZPanelController 面向本协议工作，使「浏览真实文件系统」与「浏览归档内部」共用同一套面板交互。
// 两个实现：SZFSDataSource（真实 FS，NSFileManager）、SZPanelModel（归档，建立在 SZFolderSession 上）。
// 公开头：纯 Foundation；面板项一律用 SZFolderItem 表达（归档项与磁盘项同结构）。
#import <Foundation/Foundation.h>
#import "SZFolderItem.h"
#import "SZFolderSession.h"   // SZSortColumn
NS_ASSUME_NONNULL_BEGIN

@protocol SZPanelSource <NSObject>

#pragma mark 列表 / 地址
/// 当前层条目（已按 sortColumn/sortAscending 排序，目录恒在文件前）。
@property (nonatomic, readonly) NSArray<SZFolderItem *> *items;
/// 地址栏显示文本：FS = 当前目录绝对路径；归档 = 档内前缀路径（根为空串）。
@property (nonatomic, readonly, copy) NSString *currentPath;
/// YES = 归档数据源（拖出走延迟解压、文件项无磁盘实体）；NO = 真实文件系统。
@property (nonatomic, readonly) BOOL representsArchive;
/// 某项对应的磁盘绝对路径；归档项返回 nil。供拖出 / 系统打开 / 文件操作统一取路径。
- (nullable NSString *)fileSystemPathForIndex:(NSUInteger)index;

#pragma mark 排序
@property (nonatomic, readonly) SZSortColumn sortColumn;
@property (nonatomic, readonly) BOOL sortAscending;
/// 点击列头：同列切向；新列用默认方向（Size/Modified 降序，余升序，对齐 7zFM）。
- (void)sortByColumn:(SZSortColumn)column;

#pragma mark 导航
- (BOOL)enterFolderAtIndex:(NSUInteger)index error:(NSError * _Nullable * _Nullable)error;
- (BOOL)enterParentFolder:(NSError * _Nullable * _Nullable)error;
@property (nonatomic, readonly) BOOL canGoToParent;
/// 重读当前层（FS 反映外部磁盘改动；归档内容不随外部变化，为空操作）。选择按项标识保留。
- (void)refresh;

#pragma mark 选择（按项标识跟随：排序 / 刷新后仍选中相同项）
@property (nonatomic, readonly) NSIndexSet *selectedIndexes;   // 相对当前 items 顺序
@property (nonatomic, readonly) NSUInteger selectedCount;
@property (nonatomic, readonly) uint64_t selectedSize;
- (BOOL)isSelectedIndex:(NSUInteger)index;
- (void)selectIndex:(NSUInteger)index;
- (void)deselectIndex:(NSUInteger)index;
- (void)toggleIndex:(NSUInteger)index;
- (void)selectAll;
- (void)invertSelection;
- (void)clearSelection;

#pragma mark 写操作
/// 是否可写（FS 恒 YES；归档看格式，只读格式如 rar 为 NO）。
@property (nonatomic, readonly) BOOL canUpdate;
- (BOOL)deleteItemsAtIndexes:(NSIndexSet *)indexes error:(NSError * _Nullable * _Nullable)error;
- (BOOL)renameItemAtIndex:(NSUInteger)index toName:(NSString *)newName error:(NSError * _Nullable * _Nullable)error;
/// FS：把外部文件拷贝进当前目录；归档：添加到当前层。
- (BOOL)addFileAtPath:(NSString *)fsPath error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
