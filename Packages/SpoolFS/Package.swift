// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SpoolFS",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SpoolFS", targets: ["SpoolFS"])
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19")
    ],
    targets: [
        .target(
            name: "SpoolFS",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ]
        ),
        .testTarget(
            name: "SpoolFSTests",
            dependencies: ["SpoolFS"]
        )
    ]
)
