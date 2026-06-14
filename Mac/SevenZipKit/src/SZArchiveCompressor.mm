// SZArchiveCompressor.mm —— 见 .h。依赖纯 C++ SZCompressCore，不含 7-Zip 头（BOOL 隔离）。
// 同 SZArchiveExtractor：压缩跑后台串行队列，进度异步 hop 主队列，密码询问经信号量同步等主队列。
#import "SevenZipKit/SZArchiveCompressor.h"
#include "SZCompressCore.h"
#include <atomic>
#include <string>
#include <vector>

static NSString *SZS(const std::string &s) {
  return [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding] ?: @"";
}
static std::string SZU(NSString *s) {
  if (!s) return std::string();
  const char *c = s.UTF8String;
  return c ? std::string(c) : std::string();
}

#pragma mark - C++ → ObjC 桥接 delegate

class CompressBridge : public SZCompressDelegate {
public:
  __weak id<SZArchiveCompressDelegate> objc;
  __weak SZArchiveCompressor *owner;
  std::atomic<bool> *cancelled;
  std::atomic<bool> *paused;
  uint64_t total = 0;

  void onTotalBytes(uint64_t t) override { total = t; }
  void onProgressBytes(uint64_t completed) override {
    id<SZArchiveCompressDelegate> d = objc; SZArchiveCompressor *o = owner;
    if (![d respondsToSelector:@selector(compressor:didUpdateFraction:completedBytes:totalBytes:)]) return;
    const uint64_t t = total; const double f = t ? (double)completed / (double)t : 0.0;
    dispatch_async(dispatch_get_main_queue(), ^{ [d compressor:o didUpdateFraction:f completedBytes:completed totalBytes:t]; });
  }
  void onFileStart(const std::string &name) override {
    id<SZArchiveCompressDelegate> d = objc; SZArchiveCompressor *o = owner;
    if (![d respondsToSelector:@selector(compressor:willAddFile:)]) return;
    NSString *n = SZS(name);
    dispatch_async(dispatch_get_main_queue(), ^{ [d compressor:o willAddFile:n]; });
  }
  void onScanError(const std::string &path, const std::string &message) override {
    id<SZArchiveCompressDelegate> d = objc; SZArchiveCompressor *o = owner;
    if (![d respondsToSelector:@selector(compressor:scanError:message:)]) return;
    NSString *p = SZS(path), *m = SZS(message);
    dispatch_async(dispatch_get_main_queue(), ^{ [d compressor:o scanError:p message:m]; });
  }
  bool getPassword(std::string &pw) override {
    id<SZArchiveCompressDelegate> d = objc; SZArchiveCompressor *o = owner;
    if (![d respondsToSelector:@selector(compressorAskPassword:)]) return false;
    __block NSString *r = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{ r = [d compressorAskPassword:o]; dispatch_semaphore_signal(sem); });
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
    if (!r) return false;
    pw = SZU(r); return true;
  }
  bool isCancelled() override { return cancelled && cancelled->load(); }
  bool isPaused() override { return paused && paused->load(); }
};

static SZCompressRequest MakeRequest(NSString *archivePath, SZCompressOptions *o) {
  SZCompressRequest req;
  req.archivePath = SZU(archivePath);
  if (o.format) req.format = SZU(o.format);
  req.level = (int)o.level;
  if (o.method) req.method = SZU(o.method);
  req.dictSize = o.dictSize;
  req.threads = (int)o.threads;
  req.solid = o.solid;
  req.encryptHeader = o.encryptHeader;
  if (o.password.length) { req.hasPassword = true; req.password = SZU(o.password); }
  for (NSString *p in o.inputPaths) req.inputPaths.push_back(SZU(p));
  return req;
}

#pragma mark - SZCompressOptions

@implementation SZCompressOptions
- (instancetype)init {
  if ((self = [super init])) { _level = 5; _solid = YES; _inputPaths = @[]; }
  return self;
}
@end

#pragma mark - SZArchiveCompressor

@implementation SZArchiveCompressor {
  dispatch_queue_t _queue;
  std::atomic<bool> _cancelled;
  std::atomic<bool> _paused;
}

- (instancetype)init {
  if ((self = [super init])) {
    _queue = dispatch_queue_create("com.7zip.SevenZipKit.compressor", DISPATCH_QUEUE_SERIAL);
    _cancelled.store(false); _paused.store(false);
  }
  return self;
}

- (void)cancel { _cancelled.store(true); }
- (void)setPaused:(BOOL)paused { _paused.store(paused); }
- (BOOL)isPaused { return _paused.load(); }

- (void)compressToArchive:(NSString *)archivePath
                  options:(SZCompressOptions *)options
                 delegate:(id<SZArchiveCompressDelegate>)delegate
               completion:(void (^)(BOOL, uint64_t, NSString *))completion {
  SZCompressRequest req = MakeRequest(archivePath, options);
  _cancelled.store(false); _paused.store(false);
  __weak id<SZArchiveCompressDelegate> wdel = delegate;
  dispatch_async(_queue, ^{
    CompressBridge bridge;
    bridge.objc = wdel; bridge.owner = self;
    bridge.cancelled = &self->_cancelled; bridge.paused = &self->_paused;
    SZCompressResult r = SZCompressCore::run(req, &bridge);
    const BOOL ok = r.isOK();
    const uint64_t sz = r.outArchiveSize;
    NSString *em = r.errorMessage.empty() ? nil : SZS(r.errorMessage);
    if (completion)
      dispatch_async(dispatch_get_main_queue(), ^{ completion(ok, sz, em); });
  });
}

@end
