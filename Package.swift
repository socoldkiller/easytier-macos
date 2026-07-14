// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "EasyTierNativeMac",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "EasyTierShared", targets: ["EasyTierShared"]),
        .library(name: "EasyTierRuntime", targets: ["EasyTierRuntime"]),
        .executable(name: "EasyTierMac", targets: ["EasyTierMac"]),
        .executable(name: "EasyTierPrivilegedHelper", targets: ["EasyTierPrivilegedHelper"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4"),
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
            ],
            linkerSettings: [
                .linkedFramework("IOKit"),
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
            dependencies: [
                "EasyTierShared",
                "EasyTierRuntime",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            resources: [
                .process("Resources"),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks",
                ]),
            ]
        ),
        .executableTarget(
            name: "EasyTierPrivilegedHelper",
            dependencies: ["EasyTierShared", "EasyTierRuntime"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Packaging/EasyTierPrivilegedHelper-Info.plist",
                ]),
            ]
        ),
        .testTarget(
            name: "EasyTierSharedTests",
            dependencies: ["EasyTierShared"]
        ),
        .testTarget(
            name: "EasyTierMacTests",
            dependencies: ["EasyTierMac", "EasyTierShared"]
        ),
    ]
)
