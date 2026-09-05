// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FleetApp",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0")
    ],
    targets: [
        .executableTarget(
            name: "FleetApp",
            dependencies: ["SwiftTerm"],
            path: "Sources/FleetApp"
        )
    ]
)
