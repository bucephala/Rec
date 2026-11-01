// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Rec",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "RecLib",
            path: "Sources/RecLib",
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("UserNotifications"),
            ]
        ),
        .executableTarget(
            name: "Rec",
            dependencies: ["RecLib"],
            path: "Sources/Rec"
        ),
        .testTarget(
            name: "RecTests",
            dependencies: ["RecLib"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
