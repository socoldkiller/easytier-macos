// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "EasyTierNativeMac",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "EasyTierShared", targets: ["EasyTierShared"]),
        .executable(name: "EasyTierMac", targets: ["EasyTierMac"]),
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
            name: "EasyTierShared",
            dependencies: [
                .product(name: "TOML", package: "swift-toml"),
            ]
        ),
        .target(
            name: "EasyTierRuntime",
            dependencies: [
                "EasyTierShared",
                "CEasyTierFFI",
            ],
            linkerSettings: [
                .linkedLibrary("System"),
            ]
        ),
        .executableTarget(
            name: "EasyTierMac",
            dependencies: ["EasyTierShared"]
        ),
        .executableTarget(
            name: "EasyTierPrivilegedHelper",
            dependencies: ["EasyTierShared", "EasyTierRuntime"],
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/EasyTierPrivilegedHelper/Info.plist",
                ]),
            ]
        ),
        .testTarget(
            name: "EasyTierSharedTests",
            dependencies: ["EasyTierShared"]
        ),
    ]
)
