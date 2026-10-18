import Foundation

/// Uma instalação do Wine utilizável pelo Vinho (ex.: build Gcenx
/// `wine-crossover`, um runtime baixado em Application Support, ou um
/// build próprio compilado a partir do código-fonte da CodeWeavers).
public struct WineRuntime: Identifiable, Hashable, Sendable {
    public let id: String
    /// Diretório que contém `bin/` e `lib/`.
    public let rootURL: URL
    public let capabilities: Set<RuntimeCapability>
    public let version: String?

    public init(id: String, rootURL: URL, capabilities: Set<RuntimeCapability>, version: String? = nil) {
        self.id = id
        self.rootURL = rootURL
        self.capabilities = capabilities
        self.version = version
    }

    public var binURL: URL { rootURL.appendingPathComponent("bin", isDirectory: true) }
    public var libURL: URL { rootURL.appendingPathComponent("lib", isDirectory: true) }

    /// Builds antigos separam `wine64`; builds WoW64 modernos usam só `wine`.
    public var wineURL: URL {
        let wine64 = binURL.appendingPathComponent("wine64")
        if FileManager.default.isExecutableFile(atPath: wine64.path) { return wine64 }
        return binURL.appendingPathComponent("wine")
    }

    public var wineserverURL: URL { binURL.appendingPathComponent("wineserver") }

    public func supports(_ backend: GraphicsBackend) -> Bool {
        guard let needed = backend.requiredCapability else { return true }
        return capabilities.contains(needed)
    }

    public var displayName: String {
        if let version { return "\(id) (\(version))" }
        return id
    }
}
