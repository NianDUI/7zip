// SZArchiveExtractor.mm —— 解压 ObjC 外观。只依赖纯 C++ 的 SZExtractCore（无 7-Zip 头，规避 BOOL 冲突）。
// 核心机制（M2-T2）：内部 C++ delegate 把引擎回调 hop 到主队列；阻塞式询问（覆盖/密码/内存）经
// dispatch_semaphore 让引擎工作线程同步等主队列对话框结果。解压本体在后台串行队列跑，绝不在主队列，
// 否则 askOverwrite 的 dispatch_async(main) 会与等待者死锁。

#import "SevenZipKit/SZArchiveExtractor.h"
#include "SZExtractCore.h"   // 纯 C++
#include <atomic>
#include <string>
#include <vector>

#pragma mark - 值转换

static NSString *SZS(const std::string &s) {
  return [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding] ?: @"";
}
static std::string SZU(NSString *s) {
  if (!s) return std::string();
  const char *c = s.UTF8String;
  return c ? std::string(c) : std::string();
}
static SZPathMode MapPathMode(SZExtractPathMode m) {
  switch (m) {
    case SZExtractPathModeNone:     return SZPathMode::NoPaths;
    case SZExtractPathModeAbsolute: return SZPathMode::AbsPaths;
    default:                        return SZPathMode::FullPaths;
  }
}
static SZOverwriteMode MapOverwriteMode(SZExtractOverwriteMode m) {
  switch (m) {
    case SZExtractOverwriteModeOverwrite:      return SZOverwriteMode::Overwrite;
    case SZExtractOverwriteModeSkip:           return SZOverwriteMode::Skip;
    case SZExtractOverwriteModeRename:         return SZOverwriteMode::Rename;
    case SZExtractOverwriteModeRenameExisting: return SZOverwriteMode::RenameExisting;
    default:                                   return SZOverwriteMode::Ask;
  }
}
static SZOverwriteAnswer MapResponse(SZOverwriteResponse r) {
  switch (r) {
    case SZOverwriteResponseYesToAll:   return SZOverwriteAnswer::YesToAll;
    case SZOverwriteResponseNo:         return SZOverwriteAnswer::No;
    case SZOverwriteResponseNoToAll:    return SZOverwriteAnswer::NoToAll;
    case SZOverwriteResponseAutoRename: return SZOverwriteAnswer::AutoRename;
    case SZOverwriteResponseCancel:     return SZOverwriteAnswer::Cancel;
    default:                            return SZOverwriteAnswer::Yes;
  }
}

// ObjC 选项 → C++ request（在调用线程拷贝，避免后台访问 ObjC 集合）
static SZExtractRequest MakeRequest(NSArray<NSString *> *archivePaths, SZArchiveExtractOptions *options) {
  SZExtractRequest req;
  for (NSString *p in archivePaths) req.archivePaths.push_back(SZU(p));
  req.outputDir     = SZU(options.outputDirectory);
  req.pathMode      = MapPathMode(options.pathMode);
  req.overwriteMode = MapOverwriteMode(options.overwriteMode);
  req.testMode      = options.testMode;
  req.elimDup       = options.eliminateDuplicatePaths;
  if (options.password) { req.hasPassword = true; req.password = SZU(options.password); }
  for (NSString *s in options.selectedPaths) req.selectedPaths.push_back(SZU(s));
  return req;
}

#pragma mark - C++ → ObjC 桥接 delegate

// 引擎在后台线程调用本类；进度异步 hop 主队列，阻塞询问经信号量同步等主队列。
class ObjCBridge : public SZExtractDelegate {
public:
  __weak id<SZArchiveExtractDelegate> objc;
  __weak SZArchiveExtractor *owner;
  std::atomic<bool> *cancelled;
  std::atomic<bool> *paused;
  uint64_t total = 0;

  void onTotalBytes(uint64_t t) override { total = t; }

  void onProgressBytes(uint64_t completed) override {
    id<SZArchiveExtractDelegate> d = objc; SZArchiveExtractor *o = owner;
    if (![d respondsToSelector:@selector(extractor:didUpdateFraction:completedBytes:totalBytes:)]) return;
    const uint64_t t = total;
    const double frac = t ? (double)completed / (double)t : 0.0;
    dispatch_async(dispatch_get_main_queue(), ^{
      [d extractor:o didUpdateFraction:frac completedBytes:completed totalBytes:t];
    });
  }

  void onFileStart(const std::string &name, bool isDir, bool isTest) override {
    (void)isTest;
    id<SZArchiveExtractDelegate> d = objc; SZArchiveExtractor *o = owner;
    if (![d respondsToSelector:@selector(extractor:willStartFile:isDirectory:)]) return;
    NSString *n = SZS(name); BOOL dir = isDir;
    dispatch_async(dispatch_get_main_queue(), ^{ [d extractor:o willStartFile:n isDirectory:dir]; });
  }

  void onFileDone(const std::string &name, int op, bool enc) override {
    if (op == 0) return;
    id<SZArchiveExtractDelegate> d = objc; SZArchiveExtractor *o = owner;
    if (![d respondsToSelector:@selector(extractor:didFailFile:message:)]) return;
    NSString *n = SZS(name);
    NSString *msg = SZS(SZExtractErrorText(op, enc));
    dispatch_async(dispatch_get_main_queue(), ^{ [d extractor:o didFailFile:n message:msg]; });
  }

  void onMessageError(const std::string &m) override {
    id<SZArchiveExtractDelegate> d = objc; SZArchiveExtractor *o = owner;
    if (![d respondsToSelector:@selector(extractor:didFailFile:message:)]) return;
    NSString *msg = SZS(m);
    dispatch_async(dispatch_get_main_queue(), ^{ [d extractor:o didFailFile:@"" message:msg]; });
  }

