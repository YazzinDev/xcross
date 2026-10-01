// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "Support", platforms: [.iOS(.v13)],
    products: [.library(name: "ProbeSupport", type: .dynamic, targets: ["ProbeSupport"])],
    targets: [.target(name: "ProbeSupport", resources: [.copy("marker.txt")])]
)
