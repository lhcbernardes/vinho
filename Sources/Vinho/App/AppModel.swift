import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers
import WineKit

struct GuideState: Identifiable, Equatable {
    enum Kind: Equatable {
        case steam
        case game(recipeID: String)
    }
    let kind: Kind
    let bottleID: Bottle.ID
    var id: String { "\(bottleID.path)|\(kind)" }
}

struct ProfileEditing: Identifiable, Equatable {
    let bottleID: Bottle.ID
    let profileID: String
    var id: String { "\(bottleID.path)|\(profileID)" }
}

struct RecipeRunState: Equatable {
    var recipeName: String
    var bottleID: Bottle.ID
    var step = "Preparando…"
    var fraction: Double?
}

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

    /// Instalações em andamento, por id do runtime/variante.
    var installs: [String: InstallProgress] = [:]
    /// `wine --version` dos runtimes sem arquivo VERSION.
    var probedVersions: [String: String] = [:]
    let catalog = Catalog.builtIn
    private var installTasks: [String: Task<Void, Never>] = [:]

    // Receitas
    var recipes: [RecipeEntry] = []
    var recipeErrors: [String] = []
    var recipeRun: RecipeRunState?
    var isShowingRecipes = false
    private var recipeTask: Task<Void, Never>?

    var communityIndexURL: String {
        didSet { UserDefaults.standard.set(communityIndexURL, forKey: "communityIndexURL") }
    }

    /// `owner/repo` onde os relatórios de compatibilidade viram issues.
    var communityRepo: String {
        didSet { UserDefaults.standard.set(communityRepo, forKey: "communityRepo") }
    }

    /// Programa sendo avaliado (abre a folha "Funcionou?").
    var reporting: Program?

    /// Guia "Próximos passos" aberto.
    var guide: GuideState?

    var snapshots: [Bottle.ID: [BottleSnapshot]] = [:]
    private let snapshotManager = SnapshotManager()

    var autoSnapshotInstallers: Bool {
        didSet { UserDefaults.standard.set(autoSnapshotInstallers, forKey: "autoSnapshotInstallers") }
    }

    var defaultRuntimeID: String? {
        didSet { UserDefaults.standard.set(defaultRuntimeID, forKey: "defaultRuntimeID") }
    }

    private let manager = BottleManager()
    private let locator = RuntimeLocator()
    private let maxLogLines = 5_000

    init() {
        defaultRuntimeID = UserDefaults.standard.string(forKey: "defaultRuntimeID")
        autoSnapshotInstallers = UserDefaults.standard.object(forKey: "autoSnapshotInstallers") as? Bool ?? true
        communityIndexURL = UserDefaults.standard.string(forKey: "communityIndexURL") ?? ""
        communityRepo = UserDefaults.standard.string(forKey: "communityRepo") ?? ""
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
        probeMissingVersions()
        defer { prepareSteamBottles() }
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
        let fm = FileManager.default
        let custom = bottle.settings.shortcuts
            .filter { fm.fileExists(atPath: $0.program) }
            .map { $0.program(in: bottle) }
        let pinned = bottle.settings.pinnedPrograms
            .map { URL(fileURLWithPath: $0) }
            .filter { fm.fileExists(atPath: $0.path) }
            .map { Program(url: $0, kind: $0.pathExtension.lowercased() == "lnk" ? .shortcut : .executable) }
        var seen = Set<String>()
        programs = (custom + pinned + ProgramScanner.scan(bottle)).filter { seen.insert($0.id).inserted }
    }

    func addShortcut(_ shortcut: ProgramShortcut, to bottle: Bottle) async {
        await update(bottle) { s in
            s.shortcuts.removeAll { $0.name == shortcut.name }
            s.shortcuts.insert(shortcut, at: 0)
        }
        rescanPrograms()
    }

    func removeShortcut(_ program: Program, from bottle: Bottle) async {
        await update(bottle) { s in
            s.shortcuts.removeAll { $0.asProgram.id == program.id }
            s.pinnedPrograms.removeAll { $0 == program.url.path }
        }
        rescanPrograms()
    }

    // MARK: Bottles

    @discardableResult
    func createBottle(name: String, windows: WindowsVersion, graphics: GraphicsBackend, preset: BottlePreset? = nil) async -> Bottle? {
        guard let runtime = bestRuntime(for: graphics, current: defaultRuntime) ?? defaultRuntime else {
            show(WineError.noRuntimeAvailable)
            return nil
        }
        busyMessage = "Criando “\(name)”… (o primeiro wineboot leva alguns segundos)"
        defer { busyMessage = nil }
        do {
            var settings = BottleSettings(name: name, runtimeID: runtime.id, windowsVersion: windows, graphics: graphics)
            preset?.apply(to: &settings)
            if !runtime.supports(settings.graphics) { settings.graphics = .wined3d }
            let bottle = try await manager.create(settings)
            let runner = WineRunner(runtime: runtime)
            log(bottle.id, "Inicializando prefixo com \(runtime.displayName)…")
            try await runner.initializePrefix(bottle)
            try await runner.apply(settings, previous: nil, to: bottle)
            log(bottle.id, "Bottle pronto.")
            await refresh()
            selection = bottle.id
            rescanPrograms()
            return bottle
        } catch {
            show(error)
            await refresh()
            return nil
        }
    }

    /// Salva e aplica no prefixo só o que mudou.
    func update(_ bottle: Bottle, _ change: (inout BottleSettings) -> Void) async {
        // Usa a versão mais recente: a View pode ter capturado uma cópia antiga.
        let current = bottles.first { $0.id == bottle.id } ?? bottle
        let previous = current.settings
        var updated = current
        change(&updated.settings)
        // O backend gráfico efetivo vem do runtime: troca para um que o suporte.
        if updated.settings.graphics != previous.graphics,
           let match = bestRuntime(for: updated.settings.graphics, current: runtime(for: current)) {
            updated.settings.runtimeID = match.id
        }
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
            try? snapshotManager.deleteAll(for: bottle)
            snapshots[bottle.id] = nil
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

    // MARK: Runtimes

    func isInstalled(_ descriptor: RuntimeDescriptor) -> Bool {
        runtimes.contains { $0.id == descriptor.id }
    }

    func isManaged(_ runtime: WineRuntime) -> Bool {
        runtime.rootURL.standardizedFileURL.path
            .hasPrefix(RuntimeLocator.managedRuntimesDirectory.standardizedFileURL.path + "/")
    }

    func displayVersion(_ runtime: WineRuntime) -> String? {
        runtime.version ?? probedVersions[runtime.id]
    }

    /// Componentes do catálogo que fazem sentido adicionar a este runtime.
    func availableComponents(for runtime: WineRuntime) -> [ComponentDescriptor] {
        catalog.components.filter { c in
            !runtime.capabilities.contains(c.kind)
                && !runtimes.contains { $0.id == RuntimeInstaller.variantID(base: runtime, component: c) }
        }
    }

    /// Prefere o runtime atual; senão, o primeiro que suporta o backend.
    /// Para WineD3D, prefere um runtime sem camadas extras.
    func bestRuntime(for backend: GraphicsBackend, current: WineRuntime?) -> WineRuntime? {
        if backend == .wined3d {
            if let current, current.capabilities.isEmpty { return current }
            return runtimes.first { $0.capabilities.isEmpty } ?? current
        }
        if let current, current.supports(backend) { return current }
        return runtimes.first { $0.supports(backend) }
    }

    func install(_ descriptor: RuntimeDescriptor) {
        startInstall(id: descriptor.id, label: "\(descriptor.name) \(descriptor.version)") { installer, progress in
            try await installer.install(descriptor, progress: progress)
        }
    }

    func addComponent(_ component: ComponentDescriptor, to base: WineRuntime) {
        let id = RuntimeInstaller.variantID(base: base, component: component)
        startInstall(id: id, label: "\(component.name) em \(base.id)") { installer, progress in
            try await installer.makeVariant(of: base, with: component, progress: progress)
        }
    }

    func cancelInstall(_ id: String) {
        installTasks[id]?.cancel()
    }

    func uninstall(_ runtime: WineRuntime) async {
        let users = bottles.filter { $0.settings.runtimeID == runtime.id }.map(\.name)
        guard users.isEmpty else {
            errorMessage = "“\(runtime.id)” está em uso por: \(users.joined(separator: ", ")). Troque o runtime desses bottles antes."
            return
        }
        do {
            try RuntimeInstaller().uninstall(runtime)
            if defaultRuntimeID == runtime.id { defaultRuntimeID = nil }
            await refresh()
        } catch {
            show(error)
        }
    }

    private func startInstall(
        id: String,
        label: String,
        _ work: @escaping @Sendable (RuntimeInstaller, @escaping @Sendable (InstallProgress) -> Void) async throws -> URL
    ) {
        guard installs[id] == nil else { return }
        installs[id] = InstallProgress(phase: .downloading, fraction: 0)

        installTasks[id] = Task {
            let installer = RuntimeInstaller()
            do {
                try FileManager.default.createDirectory(at: installer.runtimesDirectory, withIntermediateDirectories: true)
                _ = try await work(installer) { progress in
                    Task { @MainActor [weak self] in
                        // Ignora callbacks que chegam depois do fim.
                        if self?.installs[id] != nil { self?.installs[id] = progress }
                    }
                }
                installs[id] = nil
                await refresh()
                if defaultRuntimeID == nil { defaultRuntimeID = id }
            } catch is CancellationError {
                installs[id] = nil
            } catch {
                installs[id] = nil
                errorMessage = "Falha ao instalar \(label): " + ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
            installTasks[id] = nil
        }
    }

    private func probeMissingVersions() {
        for runtime in runtimes where runtime.version == nil && probedVersions[runtime.id] == nil {
            Task {
                if let v = await WineRunner.probeVersion(runtime) { probedVersions[runtime.id] = v }
            }
        }
    }

    // MARK: Execução

    func launch(_ url: URL, in bottle: Bottle) {
        launch(Program(url: url, kind: .executable), in: bottle)
    }

    func launch(_ program: Program, in bottle: Bottle) {
        if autoSnapshotInstallers && program.arguments.isEmpty && Self.looksLikeInstaller(program.url) {
            Task {
                await createSnapshot(bottle, label: "Antes de \(program.url.lastPathComponent)")
                launchNow(program, in: bottle)
            }
        } else {
            launchNow(program, in: bottle)
        }
    }

    private func launchNow(_ program: Program, in bottle: Bottle) {
        // steam.exe (direto ou via atalho de jogo) passa pelas correções da Steam.
        if program.url.lastPathComponent.lowercased() == "steam.exe", Steam.isInstalled(in: bottle) {
            Task { await openSteam(in: bottle, url: program.arguments.first) }
            return
        }
        let (args, cwd) = WineRunner.launchArguments(for: program)
        run(args, in: bottle, currentDirectory: cwd, label: program.name)
    }

    static func looksLikeInstaller(_ url: URL) -> Bool {
        if url.pathExtension.lowercased() == "msi" { return true }
        let name = url.deletingPathExtension().lastPathComponent.lowercased()
        return ["setup", "install", "instal"].contains { name.contains($0) }
    }

    // MARK: Snapshots

    func loadSnapshots(_ bottle: Bottle) {
        snapshots[bottle.id] = snapshotManager.list(bottle)
    }

    func createSnapshot(_ bottle: Bottle, label: String) async {
        busyMessage = "Criando snapshot…"
        defer { busyMessage = nil }
        let manager = snapshotManager
        do {
            _ = try await Task.detached { try manager.create(bottle, label: label) }.value
            log(bottle.id, "📸 Snapshot criado: \(label)")
            loadSnapshots(bottle)
        } catch {
            show(error)
        }
    }

    func restore(_ snapshot: BottleSnapshot, in bottle: Bottle) async {
        busyMessage = "Restaurando snapshot…"
        defer { busyMessage = nil }
        let manager = snapshotManager
        do {
            if let runtime = runtime(for: bottle) {
                try? await WineRunner(runtime: runtime).killAll(bottle)
            }
            try await Task.detached { try manager.restore(snapshot, to: bottle) }.value
            log(bottle.id, "⏪ Restaurado: \(snapshot.label)")
            await refresh()
            loadSnapshots(bottle)
        } catch {
            show(error)
        }
    }

    func deleteSnapshot(_ snapshot: BottleSnapshot, in bottle: Bottle) {
        do {
            try snapshotManager.delete(snapshot)
            loadSnapshots(bottle)
        } catch {
            show(error)
        }
    }

    // MARK: Exportar / importar

    static var bottleArchiveType: UTType {
        UTType(filenameExtension: BottleArchiver.fileExtension) ?? .data
    }

    func exportBottle(_ bottle: Bottle) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [Self.bottleArchiveType]
        panel.nameFieldStringValue = "\(bottle.name).\(BottleArchiver.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            busyMessage = "Exportando “\(bottle.name)”…"
            defer { busyMessage = nil }
            do {
                if let runtime = runtime(for: bottle) {
                    try? await WineRunner(runtime: runtime).killAll(bottle)
                }
                try await BottleArchiver.export(bottle, to: url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                show(error)
            }
        }
    }

    func importBottle() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [Self.bottleArchiveType]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            busyMessage = "Importando…"
            defer { busyMessage = nil }
            do {
                let bottle = try await manager.importBottle(from: url)
                await refresh()
                selection = bottle.id
                rescanPrograms()
            } catch {
                show(error)
            }
        }
    }

    // MARK: Receitas

    func loadRecipes() async {
        let user = RecipeLibrary.loadUser()
        var errors = user.errors
        var community: [RecipeEntry] = []
        let index = communityIndexURL.trimmingCharacters(in: .whitespaces)
        if !index.isEmpty {
            if let url = URL(string: index) {
                do {
                    let remote = try await RecipeLibrary.loadCommunity(index: url)
                    community = remote.entries
                    errors += remote.errors
                } catch {
                    errors.append("Fonte comunitária: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
                }
            } else {
                errors.append("Fonte comunitária: URL inválida")
            }
        }
        recipes = RecipeLibrary.merge([RecipeLibrary.builtIn(), community, user.entries])
        recipeErrors = errors
    }

    /// Copia um .yaml para a pasta de receitas do usuário.
    func importRecipe() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "yaml"), UTType(filenameExtension: "yml")].compactMap { $0 }
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        do {
            let dir = RecipeLibrary.userDirectory
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for url in panel.urls {
                _ = try Recipe.parse(String(contentsOf: url, encoding: .utf8)) // valida antes de copiar
                let dest = dir.appendingPathComponent(url.lastPathComponent)
                if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
                try FileManager.default.copyItem(at: url, to: dest)
            }
            Task { await loadRecipes() }
        } catch {
            show(error)
        }
    }

    /// Instala uma receita num bottle novo (target nil) ou existente.
    func install(_ entry: RecipeEntry, into target: Bottle?) {
        guard recipeRun == nil else { return }
        isShowingRecipes = false
        recipeTask = Task {
            if let game = entry.recipe.game {
                await installGame(entry.recipe, game: game, preferred: target)
            } else {
                await installRegular(entry.recipe, into: target)
            }
            recipeRun = nil
            recipeTask = nil
            rescanPrograms()
        }
    }

    /// Receita comum: cria/usa bottle, roda os passos, cria atalho.
    @discardableResult
    private func installRegular(_ recipe: Recipe, into target: Bottle?, bottleName: String? = nil,
                                graphics: GraphicsBackend? = nil) async -> Bottle? {
        var chosen = target
        if chosen == nil {
            var preset = recipe.bottle ?? BottlePreset()
            if let graphics { preset.graphics = graphics }
            chosen = await createBottle(
                name: bottleName ?? uniqueBottleName(recipe.name),
                windows: preset.windows ?? .win10,
                graphics: preset.graphics ?? .dxmt,
                preset: preset
            )
        } else if let b = chosen, autoSnapshotInstallers {
            await createSnapshot(b, label: "Antes de \(recipe.name)")
        }
        guard let bottle = chosen else { return nil }

        do {
            try await runSteps(of: recipe, in: bottle)
            await update(bottle) { $0.installedRecipes[recipe.id] = recipe.revision ?? 1 }
            if let launch = recipe.launch, let url = WindowsPath.toUnix(launch.program, in: bottle) {
                let hasExtras = launch.name != nil || launch.icon != nil || !(launch.args ?? []).isEmpty
                if hasExtras {
                    let icon = launch.icon.flatMap { WindowsPath.toUnix($0, in: bottle)?.path }
                    await addShortcut(ProgramShortcut(
                        name: launch.name ?? recipe.name, program: url.path,
                        arguments: launch.args ?? [], icon: icon
                    ), to: bottle)
                } else if FileManager.default.fileExists(atPath: url.path) {
                    await pin(url, in: bottle)
                }
            }
            log(bottle.id, "✅ \(recipe.name) instalado.")
            if let notes = recipe.notes { log(bottle.id, "ℹ️ \(notes)") }
            if recipe.provides.contains("steam") {
                ensureSharedLibrary()
                await applySteamOverrides(bottle)
                guide = GuideState(kind: .steam, bottleID: bottle.id)
            }
            return bottle
        } catch is CancellationError {
            log(bottle.id, "Instalação cancelada.")
        } catch {
            log(bottle.id, "❌ \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
            show(error)
        }
        return nil
    }

    /// Jogo de loja: usa a Steam única (cria se não existir), pede a instalação,
    /// cria o atalho e aplica o perfil só deste jogo.
    private func installGame(_ recipe: Recipe, game: GameSpec, preferred: Bottle?) async {
        let family = game.family

        var bottle: Bottle?
        if let preferred, Steam.isInstalled(in: preferred) {
            bottle = preferred
        } else if preferred == nil {
            bottle = LauncherPlanner.steamBottle(in: bottles)
        }

        if bottle == nil {
            if family == .dx12 && !runtimes.contains(where: { $0.supports(.d3dMetal) }) {
                errorMessage = Self.gptkMissingMessage(recipe.name)
                return
            }
            guard let steam = (recipes + RecipeLibrary.builtIn()).first(where: { $0.recipe.provides.contains("steam") })?.recipe else {
                errorMessage = "Nenhuma receita fornece a Steam."
                return
            }
            bottle = await installRegular(
                steam, into: preferred,
                bottleName: preferred == nil ? uniqueBottleName(GraphicsFamily.steamBottleName) : nil,
                graphics: LauncherPlanner.preferredSteamBackend(runtimes: runtimes)
            )
        }
        guard let bottle, Steam.isInstalled(in: bottle) else {
            if bottle != nil { errorMessage = "A Steam não foi encontrada no bottle depois da instalação." }
            return
        }

        if !LauncherPlanner.runtime(runtime(for: bottle), supports: family) {
            errorMessage = """
            \(recipe.name) é DirectX 12, mas a Steam deste Mac está num runtime sem D3DMetal.
            Instale o Game Porting Toolkit (brew install --cask gcenx/wine/game-porting-toolkit) e reinstale a Steam nele — a biblioteca compartilhada evita baixar os jogos de novo.
            """
            return
        }

        do {
            if !recipe.steps.isEmpty { try await runSteps(of: recipe, in: bottle) }
        } catch {
            show(error)
            return
        }

        // Perfil só deste jogo (AppDefaults do exe), sem afetar os outros.
        if let profile = game.makeProfile() {
            await saveProfile(profile, id: recipe.id, in: bottle)
        }

        await addShortcut(ProgramShortcut(
            name: recipe.launch?.name ?? recipe.name,
            program: Steam.executable(in: bottle).path,
            arguments: [Steam.runURL(appID: game.appid)],
            steamGameExe: game.exe,
            profileID: recipe.id
        ), to: bottle)
        await update(bottle) { $0.installedRecipes[recipe.id] = recipe.revision ?? 1 }

        selection = bottle.id
        ensureSharedLibrary()
        log(bottle.id, "🎮 Pedindo à Steam para instalar \(recipe.name) (app \(game.appid))…")
        await openSteam(in: bottle, url: Steam.installURL(appID: game.appid))
        guide = GuideState(kind: .game(recipeID: recipe.id), bottleID: bottle.id)
    }

    static func gptkMissingMessage(_ name: String) -> String {
        """
        \(name) é DirectX 12 e precisa do Game Porting Toolkit (D3DMetal).
        Instale com: brew install --cask gcenx/wine/game-porting-toolkit
        Depois clique em “Procurar de novo” em Ajustes ▸ Runtimes.
        """
    }

    // MARK: Perfis de jogo

    func profile(_ id: String, in bottle: Bottle) -> GameProfile? {
        (bottles.first { $0.id == bottle.id } ?? bottle).settings.gameProfiles[id]
    }

    /// Salva e aplica no registro só o que mudou no perfil.
    func saveProfile(_ profile: GameProfile, id: String, in bottle: Bottle) async {
        let previous = self.profile(id, in: bottle)
        await update(bottle) { $0.gameProfiles[id] = profile }
        let commands = WineConfigurator.commands(for: profile, previous: previous)
        guard !commands.isEmpty, let runtime = runtime(for: bottle) else { return }
        let runner = WineRunner(runtime: runtime)
        do {
            for command in commands {
                let result = try await runner.runToCompletion(command, in: bottle)
                // `reg delete` de um valor que não existe não é erro para nós.
                if command.first == "reg", command.dropFirst().first == "add" { try result.check() }
            }
            log(bottle.id, "⚙️ Perfil de \(profile.exeName) aplicado.")
        } catch {
            show(error)
        }
    }

    var editingProfile: ProfileEditing?

    /// Roda os passos de uma receita com progresso no banner.
    private func runSteps(of recipe: Recipe, in bottle: Bottle) async throws {
        guard let runtime = runtime(for: bottle) else { throw WineError.noRuntimeAvailable }
        recipeRun = RecipeRunState(recipeName: recipe.name, bottleID: bottle.id)
        selection = bottle.id
        log(bottle.id, "🍷 Receita: \(recipe.name)\(recipe.isVerified ? "" : " (não verificada)")")
        let id = bottle.id
        defer { recipeRun = nil }
        try await RecipeRunner(runtime: runtime).run(recipe, in: bottle) { event in
            Task { @MainActor [weak self] in self?.handle(event, bottle: id) }
        }
    }

    // MARK: Guia / launchers

    func recipe(withID id: String) -> Recipe? {
        (recipes + RecipeLibrary.builtIn()).first { $0.id == id }?.recipe
    }

    /// Itens do guia, recalculados a partir do disco (o checklist se marca sozinho).
    func guideItems(for state: GuideState) -> [GuideItem] {
        guard let bottle = bottles.first(where: { $0.id == state.bottleID }) else { return [] }
        switch state.kind {
        case .steam:
            return GuideBuilder.steam(bottle: bottle)
        case .game(let recipeID):
            guard let recipe = recipe(withID: recipeID) else { return [] }
            // Login é pré-requisito: mostra no topo enquanto não estiver feito.
            let login = GuideBuilder.steam(bottle: bottle).filter { $0.id == "steam-login" && $0.status == .todo }
            return login + GuideBuilder.game(recipe, bottle: bottle)
        }
    }

    /// Guias com passos pendentes neste bottle (Steam + jogos instalados por receita).
    func pendingGuides(for bottle: Bottle) -> [(GuideState, Int)] {
        var result: [(GuideState, Int)] = []
        if Steam.isInstalled(in: bottle) {
            let state = GuideState(kind: .steam, bottleID: bottle.id)
            let pending = GuideBuilder.pendingCount(guideItems(for: state))
            if pending > 0 { result.append((state, pending)) }
        }
        for recipeID in bottle.settings.installedRecipes.keys.sorted() {
            guard recipe(withID: recipeID)?.game != nil else { continue }
            let state = GuideState(kind: .game(recipeID: recipeID), bottleID: bottle.id)
            let pending = GuideBuilder.pendingCount(guideItems(for: state).filter { $0.id.hasPrefix("game-") })
            if pending > 0 { result.append((state, pending)) }
        }
        return result
    }

    func perform(_ action: GuideItem.Action, bottleID: Bottle.ID) {
        guard let bottle = bottles.first(where: { $0.id == bottleID }) else { return }
        switch action {
        case .openSteam(let url):
            Task { await openSteam(in: bottle, url: url) }
        case .fixSteam:
            Task { await fixSteam(bottle) }
        case .mountSharedLibrary:
            // Fecha a Steam, monta S:, registra a biblioteca e reabre.
            Task { await fixSteam(bottle) }
        case .gameSettings(let id):
            guide = nil
            editingProfile = ProfileEditing(bottleID: bottle.id, profileID: id)
        case .copy(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .revealFolder(let folder):
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        case .launchShortcut(let name):
            if let program = programs.first(where: { $0.name == name }) {
                launch(program, in: bottle)
            }
        }
    }

    /// Abre a Steam do bottle sem esperar (ela fica aberta), com as correções
    /// para o Wine do macOS: wrapper do steamwebhelper, overrides e flags.
    func openSteam(in bottle: Bottle, url: String? = nil) async {
        await applySteamOverrides(bottle)
        let current = bottles.first { $0.id == bottle.id } ?? bottle
        prepareSharedLibrary(in: current)
        if (runningCount[current.id] ?? 0) == 0 {
            SteamFixes.clearStaleLocks(in: current)
        }
        do {
            if try SteamFixes.deployWebHelperWrapper(in: current) > 0 {
                log(current.id, "🩹 Correção da tela preta da Steam aplicada.")
            }
        } catch {
            log(current.id, "⚠️ Não consegui aplicar a correção da Steam: \(error.localizedDescription)")
        }
        let args = WineRunner.detachedLaunchArguments(
            for: Steam.executable(in: current),
            extra: SteamFixes.launchArguments + (url.map { [$0] } ?? [])
        )
        run(args, in: current, currentDirectory: nil, label: "Steam")
        if !SteamFixes.isWrapperDeployed(in: current) { watchSteamFirstRun(current) }
    }

    /// Fecha tudo, reaplica as correções e reabre a Steam.
    func fixSteam(_ bottle: Bottle) async {
        if let runtime = runtime(for: bottle) {
            try? await WineRunner(runtime: runtime).killAll(bottle)
        }
        SteamFixes.clearStaleLocks(in: bottle)
        mountSharedLibrary(in: bottle)
        // A Steam acabou de ser fechada: seguro escrever na lista de bibliotecas.
        if (try? SteamLibraryRegistrar.register(in: bottle)) == true {
            log(bottle.id, "📚 Biblioteca \(SteamLibraryRegistrar.windowsPath()) registrada na Steam.")
        }
        await openSteam(in: bottle)
    }

    private func applySteamOverrides(_ bottle: Bottle) async {
        let current = bottles.first { $0.id == bottle.id } ?? bottle
        let missing = SteamFixes.dllOverrides.filter { current.settings.dllOverrides[$0.key] == nil }
        guard !missing.isEmpty else { return }
        await update(current) { s in s.dllOverrides.merge(missing) { old, _ in old } }
    }

    private var steamWatchers: Set<Bottle.ID> = []

    /// Na primeira abertura a Steam baixa o CEF e abre com tela preta. Assim que
    /// o CEF aparece, aplica a correção e reabre a Steam (uma vez).
    private func watchSteamFirstRun(_ bottle: Bottle) {
        guard steamWatchers.insert(bottle.id).inserted else { return }
        Task {
            defer { steamWatchers.remove(bottle.id) }
            for _ in 0..<120 { // até 10 minutos
                try? await Task.sleep(for: .seconds(5))
                if !SteamFixes.cefDirectories(in: bottle).isEmpty, !SteamFixes.isWrapperDeployed(in: bottle) {
                    // Dá tempo da atualização terminar de gravar arquivos.
                    try? await Task.sleep(for: .seconds(10))
                    log(bottle.id, "🩹 A Steam terminou de se atualizar; aplicando a correção e reabrindo…")
                    await fixSteam(bottle)
                    return
                }
                if SteamFixes.isWrapperDeployed(in: bottle) { return }
            }
        }
    }

    func ensureSharedLibrary() {
        try? FileManager.default.createDirectory(at: VinhoPaths.sharedSteamLibrary, withIntermediateDirectories: true)
    }

    /// Em todo bottle com Steam: monta o drive S: (bottles antigos também).
    private func prepareSteamBottles() {
        for bottle in bottles where Steam.isInstalled(in: bottle) {
            mountSharedLibrary(in: bottle)
        }
    }

    /// Monta o S: e, com a Steam fechada, registra a biblioteca nela.
    func prepareSharedLibrary(in bottle: Bottle) {
        mountSharedLibrary(in: bottle)
        guard (runningCount[bottle.id] ?? 0) == 0, Steam.isSharedLibraryMounted(in: bottle) else { return }
        do {
            if try SteamLibraryRegistrar.register(in: bottle) {
                log(bottle.id, "📚 Biblioteca \(SteamLibraryRegistrar.windowsPath()) registrada na Steam.")
            }
        } catch {
            log(bottle.id, "⚠️ Não consegui registrar a biblioteca S: na Steam: \(error.localizedDescription)")
        }
    }

    /// Cria a pasta compartilhada e a monta como drive S: no bottle da Steam.
    func mountSharedLibrary(in bottle: Bottle) {
        do {
            if !Steam.isSharedLibraryMounted(in: bottle) {
                try Steam.mountSharedLibrary(in: bottle)
                log(bottle.id, "📁 Biblioteca compartilhada montada como drive S: (\(VinhoPaths.sharedSteamLibrary.path)).")
            }
        } catch {
            log(bottle.id, "⚠️ Não consegui montar o drive S:: \(error.localizedDescription)")
        }
    }

    func cancelRecipe() {
        recipeTask?.cancel()
    }

    private func handle(_ event: RecipeRunner.Event, bottle id: Bottle.ID) {
        switch event {
        case .step(let index, let total, let title):
            recipeRun?.step = "\(index)/\(total) · \(title)"
            recipeRun?.fraction = nil
            log(id, "— \(title)")
        case .progress(let fraction):
            recipeRun?.fraction = fraction
        case .log(let line):
            append(id, LogLine(source: .stdout, text: line))
        }
    }

    private func uniqueBottleName(_ base: String) -> String {
        let taken = Set(bottles.map { $0.name.lowercased() })
        var name = base
        var n = 2
        while taken.contains(name.lowercased()) {
            name = "\(base) \(n)"
            n += 1
        }
        return name
    }

    // MARK: Compatibilidade

    static var vinhoVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    func rating(for program: Program, in bottle: Bottle) -> CompatibilityRating? {
        bottle.settings.compatibility[program.id]
    }

    func makeReport(for program: Program, in bottle: Bottle, rating: CompatibilityRating, notes: String) -> CompatibilityReport {
        let current = bottles.first { $0.id == bottle.id } ?? bottle
        let runtime = runtime(for: current)
        return CompatibilityReport(
            program: program.name,
            rating: rating,
            notes: notes,
            recipes: current.settings.installedRecipes,
            runtime: runtime.map { r in displayVersion(r).map { "\(r.id) (\($0))" } ?? r.id } ?? "—",
            backend: current.settings.graphics,
            windows: current.settings.windowsVersion,
            macOS: CompatibilityReport.macOSVersion,
            hardware: CompatibilityReport.hardwareDescription,
            vinhoVersion: Self.vinhoVersion
        )
    }

    /// Guarda a nota localmente e, se pedido, abre a issue pré-preenchida.
    func submit(_ report: CompatibilityReport, program: Program, in bottle: Bottle, openGitHub: Bool) async {
        await update(bottle) { $0.compatibility[program.id] = report.rating }
        if openGitHub {
            if let url = report.issueURL(repository: communityRepo) {
                NSWorkspace.shared.open(url)
            } else {
                errorMessage = "Configure o repositório da comunidade (owner/repo) em Ajustes ▸ Geral."
            }
        }
    }

    func copyReport(_ report: CompatibilityReport) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("# \(report.title)\n\n\(report.markdown)", forType: .string)
    }

    // MARK: Atalhos (Launchpad / Spotlight / Dock)

    func createShortcut(for program: Program, in bottle: Bottle) {
        guard let runtime = runtime(for: bottle) else { return show(WineError.noRuntimeAvailable) }
        let (args, cwd) = WineRunner.launchArguments(for: program)
        let invocation = WineRunner(runtime: runtime).invocation(args, in: bottle, currentDirectory: cwd)
        do {
            let dir = LauncherBuilder.defaultDirectory
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let app = try LauncherBuilder.makeApp(named: program.name, invocation: invocation, in: dir)
            if let data = ProgramIconResolver.iconData(for: program.iconURL ?? program.url, in: bottle), let image = NSImage(data: data) {
                NSWorkspace.shared.setIcon(image, forFile: app.path, options: [])
            }
            log(bottle.id, "Atalho criado em \(app.path)")
            NSWorkspace.shared.activateFileViewerSelecting([app])
        } catch {
            show(error)
        }
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
            // Instalou a Steam "na mão" (arrastando o SteamSetup.exe)? Mostra o guia.
            if label.lowercased().hasPrefix("steamsetup"), Steam.isInstalled(in: bottle), recipeRun == nil {
                ensureSharedLibrary()
                guide = GuideState(kind: .steam, bottleID: id)
            }
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
