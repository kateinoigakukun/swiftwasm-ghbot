// swift-tools-version:5.5

import PackageDescription

let package = Package(
    name: "ghbot",
    platforms: [.macOS(.v12)],
    dependencies: [
        .package(name: "Compute", url: "https://github.com/AndrewBarba/swift-compute-runtime", branch: "main"),
        .package(url: "https://github.com/GoodNotes/CryptoSwift.git", branch: "swiftwasm-support"),
//        .package(name: "Compute", path: "../../AndrewBarba/swift-compute-runtime")
    ],
    targets: [
        .executableTarget(name: "ghbot", dependencies: ["Compute", "CryptoSwift"]),
    ]
)
