import Foundation
import Yams

/// Receita de instalação aberta (YAML): como preparar um bottle e instalar
/// um app/jogo. É o equivalente aberto dos perfis C4P/CrossTie.
///
/// ```yaml
/// id: notepad-plus-plus
/// name: Notepad++
/// category: app
/// description: Editor de texto.
/// bottle: { windows: win10, graphics: wined3d }
/// steps:
///   - download: { url: https://…, sha256: …, file: npp.exe }
///   - run: { file: npp.exe, args: ["/S"] }
/// launch: { program: 'C:\Program Files\Notepad++\notepad++.exe' }
/// ```
public struct Recipe: Decodable, Identifiable, Hashable, Sendable {
    public enum Category: String, Decodable, Hashable, Sendable, CaseIterable {
        case app, game, tool

        public var displayName: String {
            switch self {
            case .app: "Apps"
            case .game: "Jogos"
            case .tool: "Ferramentas"
            }
        }
    }

    public var id: String
    public var name: String
    public var revision: Int?
    public var summary: String?
    public var category: Category
    public var homepage: String?
    public var notes: String?
    public var bottle: BottlePreset?
    public var requires: Requirements?
    public var steps: [RecipeStep]
    public var launch: LaunchSpec?
    /// Jogo instalado por uma loja (Steam): o Vinho escolhe/cria o bottle da loja.
    public var game: GameSpec?
    /// O que esta receita oferece a outras (ex.: `[steam]`).
    public var provides: [String]
    /// Dicas extras exibidas no guia de próximos passos.
    public var guide: [String]?

    private enum CodingKeys: String, CodingKey {
        case id, name, revision, category, homepage, notes, bottle, requires, steps, launch, game, provides, guide
        case summary = "description"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        revision = try c.decodeIfPresent(Int.self, forKey: .revision)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        category = (try? c.decodeIfPresent(Category.self, forKey: .category)) ?? .app
        homepage = try c.decodeIfPresent(String.self, forKey: .homepage)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        bottle = try c.decodeIfPresent(BottlePreset.self, forKey: .bottle)
        requires = try c.decodeIfPresent(Requirements.self, forKey: .requires)
        steps = try c.decodeIfPresent([RecipeStep].self, forKey: .steps) ?? []
        launch = try c.decodeIfPresent(LaunchSpec.self, forKey: .launch)
        game = try c.decodeIfPresent(GameSpec.self, forKey: .game)
        provides = try c.decodeIfPresent([String].self, forKey: .provides) ?? []
        guide = try c.decodeIfPresent([String].self, forKey: .guide)
    }

    // MARK: Parse + validação

    public static func parse(_ yaml: String) throws -> Recipe {
        let recipe: Recipe
        do {
            recipe = try YAMLDecoder().decode(Recipe.self, from: yaml)
        } catch let error as RecipeError {
            throw error
        } catch {
            throw RecipeError.parse(String(describing: error))
        }
        try recipe.validate()
        return recipe
    }

    /// Todos os downloads têm SHA-256?
    public var isVerified: Bool {
        steps.allSatisfy { step in
            if case .download(let d) = step { return d.sha256 != nil }
            return true
        }
    }

    public var needsWinetricks: Bool {
        steps.contains { if case .winetricks = $0 { return true } else { return false } }
    }

