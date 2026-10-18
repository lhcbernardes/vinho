import Foundation

/// CRUD de bottles no disco. Não executa Wine: a inicialização do prefixo
/// é responsabilidade do `WineRunner`, o que mantém este tipo testável.
public actor BottleManager {
    public let rootURL: URL
    private let fileManager = FileManager.default

    public init(rootURL: URL = VinhoPaths.bottles) {
        self.rootURL = rootURL
    }

    // MARK: - Leitura

    public func list() throws -> [Bottle] {
        try ensureRoot()
        let entries = try fileManager.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )
        return entries
            .compactMap { try? load(at: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func load(at url: URL) throws -> Bottle {
        let metadata = url.appendingPathComponent(Bottle.metadataFileName)
        guard fileManager.fileExists(atPath: metadata.path) else {
            throw WineError.notABottle(path: url.path)
        }
        let data = try Data(contentsOf: metadata)
        let settings = try Self.decoder.decode(BottleSettings.self, from: data)
        return Bottle(url: url, settings: settings)
    }

    // MARK: - Escrita

    /// Cria o diretório e o `vinho.json`. Rode `WineRunner.initializePrefix` depois.
    public func create(_ settings: BottleSettings) throws -> Bottle {
        let name = settings.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw WineError.invalidBottleName }

        let existing = try list()
        if existing.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            throw WineError.bottleAlreadyExists(name: name)
        }

        let folder = uniqueFolderName(for: name)
        let url = rootURL.appendingPathComponent(folder, isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)

        var settings = settings
        settings.name = name
        let bottle = Bottle(url: url, settings: settings)
        try save(bottle)
        return bottle
    }

    public func save(_ bottle: Bottle) throws {
        let data = try Self.encoder.encode(bottle.settings)
        try data.write(to: bottle.metadataURL, options: .atomic)
    }

    /// Renomeia só o nome exibido; o diretório fica estável para não quebrar atalhos.
    public func rename(_ bottle: Bottle, to newName: String) throws -> Bottle {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw WineError.invalidBottleName }
        if try list().contains(where: { $0.url != bottle.url && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            throw WineError.bottleAlreadyExists(name: name)
        }
        var updated = bottle
        updated.settings.name = name
        try save(updated)
        return updated
    }

    /// Duplica um bottle (clone APFS: instantâneo e quase sem espaço extra).
    public func duplicate(_ bottle: Bottle, as newName: String? = nil) throws -> Bottle {
        let taken = Set(try list().map { $0.name.lowercased() })
        let base = newName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "\(bottle.name) (cópia)"
        var name = base
        var n = 2
        while taken.contains(name.lowercased()) {
            name = "\(base) \(n)"
            n += 1
        }
        let destination = rootURL.appendingPathComponent(uniqueFolderName(for: name), isDirectory: true)
        try fileManager.copyItem(at: bottle.url, to: destination)
        var copy = Bottle(url: destination, settings: bottle.settings)
        copy.settings.name = name
        copy.settings.createdAt = Date()
        // Atalhos personalizados apontam para caminhos do bottle original: reescreve.
        copy.settings.shortcuts = bottle.settings.shortcuts.map { shortcut in
            var s = shortcut
            s.program = s.program.replacingOccurrences(of: bottle.url.path, with: destination.path)
            s.icon = s.icon?.replacingOccurrences(of: bottle.url.path, with: destination.path)
            return s
        }
        copy.settings.pinnedPrograms = bottle.settings.pinnedPrograms.map {
            $0.replacingOccurrences(of: bottle.url.path, with: destination.path)
        }
        try save(copy)
        return copy
    }

    /// Por padrão manda para o Lixo (recuperável).
    public func delete(_ bottle: Bottle, moveToTrash: Bool = true) throws {
        #if os(macOS)
        if moveToTrash {
            try fileManager.trashItem(at: bottle.url, resultingItemURL: nil)
            return
        }
        #endif
        try fileManager.removeItem(at: bottle.url)
    }

    // MARK: - Utilidades

    private func ensureRoot() throws {
        if !fileManager.fileExists(atPath: rootURL.path) {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        }
    }

    func uniqueFolderName(for name: String) -> String {
        let base = Self.slug(name)
        var candidate = base
        var n = 2
        while fileManager.fileExists(atPath: rootURL.appendingPathComponent(candidate).path) {
            candidate = "\(base)-\(n)"
            n += 1
        }
        return candidate
    }

    /// "Meu Jogo: Edição GOTY!" → "Meu-Jogo-Edicao-GOTY"
    public static func slug(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let parts = folded.unicodeScalars
            .map { allowed.contains($0) && $0.isASCII ? Character($0) : " " }
        let slug = String(parts)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return slug.isEmpty ? "bottle" : slug
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
