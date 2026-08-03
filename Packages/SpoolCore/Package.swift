// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SpoolCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SpoolCore", targets: ["SpoolCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(path: "../SpoolMesh"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
    ],
    targets: [
        .target(
            name: "SpoolCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                "SpoolMesh",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        .testTarget(
            name: "SpoolCoreTests",
            dependencies: [
                "SpoolCore",
                "SpoolMesh",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        )
    ]
)
