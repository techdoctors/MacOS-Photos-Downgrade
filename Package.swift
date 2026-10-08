// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PhotosDowngrade",
    platforms: [.macOS(.v10_15)],
    products: [
        .executable(name: "pdowngrade", targets: ["pdowngrade"]),
        .executable(name: "PhotosDowngradeApp", targets: ["PhotosDowngradeApp"]),
    ],
    targets: [
        .target(name: "PhotosDowngradeCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "pdowngrade", dependencies: ["PhotosDowngradeCore"]),
        .executableTarget(name: "PhotosDowngradeApp", dependencies: ["PhotosDowngradeCore"]),
    ]
)
