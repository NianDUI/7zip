// SZPanelController.h —— 单面板控制器：驱动 NSTableView（view-based 虚拟模式）显示 SZPanelModel。
// 承载列/排序/选择/导航的 UI 绑定。核心格式化与导航逻辑（stringForColumn:/双击/Backspace/排序）
// 不依赖真实 NSTableView 渲染，可 headless 单测。对应 05-roadmap §2 M1-T7。
#import <AppKit/AppKit.h>
#import "SevenZipKit/SZPanelModel.h"
NS_ASSUME_NONNULL_BEGIN

// 列标识（与 NSTableColumn.identifier 一致）
extern NSString *const SZColID_Name;
extern NSString *const SZColID_Size;
extern NSString *const SZColID_Modified;

@interface SZPanelController : NSObject <NSTableViewDataSource, NSTableViewDelegate>

- (instancetype)initWithModel:(SZPanelModel *)model;
@property (nonatomic, readonly) SZPanelModel *model;

/// 绑定一个 NSTableView（设 dataSource/delegate、建列、装双击/排序回调）。可为 nil 走纯逻辑（headless）。
- (void)bindTableView:(nullable NSTableView *)tableView;

/// 当前路径 / 状态栏文本（“N 项，选中 M，合计 X”）。
@property (nonatomic, readonly, copy) NSString *addressText;
@property (nonatomic, readonly, copy) NSString *statusText;

#pragma mark 可测的纯逻辑（不依赖 NSTableView 渲染）
- (NSInteger)rowCount;
- (NSString *)stringForColumn:(NSString *)columnID row:(NSInteger)row;  // 单元格文本
- (NSImage *_Nullable)iconForRow:(NSInteger)row;                        // 系统图标
/// 双击行：目录则进入并返回 YES（调用方据此刷新表）；文件返回 NO。
- (BOOL)activateRow:(NSInteger)row;
/// Backspace：上溯父目录，成功返回 YES。
- (BOOL)goToParent;
/// 点击列头排序（columnID→SZSortColumn，同列切向/新列默认向，逻辑在 SZPanelModel）。
- (void)sortByColumnID:(NSString *)columnID;

/// 表数据变化后通知（重载 tableView，更新地址/状态栏回调）。
@property (nonatomic, copy, nullable) void (^onReload)(void);

@end

NS_ASSUME_NONNULL_END
