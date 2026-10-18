// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "OpenMimoProtocol",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "OpenMimoProtocol", targets: ["OpenMimoProtocol"])
    ],
    targets: [
        .target(name: "OpenMimoProtocol"),
        .testTarget(name: "OpenMimoProtocolTests", dependencies: ["OpenMimoProtocol"],
                    resources: [.copy("oa4_6.bin")]),
    ]
)