  SZOverwriteAnswer askOverwrite(
      const std::string &existPath, uint64_t existSize, double existMTime,
      const std::string &newPath, uint64_t newSize, double newMTime) override {
    id<SZArchiveExtractDelegate> d = objc; SZArchiveExtractor *o = owner;
    if (![d respondsToSelector:@selector(extractor:askOverwriteExisting:existSize:existDate:withNew:newSize:newDate:)])
      return SZOverwriteAnswer::Yes;
    NSString *ep = SZS(existPath), *np = SZS(newPath);
    NSDate *ed = existMTime >= 0 ? [NSDate dateWithTimeIntervalSince1970:existMTime] : nil;
    NSDate *nd = newMTime  >= 0 ? [NSDate dateWithTimeIntervalSince1970:newMTime]  : nil;
    __block SZOverwriteResponse resp = SZOverwriteResponseCancel;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
      resp = [d extractor:o askOverwriteExisting:ep existSize:existSize existDate:ed
                  withNew:np newSize:newSize newDate:nd];
      dispatch_semaphore_signal(sem);
    });
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    return MapResponse(resp);
  }

  bool getPassword(std::string &pw) override {
    id<SZArchiveExtractDelegate> d = objc; SZArchiveExtractor *o = owner;
    if (![d respondsToSelector:@selector(extractorAskPassword:)]) return false;
    __block NSString *result = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{ result = [d extractorAskPassword:o]; dispatch_semaphore_signal(sem); });
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    if (!result) return false;
    pw = SZU(result);
    return true;
  }

  bool askKeepGoingOnMemory(uint64_t required, uint64_t allowed) override {
    id<SZArchiveExtractDelegate> d = objc; SZArchiveExtractor *o = owner;
    if (![d respondsToSelector:@selector(extractor:askKeepGoingOnMemoryRequired:allowed:)]) return true;
    __block BOOL keep = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
      keep = [d extractor:o askKeepGoingOnMemoryRequired:required allowed:allowed];
      dispatch_semaphore_signal(sem);
    });
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    return keep;
  }

  bool isCancelled() override { return cancelled && cancelled->load(); }
  bool isPaused() override { return paused && paused->load(); }
};

#pragma mark - SZArchiveExtractOptions

@implementation SZArchiveExtractOptions
- (instancetype)init {
  if ((self = [super init])) {
    _pathMode = SZExtractPathModeFull;
    _overwriteMode = SZExtractOverwriteModeAsk;
  }
  return self;
}
@end

#pragma mark - SZExtractor

@implementation SZArchiveExtractor {
  dispatch_queue_t _queue;
  std::atomic<bool> _cancelled;
  std::atomic<bool> _paused;
}

- (instancetype)init {
  if ((self = [super init])) {
    _queue = dispatch_queue_create("com.7zip.SevenZipKit.extractor", DISPATCH_QUEUE_SERIAL);
    _cancelled.store(false);
    _paused.store(false);
  }
  return self;
}

- (void)cancel { _cancelled.store(true); }
- (void)setPaused:(BOOL)paused { _paused.store(paused); }
- (BOOL)isPaused { return _paused.load(); }

- (void)extractArchive:(NSString *)archivePath
               options:(SZArchiveExtractOptions *)options
              delegate:(id<SZArchiveExtractDelegate>)delegate
            completion:(void (^)(BOOL, uint64_t, uint64_t, uint64_t, NSString *))completion {
  [self extractArchives:archivePath ? @[archivePath] : @[]
                options:options delegate:delegate completion:completion];
}

- (void)extractArchives:(NSArray<NSString *> *)archivePaths
                options:(SZArchiveExtractOptions *)options
               delegate:(id<SZArchiveExtractDelegate>)delegate
             completion:(void (^)(BOOL, uint64_t, uint64_t, uint64_t, NSString *))completion {
  // 在调用线程把所有 ObjC 参数拷成 C++ request，避免后台线程访问 ObjC 集合。
  SZExtractRequest req = MakeRequest(archivePaths, options);

  _cancelled.store(false);
  _paused.store(false);
  __weak id<SZArchiveExtractDelegate> wdel = delegate;
  // 强引用 self：保证解压期间 _cancelled / _paused / _queue 有效（任务结束 block 释放，无长期循环引用）。
  dispatch_async(_queue, ^{
    ObjCBridge bridge;
    bridge.objc = wdel;
    bridge.owner = self;
    bridge.cancelled = &self->_cancelled;
    bridge.paused = &self->_paused;

    SZExtractResult r = SZExtractCore::run(req, &bridge);

    const BOOL ok = (r.hresult == 0 && r.numFileErrors == 0 && r.numOpenErrors == 0);
    const uint64_t nf = r.numFiles, nfe = r.numFileErrors, noe = r.numOpenErrors;
    NSString *em = r.errorMessage.empty() ? nil : SZS(r.errorMessage);
    if (completion)
      dispatch_async(dispatch_get_main_queue(), ^{ completion(ok, nf, nfe, noe, em); });
  });
}

- (BOOL)extractArchiveSync:(NSString *)archivePath options:(SZArchiveExtractOptions *)options {
  SZExtractRequest req = MakeRequest(archivePath ? @[archivePath] : @[], options);
  SZExtractResult r = SZExtractCore::run(req, nullptr);
  return (r.hresult == 0 && r.numFileErrors == 0 && r.numOpenErrors == 0);
}

@end
