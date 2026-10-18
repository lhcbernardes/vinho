import Foundation

/// Executa os passos de uma receita num bottle.
public struct RecipeRunner: Sendable {
    public enum Event: Sendable, Equatable {
        case step(index: Int, total: Int, title: String)
        case progress(Double?)
        case log(String)
    }

    public let runtime: WineRuntime
    public let launcher: any ProcessLaunching
    public let downloader: any Downloading
    public let cacheDirectory: URL
    public let winetricksURL: URL?

    public init(
        runtime: WineRuntime,
        launcher: any ProcessLaunching = FoundationProcessLauncher(),
        downloader: any Downloading = URLSessionDownloader(),
        cacheDirectory: URL = VinhoPaths.applicationSupport.appendingPathComponent("Cache/Recipes", isDirectory: true),
        winetricksURL: URL? = RecipeRunner.findWinetricks()
    ) {
        self.runtime = runtime
        self.launcher = launcher
        self.downloader = downloader
        self.cacheDirectory = cacheDirectory
        self.winetricksURL = winetricksURL
    }

    /// Procura `winetricks` no Homebrew e no PATH.
    public static func findWinetricks(path: String? = ProcessInfo.processInfo.environment["PATH"]) -> URL? {
        let dirs = ["/opt/homebrew/bin", "/usr/local/bin"] + (path?.split(separator: ":").map(String.init) ?? [])
        return dirs
            .map { URL(fileURLWithPath: $0).appendingPathComponent("winetricks") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    public func run(_ recipe: Recipe, in bottle: Bottle, events: @escaping @Sendable (Event) -> Void = { _ in }) async throws {
        try recipe.validate()
        if recipe.needsWinetricks && winetricksURL == nil { throw RecipeError.winetricksMissing }

        let missing = (recipe.requires?.capabilities ?? []).filter { !runtime.capabilities.contains($0) }
        if !missing.isEmpty {
            events(.log("⚠️ O runtime \(runtime.id) não tem: \(missing.map(\.rawValue).joined(separator: ", "))"))
        }

        let wine = WineRunner(runtime: runtime, launcher: launcher)
        let cache = cacheDirectory.appendingPathComponent(recipe.id, isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        var downloaded: [String: URL] = [:]

        for (index, step) in recipe.steps.enumerated() {
            try Task.checkCancellation()
            events(.step(index: index + 1, total: recipe.steps.count, title: step.title))

            switch step {
            case .download(let d):
                downloaded[d.fileName] = try await fetch(d, into: cache, events: events)

            case .run(let r):
                let target: URL
                if let local = downloaded[r.file] {
                    target = local
                } else if let url = WindowsPath.toUnix(r.file, in: bottle) {
                    target = url
                } else {
                    throw RecipeError.invalid("não encontrei \(r.file)")
                }
                if r.wait == false {
                    // Abre e segue: `start` retorna assim que o programa inicia.
                    let args = WineRunner.detachedLaunchArguments(for: target, extra: r.args ?? [])
                    try await execute(wine.invocation(args, in: bottle), accepting: r.okExitCodes ?? [0], events: events)
                } else {
                    let launch = WineRunner.launchArguments(for: target)
                    let invocation = wine.invocation(launch.arguments + (r.args ?? []), in: bottle, currentDirectory: launch.currentDirectory)
                    try await execute(invocation, accepting: r.okExitCodes ?? [0, 3010], events: events)
                    try await wine.waitForServer(bottle)
                }

            case .winetricks(let verbs):
                guard let winetricks = winetricksURL else { throw RecipeError.winetricksMissing }
                let invocation = wine.invocation(
                    ["-q"] + verbs, in: bottle, executable: winetricks,
                    environment: ["WINE": runtime.wineURL.path, "WINESERVER": runtime.wineserverURL.path]
                )
                try await execute(invocation, accepting: [0], events: events)

            case .registry(let r):
                let args = WineConfigurator.regAdd(key: r.key, value: r.value, type: r.type ?? "REG_SZ", data: r.data)
                try await execute(wine.invocation(args, in: bottle), accepting: [0], events: events)
            }
        }
        // Se algum passo deixou um programa aberto (wait: false), não espere o wineserver.
        let leavesRunning = recipe.steps.contains { if case .run(let r) = $0 { return r.wait == false } else { return false } }
        if !leavesRunning { try await wine.waitForServer(bottle) }
    }

    func execute(_ invocation: WineInvocation, accepting codes: [Int32], events: @escaping @Sendable (Event) -> Void) async throws {
        events(.log("▶ \(invocation.commandLine)"))
        var code: Int32 = -1
        var tail: [String] = []
        for try await event in launcher.run(invocation) {
            switch event {
            case .stdout(let line), .stderr(let line):
                events(.log(line))
                tail.append(line)
                if tail.count > 15 { tail.removeFirst() }
            case .exited(let c):
                code = c
            }
        }
        guard codes.contains(code) else {
            throw WineError.nonZeroExit(command: invocation.commandLine, code: code, stderrTail: tail.joined(separator: "\n"))
        }
    }

    /// Baixa para o cache. Com SHA-256, reaproveita o arquivo se já estiver lá.
    func fetch(_ step: DownloadStep, into cache: URL, events: @escaping @Sendable (Event) -> Void) async throws -> URL {
        let fm = FileManager.default
        let destination = cache.appendingPathComponent(step.fileName)
        if let sha = step.sha256, fm.fileExists(atPath: destination.path),
           (try? Checksum.sha256(of: destination)) == sha.lowercased() {
            events(.log("✓ \(step.fileName) já está em cache"))
            return destination
        }
        guard let url = URL(string: step.url) else { throw RecipeError.invalid("URL inválida: \(step.url)") }

        let partial = cache.appendingPathComponent(".\(step.fileName).part")
        try? fm.removeItem(at: partial)
        try await downloader.download(url, to: partial) { received, total in
            events(.progress(total.map { min(1, Double(received) / Double(max($0, 1))) }))
        }
        events(.progress(nil))

        if let sha = step.sha256 {
            let actual = try Checksum.sha256(of: partial)
            guard actual == sha.lowercased() else {
                try? fm.removeItem(at: partial)
                throw WineError.checksumMismatch(expected: sha, actual: actual)
            }
        } else {
            events(.log("⚠️ \(step.fileName) baixado SEM verificação SHA-256"))
        }

        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: partial, to: destination)
        return destination
    }
}
