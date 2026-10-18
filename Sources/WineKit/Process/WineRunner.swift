import Foundation

/// Executa comandos Wine dentro de um bottle com um runtime específico.
public struct WineRunner: Sendable {
    public let runtime: WineRuntime
    public let launcher: any ProcessLaunching
    public let baseEnvironment: [String: String]

    public init(
        runtime: WineRuntime,
        launcher: any ProcessLaunching = FoundationProcessLauncher(),
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.runtime = runtime
        self.launcher = launcher
        self.baseEnvironment = baseEnvironment
    }

    // MARK: - Montagem

    public func invocation(
        _ arguments: [String],
        in bottle: Bottle,
        executable: URL? = nil,
        currentDirectory: URL? = nil,
        environment extra: [String: String] = [:]
    ) -> WineInvocation {
        WineInvocation(
            executable: executable ?? runtime.wineURL,
            arguments: arguments,
            environment: WineEnvironment.make(bottle: bottle, runtime: runtime, base: baseEnvironment, extra: extra),
            currentDirectory: currentDirectory
        )
    }

    /// Argumentos para abrir um programa do Windows.
    /// - `.exe`: executado diretamente, com o diretório do exe como cwd
    ///   (muitos jogos procuram assets relativos a ele).
    /// - `.lnk`, `.bat`, `.msi` e outros: via `start /unix`, que resolve atalhos e associações.
    public static func launchArguments(for program: URL) -> (arguments: [String], currentDirectory: URL?) {
        switch program.pathExtension.lowercased() {
        case "exe":
            return ([program.path], program.deletingLastPathComponent())
        case "msi":
            return (["msiexec", "/i", program.path], program.deletingLastPathComponent())
        default:
            return (["start", "/unix", program.path], nil)
        }
    }

    /// Argumentos para um `Program` (inclui argumentos de atalhos personalizados).
    public static func launchArguments(for program: Program) -> (arguments: [String], currentDirectory: URL?) {
        let base = launchArguments(for: program.url)
        return (base.arguments + program.arguments, base.currentDirectory)
    }

    /// Versão que não espera o programa: `start /unix` retorna assim que ele abre.
    /// Útil para clientes que ficam abertos (Steam, launchers).
    public static func detachedLaunchArguments(for program: URL, extra: [String] = []) -> [String] {
        ["start", "/unix", program.path] + extra
    }

    // MARK: - Execução

    public func run(_ invocation: WineInvocation) -> AsyncThrowingStream<ProcessEvent, Error> {
        launcher.run(invocation)
    }

    public func run(_ arguments: [String], in bottle: Bottle) -> AsyncThrowingStream<ProcessEvent, Error> {
        run(invocation(arguments, in: bottle))
    }

    public func runToCompletion(_ invocation: WineInvocation) async throws -> ProcessResult {
        try await launcher.collect(invocation)
    }

    public func runToCompletion(_ arguments: [String], in bottle: Bottle) async throws -> ProcessResult {
        try await runToCompletion(invocation(arguments, in: bottle))
    }

    // MARK: - Operações comuns

    /// Cria/atualiza o prefixo e espera o wineserver terminar de gravar o registro.
    public func initializePrefix(_ bottle: Bottle) async throws {
        try await runToCompletion(["wineboot", "--init"], in: bottle).check()
        try await waitForServer(bottle)
    }

    /// Aplica as configurações que vivem dentro do prefixo (registro, versão do Windows).
    public func apply(_ settings: BottleSettings, previous: BottleSettings?, to bottle: Bottle) async throws {
        let commands = WineConfigurator.commands(for: settings, previous: previous)
        guard !commands.isEmpty else { return }
        for command in commands {
            try await runToCompletion(command, in: bottle).check()
        }
        try await waitForServer(bottle)
    }

    /// `wineserver -w`: bloqueia até todos os processos do prefixo saírem.
    public func waitForServer(_ bottle: Bottle) async throws {
        let inv = invocation(["-w"], in: bottle, executable: runtime.wineserverURL)
        _ = try await runToCompletion(inv)
    }

    /// `wine --version` (não precisa de prefixo).
    public static func probeVersion(_ runtime: WineRuntime, launcher: any ProcessLaunching = FoundationProcessLauncher()) async -> String? {
        let inv = WineInvocation(
            executable: runtime.wineURL,
            arguments: ["--version"],
            environment: ["PATH": "\(runtime.binURL.path):/usr/bin:/bin", "WINEDEBUG": "-all"]
        )
        guard let result = try? await launcher.collect(inv), result.exitCode == 0,
              let line = result.stdout.first(where: { !$0.isEmpty }) else { return nil }
        return line.trimmingCharacters(in: .whitespaces)
    }

    /// `wineserver -k`: mata todos os processos do bottle.
    public func killAll(_ bottle: Bottle) async throws {
        let inv = invocation(["-k"], in: bottle, executable: runtime.wineserverURL)
        _ = try await runToCompletion(inv)
    }
}

/// Converte configurações em comandos Wine. Puro e testável.
public enum WineConfigurator {
    public static let macDriverKey = #"HKCU\Software\Wine\Mac Driver"#

    public static func commands(for settings: BottleSettings, previous: BottleSettings?) -> [[String]] {
        var commands: [[String]] = []

        if previous?.windowsVersion != settings.windowsVersion {
            commands.append(["winecfg", "-v", settings.windowsVersion.rawValue])
        }

        if previous?.retinaMode != settings.retinaMode {
            commands.append(regAdd(
                key: macDriverKey, value: "RetinaMode", type: "REG_SZ",
                data: settings.retinaMode ? "y" : "n"
            ))
        }

        return commands
    }

    public static func regAdd(key: String, value: String, type: String, data: String) -> [String] {
        ["reg", "add", key, "/v", value, "/t", type, "/d", data, "/f"]
    }
}