    public func validate() throws {
        guard id.range(of: "^[a-z0-9][a-z0-9-]*$", options: .regularExpression) != nil else {
            throw RecipeError.invalid("id inválido \"\(id)\" (use letras minúsculas, números e hífen)")
        }
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { throw RecipeError.invalid("name vazio") }
        guard !steps.isEmpty || game != nil else { throw RecipeError.invalid("receita sem steps") }
        if let game {
            guard game.appid > 0 else { throw RecipeError.invalid("game.appid inválido") }
            if let exe = game.exe {
                let parts = exe.replacingOccurrences(of: "\\", with: "/").split(separator: "/")
                guard !parts.isEmpty, !parts.contains(".."), !exe.contains(":") else {
                    throw RecipeError.invalid("game.exe deve ser relativo a steamapps\\common")
                }
            }
            if let dx = game.directx, ![9, 10, 11, 12].contains(dx) {
                throw RecipeError.invalid("game.directx deve ser 9, 10, 11 ou 12")
            }
            for (dll, value) in game.profile?.dllOverrides ?? [:] where DLLOverrideMode(recipeValue: value) == nil {
                throw RecipeError.invalid("override inválido em game.profile: \(dll)=\(value)")
            }
        }

        var files = Set<String>()
        for step in steps {
            switch step {
            case .download(let d):
                guard let url = URL(string: d.url), url.scheme == "https" else {
                    throw RecipeError.invalid("download precisa de URL https: \(d.url)")
                }
                if let sha = d.sha256 {
                    guard sha.count == 64, sha.allSatisfy(\.isHexDigit) else {
                        throw RecipeError.invalid("sha256 inválido em \(d.fileName)")
                    }
                }
                guard !d.fileName.isEmpty, !d.fileName.contains("/"), !d.fileName.hasPrefix(".") else {
                    throw RecipeError.invalid("nome de arquivo inválido: \(d.fileName)")
                }
                files.insert(d.fileName)
            case .run(let r):
                guard files.contains(r.file) || WindowsPath.looksLikeWindowsPath(r.file) else {
                    throw RecipeError.invalid("run.file \"\(r.file)\" não foi baixado antes nem é um caminho C:\\…")
                }
            case .winetricks(let verbs):
                guard !verbs.isEmpty, verbs.allSatisfy({ $0.range(of: "^[A-Za-z0-9_.=-]+$", options: .regularExpression) != nil }) else {
                    throw RecipeError.invalid("verbos do winetricks inválidos")
                }
            case .registry(let r):
                guard r.key.uppercased().hasPrefix("HK") else {
                    throw RecipeError.invalid("chave de registro inválida: \(r.key)")
                }
            }
        }

        for (dll, value) in bottle?.dllOverrides ?? [:] where DLLOverrideMode(recipeValue: value) == nil {
            throw RecipeError.invalid("override inválido \(dll)=\(value) (use native, builtin, native,builtin ou disabled)")
        }
        if let program = launch?.program, !WindowsPath.looksLikeWindowsPath(program) {
            throw RecipeError.invalid("launch.program precisa ser um caminho C:\\…")
        }
        if let icon = launch?.icon, !WindowsPath.looksLikeWindowsPath(icon) {
            throw RecipeError.invalid("launch.icon precisa ser um caminho C:\\…")
        }
    }
}

// MARK: - Partes

public struct BottlePreset: Decodable, Hashable, Sendable {
    public var windows: WindowsVersion?
    public var graphics: GraphicsBackend?
    public var sync: SyncMode?
    public var retina: Bool?
    public var environment: [String: String]?
    public var dllOverrides: [String: String]?

    public init(windows: WindowsVersion? = nil, graphics: GraphicsBackend? = nil, sync: SyncMode? = nil,
                retina: Bool? = nil, environment: [String: String]? = nil, dllOverrides: [String: String]? = nil) {
        self.windows = windows
        self.graphics = graphics
        self.sync = sync
        self.retina = retina
        self.environment = environment
        self.dllOverrides = dllOverrides
    }

    /// Aplica o preset sobre as configurações de um bottle.
    public func apply(to settings: inout BottleSettings) {
        if let windows { settings.windowsVersion = windows }
        if let graphics { settings.graphics = graphics }
        if let sync { settings.sync = sync }
        if let retina { settings.retinaMode = retina }
        if let environment { settings.environment.merge(environment) { _, new in new } }
        for (dll, value) in dllOverrides ?? [:] {
            if let mode = DLLOverrideMode(recipeValue: value) { settings.dllOverrides[dll] = mode }
        }
    }
}

/// Jogo distribuído por uma loja.
///
/// ```yaml
/// game:
///   store: steam
///   appid: 550
///   exe: 'Left 4 Dead 2\left4dead2.exe'   # relativo a steamapps\common (para o ícone e o status)
///   directx: 9                             # escolhe o bottle DX9–11 ou DX12
///   launchOptions: "-vulkan"               # sugerido no guia
/// ```
public struct GameSpec: Decodable, Hashable, Sendable {
    public var store: GameStore
    public var appid: Int
    public var exe: String?
    public var directx: Int?
    public var launchOptions: String?
    /// Ajustes só deste jogo (aplicados por executável, dentro da Steam compartilhada).
    public var profile: GameProfilePreset?

    public var family: GraphicsFamily { GraphicsFamily(directX: directx) }

    /// `Left 4 Dead 2\left4dead2.exe` → `left4dead2.exe`
    public var exeName: String? {
        exe?.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init)
    }

    /// Perfil inicial do jogo a partir da receita.
    public func makeProfile() -> GameProfile? {
        guard let exeName else { return nil }
        var overrides: [String: DLLOverrideMode] = [:]
        for (dll, value) in profile?.dllOverrides ?? [:] {
            if let mode = DLLOverrideMode(recipeValue: value) { overrides[dll] = mode }
        }
        return GameProfile(exeName: exeName, dllOverrides: overrides, renderer: profile?.renderer,
                           retina: profile?.retina, launchOptions: launchOptions)
    }
}

