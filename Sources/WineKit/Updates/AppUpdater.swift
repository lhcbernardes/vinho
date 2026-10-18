import Foundation

/// Versão semântica simples (`v0.5.0`, `0.5.0-3-gabc123` → 0.5.0).
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init?(_ string: String) {
        var s = string.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        let core = s.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? s
        let parts = core.split(separator: ".").map { Int($0) }
        guard let first = parts.first, let major = first, parts.allSatisfy({ $0 != nil }) else { return nil }
        self.major = major
        self.minor = parts.count > 1 ? parts[1]! : 0
        self.patch = parts.count > 2 ? parts[2]! : 0
    }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}

/// Procura releases novas no GitHub (o workflow de release publica `Vinho-<tag>.zip`).
public struct AppUpdater: Sendable {
    public struct Release: Equatable, Sendable {
        public let tag: String
        public let version: AppVersion
        public let notes: String
        public let zipURL: URL
        public let pageURL: URL
    }

    public static let defaultRepository = "lhcbernardes/vinho"

    public let repository: String

    public init(repository: String = AppUpdater.defaultRepository) {
        self.repository = repository
    }

    public func latestRelease() async throws -> Release? {
        let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 { return nil }
        return try Self.parse(data)
    }

    /// Release mais nova que `current`, se houver.
    public func update(newerThan current: String) async throws -> Release? {
        guard let release = try await latestRelease(), let mine = AppVersion(current) else { return nil }
        return release.version > mine ? release : nil
    }

    static func parse(_ data: Data) throws -> Release? {
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        struct Payload: Decodable {
            let tag_name: String
            let body: String?
            let html_url: URL
            let assets: [Asset]
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard let version = AppVersion(payload.tag_name),
              let zip = payload.assets.first(where: { $0.name.hasPrefix("Vinho") && $0.name.hasSuffix(".zip") }) else {
            return nil
        }
        return Release(tag: payload.tag_name, version: version, notes: payload.body ?? "",
                       zipURL: zip.browser_download_url, pageURL: payload.html_url)
    }

    /// Baixa o zip, extrai e troca o app em `appURL`. Retorna o app novo.
    public func install(_ release: Release, replacing appURL: URL,
                        downloader: any Downloading = URLSessionDownloader(),
                        progress: @escaping @Sendable (Double?) -> Void = { _ in }) async throws -> URL {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("vinho-update-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let zip = work.appendingPathComponent("Vinho.zip")
        try await downloader.download(release.zipURL, to: zip) { received, total in
            progress(total.map { Double(received) / Double(max($0, 1)) })
        }
        let unzip = try await FoundationProcessLauncher().collect(WineInvocation(
            executable: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-x", "-k", zip.path, work.path],
            environment: ProcessInfo.processInfo.environment
        ))
        guard unzip.exitCode == 0,
              let newApp = (try? fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil))?
                .first(where: { $0.pathExtension == "app" }) else {
            throw WineError.invalidArchive(reason: "atualização sem Vinho.app")
        }
        _ = try fm.replaceItemAt(appURL, withItemAt: newApp)
        return appURL
    }
}
