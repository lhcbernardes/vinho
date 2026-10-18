import AppKit
import Foundation
import Observation
import WineKit

struct LogLine: Identifiable, Hashable {
    enum Source { case stdout, stderr, vinho }
    let id = UUID()
    let date = Date()
    let source: Source
    let text: String
}

@Observable
@MainActor
final class AppModel {
    // MARK: Estado
    var bottles: [Bottle] = []
    var runtimes: [WineRuntime] = []
    var selection: Bottle.ID?
    var programs: [Program] = []
    var logs: [Bottle.ID: [LogLine]] = [:]
    var runningCount: [Bottle.ID: Int] = [:]
    var busyMessage: String?
    var errorMessage: String?
    var isCreatingBottle = false
    var isPickingProgram = false

    var defaultRuntimeID: String? {
        didSet { UserDefaults.standard.set(defaultRuntimeID, forKey: "defaultRuntimeID") }
    }

    private let manager = BottleManager()
    private let locator = RuntimeLocator()
    private let maxLogLines = 5_000

    init() {
        defaultRuntimeID = UserDefaults.standard.string(forKey: "defaultRuntimeID")
    }

    // MARK: Derivados

    var selectedBottle: Bottle? {
        bottles.first { $0.id == selection }
    }

    var defaultRuntime: WineRuntime? {
        runtimes.first { $0.id == defaultRuntimeID } ?? runtimes.first
    }

    var rosettaMissing: Bool {
        SystemCheck.needsRosetta && !SystemCheck.isRosettaInstalled
    }

    func runtime(for bottle: Bottle) -> WineRuntime? {
        if let id = bottle.settings.runtimeID, let match = runtimes.first(where: { $0.id == id }) {
            return match
        }
        return defaultRuntime
    }

    // MARK: Carregamento

    func refresh() async {
        runtimes = locator.discover()
        do {
            bottles = try await manager.list()
            if selection == nil || selectedBottle == nil { selection = bottles.first?.id }
            rescanPrograms()
        } catch {
            show(error)
        }
    }

    func rescanPrograms() {
        guard let bottle = selectedBottle else { programs = []; return }
        let pinned = bottle.settings.pinnedPrograms.map { URL(fileURLWithPath: $0) }
        let scanned = ProgramScanner.scan(bottle)
        let pinnedPrograms = pinned
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map { Program(url: $0, kind: $0.pathExtension.lowercased() == "lnk" ? .shortcut : .executable) }
        var seen = Set<URL>()
        programs = (pinnedPrograms + scanned).filter { seen.insert($0.url).inserted }
    }

    // MARK: Bottles

    func createBottle(name: String, windows: WindowsVersion, graphics: GraphicsBackend) async {
        guard let runtime = defaultRuntime else { return show(WineError.noRuntimeAvailable) }
        busyMessage = "Criando “\(name)”… (o primeiro wineboot leva alguns segundos)"
        defer { busyMessage = nil }
        do {
            let settings = BottleSettings(
                name: name,
                runtimeID: runtime.id,
                windowsVersion: windows,
                graphics: runtime.supports(graphics) ? graphics : .wined3d
            )
            let bottle = try await manager.create(settings)
            let runner = WineRunner(runtime: runtime)
            log(bottle.id, "Inicializando prefixo com \(runtime.displayName)…")
            try await runner.initializePrefix(bottle)
            try await runner.apply(settings, previous: nil, to: bottle)
            log(bottle.id, "Bottle pronto.")
            await refresh()
            selection = bottle.id
            rescanPrograms()
        } catch {
            show(error)
            await refresh()
        }
    }

    /// Salva e aplica no prefixo só o que mudou.
    func update(_ bottle: Bottle, _ change: (inout BottleSettings) -> Void) async {
        // Usa a versão mais recente: a View pode ter capturado uma cópia antiga.
        let current = bottles.first { $0.id == bottle.id } ?? bottle
        let previous = current.settings
        var updated = current
        change(&updated.settings)
        guard updated.settings != previous else { return }
        do {
            try await manager.save(updated)
            replace(updated)
            if let runtime = runtime(for: updated) {
                try await WineRunner(runtime: runtime).apply(updated.settings, previous: previous, to: updated)
            }
        } catch {
            show(error)
        }
    }

