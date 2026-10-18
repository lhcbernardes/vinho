import Foundation

/// Descobre runtimes Wine instalados.
///
/// Locais padrão (em ordem):
/// 1. `~/Library/Application Support/Vinho/Runtimes/<nome>/` — runtimes gerenciados pelo Vinho
/// 2. `/Applications` e `~/Applications`: `Wine*.app` e `Game Porting Toolkit.app` (layout Gcenx)
public struct RuntimeLocator: Sendable {
    public var searchDirectories: [URL]

    public init(searchDirectories: [URL] = RuntimeLocator.defaultSearchDirectories) {
        self.searchDirectories = searchDirectories
    }

    public static var managedRuntimesDirectory: URL {
        VinhoPaths.applicationSupport.appendingPathComponent("Runtimes", isDirectory: true)
    }

    public static var defaultSearchDirectories: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            managedRuntimesDirectory,
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true),
        ]
    }

    public func discover() -> [WineRuntime] {
        let fm = FileManager.default
        var found: [WineRuntime] = []
        var seenRoots = Set<String>()

        for dir in searchDirectories {
            guard let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            ) else { continue }

            let isAppsFolder = dir.lastPathComponent == "Applications"
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = entry.lastPathComponent
                // Em /Applications só olhamos bundles conhecidos para não varrer tudo.
                if isAppsFolder && !Self.isKnownRuntimeBundle(name) { continue }

                guard let root = Self.resolveRoot(entry) else { continue }
                let key = root.standardizedFileURL.path
                guard seenRoots.insert(key).inserted else { continue }

                let id = name.hasSuffix(".app") ? String(name.dropLast(4)) : name
                found.append(WineRuntime(
                    id: id,
                    rootURL: root,
                    capabilities: Self.detectCapabilities(root: root),
                    version: Self.readVersion(root: root)
                ))
            }
        }
        return found
    }

    /// "Wine Stable.app", "Wine Devel.app", "Game Porting Toolkit.app"…
    static func isKnownRuntimeBundle(_ name: String) -> Bool {
        guard name.hasSuffix(".app") else { return false }
        return name.hasPrefix("Wine") || name.contains("Porting Toolkit")
    }

    /// Aceita tanto um diretório com `bin/wine` quanto um `.app` com
    /// `Contents/Resources/wine/bin/wine` (layout dos builds Gcenx).
    static func resolveRoot(_ url: URL) -> URL? {
        let candidates = [
            url,
            url.appendingPathComponent("Contents/Resources/wine", isDirectory: true),
            url.appendingPathComponent("wine", isDirectory: true),
        ]
        return candidates.first(where: hasWineBinary)
    }

    static func hasWineBinary(_ root: URL) -> Bool {
        let fm = FileManager.default
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        return ["wine", "wine64"].contains {
            fm.isExecutableFile(atPath: bin.appendingPathComponent($0).path)
        }
    }

    static func detectCapabilities(root: URL) -> Set<RuntimeCapability> {
        let fm = FileManager.default
        func exists(_ relative: String) -> Bool {
            fm.fileExists(atPath: root.appendingPathComponent(relative).path)
        }
        var caps = Set<RuntimeCapability>()
        if exists("lib/external/D3DMetal.framework") || exists("lib64/apple_gptk/external/D3DMetal.framework") {
            caps.insert(.d3dMetal)
        }
        if exists("lib/dxmt") || exists("lib/wine/x86_64-unix/winemetal.so") {
            caps.insert(.dxmt)
        }
        if exists("lib/dxvk") && (exists("lib/libMoltenVK.dylib") || exists("lib64/libMoltenVK.dylib")) {
            caps.insert(.dxvk)
        }
        // Componentes instalados pelo Vinho (variantes de runtime).
        if let manifest = RuntimeComponentsManifest.read(from: root) {
            caps.formUnion(manifest.components.map(\.kind))
        }
        return caps
    }

    /// Lê `VERSION` (runtimes do Vinho) se existir. Não executa o binário
    /// para manter a descoberta rápida e sem efeitos colaterais.
    static func readVersion(root: URL) -> String? {
        let file = root.appendingPathComponent("VERSION")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public enum VinhoPaths {
    public static var applicationSupport: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Vinho", isDirectory: true)
    }

    public static var bottles: URL {
        applicationSupport.appendingPathComponent("Bottles", isDirectory: true)
    }
}
