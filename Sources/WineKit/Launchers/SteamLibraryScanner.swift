import Foundation

/// Jogo instalado pela Steam (lido de `steamapps/appmanifest_<appid>.acf`).
public struct InstalledSteamGame: Identifiable, Hashable, Sendable {
    public let appid: Int
    public let name: String
    /// `steamapps/common/<installdir>`
    public let installDirectory: URL
    /// O download terminou? (StateFlags 4 = totalmente instalado)
    public let isFullyInstalled: Bool

    public var id: Int { appid }
}

/// Descobre os jogos instalados em todas as bibliotecas da Steam do bottle,
/// para criar atalhos e aplicar perfis sem precisar de receita.
public enum SteamLibraryScanner {
    /// Ferramentas e redistribuíveis que não são jogos.
    static let ignoredAppIDs: Set<Int> = [228980, 1070560, 1391110, 1493710, 1628350, 961940, 1887720, 2180100, 2805730]

    public static func installedGames(in bottle: Bottle) -> [InstalledSteamGame] {
        var roots = [Steam.directory(in: bottle)]
        roots += Steam.libraryPaths(in: bottle).compactMap { WindowsPath.toUnix($0, in: bottle) }

        var seen = Set<Int>()
        var games: [InstalledSteamGame] = []
        for root in roots {
            let steamapps = root.appendingPathComponent("steamapps", isDirectory: true)
            let files = (try? FileManager.default.contentsOfDirectory(atPath: steamapps.path)) ?? []
            for file in files where file.hasPrefix("appmanifest_") && file.hasSuffix(".acf") {
                guard let text = try? String(contentsOf: steamapps.appendingPathComponent(file), encoding: .utf8),
                      let game = parseManifest(text, steamapps: steamapps),
                      !ignoredAppIDs.contains(game.appid),
                      !game.name.localizedCaseInsensitiveContains("redistributable"),
                      seen.insert(game.appid).inserted else { continue }
                games.append(game)
            }
        }
        return games.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func parseManifest(_ text: String, steamapps: URL) -> InstalledSteamGame? {
        func value(_ key: String) -> String? {
            let pattern = "\"\(key)\"\\s+\"((?:[^\"\\\\]|\\\\.)*)\""
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range]).replacingOccurrences(of: "\\\\", with: "\\")
        }
        guard let appid = value("appid").flatMap(Int.init), let name = value("name"),
              let installdir = value("installdir"), !installdir.isEmpty else { return nil }
        let flags = value("StateFlags").flatMap(Int.init) ?? 0
        return InstalledSteamGame(
            appid: appid, name: name,
            installDirectory: steamapps.appendingPathComponent("common/\(installdir)", isDirectory: true),
            isFullyInstalled: flags & 4 != 0
        )
    }

    /// Melhor palpite do executável do jogo (para ícone e perfil): o maior
    /// .exe até 3 níveis abaixo, ignorando instaladores, crash reporters etc.
    public static func guessExecutable(in directory: URL) -> URL? {
        let candidates = ProgramScanner.files(in: directory, extensions: ["exe"], maxDepth: 3)
            .filter { !ProgramScanner.isNoise($0) }
        return candidates.max { size($0) < size($1) }
    }

    private static func size(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }
}

/// Launchers de loja que o Vinho sabe instalar e abrir.
public enum GameLauncher: String, CaseIterable, Sendable {
    case steam, epic, gog

    public var displayName: String {
        switch self {
        case .steam: "Steam"
        case .epic: "Epic Games Launcher"
        case .gog: "GOG Galaxy"
        }
    }

    /// Caminho Windows do executável depois de instalado.
    public var windowsExecutable: String {
        switch self {
        case .steam: #"C:\Program Files (x86)\Steam\steam.exe"#
        case .epic: #"C:\Program Files (x86)\Epic Games\Launcher\Portal\Binaries\Win64\EpicGamesLauncher.exe"#
        case .gog: #"C:\Program Files (x86)\GOG Galaxy\GalaxyClient.exe"#
        }
    }

    /// Id da receita que instala o launcher (`provides: [<rawValue>]`).
    public var providesKey: String { rawValue }

    /// Argumentos para o launcher rodar no Wine do macOS. O Epic e o GOG usam
    /// CEF como a Steam; sem GPU no Wine, a interface fica preta.
    public var launchArguments: [String] {
        switch self {
        case .steam: SteamFixes.launchArguments
        case .epic: ["-opengl", "-SkipBuildPatchPrereq"]
        case .gog: ["--disable-gpu"]
        }
    }

    public func executable(in bottle: Bottle) -> URL? {
        WindowsPath.toUnix(windowsExecutable, in: bottle)
    }

    public func isInstalled(in bottle: Bottle) -> Bool {
        executable(in: bottle).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    public static func detect(_ program: URL) -> GameLauncher? {
        let name = program.lastPathComponent.lowercased()
        return allCases.first { URL(fileURLWithPath: $0.windowsExecutable.replacingOccurrences(of: "\\", with: "/")).lastPathComponent.lowercased() == name }
    }
}
