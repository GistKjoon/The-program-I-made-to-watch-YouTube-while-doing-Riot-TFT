// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "OnTopKeeper",
    platforms: [.macOS(.v13)],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "OnTopKeeper",
            dependencies: [],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Foundation"),
            ]
        )
    ]
)
