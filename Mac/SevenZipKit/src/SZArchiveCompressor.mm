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
  // 时间戳：仅下发偏离默认者（引擎默认 tm=on、tc/ta=off），降低对 tar 等格式触发不支持属性的概率。
  if (!o.storeMTime) req.extraProperties.push_back("tm=off");
  if (o.storeCTime)  req.extraProperties.push_back("tc=on");
  if (o.storeATime)  req.extraProperties.push_back("ta=on");
  if (o.timePrecision != SZTimePrecisionDefault) {  // tpN 后缀式（与命令行 -mtp 一致）
    char buf[16]; snprintf(buf, sizeof buf, "tp%ld", (long)o.timePrecision);
    req.extraProperties.push_back(buf);
  }
  return req;
}

#pragma mark - 内存估算（移植 CompressDialog.cpp::GetMemoryUsage_Threads_Dict_DecompMem）

namespace {
enum SZMethodId { SZ_M_NONE, SZ_M_LZMA2, SZ_M_DEFLATE };

// 等级→默认字典：与 C/LzmaEnc.c LzmaEncProps_Normalize 同式（64 位 size_t），
// 故本估算的字典即引擎压缩时实际采用者（我们走 -mx=N、不显式 -md）。
uint64_t SZLevelDict(int level) {
  if (level <= 4) return (uint64_t)1 << (level * 2 + 16);
  if (level <= 8) return (uint64_t)1 << (level + 20);
  return (uint64_t)1 << 28;   // level 9
}

uint64_t SZLzma2ChunkSize(uint64_t dict) {   // = Get_Lzma2_ChunkSize()
  uint64_t cs = dict << 2;
  const uint32_t kMin = (uint32_t)1 << 20, kMax = (uint32_t)1 << 28;
  if (cs < kMin) cs = kMin;
  if (cs > kMax) cs = kMax;
  if (cs < dict) cs = dict;
  cs += (kMin - 1);
  cs &= ~(uint64_t)(kMin - 1);
  return cs;
}

SZMemoryEstimate SZEstimate(int method, int level, int numThreads) {
  SZMemoryEstimate r = { (uint64_t)-1, (uint64_t)-1 };
  if (numThreads < 1) numThreads = 1;

  if (method == SZ_M_NONE || level == 0) {   // tar / 仅存储
    r.compressBytes = (1 << 20); r.decompressBytes = (1 << 20);
    return r;
  }

  if (method == SZ_M_LZMA2) {
    uint64_t size = 0;
    const uint64_t dict = SZLevelDict(level);
    uint32_t hs = (uint32_t)dict - 1;
    hs |= hs >> 1; hs |= hs >> 2; hs |= hs >> 4; hs |= hs >> 8;
    hs >>= 1;
    if (hs >= (1u << 24)) hs >>= 1;
    hs |= (1u << 16) - 1;
    if (level < 5) hs |= (256u << 10) - 1;
    hs++;
    uint64_t size1 = (uint64_t)hs * 4;
    size1 += dict * 4;
    if (level >= 5) size1 += dict * 4;
    size1 += (2 << 20);

    uint32_t numThreads1 = 1;
    if (numThreads > 1 && level >= 5) { size1 += (2 << 20) + (4 << 20); numThreads1 = 2; }
    uint32_t numBlockThreads = (uint32_t)numThreads / numThreads1;

    uint64_t chunkSize = (numBlockThreads != 1) ? SZLzma2ChunkSize(dict) : 0;
    if (chunkSize == 0) {
      const uint32_t kBlockSizeMax = (uint32_t)0 - (uint32_t)(1 << 16);
      uint64_t blockSize = dict + (1 << 16) + (numThreads1 > 1 ? (1 << 20) : 0);
      blockSize += (blockSize >> (blockSize < ((uint32_t)1 << 30) ? 1 : 2));
      if (blockSize >= kBlockSizeMax) blockSize = kBlockSizeMax;
      size += (uint64_t)numBlockThreads * (size1 + blockSize);
    } else {
      size += (uint64_t)numBlockThreads * (size1 + chunkSize);
      const uint32_t numPackChunks = numBlockThreads + (numBlockThreads / 8) + 1;
      if (chunkSize < ((uint32_t)1 << 26)) numBlockThreads++;
      if (chunkSize < ((uint32_t)1 << 24)) numBlockThreads++;
      if (chunkSize < ((uint32_t)1 << 22)) numBlockThreads++;
      size += (uint64_t)numPackChunks * chunkSize;
    }
    r.compressBytes = size;
    r.decompressBytes = dict + (2 << 20);
    return r;
  }

  if (method == SZ_M_DEFLATE) {
    uint64_t size = 0;
    uint32_t numMainZipThreads = (uint32_t)numThreads;   // deflate 子线程=1
    if (numMainZipThreads > 1)
      size += (uint64_t)numMainZipThreads * ((uint64_t)sizeof(size_t) << 23);
    else numMainZipThreads = 1;
    size += (uint64_t)((3 << 20) + (1 << 20)) * numMainZipThreads;   // 4 MB/线程
    r.compressBytes = size;
    r.decompressBytes = (2 << 20);
    return r;
  }
  return r;
}
} // namespace

#pragma mark - SZCompressOptions

@implementation SZCompressOptions
- (instancetype)init {
  if ((self = [super init])) {
    _level = 5; _solid = YES; _inputPaths = @[];
    _storeMTime = YES; _timePrecision = SZTimePrecisionDefault;
  }
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

+ (SZMemoryEstimate)memoryEstimateForFormat:(NSString *)format level:(NSInteger)level threads:(NSInteger)threads {
  int method = SZ_M_NONE;
  NSString *f = format.lowercaseString;
  if      ([f isEqualToString:@"7z"])  method = SZ_M_LZMA2;
  else if ([f isEqualToString:@"zip"]) method = SZ_M_DEFLATE;   // tar/其它 → 仅存储估算
  int nt = (int)threads;
  if (nt < 1) nt = (int)NSProcessInfo.processInfo.activeProcessorCount;
  return SZEstimate(method, (int)level, nt);
}

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
