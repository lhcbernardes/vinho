// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Vinho",
    defaultLocalization: "pt-BR",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "WineKit", targets: ["WineKit"]),
        .executable(name: "Vinho", targets: ["Vinho"]),
    ],
    targets: [
        // Núcleo sem dependência de UI: bottles, runtimes, processos Wine.
        .target(name: "WineKit"),
        // App SwiftUI.
        .executableTarget(name: "Vinho", dependencies: ["WineKit"]),
        .testTarget(name: "WineKitTests", dependencies: ["WineKit"]),
    ]
)
