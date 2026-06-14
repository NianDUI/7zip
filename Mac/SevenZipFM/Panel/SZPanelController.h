// SZPanelController.h —— 单面板控制器：驱动 NSTableView（view-based 虚拟模式）显示一个 id<SZPanelSource>。
// 面向统一数据源协议工作（M4-T1）：真实文件系统（SZFSDataSource）与归档内部（SZPanelModel）共用同一面板交互。
// 列/排序/选择/导航 UI 绑定；拖出/打开/解压按 source.representsArchive 分流。对应 05-roadmap M1-T7 / M4-T1。
#import <AppKit/AppKit.h>
#import "SevenZipKit/SZPanelModel.h"
#import "SevenZipKit/SZPanelSource.h"
NS_ASSUME_NONNULL_BEGIN

// 列标识（与 NSTableColumn.identifier 一致）
extern NSString *const SZColID_Name;
extern NSString *const SZColID_Size;
extern NSString *const SZColID_Modified;

@interface SZPanelController : NSObject <NSTableViewDataSource, NSTableViewDelegate, NSFilePromiseProviderDelegate, NSMenuDelegate>

/// 以 FS 数据源初始化（栈底）。归档通过 pushArchiveAtFSPath: 进入。
- (instancetype)initWithSource:(id<SZPanelSource>)source;
@property (nonatomic, readonly) id<SZPanelSource> source;

/// 当前栈顶若为归档则其磁盘路径，否则 nil——Finder 拖出（file promise 延迟解压）的解压源。
@property (nonatomic, readonly, nullable) NSString *archivePath;
/// 栈顶是否归档（调用方据此决定标题 / 自动刷新策略）。
@property (nonatomic, readonly) BOOL inArchive;

/// 进入 FS 上的归档文件（内部 push 归档数据源到栈顶）。成功返回 YES。
- (BOOL)pushArchiveAtFSPath:(NSString *)fsPath;
/// 当前可解压/测试的目标归档：栈顶归档→其路径；FS→选中的归档文件。供工具栏「解压/测试」。
- (nullable NSString *)currentArchiveFSPath;

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
/// 刷新当前层（重读数据源 + 重画表 + 按项标识恢复选择）。
- (void)refresh;
/// 新建文件夹（仅 FS；弹输入框）。
- (void)createFolderInteractive;
/// 在 Finder 中显示选中项（FS）或当前归档文件（归档）；无选中则显示当前目录。
- (void)revealSelectionInFinder;
/// 反选当前层选择。
- (void)invertSelectionInPanel;
/// 删除当前选中项（带确认；FS 进废纸篓 / 归档重写）。
- (void)deleteSelectionInteractive;
/// 点击列头排序（columnID→SZSortColumn，同列切向/新列默认向，逻辑在 SZPanelModel）。
- (void)sortByColumnID:(NSString *)columnID;

/// 表数据变化后通知（重载 tableView，更新地址/状态栏回调）。
@property (nonatomic, copy, nullable) void (^onReload)(void);

@end

NS_ASSUME_NONNULL_END
