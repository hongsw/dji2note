// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DJI2Note",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "DJI2Note", path: "Sources/DJI2Note",
                          swiftSettings: [.enableUpcomingFeature("BareSlashRegexLiterals")])
    ]
)
