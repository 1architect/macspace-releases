// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MACSPACE",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "Cleaning", type: .dynamic, targets: ["MacSpaceCleaning"]),
        .library(name: "Siri", type: .dynamic, targets: ["MacSpaceSiri"]),
        .library(name: "Debloat", type: .dynamic, targets: ["MacSpaceDebloat"]),
        .executable(name: "MacSpaceMain", targets: ["MacSpaceMain"]),
        .executable(name: "MacSpaceCli", targets: ["MacSpaceCli"]),
    ],
    dependencies: [.package(path: "Sdk"), .package(path: "Platform")],
    targets: [
        // Modules: each builds as a dynamic library and ships as a bundle in the app's PlugIns folder.
        .target(name: "MacSpaceCleaning", dependencies: [.product(name: "MacSpaceSdk", package: "Sdk"), .product(name: "MacSpacePlatform", package: "Platform")], path: "Modules/Cleaning/Module"),
        .target(name: "MacSpaceSiri", dependencies: [.product(name: "MacSpaceSdk", package: "Sdk"), .product(name: "MacSpacePlatform", package: "Platform")], path: "Modules/Siri/Module"),
        .target(name: "MacSpaceDebloat", dependencies: [.product(name: "MacSpaceSdk", package: "Sdk"), .product(name: "MacSpacePlatform", package: "Platform")], path: "Modules/Debloat/Module"),
        // The app: shell, module registry, renderer, settings, scheduler.
        .target(name: "MacSpaceApp", dependencies: [.product(name: "MacSpaceSdk", package: "Sdk"), .product(name: "MacSpacePlatform", package: "Platform")], path: "App", exclude: ["Resources", "Main"]),
        .executableTarget(name: "MacSpaceMain", dependencies: ["MacSpaceApp"], path: "App/Main"),
        .executableTarget(name: "MacSpaceCli", dependencies: ["MacSpaceApp", .product(name: "MacSpaceSdk", package: "Sdk"), .product(name: "MacSpacePlatform", package: "Platform")], path: "Cli"),
        .testTarget(name: "SdkTests", dependencies: [.product(name: "MacSpaceSdk", package: "Sdk")], path: "Tests/Sdk"),
        .testTarget(name: "AppTests", dependencies: ["MacSpaceApp", .product(name: "MacSpaceSdk", package: "Sdk")], path: "Tests/App"),
        .testTarget(name: "PlatformTests", dependencies: [.product(name: "MacSpacePlatform", package: "Platform")], path: "Tests/Platform"),
    ]
)
