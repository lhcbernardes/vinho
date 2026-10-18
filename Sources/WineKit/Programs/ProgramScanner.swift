import Foundation

public struct Program: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case executable, shortcut, custom }

    public let url: URL
    public let kind: Kind
    /// Argumentos extras (atalhos personalizados, ex. `steam://rungameid/550`).
    public let arguments: [String]
    public let displayName: String?
    /// Executável/ícone de onde extrair o ícone (padrão: `url`).
    public let iconURL: URL?
    /// Perfil de jogo associado (id da receita), se houver.
    public let profileID: String?

    public init(url: URL, kind: Kind, arguments: [String] = [], displayName: String? = nil, iconURL: URL? = nil, profileID: String? = nil) {
        self.url = url
        self.kind = kind
        self.arguments = arguments
        self.displayName = displayName
        self.iconURL = iconURL
        self.profileID = profileID
    }

    /// Único mesmo para dois atalhos do mesmo executável com argumentos diferentes.
    public var id: String {
        ([url.path] + arguments).joined(separator: "\u{1F}")
    }

    public var name: String { displayName ?? url.deletingPathExtension().lastPathComponent }
}

/// Atalho personalizado salvo no bottle (ex.: "Left 4 Dead 2" → steam.exe steam://rungameid/550).
public struct ProgramShortcut: Codable, Hashable, Sendable {
    public var name: String
    /// Caminho Unix do executável.
    public var program: String
    public var arguments: [String]
    /// Caminho Unix de onde tirar o ícone (opcional).
    public var icon: String?
    /// Jogo da Steam: exe relativo a `steamapps\common` — o ícone é achado em
    /// qualquer biblioteca, inclusive na compartilhada.
    public var steamGameExe: String?
    /// Perfil de jogo associado (id da receita).
    public var profileID: String?

    public init(name: String, program: String, arguments: [String] = [], icon: String? = nil,
                steamGameExe: String? = nil, profileID: String? = nil) {
        self.name = name
        self.program = program
        self.arguments = arguments
        self.icon = icon
        self.steamGameExe = steamGameExe
        self.profileID = profileID
    }

    /// Resolve o ícone dinamicamente (jogos da Steam podem estar em outra biblioteca).
    public func program(in bottle: Bottle) -> Program {
        let iconURL = steamGameExe.flatMap { Steam.gameExecutable($0, in: bottle) } ?? icon.map { URL(fileURLWithPath: $0) }
        return Program(url: URL(fileURLWithPath: program), kind: .custom, arguments: arguments,
                       displayName: name, iconURL: iconURL, profileID: profileID)
    }

    public var asProgram: Program {
        Program(
            url: URL(fileURLWithPath: program),
            kind: .custom,
            arguments: arguments,
            displayName: name,
            iconURL: icon.map { URL(fileURLWithPath: $0) }
        )
    }
}

/// Encontra programas instalados num bottle: atalhos do Menu Iniciar/Desktop
/// e executáveis em `Program Files`.
public enum ProgramScanner {
    /// Termos que indicam instaladores, desinstaladores e utilitários auxiliares.
    static let noiseTerms = [
        "unins", "uninst", "setup", "installer", "update", "crashreport", "crashhandler",
        "helper", "redist", "vcredist", "vc_redist", "dxsetup", "dotnet", "cefprocess", "webhelper",
    ]

    public static func scan(_ bottle: Bottle, maxDepth: Int = 4) -> [Program] {
        let c = bottle.driveC
        var programs: [Program] = []
        var seen = Set<String>()

        func add(_ url: URL, _ kind: Program.Kind) {
            guard !isNoise(url) else { return }
            if seen.insert(url.standardizedFileURL.path.lowercased()).inserted {
                programs.append(Program(url: url, kind: kind))
            }
        }

        // 1. Atalhos (o que o instalador quis expor ao usuário).
        for dir in shortcutDirectories(driveC: c) {
            for url in files(in: dir, extensions: ["lnk"], maxDepth: maxDepth) { add(url, .shortcut) }
        }

        // 2. Executáveis em Program Files.
        for name in ["Program Files", "Program Files (x86)"] {
            let dir = c.appendingPathComponent(name, isDirectory: true)
            for url in files(in: dir, extensions: ["exe"], maxDepth: maxDepth) { add(url, .executable) }
        }

        return programs.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func shortcutDirectories(driveC c: URL) -> [URL] {
        var dirs = [
            c.appendingPathComponent("ProgramData/Microsoft/Windows/Start Menu/Programs", isDirectory: true),
            c.appendingPathComponent("users/Public/Desktop", isDirectory: true),
        ]
        let users = c.appendingPathComponent("users", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: users.path)) ?? []
        for user in names where user != "Public" {
            let home = users.appendingPathComponent(user, isDirectory: true)
            dirs.append(home.appendingPathComponent("Desktop", isDirectory: true))
            dirs.append(home.appendingPathComponent("AppData/Roaming/Microsoft/Windows/Start Menu/Programs", isDirectory: true))
        }
        return dirs
    }

    static func isNoise(_ url: URL) -> Bool {
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        return noiseTerms.contains { name.contains($0) }
    }

    static func files(in dir: URL, extensions: Set<String>, maxDepth: Int) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var result: [URL] = []
        for case let url as URL in enumerator {
            if enumerator.level > maxDepth {
                enumerator.skipDescendants()
                continue
            }
            if extensions.contains(url.pathExtension.lowercased()) {
                result.append(url)
            }
        }
        return result
    }
}

/// Conversão de caminhos Unix ↔ Windows dentro de um bottle.
public enum WindowsPath {
    /// `<bottle>/drive_c/Games/x.exe` → `C:\Games\x.exe`; fora do drive_c → `Z:\…`.
    public static func from(_ url: URL, in bottle: Bottle) -> String {
        let path = url.standardizedFileURL.path
        let driveC = bottle.driveC.standardizedFileURL.path
        if path == driveC { return #"C:\"# }
        if path.hasPrefix(driveC + "/") {
            let rel = path.dropFirst(driveC.count + 1)
            return #"C:\"# + rel.replacingOccurrences(of: "/", with: #"\"#)
        }
        return "Z:" + path.replacingOccurrences(of: "/", with: #"\"#)
    }
}
