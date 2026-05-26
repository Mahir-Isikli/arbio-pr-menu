// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ArbioPRMenu",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ArbioPRMenu", targets: ["ArbioPRMenu"])
    ],
    targets: [
        .executableTarget(name: "ArbioPRMenu")
    ]
)
