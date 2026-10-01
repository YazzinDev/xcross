// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "xcross_objc_probe", platforms: [.iOS(.v13)],
    products: [.library(name: "xcross-objc-probe", targets: ["xcross_objc_probe"])],
    targets: [
        .binaryTarget(name: "ProbeBinary", path: "ProbeBinary.xcframework"),
        .target(name: "xcross_objc_probe", dependencies: ["ProbeBinary"], publicHeadersPath: "include")
    ]
)
