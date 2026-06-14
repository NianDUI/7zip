// SZHashCalculator.mm —— 哈希 ObjC 外观。只依赖纯 C++ 的 SZHashCore（无 7-Zip 头，规避 BOOL 冲突）。
// 计算在后台串行队列跑；进度/每文件结果/错误 hop 主队列；完成回主队列。无阻塞式询问。
#import "SevenZipKit/SZHashCalculator.h"
#include "SZHashCore.h"   // 纯 C++（核心 struct 名 SZHashFileResult，与 ObjC 类 SZHashItem 不冲突）
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
static NSDictionary<NSString *, NSString *> *PairsToDict(const std::vector<SZHashPair> &pairs) {
  NSMutableDictionary *d = [NSMutableDictionary dictionaryWithCapacity:pairs.size()];
  for (size_t i = 0; i < pairs.size(); i++)
    d[SZS(pairs[i].method)] = SZS(pairs[i].hex);
  return d;
}

#pragma mark - 算法名常量

NSString * const SZHashMethodCRC32    = @"CRC32";
NSString * const SZHashMethodCRC64    = @"CRC64";
NSString * const SZHashMethodSHA1     = @"SHA1";
NSString * const SZHashMethodSHA256   = @"SHA256";
NSString * const SZHashMethodSHA384   = @"SHA384";
NSString * const SZHashMethodSHA512   = @"SHA512";
NSString * const SZHashMethodSHA3_256 = @"SHA3-256";
NSString * const SZHashMethodBLAKE2sp = @"BLAKE2sp";
NSString * const SZHashMethodXXH64    = @"XXH64";
NSString * const SZHashMethodMD5      = @"MD5";

#pragma mark - SZHashItem

@interface SZHashItem ()
- (instancetype)initWithCore:(const SZHashFileResult &)r;   // C++ 引用参数须先声明，调用点才能正确推断
@end

@implementation SZHashItem
- (instancetype)initWithCore:(const SZHashFileResult &)r {
  if ((self = [super init])) {
    _path = SZS(r.path);
    _size = r.size;
    _hashes = PairsToDict(r.hashes);
  }
  return self;
}
- (NSString *)hashForMethod:(NSString *)method { return _hashes[method]; }
@end

#pragma mark - SZHashSummary

@interface SZHashSummary ()
@property (nonatomic) BOOL ok;
@property (nonatomic, copy) NSArray<SZHashItem *> *items;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *dataSum;
@property (nonatomic) uint64_t numFiles, numDirs, numErrors, totalSize;
@property (nonatomic, copy, nullable) NSString *errorMessage;
@end
@implementation SZHashSummary
@end

#pragma mark - C++ → ObjC 桥接 delegate

namespace {
class HashBridge : public SZHashDelegate {
public:
  __weak id<SZHashDelegate> objc;
  __weak SZHashCalculator *owner;
  std::atomic<bool> *cancelled = nullptr;
  uint64_t total = 0;
  NSMutableArray<SZHashItem *> *items;   // 强引用，主线程拼装结果（计算完才回 completion，无并发读写）

  void onTotalBytes(uint64_t t) override { total = t; }

  void onProgressBytes(uint64_t completed) override {
    id<SZHashDelegate> d = objc; SZHashCalculator *o = owner;
    if (![d respondsToSelector:@selector(hashCalculator:didUpdateFraction:completedBytes:totalBytes:)]) return;
    const uint64_t t = total;
    const double frac = t ? (double)completed / (double)t : 0.0;
    dispatch_async(dispatch_get_main_queue(), ^{
      [d hashCalculator:o didUpdateFraction:frac completedBytes:completed totalBytes:t];
    });
  }

  void onFileResult(const SZHashFileResult &r) override {
    SZHashItem *item = [[SZHashItem alloc] initWithCore:r];
    [items addObject:item];   // 后台线程独占 items（completion 前主线程不读），安全
    id<SZHashDelegate> d = objc; SZHashCalculator *o = owner;
    if (![d respondsToSelector:@selector(hashCalculator:didFinishFile:)]) return;
    dispatch_async(dispatch_get_main_queue(), ^{ [d hashCalculator:o didFinishFile:item]; });
  }

  void onScanError(const std::string &path, const std::string &message) override {
    id<SZHashDelegate> d = objc; SZHashCalculator *o = owner;
    if (![d respondsToSelector:@selector(hashCalculator:didEncounterError:message:)]) return;
    NSString *p = SZS(path), *m = SZS(message);
    dispatch_async(dispatch_get_main_queue(), ^{ [d hashCalculator:o didEncounterError:p message:m]; });
  }

  bool isCancelled() override { return cancelled && cancelled->load(); }
};
} // namespace

#pragma mark - SZHashCalculator

@implementation SZHashCalculator {
  dispatch_queue_t _queue;
  std::atomic<bool> _cancelled;
}

- (instancetype)init {
  if ((self = [super init])) {
    _queue = dispatch_queue_create("com.7zip.SevenZipKit.hash", DISPATCH_QUEUE_SERIAL);
    _cancelled.store(false);
  }
  return self;
}

- (void)cancel { _cancelled.store(true); }

+ (NSArray<NSString *> *)supportedMethods {
  std::vector<std::string> m = SZHashCore::supportedMethods();
  NSMutableArray *a = [NSMutableArray arrayWithCapacity:m.size()];
  for (size_t i = 0; i < m.size(); i++) [a addObject:SZS(m[i])];
  return a;
}

- (void)calculateForPaths:(NSArray<NSString *> *)paths
                  methods:(NSArray<NSString *> *)methods
                 delegate:(id<SZHashDelegate>)delegate
               completion:(void (^)(SZHashSummary *))completion {
  // 在调用线程把 ObjC 参数拷成 C++ request，避免后台访问 ObjC 集合。
  SZHashRequest req;
  for (NSString *p in paths) req.paths.push_back(SZU(p));
  for (NSString *m in methods) req.methods.push_back(SZU(m));

  _cancelled.store(false);
  __weak id<SZHashDelegate> wdel = delegate;
  dispatch_async(_queue, ^{
    HashBridge bridge;
    bridge.objc = wdel;
    bridge.owner = self;
    bridge.cancelled = &self->_cancelled;
    bridge.items = [NSMutableArray array];

    SZHashResult r = SZHashCore::run(req, &bridge);

    SZHashSummary *sum = [SZHashSummary new];
    sum.ok = (r.hresult == 0 && r.numErrors == 0);
    sum.items = [bridge.items copy];
    sum.dataSum = PairsToDict(r.dataSum);
    sum.numFiles = r.numFiles;
    sum.numDirs = r.numDirs;
    sum.numErrors = r.numErrors;
    sum.totalSize = r.totalSize;
    sum.errorMessage = r.errorMessage.empty() ? nil : SZS(r.errorMessage);
    if (completion)
      dispatch_async(dispatch_get_main_queue(), ^{ completion(sum); });
  });
}

@end
