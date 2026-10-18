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
    dependencies: [
        // Parser YAML para as receitas de instalação.
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
    ],
    targets: [
        // Núcleo sem dependência de UI: bottles, runtimes, processos Wine, receitas.
        .target(name: "WineKit", dependencies: ["Yams"]),
        // App SwiftUI.
        .executableTarget(name: "Vinho", dependencies: ["WineKit"]),
        .testTarget(name: "WineKitTests", dependencies: ["WineKit"]),
    ]
)
