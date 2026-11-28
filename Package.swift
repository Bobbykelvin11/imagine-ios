// swift-tools-version:5.9
// Lets the online engine be unit-tested with `swift test` (no Xcode project needed).
import PackageDescription

let package = Package(
    name: "ImagineCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "ImagineCore", targets: ["ImagineCore"])],
    targets: [
        .target(name: "ImagineCore", path: "Imagine/Online/Core"),
        .testTarget(name: "ImagineCoreTests", dependencies: ["ImagineCore"], path: "Tests/ImagineCoreTests")
    ]
)
