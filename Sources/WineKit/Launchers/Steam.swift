import Foundation

/// Lojas/launchers que instalam jogos por conta própria.
public enum GameStore: String, Codable, Hashable, Sendable {
    case steam
}

/// Família gráfica de um bottle de launcher. Jogos DX9–11 e DX12 ficam em
/// bottles separados porque o backend vem do runtime (Wine × GPTK).
public enum GraphicsFamily: String, Codable, Hashable, Sendable, CaseIterable {
    /// DirectX 9, 10 e 11 — Wine (+ DXMT quando disponível).
    case classic
    /// DirectX 12 — runtime Game Porting Toolkit (D3DMetal).
    case dx12

    public init(directX: Int?) {
        self = (directX ?? 11) >= 12 ? .dx12 : .classic
    }

    public init(bottle: Bottle) {
        self = bottle.settings.graphics == .d3dMetal ? .dx12 : .classic
    }

    /// Backend preferido; o app cai para WineD3D se o runtime não tiver.
    public var preferredBackend: GraphicsBackend {
        switch self {
        case .classic: .dxmt
        case .dx12: .d3dMetal
        }
    }

    public var displayName: String {
        switch self {
        case .classic: "DX9–11"
        case .dx12: "DX12"
        }
    }

    public func steamBottleName() -> String { "Steam (\(displayName))" }
}

/// Informações sobre a Steam dentro de um bottle (só leitura de arquivos).
public enum Steam {
    public static let appRelativePath = "Program Files (x86)/Steam"

    public static func directory(in bottle: Bottle) -> URL {
        bottle.driveC.appendingPathComponent(appRelativePath, isDirectory: true)
    }

    public static func executable(in bottle: Bottle) -> URL {
        directory(in: bottle).appendingPathComponent("steam.exe")
    }

    public static func isInstalled(in bottle: Bottle) -> Bool {
        FileManager.default.fileExists(atPath: executable(in: bottle).path)
    }

    /// Há uma conta salva em `config/loginusers.vdf`?
    public static func isLoggedIn(in bottle: Bottle) -> Bool {
        let file = directory(in: bottle).appendingPathComponent("config/loginusers.vdf")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
        return text.contains("\"AccountName\"")
    }

    public static func installURL(appID: Int) -> String { "steam://install/\(appID)" }
    public static func runURL(appID: Int) -> String { "steam://rungameid/\(appID)" }

    /// Caminhos (Windows) das bibliotecas configuradas na Steam.
    public static func libraryPaths(in bottle: Bottle) -> [String] {
        let dir = directory(in: bottle)
        let candidates = ["steamapps/libraryfolders.vdf", "config/libraryfolders.vdf"]
        var paths: [String] = []
        for relative in candidates {
            guard let text = try? String(contentsOf: dir.appendingPathComponent(relative), encoding: .utf8) else { continue }
            for path in parseLibraryPaths(text) where !paths.contains(where: { $0.caseInsensitiveCompare(path) == .orderedSame }) {
                paths.append(path)
            }
        }
        return paths
    }

    /// Extrai os valores de `"path"` de um libraryfolders.vdf.
    static func parseLibraryPaths(_ vdf: String) -> [String] {
        let pattern = #""path"\s+"((?:[^"\\]|\\.)*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(vdf.startIndex..., in: vdf)
        return regex.matches(in: vdf, range: range).compactMap { match in
            Range(match.range(at: 1), in: vdf).map { String(vdf[$0]).replacingOccurrences(of: #"\\"#, with: #"\"#) }
        }
    }

    /// Procura o executável do jogo na pasta da Steam e em todas as bibliotecas.
    /// - relativeExe: relativo a `steamapps\common`, ex. `Left 4 Dead 2\left4dead2.exe`.
    public static func gameExecutable(_ relativeExe: String, in bottle: Bottle) -> URL? {
        let rel = relativeExe.replacingOccurrences(of: "\\", with: "/")
        var roots = [directory(in: bottle)]
        roots += libraryPaths(in: bottle).compactMap { WindowsPath.toUnix($0, in: bottle) }
        for root in roots {
            let url = WindowsPath.resolveCaseInsensitive(
                ["steamapps", "common"] + rel.split(separator: "/").map(String.init), from: root)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// A biblioteca compartilhada do Vinho já foi adicionada nesta Steam?
    public static func hasLibrary(_ folder: URL, in bottle: Bottle) -> Bool {
        let expected = WindowsPath.from(folder, in: bottle)
        return libraryPaths(in: bottle).contains {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "\\")).caseInsensitiveCompare(expected) == .orderedSame
        }
    }
}

extension VinhoPaths {
    /// Pasta de jogos compartilhada entre os bottles de Steam.
    public static var sharedSteamLibrary: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Games/Vinho Steam Library", isDirectory: true)
    }
}

/// Escolhe em qual bottle instalar um jogo de loja.
public enum LauncherPlanner {
    /// Bottle com a Steam instalada e da família certa (prefere o que já tem mais receitas).
    public static func steamBottle(for family: GraphicsFamily, in bottles: [Bottle]) -> Bottle? {
        bottles
            .filter { GraphicsFamily(bottle: $0) == family && Steam.isInstalled(in: $0) }
            .max { $0.settings.installedRecipes.count < $1.settings.installedRecipes.count }
    }
}
