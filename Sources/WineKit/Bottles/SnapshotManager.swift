import Foundation

public struct BottleSnapshot: Identifiable, Hashable, Sendable {
    public let id: String
    public let label: String
    public let createdAt: Date
    /// Pasta do snapshot (contém `bottle/` e `snapshot.json`).
    public let url: URL

    var contentURL: URL { url.appendingPathComponent("bottle", isDirectory: true) }
}

/// Snapshots de bottles via cópia com clone APFS (`clonefile`): instantâneo
/// e só ocupa disco com o que mudar depois.
///
/// Layout: `Bottles/.snapshots/<pasta-do-bottle>/<id>/{bottle/, snapshot.json}`.
public struct SnapshotManager: Sendable {
    private struct Metadata: Codable { var id: String; var label: String; var createdAt: Date }

    public init() {}

    func directory(for bottle: Bottle) -> URL {
        bottle.url.deletingLastPathComponent()
            .appendingPathComponent(".snapshots", isDirectory: true)
            .appendingPathComponent(bottle.url.lastPathComponent, isDirectory: true)
    }

    public func list(_ bottle: Bottle) -> [BottleSnapshot] {
        let dir = directory(for: bottle)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return entries.compactMap { url -> BottleSnapshot? in
            guard let data = try? Data(contentsOf: url.appendingPathComponent("snapshot.json")),
                  let meta = try? Self.decoder.decode(Metadata.self, from: data) else { return nil }
            return BottleSnapshot(id: meta.id, label: meta.label, createdAt: meta.createdAt, url: url)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    public func create(_ bottle: Bottle, label: String) throws -> BottleSnapshot {
        let fm = FileManager.default
        let now = Date()
        let id = Self.idFormatter.string(from: now) + "-" + UUID().uuidString.prefix(4).lowercased()
        let url = directory(for: bottle).appendingPathComponent(id, isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        do {
            try fm.copyItem(at: bottle.url, to: url.appendingPathComponent("bottle", isDirectory: true))
            let meta = Metadata(id: id, label: label, createdAt: now)
            try Self.encoder.encode(meta).write(to: url.appendingPathComponent("snapshot.json"))
        } catch {
            try? fm.removeItem(at: url)
            throw error
        }
        return BottleSnapshot(id: id, label: label, createdAt: now, url: url)
    }

    /// Substitui o bottle pelo conteúdo do snapshot. Feche os programas antes
    /// (`WineRunner.killAll`). Em caso de falha o estado atual é preservado.
    public func restore(_ snapshot: BottleSnapshot, to bottle: Bottle) throws {
        let fm = FileManager.default
        let parent = bottle.url.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(".restore-\(UUID().uuidString)", isDirectory: true)
        let old = parent.appendingPathComponent(".old-\(UUID().uuidString)", isDirectory: true)

        try fm.copyItem(at: snapshot.contentURL, to: staging)
        do {
            try fm.moveItem(at: bottle.url, to: old)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        do {
            try fm.moveItem(at: staging, to: bottle.url)
        } catch {
            try? fm.moveItem(at: old, to: bottle.url) // rollback
            try? fm.removeItem(at: staging)
            throw error
        }
        try? fm.removeItem(at: old)
    }

    public func delete(_ snapshot: BottleSnapshot) throws {
        try FileManager.default.removeItem(at: snapshot.url)
    }

    public func deleteAll(for bottle: Bottle) throws {
        let dir = directory(for: bottle)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    static let idFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

/// Exporta/importa bottles como `.vinhobottle` (tar.gz).
public enum BottleArchiver {
    public static let fileExtension = "vinhobottle"

    public static func export(_ bottle: Bottle, to file: URL) async throws {
        let result = try await FoundationProcessLauncher().collect(WineInvocation(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-czf", file.path, "-C", bottle.url.deletingLastPathComponent().path, bottle.url.lastPathComponent],
            environment: ProcessInfo.processInfo.environment
        ))
        guard result.exitCode == 0 else {
            try? FileManager.default.removeItem(at: file)
            throw WineError.invalidArchive(reason: result.stderr.suffix(5).joined(separator: "\n"))
        }
    }
}

extension BottleManager {
    /// Importa um `.vinhobottle`. Se o nome já existir, vira "Nome 2", "Nome 3"…
    public func importBottle(from archive: URL) async throws -> Bottle {
        let fm = FileManager.default
        try fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let staging = rootURL.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }

        try await Archive.extract(archive, to: staging)
        let children = (try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        guard let folder = children.first(where: {
            fm.fileExists(atPath: $0.appendingPathComponent(Bottle.metadataFileName).path)
        }) else {
            throw WineError.invalidArchive(reason: "nenhum vinho.json no arquivo")
        }
        return try adopt(folder)
    }

    /// Move uma pasta de bottle para dentro da raiz, com nome e pasta únicos.
    func adopt(_ folder: URL) throws -> Bottle {
        var bottle = try load(at: folder)
        let taken = Set(try list().map { $0.name.lowercased() })
        let baseName = bottle.name
        var name = baseName
        var n = 2
        while taken.contains(name.lowercased()) {
            name = "\(baseName) \(n)"
            n += 1
        }
        let destination = rootURL.appendingPathComponent(uniqueFolderName(for: name), isDirectory: true)
        try FileManager.default.moveItem(at: folder, to: destination)
        bottle = Bottle(url: destination, settings: bottle.settings)
        bottle.settings.name = name
        try save(bottle)
        return bottle
    }
}
