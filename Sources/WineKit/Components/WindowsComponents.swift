import Foundation

/// Componentes do Windows que muitos programas exigem (.NET, Visual C++,
/// DirectX, fontes). Cada um vira uma receita interna, então reaproveita
/// download verificado, progresso e cancelamento.
public struct WindowsComponent: Identifiable, Hashable, Sendable {
    public enum Group: String, CaseIterable, Sendable {
        case runtime = "Runtimes"
        case directx = "DirectX e áudio"
        case fonts = "Fontes"
        case other = "Outros"
    }

    public let id: String
    public let name: String
    public let summary: String
    public let group: Group
    /// Passos no formato das receitas (YAML).
    let stepsYAML: String
    /// DLLs cuja falta no log indica este componente.
    public let providesDLLs: [String]

    public var needsWinetricks: Bool { stepsYAML.contains("winetricks:") }

    public var recipe: Recipe {
        // swiftlint:disable:next force_try
        try! Recipe.parse("id: component-\(id.replacingOccurrences(of: "_", with: "-"))\nname: \"\(name)\"\nsteps:\n\(stepsYAML)")
    }

    static func winetricks(_ id: String, _ name: String, _ summary: String, _ group: Group,
                           verbs: [String], dlls: [String] = []) -> WindowsComponent {
        WindowsComponent(id: id, name: name, summary: summary, group: group,
                         stepsYAML: "  - winetricks: [\(verbs.joined(separator: ", "))]\n", providesDLLs: dlls)
    }
}

public enum WindowsComponents {
    // Wine Mono 11.3.0 — SHA-256 do campo `digest` da release no GitHub (out/2026).
    public static let wineMono = WindowsComponent(
        id: "wine-mono", name: "Wine Mono (.NET Framework)",
        summary: "Implementação aberta do .NET Framework para o Wine. Resolve a maioria dos apps .NET sem instalar o .NET da Microsoft.",
        group: .runtime,
        stepsYAML: """
          - download:
              url: https://github.com/wine-mono/wine-mono/releases/download/wine-mono-11.3.0/wine-mono-11.3.0-x86.msi
              sha256: df2dfc1665c2511882e7cabd56eafd0c0a3d94e5a7e86f969277f6c189d418d3
              file: wine-mono-11.3.0-x86.msi
          - run:
              file: wine-mono-11.3.0-x86.msi
              args: ["/qn"]

        """,
        providesDLLs: ["mscoree.dll", "mscorlib.dll"]
    )

    public static let all: [WindowsComponent] = [
        wineMono,
        .winetricks("vcrun2022", "Visual C++ 2015–2022", "Runtime exigido pela maioria dos jogos e apps modernos.", .runtime,
                    verbs: ["vcrun2022"], dlls: ["msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll", "msvcp140_1.dll", "concrt140.dll"]),
        .winetricks("vcrun2013", "Visual C++ 2013", "Para programas de 2013–2015.", .runtime,
                    verbs: ["vcrun2013"], dlls: ["msvcp120.dll", "msvcr120.dll"]),
        .winetricks("vcrun2010", "Visual C++ 2010", "Para programas e jogos antigos.", .runtime,
                    verbs: ["vcrun2010"], dlls: ["msvcp100.dll", "msvcr100.dll"]),
        .winetricks("vcrun2008", "Visual C++ 2008", "Para programas e jogos bem antigos.", .runtime,
                    verbs: ["vcrun2008"], dlls: ["msvcp90.dll", "msvcr90.dll"]),
        .winetricks("dotnet48", ".NET Framework 4.8 (Microsoft)", "O .NET original. Demorado (~15 min); use só se o Wine Mono não bastar.", .runtime,
                    verbs: ["dotnet48"]),
        .winetricks("d3dx9", "DirectX 9 (d3dx9)", "Bibliotecas auxiliares do DirectX 9 usadas por jogos antigos.", .directx,
                    verbs: ["d3dx9"], dlls: (24...43).map { "d3dx9_\($0).dll" }),
        .winetricks("d3dcompiler_47", "Compilador de shaders (d3dcompiler_47)", "Exigido por jogos e apps DX11 e por navegadores embutidos.", .directx,
                    verbs: ["d3dcompiler_47"], dlls: ["d3dcompiler_47.dll", "d3dcompiler_43.dll"]),
        .winetricks("xact", "XACT / XAudio (áudio de jogos)", "Áudio de jogos que usam XAudio2/X3DAudio.", .directx,
                    verbs: ["xact"], dlls: ["xaudio2_7.dll", "x3daudio1_7.dll", "xactengine3_7.dll"]),
        .winetricks("xinput", "XInput (controles)", "Suporte a controles de jogos antigos.", .directx,
                    verbs: ["xinput"], dlls: ["xinput1_3.dll", "xinput1_4.dll"]),
        .winetricks("physx", "NVIDIA PhysX", "Física de jogos que usam PhysX (roda na CPU).", .other,
                    verbs: ["physx"], dlls: ["physxloader.dll", "physx3_x86.dll", "physx3_x64.dll"]),
        .winetricks("corefonts", "Fontes da Microsoft", "Arial, Times New Roman, Verdana… — corrige textos quadrados ou faltando.", .fonts,
                    verbs: ["corefonts"]),
        .winetricks("cjkfonts", "Fontes CJK", "Chinês, japonês e coreano.", .fonts,
                    verbs: ["cjkfonts"]),
    ]

    /// Componentes que fornecem o mscoree (.NET).
    public static let dotNetIDs: Set<String> = ["wine-mono", "dotnet48"]

    public static func component(_ id: String) -> WindowsComponent? {
        all.first { $0.id == id }
    }
}