    func rename(_ bottle: Bottle, to name: String) async {
        do {
            let renamed = try await manager.rename(bottle, to: name)
            replace(renamed)
        } catch {
            show(error)
        }
    }

    func delete(_ bottle: Bottle) async {
        do {
            if let runtime = runtime(for: bottle) {
                try? await WineRunner(runtime: runtime).killAll(bottle)
            }
            try await manager.delete(bottle)
            logs[bottle.id] = nil
            if selection == bottle.id { selection = nil }
            await refresh()
        } catch {
            show(error)
        }
    }

    func pin(_ url: URL, in bottle: Bottle) async {
        await update(bottle) { s in
            if !s.pinnedPrograms.contains(url.path) { s.pinnedPrograms.append(url.path) }
        }
        rescanPrograms()
    }

    // MARK: Execução

    func launch(_ program: URL, in bottle: Bottle) {
        let (args, cwd) = WineRunner.launchArguments(for: program)
        run(args, in: bottle, currentDirectory: cwd, label: program.lastPathComponent)
    }

    /// Ferramentas embutidas do Wine: winecfg, regedit, taskmgr, cmd, control…
    func runTool(_ tool: String, in bottle: Bottle) {
        run([tool], in: bottle, currentDirectory: nil, label: tool)
    }

    func killAllInSelectedBottle() async {
        guard let bottle = selectedBottle, let runtime = runtime(for: bottle) else { return }
        do {
            try await WineRunner(runtime: runtime).killAll(bottle)
            log(bottle.id, "Todos os processos encerrados.")
        } catch {
            show(error)
        }
    }

    func openDriveC(_ bottle: Bottle) {
        NSWorkspace.shared.open(bottle.driveC)
    }

    private func run(_ args: [String], in bottle: Bottle, currentDirectory: URL?, label: String) {
        guard let runtime = runtime(for: bottle) else { return show(WineError.noRuntimeAvailable) }
        if !runtime.supports(bottle.settings.graphics) {
            log(bottle.id, "Aviso: \(runtime.id) não suporta \(bottle.settings.graphics.displayName); o jogo pode cair para WineD3D.")
        }
        let runner = WineRunner(runtime: runtime)
        let invocation = runner.invocation(args, in: bottle, currentDirectory: currentDirectory)
        let id = bottle.id
        log(id, "▶ \(invocation.commandLine)")
        runningCount[id, default: 0] += 1

        Task {
            do {
                for try await event in runner.run(invocation) {
                    switch event {
                    case .stdout(let line): append(id, LogLine(source: .stdout, text: line))
                    case .stderr(let line): append(id, LogLine(source: .stderr, text: line))
                    case .exited(let code): log(id, "■ \(label) saiu com código \(code)")
                    }
                }
            } catch {
                show(error)
            }
            runningCount[id, default: 1] -= 1
            rescanPrograms() // um instalador pode ter criado novos atalhos
        }
    }

    // MARK: Logs e erros

    func clearLogs(_ bottle: Bottle) { logs[bottle.id] = [] }

    private func log(_ id: Bottle.ID, _ text: String) {
        append(id, LogLine(source: .vinho, text: text))
    }

    private func append(_ id: Bottle.ID, _ line: LogLine) {
        var lines = logs[id, default: []]
        lines.append(line)
        if lines.count > maxLogLines { lines.removeFirst(lines.count - maxLogLines) }
        logs[id] = lines
    }

    private func replace(_ bottle: Bottle) {
        if let i = bottles.firstIndex(where: { $0.id == bottle.id }) { bottles[i] = bottle }
    }

    private func show(_ error: Error) {
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
