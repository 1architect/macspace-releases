// swift-tools-version: 6.0
import PackageDescription

// The module contract. A separate package so that the app and every module link ONE shared copy of these types
// (SwiftPM would otherwise embed a private copy in each module, and the app could not recognise their classes).
let package = Package(
    name: "Sdk",
    platforms: [.macOS("27.0")],
    products: [.library(name: "MacSpaceSdk", type: .dynamic, targets: ["MacSpaceSdk"])],
    targets: [.target(name: "MacSpaceSdk", path: ".", exclude: ["Package.swift"])]
)
