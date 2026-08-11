// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "DevFlow",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "DevFlow", targets: ["DevFlow"])
    ],
    targets: [
        .executableTarget(
            name: "DevFlow",
            path: "Sources/DevFlow",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "DevFlowTests",
            dependencies: ["DevFlow"],
            path: "Tests/DevFlowTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
