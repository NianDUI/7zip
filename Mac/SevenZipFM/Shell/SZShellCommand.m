// SZShellCommand.m —— Shell 命令模型实现（M5-T2）。
#import "SZShellCommand.h"

@implementation SZShellCommand

+ (instancetype)commandWithOp:(SZShellOp)op paths:(NSArray<NSString *> *)paths {
  SZShellCommand *c = [SZShellCommand new];
  c.op = op;
  c.paths = paths ?: @[];
  c.methods = @[];
  return c;
}

#pragma mark op ↔ string

+ (NSString *)stringForOp:(SZShellOp)op {
  switch (op) {
    case SZShellOpOpen:            return @"open";
    case SZShellOpExtract:         return @"extract";
    case SZShellOpExtractHere:     return @"extracthere";
    case SZShellOpExtractToFolder: return @"extractto";
    case SZShellOpTest:            return @"test";
    case SZShellOpCompress:        return @"compress";
    case SZShellOpCompress7z:      return @"compress7z";
    case SZShellOpCompressZip:     return @"compresszip";
    case SZShellOpHash:            return @"hash";
    default:                       return @"";
  }
}

+ (SZShellOp)opForString:(NSString *)s {
  static NSDictionary<NSString *, NSNumber *> *map; static dispatch_once_t once;
  dispatch_once(&once, ^{
    map = @{ @"open": @(SZShellOpOpen), @"extract": @(SZShellOpExtract),
             @"extracthere": @(SZShellOpExtractHere), @"extractto": @(SZShellOpExtractToFolder),
             @"test": @(SZShellOpTest), @"compress": @(SZShellOpCompress),
             @"compress7z": @(SZShellOpCompress7z), @"compresszip": @(SZShellOpCompressZip),
             @"hash": @(SZShellOpHash) };
  });
  NSNumber *n = s ? map[s] : nil;
  return n ? (SZShellOp)n.integerValue : SZShellOpUnknown;
}

#pragma mark base64url

+ (NSString *)b64urlEncode:(NSData *)data {
  NSString *s = [data base64EncodedStringWithOptions:0];
  s = [s stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
  s = [s stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
  s = [s stringByReplacingOccurrencesOfString:@"=" withString:@""];
  return s;
}

+ (NSData *)b64urlDecode:(NSString *)s {
  NSMutableString *m = [s mutableCopy];
  [m replaceOccurrencesOfString:@"-" withString:@"+" options:0 range:NSMakeRange(0, m.length)];
  [m replaceOccurrencesOfString:@"_" withString:@"/" options:0 range:NSMakeRange(0, m.length)];
  while (m.length % 4) [m appendString:@"="];   // 补回 padding
  return [[NSData alloc] initWithBase64EncodedString:m options:0];
}

#pragma mark URL 编解码

- (NSURL *)url {
  if (self.op == SZShellOpUnknown) return nil;
  NSURLComponents *c = [NSURLComponents new];
  c.scheme = @"sevenzip";
  c.host = [SZShellCommand stringForOp:self.op];
  NSMutableArray<NSURLQueryItem *> *q = [NSMutableArray array];
  if (self.paths.count) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:self.paths options:0 error:nil];
    if (json) [q addObject:[NSURLQueryItem queryItemWithName:@"paths" value:[SZShellCommand b64urlEncode:json]]];
  }
  if (self.methods.count)
    [q addObject:[NSURLQueryItem queryItemWithName:@"methods" value:[self.methods componentsJoinedByString:@","]]];
  if (q.count) c.queryItems = q;
  return c.URL;
}

+ (instancetype)commandFromURL:(NSURL *)url {
  if (![url.scheme isEqualToString:@"sevenzip"]) return nil;
  SZShellOp op = [self opForString:url.host];
  if (op == SZShellOpUnknown) return nil;

  NSArray<NSString *> *paths = @[];
  NSArray<NSString *> *methods = @[];
  NSURLComponents *c = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
  for (NSURLQueryItem *it in c.queryItems) {
    if ([it.name isEqualToString:@"paths"] && it.value.length) {
      NSData *json = [self b64urlDecode:it.value];
      id arr = json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:nil] : nil;
      if ([arr isKindOfClass:NSArray.class]) {
        NSMutableArray *ps = [NSMutableArray array];
        for (id e in arr) if ([e isKindOfClass:NSString.class]) [ps addObject:e];
        paths = ps;
      }
    } else if ([it.name isEqualToString:@"methods"] && it.value.length) {
      methods = [it.value componentsSeparatedByString:@","];
    }
  }
  SZShellCommand *cmd = [SZShellCommand commandWithOp:op paths:paths];
  cmd.methods = methods;
  return cmd;
}

#pragma mark 共享启发式

+ (NSString *)baseNameForArchive:(NSString *)archivePath {
  NSString *name = archivePath.lastPathComponent;
  NSString *base = name.stringByDeletingPathExtension;
  return base.length ? base : name;   // 无扩展名时原样
}

+ (BOOL)isArchivePath:(NSString *)path {
  static NSSet *exts; static dispatch_once_t once;
  dispatch_once(&once, ^{
    exts = [NSSet setWithArray:@[
      @"7z", @"zip", @"rar", @"tar", @"gz", @"tgz", @"bz2", @"tbz", @"tbz2",
      @"xz", @"txz", @"zst", @"tzst", @"lz4", @"lzma", @"cab", @"iso", @"dmg",
      @"wim", @"arj", @"lzh", @"z", @"cpio", @"rpm", @"deb", @"chm", @"jar",
      @"war", @"apk", @"gzip", @"bzip2", @"001" ]];
  });
  NSString *ext = path.pathExtension.lowercaseString;
  return ext.length > 0 && [exts containsObject:ext];
}

+ (NSString *)archiveBaseNameForPaths:(NSArray<NSString *> *)paths {
  if (paths.count == 0) return @"Archive";
  if (paths.count == 1) {
    NSString *base = paths[0].lastPathComponent.stringByDeletingPathExtension;
    return base.length ? base : paths[0].lastPathComponent;
  }
  // 多选：用共同父目录名（同目录时是该目录名）
  NSString *parent = [paths[0] stringByDeletingLastPathComponent];
  NSString *pname = parent.lastPathComponent;
  return pname.length ? pname : @"Archive";
}

@end
