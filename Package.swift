// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "IAlert",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "IAlert", targets: ["IAlert"]),
    ],
    targets: [
        .target(name: "IAlert"),
        .testTarget(name: "IAlertTests", dependencies: ["IAlert"]),
    ]
)
