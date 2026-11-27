// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FujiDropKit",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "FujiDropKit", targets: ["FujiDropKit"]),
    ],
    targets: [
        // LibRaw 0.22.2, vendored unchanged and used under CDDL 1.0 (see CLibRaw/VENDORED.md).
        // Only its C API is exposed. Always optimised: unoptimised Markesteijn is very slow, and
        // Debug builds on the phone would make every merge painful. No OpenMP (Apple's clang
        // doesn't ship it); the merge does its own strip parallelism.
        .target(
            name: "CLibRaw",
            exclude: ["VENDORED.md", "LICENSE.CDDL", "COPYRIGHT"],
            publicHeadersPath: "libraw",
            cxxSettings: [
                .headerSearchPath("."),
                .define("USE_ZLIB"),
                .unsafeFlags(["-O3", "-w"]),
            ],
            linkerSettings: [.linkedLibrary("z")]
        ),
        .target(name: "FujiDropKit", dependencies: ["CLibRaw"]),
        .testTarget(name: "FujiDropKitTests", dependencies: ["FujiDropKit"]),
    ],
    swiftLanguageModes: [.v5],
    cxxLanguageStandard: .cxx17
)
