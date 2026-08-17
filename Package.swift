// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HarnessMobileCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v18)
    ],
    products: [
        .library(name: "HarnessMobileCore", targets: ["HarnessMobileCore"])
    ],
    targets: [
        .target(
            name: "HarnessMobileCore",
            path: "HarnessMobile/Core",
            exclude: [
                "Tools/CameraOCRTool.swift",
                "Tools/ProductionToolCatalog.swift"
            ]
        ),
        .testTarget(
            name: "HarnessMobileCoreTests",
            dependencies: ["HarnessMobileCore"],
            path: "HarnessMobileTests",
            exclude: [
                "AppModelProviderProfileTests.swift",
                "AppModelModelDiscoveryTests.swift",
                "ProductionToolCatalogTests.swift",
                "ISHPluginHostNodeSmoke.mjs"
            ]
        )
    ]
)
