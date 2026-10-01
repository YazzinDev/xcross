import Flutter
import Foundation
import ProbeSupport

public class SwiftProbePlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "xcross/swift-probe", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(SwiftProbePlugin(), channel: channel)
    }
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard call.method == "probe" else { result(FlutterMethodNotImplemented); return }
        #if DEBUG
        let release = false
        #else
        let release = true
        #endif
        result(["sum": ProbeSupport.sumSquares(100), "resource": ProbeSupport.resource(), "release": release])
    }
}
