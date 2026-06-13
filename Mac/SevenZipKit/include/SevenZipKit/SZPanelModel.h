// SZPanelModel.h —— 7zFM 面板的数据模型（排序 / 选择 / 列），建立在 SZFolderSession 之上。
// 对应 03-feature-map-filemanager.md §4.2-4.4 的 PanelSort/PanelSelect/PanelItems 纯逻辑部分。
// 不依赖 AppKit（可单测）；M1-T7 的 NSTableView dataSource 在其上实现。公开头：纯 Foundation。
#import <Foundation/Foundation.h>
#import "SZFolderItem.h"
#import "SZFolderSession.h"
NS_ASSUME_NONNULL_BEGIN

/// 一列定义（标题 / 对应排序列 / 显隐 / 宽度）。列持久化（结构化 plist）见 M4-T4。
@interface SZColumn : NSObject
@property (nonatomic, readonly, copy) NSString *title;
@property (nonatomic, readonly) SZSortColumn sortColumn;
@property (nonatomic) BOOL visible;
@property (nonatomic) double width;
@end

@interface SZPanelModel : NSObject

+ (nullable instancetype)panelWithFileURL:(NSURL *)url error:(NSError * _Nullable * _Nullable)error;

/// 当前层条目（已按 sortColumn/sortAscending 排序，目录恒在文件前）。
@property (nonatomic, readonly) NSArray<SZFolderItem *> *items;
@property (nonatomic, readonly, copy) NSString *currentPath;

#pragma mark 列与排序
@property (nonatomic, readonly) NSArray<SZColumn *> *columns;
@property (nonatomic, readonly) SZSortColumn sortColumn;
@property (nonatomic, readonly) BOOL sortAscending;
/// 点击列表头：同列切换升降序；新列用默认方向（Size/Modified 降序，其余升序，对齐 7zFM）。
- (void)sortByColumn:(SZSortColumn)column;

#pragma mark 导航（进入子目录/上溯后选择重置）
- (BOOL)enterFolderAtIndex:(NSUInteger)index error:(NSError * _Nullable * _Nullable)error;
- (BOOL)enterParentFolder:(NSError * _Nullable * _Nullable)error;
@property (nonatomic, readonly) BOOL canGoToParent;

#pragma mark 选择（按项跟随：排序后仍选中相同项）
@property (nonatomic, readonly) NSIndexSet *selectedIndexes;   // 相对当前 items 顺序
@property (nonatomic, readonly) NSUInteger selectedCount;
@property (nonatomic, readonly) uint64_t selectedSize;         // 选中项 size 合计
- (BOOL)isSelectedIndex:(NSUInteger)index;
- (void)selectIndex:(NSUInteger)index;
- (void)deselectIndex:(NSUInteger)index;
- (void)toggleIndex:(NSUInteger)index;
- (void)selectAll;
- (void)invertSelection;
- (void)clearSelection;

#pragma mark 归档级
@property (nonatomic, readonly) uint32_t archiveErrorFlags;

@end

NS_ASSUME_NONNULL_END
