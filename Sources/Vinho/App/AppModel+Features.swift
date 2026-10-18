import AppKit
import Foundation
import WineKit

/// Arquivo aberto pelo Finder esperando a escolha do bottle.
struct OpenRequest: Identifiable, Equatable {
    let url: URL
    var id: String { url.path }
}

/// Ponte entre o AppDelegate (Abrir com… / arrastar no Dock) e o modelo.
@MainActor
enum OpenFileRouter {
    static var handler: (@MainActor ([URL]) -> Void)?
    static var pending: [URL] = []

    static func open(_ urls: [URL]) {
        if let handler { handler(urls) } else { pending += urls }
    }
}

extension AppModel {
    // MARK: Componentes do Windows

    func isComponentInstalled(_ component: WindowsComponent, in bottle: Bottle) -> Bool {
        let current = bottles.first { $0.id == bottle.id } ?? bottle
        return current.settings.windowsComponents.contains(component.id)
    }

    /// Instala um componente (.NET, VC++, DirectX, fontes) no bottle.
    func installComponent(_ component: WindowsComponent, in bottle: Bottle) {
        guard recipeRun == nil else { return }
        if component.needsWinetricks && !WinetricksManager.cabextractAvailable {
            errorMessage = """
            \(component.name) precisa do cabextract para extrair os instaladores da Microsoft.
            Instale com: brew install cabextract
            """
            return
        }
        recipeTask = Task {
            defer { recipeTask = nil }
            do {
                if component.needsWinetricks && WinetricksManager.resolve() == nil {
                    busyMessage = "Baixando o winetricks \(WinetricksManager.version)…"
                    defer { busyMessage = nil }
                    try await WinetricksManager.install()
                    log(bottle.id, "🧰 winetricks \(WinetricksManager.version) instalado (verificado por SHA-256).")
                }
                if autoSnapshotInstallers { await createSnapshot(bottle, label: "Antes de \(component.name)") }
                try await runSteps(of: component.recipe, in: bottle)
                await update(bottle) { s in
                    if !s.windowsComponents.contains(component.id) { s.windowsComponents.append(component.id) }
                }
                log(bottle.id, "✅ \(component.name) instalado.")
            } catch is CancellationError {
                log(bottle.id, "Instalação de \(component.name) cancelada.")
            } catch {
                log(bottle.id, "❌ \(component.name): \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
                show(error)
            }
        }
    }

    /// Componentes sugeridos a partir das DLLs que o Wine não achou no log.
    func missingComponentSuggestions(for bottle: Bottle) -> [WindowsComponent] {
        let lines = (logs[bottle.id] ?? []).suffix(2_000).map(\.text)
        let current = bottles.first { $0.id == bottle.id } ?? bottle
        return MissingComponentDetector.suggestions(for: Array(lines), installed: Set(current.settings.windowsComponents))
    }

    // MARK: Abrir pelo Finder

    func registerOpenHandler() {
        OpenFileRouter.handler = { [weak self] urls in self?.open(urls) }
        if !OpenFileRouter.pending.isEmpty {
            open(OpenFileRouter.pending)
            OpenFileRouter.pending = []
        }
    }

    func open(_ urls: [URL]) {
        pendingOpenURLs += urls
        if hasLoadedBottles { processPendingOpens() }
    }

    func processPendingOpens() {
        guard hasLoadedBottles, !pendingOpenURLs.isEmpty else { return }
        let urls = pendingOpenURLs
        pendingOpenURLs = []
        for url in urls {
            switch url.pathExtension.lowercased() {
            case BottleArchiver.fileExtension:
                importBottle(from: url)
            case "yaml", "yml":
                importRecipe(from: [url])
            default:
                if let bottle = defaultBottle {
                    selection = bottle.id
                    launch(url, in: bottle)
                } else if bottles.isEmpty {
                    errorMessage = "Crie um bottle antes de abrir “\(url.lastPathComponent)”."
                } else {
                    openRequest = OpenRequest(url: url)
                }
            }
        }
    }

    var defaultBottle: Bottle? {
        guard let path = defaultBottlePath else { return nil }
        return bottles.first { $0.url.standardizedFileURL.path == path }
    }

    func isDefault(_ bottle: Bottle) -> Bool {
        defaultBottlePath == bottle.url.standardizedFileURL.path
    }

    func setDefault(_ bottle: Bottle?) {
        defaultBottlePath = bottle?.url.standardizedFileURL.path
    }

    /// Resposta da folha "Abrir com qual bottle?".
    func open(_ request: OpenRequest, in bottle: Bottle, always: Bool) {
        openRequest = nil
        if always { setDefault(bottle) }
        selection = bottle.id
        launch(request.url, in: bottle)
    }

    // MARK: Executar comando

    /// Executa um programa (caminho do Windows ou do Mac) com argumentos e,
    /// opcionalmente, salva como atalho na grade.
    func runCommand(program path: String, arguments: String, in bottle: Bottle, saveAs name: String?) async {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let args = CommandLineSplitter.split(arguments)

        // "regedit", "cmd" etc.: ferramentas do Wine, sem caminho.
        let isWindowsPath = trimmed.count > 1 && trimmed.dropFirst().first == ":"
        guard isWindowsPath || trimmed.hasPrefix("/") else {
            run([trimmed] + args, in: bottle, currentDirectory: nil, label: trimmed)
            return
        }
        let url: URL? = isWindowsPath ? WindowsPath.toUnix(trimmed, in: bottle) : URL(fileURLWithPath: trimmed)
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            errorMessage = "Não encontrei “\(trimmed)” neste bottle."
            return
        }
        if let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            await addShortcut(ProgramShortcut(name: name, program: url.path, arguments: args), to: bottle)
        }
        launch(Program(url: url, kind: .executable, arguments: args), in: bottle)
    }

    // MARK: Duplicar

    func duplicate(_ bottle: Bottle) async {
        busyMessage = "Duplicando “\(bottle.name)”…"
        defer { busyMessage = nil }
        do {
            if let runtime = runtime(for: bottle) {
                try? await WineRunner(runtime: runtime).killAll(bottle)
            }
            let copy = try await manager.duplicate(bottle)
            await refresh()
            selection = copy.id
            rescanPrograms()
        } catch {
            show(error)
        }
    }

    // MARK: Catálogo da comunidade (Wine com patches da CodeWeavers)

    func loadCommunityCatalog() async {
        guard let remote = try? await Catalog.load(from: Catalog.communityURL) else { return }
        catalog = Catalog.builtIn.merging(remote)
    }

    // MARK: Atualizações

    /// Checagem automática no máximo uma vez por dia.
    func checkForUpdatesIfDue() async {
        guard autoCheckUpdates else { return }
        let last = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 24 * 3600 else { return }
        await checkForUpdates(userInitiated: false)
    }

    func checkForUpdates(userInitiated: Bool) async {
        UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")
        guard AppVersion(Self.vinhoVersion) != nil else {
            if userInitiated { updateStatus = "Esta cópia foi compilada localmente (versão “\(Self.vinhoVersion)”). Use git pull para atualizar." }
            return
        }
        do {
            if let release = try await AppUpdater().update(newerThan: Self.vinhoVersion) {
                availableUpdate = release
            } else if userInitiated {
                updateStatus = "Você já está na versão mais recente (\(Self.vinhoVersion))."
            }
        } catch {
            if userInitiated { updateStatus = "Não consegui procurar atualizações: \(error.localizedDescription)" }
        }
    }

    /// Baixa, troca o Vinho.app e reabre.
    func installUpdate(_ release: AppUpdater.Release) {
        let appURL = Bundle.main.bundleURL
        guard appURL.pathExtension == "app" else {
            NSWorkspace.shared.open(release.pageURL)
            return
        }
        availableUpdate = nil
        isInstallingUpdate = true
        Task {
            busyMessage = "Baixando o Vinho \(release.version)…"
            defer { busyMessage = nil; isInstallingUpdate = false }
            do {
                let installed = try await AppUpdater().install(release, replacing: appURL)
                Self.relaunch(installed)
            } catch {
                show(error)
            }
        }
    }

    private static func relaunch(_ app: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", app.path]
        try? process.run()
        NSApp.terminate(nil)
    }

    // MARK: Biblioteca da Steam → atalhos

    func syncSteamLibraries() async {
        for bottle in bottles where Steam.isInstalled(in: bottle) {
            await syncSteamLibrary(bottle)
        }
    }

    /// Cria um atalho (com perfil próprio) para cada jogo baixado pela Steam,
    /// mesmo os instalados pela loja, sem receita.
    func syncSteamLibrary(_ bottle: Bottle) async {
        let current = bottles.first { $0.id == bottle.id } ?? bottle
        let existing = Set(current.settings.shortcuts.flatMap(\.arguments))
        let known = recipes.map(\.recipe) + RecipeLibrary.builtIn().map(\.recipe)

        var newShortcuts: [ProgramShortcut] = []
        var profiles: [(String, GameProfile)] = []
        for game in SteamLibraryScanner.installedGames(in: current) where game.isFullyInstalled {
            let runURL = Steam.runURL(appID: game.appid)
            guard !existing.contains(runURL) else { continue }
            let recipe = known.first { $0.game?.appid == game.appid }
            let profileID = recipe?.id ?? "steam-\(game.appid)"

            var exe = recipe?.game?.exe
            if exe == nil, let guess = SteamLibraryScanner.guessExecutable(in: game.installDirectory) {
                exe = Self.relativeToSteamCommon(guess)
            }
            newShortcuts.append(ProgramShortcut(
                name: recipe?.launch?.name ?? recipe?.name ?? game.name,
                program: Steam.executable(in: current).path,
                arguments: [runURL],
                steamGameExe: exe,
                profileID: profileID
            ))
            if current.settings.gameProfiles[profileID] == nil {
                if let profile = recipe?.game?.makeProfile() {
                    profiles.append((profileID, profile))
                } else if let exeName = exe?.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last {
                    profiles.append((profileID, GameProfile(exeName: String(exeName))))
                }
            }
        }
        guard !newShortcuts.isEmpty else { return }
        await update(current) { s in
            // Outra sincronização pode ter rodado no meio: não duplica.
            let taken = Set(s.shortcuts.flatMap(\.arguments))
            s.shortcuts.append(contentsOf: newShortcuts.filter { !taken.contains($0.arguments[0]) })
        }
        for (id, profile) in profiles { await saveProfile(profile, id: id, in: current) }
        log(current.id, "🎮 Jogos da Steam adicionados à grade: \(newShortcuts.map(\.name).joined(separator: ", ")).")
        if selection == current.id { rescanPrograms() }
    }

    /// `…/steamapps/common/Portal 2/portal2.exe` → `Portal 2\portal2.exe`
    static func relativeToSteamCommon(_ url: URL) -> String? {
        let parts = url.standardizedFileURL.pathComponents
        guard let i = parts.lastIndex(where: { $0.lowercased() == "common" }), i > 0,
              parts[i - 1].lowercased() == "steamapps", i + 1 < parts.count else { return nil }
        return parts[(i + 1)...].joined(separator: "\\")
    }
}
