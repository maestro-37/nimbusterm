// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "NimbusTerm",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "NimbusTerm", targets: ["NimbusTerm"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.99.3")
    ],
    targets: [
        .target(name: "NimbusCore", path: "Sources/NimbusCore"),
        .executableTarget(
            name: "NimbusTerm",
            dependencies: [
                "NimbusCore",
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/NimbusTerm"
        ),
        .executableTarget(
            name: "NimbusCoreSelfTest",
            dependencies: ["NimbusCore"],
            path: "Tests/NimbusCoreSelfTest"
        )
    ],
    swiftLanguageModes: [.v5]
)
