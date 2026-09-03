// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NoseyFactChecker",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "NoseyFactChecker",
            path: "Sources/NoseyFactChecker",
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ],
    swiftLanguageVersions: [.v5]
)
