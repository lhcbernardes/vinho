import Foundation

/// Um bottle é um WINEPREFIX isolado (com seu próprio `drive_c`) mais as
/// configurações do Vinho em `vinho.json`.
public struct Bottle: Identifiable, Hashable, Sendable {
    public static let metadataFileName = "vinho.json"

    /// Diretório do bottle; é também o WINEPREFIX.
    public let url: URL
    public var settings: BottleSettings

    public init(url: URL, settings: BottleSettings) {
        self.url = url
        self.settings = settings
    }

    public var id: URL { url }
    public var name: String { settings.name }
    public var prefixURL: URL { url }
    public var driveC: URL { url.appendingPathComponent("drive_c", isDirectory: true) }
    public var metadataURL: URL { url.appendingPathComponent(Self.metadataFileName) }

    /// `true` depois que o `wineboot --init` criou o prefixo.
    public var isInitialized: Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("system.reg").path)
    }
}
