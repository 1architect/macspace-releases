// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacSpace",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "SystemData", type: .dynamic, targets: ["MacSpaceSystemData"]),
        .library(name: "Siri", type: .dynamic, targets: ["MacSpaceSiri"]),
        .library(name: "Debloat", type: .dynamic, targets: ["MacSpaceDebloat"]),
        .executable(name: "MacSpaceMain", targets: ["MacSpaceMain"]),
        .executable(name: "MacSpaceCli", targets: ["MacSpaceCli"]),
        .executable(name: "MacSpaceHelper", targets: ["MacSpaceHelper"]),
    ],
    dependencies: [.package(path: "Sdk"), .package(path: "Platform"), .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0")],
    targets: [
        // Modules: each builds as a dynamic library and ships as a bundle in the app's PlugIns folder.
        .target(name: "MacSpaceSystemDataPrivileged", dependencies: [.product(name: "MacSpacePlatform", package: "Platform")], path: "Modules/SystemData/Privileged"),
        .target(name: "MacSpaceSystemData", dependencies: ["MacSpaceSystemDataPrivileged", .product(name: "MacSpaceSdk", package: "Sdk"), .product(name: "MacSpacePlatform", package: "Platform")], path: "Modules/SystemData/Module"),
        .target(name: "MacSpaceSiriPrivileged", dependencies: [.product(name: "MacSpacePlatform", package: "Platform")], path: "Modules/Siri/Privileged"),
        .target(name: "MacSpaceSiri", dependencies: ["MacSpaceSiriPrivileged", .product(name: "MacSpaceSdk", package: "Sdk"), .product(name: "MacSpacePlatform", package: "Platform")], path: "Modules/Siri/Module"),
        .target(name: "MacSpaceDebloatPrivileged", dependencies: [.product(name: "MacSpacePlatform", package: "Platform")], path: "Modules/Debloat/Privileged"),
        .target(name: "MacSpaceDebloat", dependencies: ["MacSpaceDebloatPrivileged", .product(name: "MacSpaceSdk", package: "Sdk"), .product(name: "MacSpacePlatform", package: "Platform")], path: "Modules/Debloat/Module"),
        // The app: shell, module registry, renderer, settings, scheduler.
        .target(name: "MacSpaceApp", dependencies: [.product(name: "MacSpaceSdk", package: "Sdk"), .product(name: "MacSpacePlatform", package: "Platform"), .product(name: "Sparkle", package: "Sparkle")], path: "App", exclude: ["Resources", "Main"]),
        .executableTarget(name: "MacSpaceMain", dependencies: ["MacSpaceApp"], path: "App/Main"),
        .executableTarget(name: "MacSpaceCli", dependencies: ["MacSpaceApp", "MacSpaceSiriPrivileged", .product(name: "MacSpaceSdk", package: "Sdk"), .product(name: "MacSpacePlatform", package: "Platform")], path: "Cli"),
        .executableTarget(name: "MacSpaceHelper", dependencies: ["MacSpaceSiriPrivileged", "MacSpaceDebloatPrivileged", "MacSpaceSystemDataPrivileged", .product(name: "MacSpacePlatform", package: "Platform")], path: "Helper"),
        .testTarget(name: "SdkTests", dependencies: [.product(name: "MacSpaceSdk", package: "Sdk")], path: "Tests/Sdk"),
        .testTarget(name: "AppTests", dependencies: ["MacSpaceApp", .product(name: "MacSpaceSdk", package: "Sdk")], path: "Tests/App"),
        .testTarget(name: "SystemDataTests", dependencies: ["MacSpaceSystemData", "MacSpaceSystemDataPrivileged", .product(name: "MacSpacePlatform", package: "Platform"), .product(name: "MacSpaceSdk", package: "Sdk")], path: "Tests/SystemData"),
        .testTarget(name: "SiriTests", dependencies: ["MacSpaceSiri", "MacSpaceSiriPrivileged", .product(name: "MacSpacePlatform", package: "Platform"), .product(name: "MacSpaceSdk", package: "Sdk")], path: "Tests/Siri"),
        .testTarget(name: "DebloatTests", dependencies: ["MacSpaceDebloat", "MacSpaceDebloatPrivileged", .product(name: "MacSpacePlatform", package: "Platform"), .product(name: "MacSpaceSdk", package: "Sdk")], path: "Tests/Debloat"),
        .testTarget(name: "PlatformTests", dependencies: [.product(name: "MacSpacePlatform", package: "Platform"), .product(name: "MacSpaceSdk", package: "Sdk")], path: "Tests/Platform"),
    ]
)
