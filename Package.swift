// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DoclingMac",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "DoclingMac", exclude: ["Resources"])
    ]
)
