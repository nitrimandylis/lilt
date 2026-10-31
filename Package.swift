// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Lilt",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Draws a window above the lock screen through the private SkyLight framework.
        .package(url: "https://github.com/Lakr233/SkyLightWindow", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(name: "Lilt", dependencies: ["SkyLightWindow"]),
    ]
)