/// `game.profile` na receita.
public struct GameProfilePreset: Decodable, Hashable, Sendable {
    public var renderer: WineD3DRenderer?
    public var retina: Bool?
    public var dllOverrides: [String: String]?
}

public struct Requirements: Decodable, Hashable, Sendable {
    /// Ex.: `[dxmt]` — o runtime precisa ter estas camadas.
    public var capabilities: [RuntimeCapability]?
}

public struct LaunchSpec: Decodable, Hashable, Sendable {
    /// Caminho do Windows, ex. `C:\Program Files\App\app.exe`.
    public var program: String
    public var args: [String]?
    /// Nome do atalho na grade (padrão: nome do executável).
    public var name: String?
    /// Caminho do Windows de onde tirar o ícone (ex. o .exe do jogo).
    public var icon: String?
}

public struct DownloadStep: Decodable, Hashable, Sendable {
    public var url: String
    public var sha256: String?
    public var file: String?

    public var fileName: String {
        file ?? URL(string: url)?.lastPathComponent ?? "download"
    }
}

public struct RunStep: Decodable, Hashable, Sendable {
    /// Nome de um arquivo baixado antes, ou caminho do Windows.
    public var file: String
    public var args: [String]?
    /// Códigos de saída aceitos (padrão 0 e 3010 = "reinicie o Windows").
    public var okExitCodes: [Int32]?
    /// `false`: abre e segue sem esperar (ex.: Steam, que fica aberta). Padrão `true`.
    public var wait: Bool?
}

public struct RegistryStep: Decodable, Hashable, Sendable {
    public var key: String
    public var value: String
    public var type: String?
    public var data: String
}

/// Um passo é um mapa com exatamente uma chave: `download`, `run`, `winetricks` ou `registry`.
public enum RecipeStep: Decodable, Hashable, Sendable {
    case download(DownloadStep)
    case run(RunStep)
    case winetricks([String])
    case registry(RegistryStep)

    private enum Key: String, CodingKey, CaseIterable {
        case download, run, winetricks, registry
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        guard c.allKeys.count == 1, let key = c.allKeys.first else {
            throw RecipeError.invalid("cada step precisa de exatamente uma ação: \(Key.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        switch key {
        case .download: self = .download(try c.decode(DownloadStep.self, forKey: key))
        case .run: self = .run(try c.decode(RunStep.self, forKey: key))
        case .winetricks: self = .winetricks(try c.decode([String].self, forKey: key))
        case .registry: self = .registry(try c.decode(RegistryStep.self, forKey: key))
        }
    }

    public var title: String {
        switch self {
        case .download(let d): "Baixando \(d.fileName)"
        case .run(let r): "Executando \(r.file)"
        case .winetricks(let verbs): "winetricks \(verbs.joined(separator: " "))"
        case .registry(let r): "Registro: \(r.value)"
        }
    }
}

public enum RecipeError: Error, LocalizedError, Equatable {
    case parse(String)
    case invalid(String)
    case winetricksMissing

    public var errorDescription: String? {
        switch self {
        case .parse(let detail): "Não consegui ler a receita: \(detail)"
        case .invalid(let detail): "Receita inválida: \(detail)"
        case .winetricksMissing: "Esta receita usa winetricks. Instale com: brew install winetricks"
        }
    }
}

extension DLLOverrideMode {
    /// Aceita nomes legíveis (`native`, `builtin`, `native,builtin`, `disabled`) ou códigos (`n`, `b`, `n,b`).
    public init?(recipeValue: String) {
        switch recipeValue.lowercased().replacingOccurrences(of: " ", with: "") {
        case "native", "n": self = .native
        case "builtin", "b": self = .builtin
        case "native,builtin", "n,b": self = .nativeThenBuiltin
        case "builtin,native", "b,n": self = .builtinThenNative
        case "disabled", "off", "": self = .disabled
        default: return nil
        }
    }
}

extension WindowsPath {
    /// `C:\…` ou `C:/…`
    public static func looksLikeWindowsPath(_ s: String) -> Bool {
        let c = Array(s)
        return c.count >= 3 && c[0].isLetter && c[1] == ":" && (c[2] == "\\" || c[2] == "/")
    }
}
