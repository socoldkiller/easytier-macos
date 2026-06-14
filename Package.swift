// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "EasyTierNativeMac",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "EasyTierCore", targets: ["EasyTierCore"]),
        .executable(name: "EasyTierMac", targets: ["EasyTierMac"]),
        .executable(name: "EasyTierValidator", targets: ["EasyTierValidator"]),
        .executable(name: "EasyTierPrivilegedHelper", targets: ["EasyTierPrivilegedHelper"]),
    ],
    dependencies: [
        .package(url: "https://github.com/mattt/swift-toml.git", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "CEasyTierFFI",
            publicHeadersPath: "include",
            linkerSettings: [
                .unsafeFlags(["-LVendor/Frameworks/static", "-leasytier_ffi"]),
                .linkedFramework("SystemConfiguration"),
            ]
        ),
        .target(
            name: "EasyTierCore",
            dependencies: [
                "CEasyTierFFI",
                .product(name: "TOML", package: "swift-toml"),
            ],
            linkerSettings: [
                .linkedLibrary("System"),
            ]
        ),
        .executableTarget(
            name: "EasyTierMac",
            dependencies: ["EasyTierCore"]
        ),
        .executableTarget(
            name: "EasyTierValidator",
            dependencies: ["EasyTierCore"]
        ),
        .executableTarget(
            name: "EasyTierPrivilegedHelper",
            dependencies: ["EasyTierCore"]
        ),
        .testTarget(
            name: "EasyTierCoreTests",
            dependencies: ["EasyTierCore"]
        ),
    ]
)
