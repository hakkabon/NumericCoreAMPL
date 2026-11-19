// swift-tools-version:5.9
import Foundation
import PackageDescription

// A local checkout can supply unreleased NumericCore changes during development.
let numericCore: Package.Dependency
if let path = ProcessInfo.processInfo.environment["NUMERICCORE_PACKAGE_PATH"] {
    numericCore = .package(name: "Swift-NumericCore", path: path)
} else {
    numericCore = .package(
        url: "https://github.com/hakkabon/Swift-NumericCore.git", from: "2.0.0")
}

let package = Package(
    name: "NumericCoreAMPL",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "NumericCoreAMPL", targets: ["NumericCoreAMPL"])],
    dependencies: [numericCore],
    targets: [
        .target(name: "NumericCoreAMPL", dependencies: [
            .product(name: "NumericCore", package: "Swift-NumericCore"),
            .product(name: "NumericCoreSparse", package: "Swift-NumericCore"),
            .product(name: "NumericCoreOptimization", package: "Swift-NumericCore"),
        ]),
        .testTarget(name: "NumericCoreAMPLTests", dependencies: [
            "NumericCoreAMPL",
            .product(name: "NumericCore", package: "Swift-NumericCore"),
            .product(name: "NumericCoreOptimization", package: "Swift-NumericCore"),
        ]),
    ]
)
