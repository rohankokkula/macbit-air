// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MacbitAir",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MacbitAir",
            path: "Sources/MacbitAir"
        )
    ]
)
