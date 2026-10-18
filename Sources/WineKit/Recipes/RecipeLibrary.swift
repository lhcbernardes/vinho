import Foundation
import Yams

public struct RecipeEntry: Identifiable, Hashable, Sendable {
    public enum Source: Hashable, Sendable {
        case builtIn
        case user(URL)
        case community(URL)

        public var label: String {
            switch self {
            case .builtIn: "Embutida"
            case .user: "Minha"
            case .community: "Comunidade"
            }
        }
    }

    public let recipe: Recipe
    public let source: Source

    public init(recipe: Recipe, source: Source) {
        self.recipe = recipe
        self.source = source
    }

    public var id: String { recipe.id }
}

/// Carrega receitas de três camadas: embutidas < comunidade < do usuário
/// (a camada de cima substitui receitas com o mesmo `id`).
public enum RecipeLibrary {
    public static var userDirectory: URL {
        VinhoPaths.applicationSupport.appendingPathComponent("Recipes", isDirectory: true)
    }

    public static func builtIn() -> [RecipeEntry] {
        BuiltInRecipes.yaml.compactMap { try? Recipe.parse($0) }.map { RecipeEntry(recipe: $0, source: .builtIn) }
    }

    /// Lê `*.yaml`/`*.yml` de uma pasta. Receitas inválidas viram mensagens de erro.
    public static func loadUser(from directory: URL = userDirectory) -> (entries: [RecipeEntry], errors: [String]) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        var entries: [RecipeEntry] = []
        var errors: [String] = []
        for file in files where ["yaml", "yml"].contains(file.pathExtension.lowercased()) {
            do {
                let text = try String(contentsOf: file, encoding: .utf8)
                entries.append(RecipeEntry(recipe: try Recipe.parse(text), source: .user(file)))
            } catch {
                errors.append("\(file.lastPathComponent): \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
            }
        }
        return (entries, errors)
    }

    /// Índice comunitário: um YAML com `recipes: [arquivo.yaml, …]`
    /// (caminhos relativos ao próprio índice). Funciona com URLs https e file://.
    public static func loadCommunity(index: URL) async throws -> (entries: [RecipeEntry], errors: [String]) {
        struct Index: Decodable { var recipes: [String] }
        let indexText = try await fetchText(index)
        let parsed: Index
        do {
            parsed = try YAMLDecoder().decode(Index.self, from: indexText)
        } catch {
            throw RecipeError.parse("índice: \(error)")
        }

        var entries: [RecipeEntry] = []
        var errors: [String] = []
        for path in parsed.recipes {
            guard let url = URL(string: path, relativeTo: index)?.absoluteURL else {
                errors.append("\(path): URL inválida")
                continue
            }
            do {
                entries.append(RecipeEntry(recipe: try Recipe.parse(try await fetchText(url)), source: .community(url)))
            } catch {
                errors.append("\(path): \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
            }
        }
        return (entries, errors)
    }

    /// Junta camadas; a última vence em caso de `id` repetido. Ordena por nome.
    public static func merge(_ layers: [[RecipeEntry]]) -> [RecipeEntry] {
        var byID: [String: RecipeEntry] = [:]
        for layer in layers {
            for entry in layer { byID[entry.id] = entry }
        }
        return byID.values.sorted { $0.recipe.name.localizedStandardCompare($1.recipe.name) == .orderedAscending }
    }

    static func fetchText(_ url: URL) async throws -> String {
        if url.isFileURL {
            return try String(contentsOf: url, encoding: .utf8)
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw WineError.downloadFailed(reason: "\(url.lastPathComponent): HTTP \(http.statusCode)")
        }
        return String(decoding: data, as: UTF8.self)
    }
}
