// swift-tools-version:5.8

import PackageDescription

let package = Package(
    name: "ghbot",
    platforms: [.macOS(.v12)],
    dependencies: [
        .package(url: "https://github.com/swift-cloud/Compute", from: "2.18.0"),
        .package(url: "https://github.com/krzyzanowskim/CryptoSwift.git", from: "1.8.1"),
    ],
    targets: [
        .executableTarget(name: "ghbot", dependencies: ["Compute", "CryptoSwift"]),
    ]
)
