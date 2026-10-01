#import <UIKit/UIKit.h>

// Synthetic device gate for asset_catalog_audit.dart's Matrix.xcassets.
// This deliberately uses UIKit's public loader, not a CAR parser.
static NSData *pixels(UIImage *image) {
  if (!image.CGImage) return nil;
  size_t width = CGImageGetWidth(image.CGImage), height = CGImageGetHeight(image.CGImage);
  NSMutableData *data = [NSMutableData dataWithLength:width * height * 4];
  // Compare both loaders in a defined color space, including color conversion.
  CGColorSpaceRef color = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef context = CGBitmapContextCreate(data.mutableBytes, width, height, 8, width * 4,
    color, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
  CGColorSpaceRelease(color);
  if (!context) return nil;
  CGContextDrawImage(context, CGRectMake(0, 0, width, height), image.CGImage);
  CGContextRelease(context);
  return data;
}

@interface AssetProbeDelegate : NSObject <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation AssetProbeDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
  // Hold the system-owned launch screen briefly for capture; diagnostic only.
  [NSThread sleepForTimeInterval:3];
  NSMutableArray *results = [NSMutableArray array];
  BOOL passed = YES;
  for (NSString *name in @[@"Single1", @"Tiny1", @"Single2", @"Single3", @"Scaled", @"EqualPixels", @"AlphaVariants"]) {
    for (NSNumber *requested in @[@1, @2, @3]) {
      UITraitCollection *traits = [UITraitCollection traitCollectionWithTraitsFromCollections:@[
        [UITraitCollection traitCollectionWithDisplayScale:requested.doubleValue],
        [UITraitCollection traitCollectionWithUserInterfaceIdiom:UIUserInterfaceIdiomPhone]]];
      UIImage *actual = [UIImage imageNamed:name inBundle:NSBundle.mainBundle compatibleWithTraitCollection:traits];
      NSInteger expectedScale = requested.integerValue;
      if ([name isEqualToString:@"Single1"] || [name isEqualToString:@"Tiny1"]) expectedScale = 1;
      if ([name isEqualToString:@"Single2"]) expectedScale = 2;
      if ([name isEqualToString:@"Single3"]) expectedScale = 3;
      NSString *reference = [NSString stringWithFormat:@"Validation/%@-%ld.png", name, (long)expectedScale];
      UIImage *original = [UIImage imageWithContentsOfFile:[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:reference]];
      NSData *actualPixels = pixels(actual), *originalPixels = pixels(original);
      BOOL matches = actualPixels && originalPixels && [actualPixels isEqualToData:originalPixels];
      BOOL ok = matches && actual.scale == expectedScale;
      passed &= ok;
      [results addObject:@{@"name":name, @"requestedScale":requested, @"loaded":@(actual != nil),
        @"scale":@(actual.scale), @"points":NSStringFromCGSize(actual.size),
        @"pixelWidth":@(actual.CGImage ? CGImageGetWidth(actual.CGImage) : 0),
        @"expectedScale":@(expectedScale), @"comparisonColorSpace":@"sRGB",
        @"pixelsMatch":@(matches), @"passed":@(ok)}];
    }
  }
  NSDictionary *report = @{@"passed":@(passed), @"screenScale":@(UIScreen.mainScreen.scale), @"images":results};
  NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
  NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
  [json writeToFile:[documents stringByAppendingPathComponent:@"asset-lookup.json"] atomically:YES];
  NSLog(@"ASSET_LOOKUP %@", [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]);
  UIViewController *controller = [[UIViewController alloc] init];
  controller.view.backgroundColor = passed ? UIColor.systemGreenColor : UIColor.systemRedColor;
  UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(20, 80, UIScreen.mainScreen.bounds.size.width - 40, 180)];
  label.numberOfLines = 0;
  label.text = passed ? @"Asset lookup PASS\n21 checks: scales, pixels, alpha, 1x-only images\nSystem launch screen must still be inspected separately."
                      : @"Asset lookup FAIL\nRead Documents/asset-lookup.json";
  [controller.view addSubview:label];
  self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
  self.window.rootViewController = controller;
  [self.window makeKeyAndVisible];
  return YES;
}
@end

int main(int argc, char **argv) {
  @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(AssetProbeDelegate.class)); }
}
