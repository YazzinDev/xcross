// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "xcross_swift_probe", platforms: [.iOS(.v13)],
    products: [.library(name: "xcross-swift-probe", targets: ["xcross_swift_probe"])],
    dependencies: [.package(path: "Support")],
    targets: [.target(name: "xcross_swift_probe", dependencies: [.product(name: "ProbeSupport", package: "Support")])]
)
