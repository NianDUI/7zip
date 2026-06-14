// SZDockProgress.m —— 见 .h。
#import "SZDockProgress.h"

#pragma mark - 自绘 dock tile（应用图标 + 底部进度条）

@interface SZDockTileView : NSView
@property (nonatomic) double fraction;       // 0–1
@property (nonatomic) BOOL indeterminate;    // 总量未知
@end

@implementation SZDockTileView

- (void)drawRect:(NSRect)dirty {
  NSRect b = self.bounds;
  [NSApp.applicationIconImage drawInRect:b fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];

  // 底部进度条（圆角胶囊）
  const CGFloat margin = b.size.width * 0.08;
  const CGFloat barH   = b.size.height * 0.13;
  NSRect track = NSMakeRect(margin, b.size.height * 0.10, b.size.width - 2 * margin, barH);
  NSBezierPath *trackPath = [NSBezierPath bezierPathWithRoundedRect:track xRadius:barH / 2 yRadius:barH / 2];
  [[NSColor colorWithWhite:1.0 alpha:0.85] setFill]; [trackPath fill];
  [[NSColor colorWithWhite:0.0 alpha:0.25] setStroke]; [trackPath stroke];

  double f = self.indeterminate ? 1.0 : MAX(0.0, MIN(1.0, self.fraction));
  if (f > 0.001) {
    NSRect fill = track;
    fill.size.width = (track.size.width) * f;
    if (fill.size.width >= barH) {   // 太窄画不出圆角就跳过
      NSBezierPath *fillPath = [NSBezierPath bezierPathWithRoundedRect:fill xRadius:barH / 2 yRadius:barH / 2];
      [(self.indeterminate ? [NSColor systemGrayColor] : [NSColor systemBlueColor]) setFill];
      [fillPath fill];
    }
  }
}

@end

#pragma mark - SZDockProgress

@implementation SZDockProgress {
  NSInteger _activeCount;
  SZDockTileView *_tileView;
}

+ (instancetype)shared {
  static SZDockProgress *s; static dispatch_once_t once;
  dispatch_once(&once, ^{ s = [SZDockProgress new]; });
  return s;
}

- (void)beginOperation {
  _activeCount++;
  if (!_tileView) {
    _tileView = [[SZDockTileView alloc] initWithFrame:NSMakeRect(0, 0, 128, 128)];
    NSApp.dockTile.contentView = _tileView;
  }
  _tileView.fraction = 0;
  _tileView.indeterminate = YES;   // 起步未知，待首个进度回调修正
  [NSApp.dockTile display];
}

- (void)updateFraction:(double)fraction {
  if (!_tileView) return;
  _tileView.indeterminate = (fraction < 0);
  _tileView.fraction = fraction < 0 ? 0 : fraction;
  [NSApp.dockTile display];
}

- (void)endOperation {
  if (--_activeCount > 0) return;
  _activeCount = 0;
  NSApp.dockTile.contentView = nil;   // 恢复正常应用图标
  _tileView = nil;
  [NSApp.dockTile display];
}

@end
