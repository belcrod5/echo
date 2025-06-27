// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "echo",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "echo",
            targets: ["echo"]
        ),
    ],
    dependencies: [
        // 必要な外部依存関係があればここに追加
    ],
    targets: [
        .executableTarget(
            name: "echo",
            dependencies: [],
            path: "echo",
            exclude: [
                "Assets.xcassets",
                "Preview Content",
                "Resources",
                ".DS_Store",
                "echo.entitlements"
            ],
            sources: [
                ".",
            ]
        ),
    ]
) 