/// Lê o log do Wine e sugere componentes que estão faltando.
public enum MissingComponentDetector {
    /// Linhas típicas:
    /// `err:module:import_dll Library MSVCP140.dll (which is needed by L"C:\\…") not found`
    /// `err:module:LdrInitializeThunk Importing dlls for L"…" failed, status c0000135`
    public static func missingDLLs(in lines: [String]) -> Set<String> {
        var result = Set<String>()
        let pattern = #"Library ([A-Za-z0-9_.\-]+\.dll)[^\n]*not found"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        for line in lines where line.contains("not found") {
            let range = NSRange(line.startIndex..., in: line)
            for match in regex.matches(in: line, range: range) {
                if let r = Range(match.range(at: 1), in: line) { result.insert(line[r].lowercased()) }
            }
        }
        return result
    }

    /// Componentes sugeridos (sem os já instalados), na ordem do catálogo.
    public static func suggestions(for lines: [String], installed: Set<String> = []) -> [WindowsComponent] {
        let missing = missingDLLs(in: lines)
        guard !missing.isEmpty else { return [] }
        return WindowsComponents.all.filter { component in
            !installed.contains(component.id) && component.providesDLLs.contains { missing.contains($0) }
        }
    }
}

/// winetricks gerenciado pelo Vinho (versão fixada, verificada por SHA-256).
public enum WinetricksManager {
    public static let version = "20260125"
    public static let artifact = DownloadableArtifact(
        url: URL(string: "https://raw.githubusercontent.com/Winetricks/winetricks/20260125/src/winetricks")!,
        sha256: "431f82fc74000e6c864409f1d8fb495d696c03928808e3e8acffc45179312a7b",
        size: 830_687
    )

    public static var managedURL: URL {
        VinhoPaths.applicationSupport.appendingPathComponent("Tools/winetricks")
    }

    /// Usa o do Vinho, senão o do Homebrew/PATH.
    public static func resolve() -> URL? {
        if FileManager.default.isExecutableFile(atPath: managedURL.path) { return managedURL }
        return RecipeRunner.findWinetricks()
    }

    /// Baixa e verifica o winetricks (se ainda não estiver instalado).
    @discardableResult
    public static func install(downloader: any Downloading = URLSessionDownloader(), into url: URL = managedURL) async throws -> URL {
        let fm = FileManager.default
        if fm.isExecutableFile(atPath: url.path), (try? Checksum.sha256(of: url)) == artifact.sha256 { return url }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = url.appendingPathExtension("part")
        try? fm.removeItem(at: partial)
        try await downloader.download(artifact.url, to: partial) { _, _ in }
        let actual = try Checksum.sha256(of: partial)
        guard actual == artifact.sha256 else {
            try? fm.removeItem(at: partial)
            throw WineError.checksumMismatch(expected: artifact.sha256, actual: actual)
        }
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        try fm.moveItem(at: partial, to: url)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// Pasta de ferramentas do Vinho (entra primeiro no PATH do winetricks).
    public static var toolsBinDirectory: URL {
        VinhoPaths.applicationSupport.appendingPathComponent("Tools/bin", isDirectory: true)
    }

    /// Onde procurar o cabextract: embutido no Vinho.app, Homebrew, ou o que vem
    /// dentro do CrossOver (se estiver instalado).
    public static var cabextractCandidates: [URL] {
        var urls: [URL] = []
        if let resources = Bundle.main.resourceURL {
            urls.append(resources.appendingPathComponent("bin/cabextract"))
        }
        urls += ["/opt/homebrew/bin/cabextract", "/usr/local/bin/cabextract"].map { URL(fileURLWithPath: $0) }
        let crossover = "Contents/SharedSupport/CrossOver/bin/cabextract"
        urls.append(URL(fileURLWithPath: "/Applications/CrossOver.app").appendingPathComponent(crossover))
        urls.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/CrossOver.app").appendingPathComponent(crossover))
        return urls
    }

    public static func findCabextract(in candidates: [URL] = cabextractCandidates) -> URL? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// O winetricks precisa do cabextract para quase todos os componentes.
    public static var cabextractAvailable: Bool { findCabextract() != nil }

    /// Liga o cabextract encontrado em `Tools/bin` (sem colocar o resto do
    /// CrossOver no PATH, que tem outro `wine`).
    @discardableResult
    public static func prepareTools(candidates: [URL] = cabextractCandidates, into dir: URL = toolsBinDirectory) -> URL? {
        let fm = FileManager.default
        guard let source = findCabextract(in: candidates) else { return nil }
        let link = dir.appendingPathComponent("cabextract")
        if let target = try? fm.destinationOfSymbolicLink(atPath: link.path), target == source.path { return link }
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.removeItem(at: link)
        do {
            try fm.createSymbolicLink(at: link, withDestinationURL: source)
            return link
        } catch {
            return nil
        }
    }

    /// PATH com as ferramentas do Vinho e o Homebrew (o app aberto pelo Finder
    /// não herda o PATH do terminal).
    public static var toolPath: String {
        "\(toolsBinDirectory.path):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    }
}

/// Divide uma linha de comando respeitando aspas: `a "b c" 'd e' f`.
/// Barras invertidas são literais (caminhos do Windows ficam intactos).
public enum CommandLineSplitter {
    public static func split(_ line: String) -> [String] {
        var args: [String] = []
        var current = ""
        var quote: Character?
        var hasToken = false
        for ch in line {
            if let q = quote {
                if ch == q { quote = nil } else { current.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch
                hasToken = true
            } else if ch == " " || ch == "\t" {
                if hasToken {
                    args.append(current)
                    current = ""
                    hasToken = false
                }
            } else {
                current.append(ch)
                hasToken = true
            }
        }
        if hasToken { args.append(current) }
        return args
    }
}
