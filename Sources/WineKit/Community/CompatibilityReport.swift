import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum CompatibilityRating: String, Codable, CaseIterable, Sendable, Identifiable {
    case perfect, playable, issues, broken

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .perfect: "Perfeito"
        case .playable: "Funciona"
        case .issues: "Com problemas"
        case .broken: "Não funciona"
        }
    }

    public var symbol: String {
        switch self {
        case .perfect: "🟢"
        case .playable: "🟡"
        case .issues: "🟠"
        case .broken: "🔴"
        }
    }
}

/// Relatório de compatibilidade. Vira uma issue pré-preenchida no GitHub:
/// o usuário revisa e envia — o Vinho não publica nada sozinho.
public struct CompatibilityReport: Sendable, Equatable {
    public var program: String
    public var rating: CompatibilityRating
    public var notes: String
    public var recipes: [String: Int]
    public var runtime: String
    public var backend: GraphicsBackend
    public var windows: WindowsVersion
    public var macOS: String
    public var hardware: String
    public var vinhoVersion: String

    public init(program: String, rating: CompatibilityRating, notes: String, recipes: [String: Int],
                runtime: String, backend: GraphicsBackend, windows: WindowsVersion,
                macOS: String, hardware: String, vinhoVersion: String) {
        self.program = program
        self.rating = rating
        self.notes = notes
        self.recipes = recipes
        self.runtime = runtime
        self.backend = backend
        self.windows = windows
        self.macOS = macOS
        self.hardware = hardware
        self.vinhoVersion = vinhoVersion
    }

    public var title: String {
        "[compat] \(program) — \(rating.displayName)"
    }

    /// Corpo em Markdown, sem dados pessoais (nada de caminhos com nome de usuário).
    public var markdown: String {
        let recipeList = recipes.isEmpty
            ? "—"
            : recipes.sorted { $0.key < $1.key }.map { "`\($0.key)` r\($0.value)" }.joined(separator: ", ")
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        ## \(rating.symbol) \(program): \(rating.displayName)

        | | |
        |---|---|
        | Receitas | \(recipeList) |
        | Runtime | \(runtime) |
        | Gráficos | \(backend.displayName) |
        | Windows | \(windows.displayName) |
        | macOS | \(macOS) |
        | Mac | \(hardware) |
        | Vinho | \(vinhoVersion) |

        ### Observações

        \(trimmedNotes.isEmpty ? "_(sem observações)_" : trimmedNotes)

        <!-- gerado pelo Vinho -->
        """
    }

    /// `owner/repo` → URL de "nova issue" com título, corpo e label.
    public func issueURL(repository: String) -> URL? {
        let repo = repository.trimmingCharacters(in: .whitespaces)
        guard repo.range(of: #"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.path = "/\(repo)/issues/new"
        components.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "labels", value: "compatibilidade"),
            URLQueryItem(name: "body", value: markdown),
        ]
        return components.url
    }

    // MARK: Sistema

    public static var macOSVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    /// Ex.: "Apple M2 Pro" (ou o modelo, se o nome do chip não estiver disponível).
    public static var hardwareDescription: String {
        sysctlString("machdep.cpu.brand_string") ?? sysctlString("hw.model") ?? "desconhecido"
    }

    static func sysctlString(_ name: String) -> String? {
        #if canImport(Darwin)
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(cString: buffer).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
        #else
        return nil
        #endif
    }
}
