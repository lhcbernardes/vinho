import Foundation

/// Um arquivo baixável com integridade verificável.
public struct DownloadableArtifact: Codable, Hashable, Sendable {
    public var url: URL
    /// SHA-256 em hexadecimal minúsculo.
    public var sha256: String
    public var size: Int64

    public init(url: URL, sha256: String, size: Int64) {
        self.url = url
        self.sha256 = sha256.lowercased()
        self.size = size
    }
}

/// Um runtime Wine disponível para download.
public struct RuntimeDescriptor: Codable, Identifiable, Hashable, Sendable {
    public enum Channel: String, Codable, Sendable { case stable, devel, staging }

    /// Também é o nome da pasta em `Runtimes/`.
    public var id: String
    public var name: String
    public var version: String
    public var channel: Channel
    public var artifact: DownloadableArtifact
    public var notes: String?

    public init(id: String, name: String, version: String, channel: Channel, artifact: DownloadableArtifact, notes: String? = nil) {
        self.id = id
        self.name = name
        self.version = version
        self.channel = channel
        self.artifact = artifact
        self.notes = notes
    }
}

/// Uma camada gráfica (DXMT/DXVK) instalável sobre um runtime.
public struct ComponentDescriptor: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: RuntimeCapability
    public var name: String
    public var version: String
    public var artifact: DownloadableArtifact
    public var notes: String?

    public init(id: String, kind: RuntimeCapability, name: String, version: String, artifact: DownloadableArtifact, notes: String? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.version = version
        self.artifact = artifact
        self.notes = notes
    }
}

/// Catálogo de downloads. O embutido cobre o uso normal; um catálogo remoto
/// (mesmo formato JSON) pode substituí-lo sem atualizar o app.
public struct Catalog: Codable, Hashable, Sendable {
    public var schemaVersion: Int
    public var runtimes: [RuntimeDescriptor]
    public var components: [ComponentDescriptor]

    public init(schemaVersion: Int = 1, runtimes: [RuntimeDescriptor], components: [ComponentDescriptor]) {
        self.schemaVersion = schemaVersion
        self.runtimes = runtimes
        self.components = components
    }

    public var recommendedRuntime: RuntimeDescriptor? {
        runtimes.first { $0.channel == .stable } ?? runtimes.first
    }

    public static func load(from url: URL) async throws -> Catalog {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw WineError.downloadFailed(reason: "catálogo HTTP \(http.statusCode)")
        }
        return try JSONDecoder().decode(Catalog.self, from: data)
    }

    // Checksums copiados do campo `digest` das releases no GitHub (18/10/2026).
    public static let builtIn = Catalog(
        runtimes: [
            RuntimeDescriptor(
                id: "wine-stable-11.0_1", name: "Wine Stable", version: "11.0", channel: .stable,
                artifact: DownloadableArtifact(
                    url: URL(string: "https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.0_1/wine-stable-11.0_1-osx64.tar.xz")!,
                    sha256: "b50dc50ec7f41d58b115a6b685d4d1315ba3c797bd3aa0f49213f2703cb82388",
                    size: 185_303_032),
                notes: "Recomendado para apps em geral."),
            RuntimeDescriptor(
                id: "wine-devel-11.18", name: "Wine Devel", version: "11.18", channel: .devel,
                artifact: DownloadableArtifact(
                    url: URL(string: "https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.18/wine-devel-11.18-osx64.tar.xz")!,
                    sha256: "aa0ea4c82e636ae7bca2076387cb0a5affa26509ad13f119ecd0d62bd7ba6f82",
                    size: 190_974_384),
                notes: "Correções mais recentes; pode ter regressões."),
            RuntimeDescriptor(
                id: "wine-staging-11.18", name: "Wine Staging", version: "11.18", channel: .staging,
                artifact: DownloadableArtifact(
                    url: URL(string: "https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.18/wine-staging-11.18-osx64.tar.xz")!,
                    sha256: "b63704b91af269bc026a87f12bd297c4a50caaf570c322e600b6621ef918f127",
                    size: 193_105_336),
                notes: "Devel + patches experimentais (melhor para alguns jogos)."),
        ],
        components: [
            ComponentDescriptor(
                id: "dxmt-v0.80", kind: .dxmt, name: "DXMT", version: "0.80",
                artifact: DownloadableArtifact(
                    url: URL(string: "https://github.com/3Shain/dxmt/releases/download/v0.80/dxmt-v0.80-builtin.tar.gz")!,
                    sha256: "8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d",
                    size: 18_681_669),
                notes: "Direct3D 10/11 → Metal."),
            ComponentDescriptor(
                id: "dxvk-macos-1.10.3", kind: .dxvk, name: "DXVK-macOS", version: "1.10.3-async",
                artifact: DownloadableArtifact(
                    url: URL(string: "https://github.com/Gcenx/DXVK-macOS/releases/download/v1.10.3-20230507-repack/dxvk-macOS-async-v1.10.3-20230507-repack-builtin.tar.gz")!,
                    sha256: "810b1e5caf8ce975b784fae866a130ad23fa0ea233b0e5609cbc4a45f3ef6f00",
                    size: 2_785_833),
                notes: "Legado (2023). Prefira DXMT."),
        ]
    )
}

/// Registro dos componentes instalados numa variante de runtime
/// (`vinho-components.json` na raiz do runtime).
public struct RuntimeComponentsManifest: Codable, Hashable, Sendable {
    public struct Entry: Codable, Hashable, Sendable {
        public var id: String
        public var kind: RuntimeCapability
        public var version: String
    }

    public static let fileName = "vinho-components.json"

    public var baseRuntimeID: String
    public var components: [Entry]

    public static func read(from root: URL) -> RuntimeComponentsManifest? {
        let url = root.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RuntimeComponentsManifest.self, from: data)
    }

    public func write(to root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: root.appendingPathComponent(Self.fileName), options: .atomic)
    }
}
