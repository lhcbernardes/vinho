import Foundation

/// Versão do Windows reportada aos programas (`winecfg -v <valor>`).
public enum WindowsVersion: String, Codable, CaseIterable, Sendable, Identifiable {
    case win11
    case win10
    case win81
    case win7
    case winxp64

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .win11: "Windows 11"
        case .win10: "Windows 10"
        case .win81: "Windows 8.1"
        case .win7: "Windows 7"
        case .winxp64: "Windows XP (64-bit)"
        }
    }
}

/// Primitiva de sincronização usada pelo wineserver.
public enum SyncMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Mach-semaphore sync (macOS). Geralmente o mais rápido.
    case msync
    /// eventfd-style sync.
    case esync
    /// Sincronização padrão do wineserver.
    case none

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .msync: "MSync"
        case .esync: "ESync"
        case .none: "Padrão"
        }
    }
}

/// Quanto o Wine deve registrar em log (`WINEDEBUG`).
public enum WineLogLevel: String, Codable, CaseIterable, Sendable, Identifiable {
    case quiet
    case errors
    case verbose

    public var id: String { rawValue }

    public var winedebug: String {
        switch self {
        case .quiet: "-all"
        case .errors: "err+all,fixme-all"
        case .verbose: "err+all,warn+all,fixme-all,+loaddll,+seh"
        }
    }

    public var displayName: String {
        switch self {
        case .quiet: "Silencioso"
        case .errors: "Erros"
        case .verbose: "Detalhado"
        }
    }
}

/// Configuração persistida de um bottle (`vinho.json`).
///
/// A decodificação tolera chaves ausentes para que versões futuras possam
/// adicionar campos sem quebrar bottles antigos.
public struct BottleSettings: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var name: String
    public var runtimeID: String?
    public var windowsVersion: WindowsVersion
    public var graphics: GraphicsBackend
    public var sync: SyncMode
    public var logLevel: WineLogLevel
    public var retinaMode: Bool
    public var metalHUD: Bool
    /// Variáveis de ambiente extras, aplicadas por último.
    public var environment: [String: String]
    /// Overrides de DLL do usuário; vencem os do backend gráfico.
    public var dllOverrides: [String: DLLOverrideMode]
    /// Programas fixados pelo usuário (caminhos Unix absolutos).
    public var pinnedPrograms: [String]
    /// Atalhos personalizados (programa + argumentos), exibidos antes dos demais.
    public var shortcuts: [ProgramShortcut]
    /// Receitas instaladas neste bottle (id → revisão).
    public var installedRecipes: [String: Int]
    /// Avaliação de compatibilidade por programa (caminho Unix → nota).
    public var compatibility: [String: CompatibilityRating]
    public var createdAt: Date

    public init(
        name: String,
        runtimeID: String? = nil,
        windowsVersion: WindowsVersion = .win10,
        graphics: GraphicsBackend = .dxmt,
        sync: SyncMode = .msync,
        logLevel: WineLogLevel = .quiet,
        retinaMode: Bool = false,
        metalHUD: Bool = false,
        environment: [String: String] = [:],
        dllOverrides: [String: DLLOverrideMode] = [:],
        pinnedPrograms: [String] = [],
        shortcuts: [ProgramShortcut] = [],
        installedRecipes: [String: Int] = [:],
        compatibility: [String: CompatibilityRating] = [:],
        createdAt: Date = Date()
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.name = name
        self.runtimeID = runtimeID
        self.windowsVersion = windowsVersion
        self.graphics = graphics
        self.sync = sync
        self.logLevel = logLevel
        self.retinaMode = retinaMode
        self.metalHUD = metalHUD
        self.environment = environment
        self.dllOverrides = dllOverrides
        self.pinnedPrograms = pinnedPrograms
        self.shortcuts = shortcuts
        self.installedRecipes = installedRecipes
        self.compatibility = compatibility
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, name, runtimeID, windowsVersion, graphics, sync, logLevel
        case retinaMode, metalHUD, environment, dllOverrides, pinnedPrograms, shortcuts, installedRecipes, compatibility, createdAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = BottleSettings(name: "")
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        name = try c.decode(String.self, forKey: .name)
        runtimeID = try c.decodeIfPresent(String.self, forKey: .runtimeID)
        windowsVersion = (try? c.decodeIfPresent(WindowsVersion.self, forKey: .windowsVersion)) ?? defaults.windowsVersion
        graphics = (try? c.decodeIfPresent(GraphicsBackend.self, forKey: .graphics)) ?? defaults.graphics
        sync = (try? c.decodeIfPresent(SyncMode.self, forKey: .sync)) ?? defaults.sync
        logLevel = (try? c.decodeIfPresent(WineLogLevel.self, forKey: .logLevel)) ?? defaults.logLevel
        retinaMode = try c.decodeIfPresent(Bool.self, forKey: .retinaMode) ?? defaults.retinaMode
        metalHUD = try c.decodeIfPresent(Bool.self, forKey: .metalHUD) ?? defaults.metalHUD
        environment = try c.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        dllOverrides = (try? c.decodeIfPresent([String: DLLOverrideMode].self, forKey: .dllOverrides)) ?? [:]
        pinnedPrograms = try c.decodeIfPresent([String].self, forKey: .pinnedPrograms) ?? []
        shortcuts = (try? c.decodeIfPresent([ProgramShortcut].self, forKey: .shortcuts)) ?? []
        installedRecipes = (try? c.decodeIfPresent([String: Int].self, forKey: .installedRecipes)) ?? [:]
        compatibility = (try? c.decodeIfPresent([String: CompatibilityRating].self, forKey: .compatibility)) ?? [:]
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}
