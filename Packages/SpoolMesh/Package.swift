// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SpoolMesh",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SpoolMesh", targets: ["SpoolMesh"])
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19")
    ],
    targets: [
        .target(
            name: "SpoolMesh",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation")
            ]
        ),
        .testTarget(
            name: "SpoolMeshTests",
            dependencies: ["SpoolMesh"],
            resources: [.copy("Fixtures")]
        )
    ]
)
