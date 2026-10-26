// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "DualScreenLink", platforms: [.macOS(.v13), .iOS(.v16), .tvOS(.v16)],
    products: [.library(name: "DualScreenLink", targets: ["DualScreenLink"])],
    targets: [.target(name: "DualScreenLink"), .testTarget(name: "DualScreenLinkTests", dependencies: ["DualScreenLink"])], swiftLanguageModes: [.v5])
