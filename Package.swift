// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Faro",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0")
    ],
    targets: [
        .target(name: "FaroCore"),
        .executableTarget(
            name: "Faro",
            dependencies: ["FaroCore", .product(name: "SwiftTerm", package: "SwiftTerm")]
        ),
        .testTarget(name: "FaroCoreTests", dependencies: ["FaroCore"]),
        .executableTarget(
            name: "FaroBench",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Bench/FaroBench"
        ),
    ]
)
