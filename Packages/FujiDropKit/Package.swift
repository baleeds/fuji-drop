// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FujiDropKit",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "FujiDropKit", targets: ["FujiDropKit"]),
    ],
    targets: [
        .target(name: "FujiDropKit"),
        .testTarget(name: "FujiDropKitTests", dependencies: ["FujiDropKit"]),
    ],
    swiftLanguageModes: [.v5]
)
