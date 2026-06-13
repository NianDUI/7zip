// SZQuarantine.m —— 见 .h。用 NSURL 的 NSURLQuarantinePropertiesKey 读写 com.apple.quarantine。
#import "SZQuarantine.h"

BOOL SZArchiveHasQuarantine(NSString *archivePath) {
  if (!archivePath.length) return NO;
  NSURL *u = [NSURL fileURLWithPath:archivePath];
  id v = nil;
  [u getResourceValue:&v forKey:NSURLQuarantinePropertiesKey error:NULL];
  return v != nil;
}

void SZApplyQuarantineFrom(NSString *archivePath, NSString *destPath) {
  if (!archivePath.length || !destPath.length) return;
  NSURL *src = [NSURL fileURLWithPath:archivePath];
  id q = nil;
  if (![src getResourceValue:&q forKey:NSURLQuarantinePropertiesKey error:NULL] || !q) return;

  NSFileManager *fm = NSFileManager.defaultManager;
  BOOL isDir = NO;
  if (![fm fileExistsAtPath:destPath isDirectory:&isDir]) return;

  // 顶层项
  [[NSURL fileURLWithPath:destPath] setResourceValue:q forKey:NSURLQuarantinePropertiesKey error:NULL];
  // 递归子项
  if (isDir) {
    NSDirectoryEnumerator *en = [fm enumeratorAtURL:[NSURL fileURLWithPath:destPath]
                          includingPropertiesForKeys:nil
                                             options:0
                                        errorHandler:nil];
    for (NSURL *child in en)
      [child setResourceValue:q forKey:NSURLQuarantinePropertiesKey error:NULL];
  }
}
