// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ialert-ios",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "IAlert", targets: ["IAlert"]),
        .library(name: "IAlertNotificationService", targets: ["IAlertNotificationService"]),
    ],
    targets: [
        .target(name: "IAlert"),
        .target(name: "IAlertNotificationService"),
        .testTarget(name: "IAlertTests", dependencies: ["IAlert"]),
    ]
)
