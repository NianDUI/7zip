// SZEditWatcher.m —— 归档内文件编辑回写。
#import "SZEditWatcher.h"
#import "SevenZipKit/SZFolderSession.h"
#import "SevenZipKit/SZFolderItem.h"

#pragma mark - 写回：独立 session 打开归档 → 导航到内部父目录 → addFile（basename 覆盖同名 = 更新）

static BOOL SZWritebackFile(NSString *archiveFSPath, NSString *internalPath, NSString *localFile,
                            NSError **outErr) {
  NSError *err = nil;
  SZFolderSession *s = [SZFolderSession sessionWithFileURL:[NSURL fileURLWithPath:archiveFSPath] error:&err];
  if (!s) { if (outErr) *outErr = err; return NO; }
  if (!s.canUpdate) {
    if (outErr) *outErr = [NSError errorWithDomain:@"SZEditWatcher" code:1
        userInfo:@{NSLocalizedDescriptionKey: @"该归档格式不支持更新（无法回写）。"}];
    return NO;
  }
  // 逐层进入内部父目录（internalPath 形如 "a/b/file.txt"，最后一段为文件名）
  NSArray<NSString *> *comps = internalPath.pathComponents;
  for (NSUInteger i = 0; i + 1 < comps.count; i++) {
    NSString *seg = comps[i];
    NSUInteger idx = NSNotFound;
    NSArray<SZFolderItem *> *items = s.items;
    for (NSUInteger j = 0; j < items.count; j++) {
      if (items[j].isDirectory && [items[j].name isEqualToString:seg]) { idx = j; break; }
    }
    if (idx == NSNotFound) {
      if (outErr) *outErr = [NSError errorWithDomain:@"SZEditWatcher" code:2
          userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"归档内找不到目录「%@」。", seg]}];
      return NO;
    }
    if (![s enterFolderAtIndex:idx error:&err]) { if (outErr) *outErr = err; return NO; }
  }
  // addFile 用 localFile 的 basename 作为归档内名；与原文件同名 → 引擎 update 覆盖更新。
  BOOL ok = [s addFileAtPath:localFile error:&err];
  if (!ok && outErr) *outErr = err;
  return ok;
}

#pragma mark - 监视项

@interface SZEditItem : NSObject
@property (copy) NSString *localFile;
@property (copy) NSString *archive;
@property (copy) NSString *internalPath;
@property (copy) NSDate *baseMtime;
@property (assign) unsigned long long baseSize;
@end
@implementation SZEditItem
@end

#pragma mark - 监视器

@implementation SZEditWatcher {
  NSMutableArray<SZEditItem *> *_items;
  dispatch_queue_t _writeQueue;   // 串行：写回（重写归档）不并发
}

+ (instancetype)shared {
  static SZEditWatcher *g;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ g = [SZEditWatcher new]; });
  return g;
}

- (instancetype)init {
  if ((self = [super init])) {
    _items = [NSMutableArray array];
    _writeQueue = dispatch_queue_create("com.niandui.SevenZipFM.editWriteback", DISPATCH_QUEUE_SERIAL);
  }
  return self;
}

static BOOL SZStat(NSString *path, NSDate **mtime, unsigned long long *size) {
  NSDictionary *a = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
  if (!a) return NO;
  if (mtime) *mtime = a[NSFileModificationDate];
  if (size) *size = [a[NSFileSize] unsignedLongLongValue];
  return YES;
}

- (void)watchFile:(NSString *)localFile inArchive:(NSString *)archiveFSPath internalPath:(NSString *)internalPath {
  if (!localFile.length || !archiveFSPath.length || !internalPath.length) return;
  // 已有同一临时文件 → 更新基线即可（重新打开同一文件编辑）
  SZEditItem *item = nil;
  for (SZEditItem *e in _items) if ([e.localFile isEqualToString:localFile]) { item = e; break; }
  if (!item) {
    item = [SZEditItem new];
    item.localFile = localFile; item.archive = archiveFSPath; item.internalPath = internalPath;
    [_items addObject:item];
  }
  NSDate *m = nil; unsigned long long sz = 0;
  SZStat(localFile, &m, &sz);
  item.baseMtime = m; item.baseSize = sz;
}

- (void)rebase:(SZEditItem *)item {
  NSDate *m = nil; unsigned long long sz = 0;
  if (SZStat(item.localFile, &m, &sz)) { item.baseMtime = m; item.baseSize = sz; }
}

- (void)checkAndPromptWithParentWindow:(NSWindow *)parent {
  NSMutableArray<SZEditItem *> *changed = [NSMutableArray array];
  NSMutableArray<SZEditItem *> *dead = [NSMutableArray array];
  for (SZEditItem *item in _items) {
    NSDate *m = nil; unsigned long long sz = 0;
    if (!SZStat(item.localFile, &m, &sz)) { [dead addObject:item]; continue; }   // 临时文件没了 → 弃
    BOOL diff = (item.baseMtime && ![m isEqualToDate:item.baseMtime]) || sz != item.baseSize;
    if (diff) [changed addObject:item];
  }
  [_items removeObjectsInArray:dead];
  if (changed.count) [self promptNext:changed parent:parent];
}

// 链式：一个 sheet 完成后再处理下一个（避免多 sheet 叠加）
- (void)promptNext:(NSMutableArray<SZEditItem *> *)queue parent:(NSWindow *)parent {
  if (!queue.count) return;
  SZEditItem *item = queue.firstObject;
  [queue removeObjectAtIndex:0];

  NSAlert *a = [NSAlert new];
  a.messageText = [NSString stringWithFormat:@"“%@” 已被修改", item.internalPath.lastPathComponent];
  a.informativeText = [NSString stringWithFormat:@"是否将更改更新回归档「%@」？", item.archive.lastPathComponent];
  [a addButtonWithTitle:@"更新到归档"];
  [a addButtonWithTitle:@"不更新"];

  void (^cont)(void) = ^{ [self promptNext:queue parent:parent]; };
  void (^afterSheet)(NSModalResponse) = ^(NSModalResponse resp) {
    if (resp == NSAlertFirstButtonReturn) [self writeback:item parent:parent then:cont];
    else { [self rebase:item]; cont(); }   // 不更新：认账当前状态，避免反复询问
  };
  if (parent) [a beginSheetModalForWindow:parent completionHandler:afterSheet];
  else afterSheet([a runModal]);
}

- (void)writeback:(SZEditItem *)item parent:(NSWindow *)parent then:(void (^)(void))cont {
  dispatch_async(_writeQueue, ^{
    NSError *err = nil;
    BOOL ok = SZWritebackFile(item.archive, item.internalPath, item.localFile, &err);
    dispatch_async(dispatch_get_main_queue(), ^{
      if (ok) {
        [self rebase:item];   // 写回成功 → 更新基线，允许继续编辑再回写
        [NSNotificationCenter.defaultCenter postNotificationName:@"SZArchiveDidWriteback"
                                                          object:item.archive];
      } else {
        NSAlert *a = [NSAlert new];
        a.messageText = @"更新失败";
        a.informativeText = err.localizedDescription ?: @"无法将文件写回归档。";
        [a addButtonWithTitle:@"好"];
        if (parent) [a beginSheetModalForWindow:parent completionHandler:^(NSModalResponse r){ if (cont) cont(); }];
        else { [a runModal]; if (cont) cont(); }
        return;
      }
      if (cont) cont();
    });
  });
}

@end
