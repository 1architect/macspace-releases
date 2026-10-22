// swift-tools-version: 6.0
import PackageDescription

// Shared plumbing for the app, the helper and the modules. A separate package for the same reason as Sdk.
let package = Package(
    name: "Platform",
    platforms: [.macOS("26.0")],
    products: [.library(name: "MacSpacePlatform", type: .dynamic, targets: ["MacSpacePlatform"])],
    dependencies: [.package(path: "../Sdk")],
    targets: [
        .target(name: "MacSpacePlatform", dependencies: [.product(name: "MacSpaceSdk", package: "Sdk")], path: ".", exclude: ["Package.swift"]),
    ]
)
