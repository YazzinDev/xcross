#import "ObjcProbePlugin.h"
#include <ProbeBinary.h>
@implementation ObjcProbePlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
    FlutterMethodChannel *channel = [FlutterMethodChannel methodChannelWithName:@"xcross/objc-probe" binaryMessenger:[registrar messenger]];
    [registrar addMethodCallDelegate:[[ObjcProbePlugin alloc] init] channel:channel];
}
- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
    if (![call.method isEqualToString:@"probe"]) { result(FlutterMethodNotImplemented); return; }
// SwiftPM release sets optimization and omits DEBUG; it does not define NDEBUG.
#if defined(__OPTIMIZE__) && !defined(DEBUG)
    NSNumber *release = @YES;
#else
    NSNumber *release = @NO;
#endif
    result(@{@"answer": @42, @"binary": @(xcross_binary_answer()), @"release": release});
}
@end
