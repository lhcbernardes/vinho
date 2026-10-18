import XCTest
@testable import WineKit

/// Registra as invocações e responde "saiu com 0".
final class RecordingLauncher: ProcessLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private var _invocations: [WineInvocation] = []
    let exitCode: Int32

    init(exitCode: Int32 = 0) { self.exitCode = exitCode }

    var invocations: [WineInvocation] {
        lock.lock(); defer { lock.unlock() }
        return _invocations
    }

    func run(_ invocation: WineInvocation) -> AsyncThrowingStream<ProcessEvent, Error> {
        lock.lock(); _invocations.append(invocation); lock.unlock()
        let code = exitCode
        return AsyncThrowingStream { c in
            c.yield(.stdout("ok"))
            c.yield(.exited(code))
            c.finish()
        }
    }
}

final class RecipeParsingTests: XCTestCase {
    func testBuiltInRecipesAreValid() {
        let entries = RecipeLibrary.builtIn()
        XCTAssertEqual(Set(entries.map(\.id)), ["notepad-plus-plus", "7zip", "steam", "left-4-dead-2"])
        let npp = entries.first { $0.id == "notepad-plus-plus" }!.recipe
        XCTAssertTrue(npp.isVerified)
        XCTAssertEqual(npp.launch?.program, #"C:\Program Files\Notepad++\notepad++.exe"#)
        XCTAssertEqual(npp.bottle?.graphics, .wined3d)
        XCTAssertFalse(entries.first { $0.id == "steam" }!.recipe.isVerified)
    }

    func testParsesAllStepKinds() throws {
        let recipe = try Recipe.parse("""
        id: jogo-x
        name: Jogo X
        category: game
        description: Teste
        bottle:
          windows: win11
          retina: true
          environment: { DXMT_LOG: "1" }
          dllOverrides: { xinput1_3: native, d3dcompiler_47: "native,builtin" }
        steps:
          - download: { url: "https://example.com/setup.exe", sha256: "\(String(repeating: "a", count: 64))" }
          - winetricks: [corefonts, vcrun2019]
          - registry: { key: 'HKCU\\Software\\X', value: Mode, data: "1" }
          - run: { file: setup.exe, args: ["/VERYSILENT"], okExitCodes: [0, 1] }
        launch: { program: 'C:\\Games\\X\\x.exe', args: ["-windowed"] }
        """)
        XCTAssertEqual(recipe.category, .game)
        XCTAssertEqual(recipe.steps.count, 4)
        XCTAssertTrue(recipe.needsWinetricks)
        guard case .download(let d) = recipe.steps[0] else { return XCTFail() }
        XCTAssertEqual(d.fileName, "setup.exe")
        guard case .run(let r) = recipe.steps[3] else { return XCTFail() }
        XCTAssertEqual(r.okExitCodes, [0, 1])

        var settings = BottleSettings(name: "x")
        recipe.bottle?.apply(to: &settings)
        XCTAssertEqual(settings.windowsVersion, .win11)
        XCTAssertTrue(settings.retinaMode)
        XCTAssertEqual(settings.environment["DXMT_LOG"], "1")
        XCTAssertEqual(settings.dllOverrides["xinput1_3"], .native)
        XCTAssertEqual(settings.dllOverrides["d3dcompiler_47"], .nativeThenBuiltin)
    }

    func testValidationErrors() {
        func invalid(_ yaml: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertThrowsError(try Recipe.parse(yaml), file: file, line: line)
        }
        // id com maiúsculas
        invalid("id: Bad\nname: x\nsteps:\n  - run: { file: 'C:\\x.exe' }")
        // download http
        invalid("id: a\nname: x\nsteps:\n  - download: { url: 'http://x.com/a.exe' }")
        // run de arquivo não baixado
        invalid("id: a\nname: x\nsteps:\n  - run: { file: nada.exe }")
        // passo desconhecido
        invalid("id: a\nname: x\nsteps:\n  - format: { disk: c }")
        // dois passos no mesmo item
        invalid("id: a\nname: x\nsteps:\n  - { winetricks: [a], registry: { key: HKCU, value: v, data: d } }")
        // override inválido
        invalid("id: a\nname: x\nbottle: { dllOverrides: { d3d11: talvez } }\nsteps:\n  - run: { file: 'C:\\x.exe' }")
        // verbo winetricks com shell
        invalid("id: a\nname: x\nsteps:\n  - winetricks: ['a; rm -rf ~']")
        // nome de arquivo com path traversal
        invalid("id: a\nname: x\nsteps:\n  - download: { url: 'https://x.com/a', file: '../../a.exe' }")
    }
}

final class RecipeRunnerTests: XCTestCase {
    private var work: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        work = fm.temporaryDirectory.appendingPathComponent("vinho-recipe-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: work)
    }

    private func setup() throws -> (installer: URL, sha: String, bottle: Bottle, runtime: WineRuntime) {
        let installer = work.appendingPathComponent("source-setup.exe")
        try Data("MZ fake installer".utf8).write(to: installer)
        let bottle = Bottle(url: work.appendingPathComponent("bottle"), settings: BottleSettings(name: "b"))
        let runtime = WineRuntime(id: "rt", rootURL: URL(fileURLWithPath: "/opt/wine"), capabilities: [])
        return (installer, try Checksum.sha256(of: installer), bottle, runtime)
    }

    func testRunsStepsInOrderAndCaches() async throws {
        let (installer, sha, bottle, runtime) = try setup()
        let recipe = try Recipe.parse("""
        id: app-teste
        name: App
        steps:
          - download: { url: "https://example.com/s.exe", sha256: "\(sha)", file: setup.exe }
          - registry: { key: 'HKCU\\Software\\App', value: Mode, data: "on" }
          - winetricks: [corefonts]
          - run: { file: setup.exe, args: ["/S"] }
        """)
        let launcher = RecordingLauncher()
        let runner = RecipeRunner(
            runtime: runtime, launcher: launcher,
            downloader: LocalFileDownloader(source: installer),
            cacheDirectory: work.appendingPathComponent("cache"),
            winetricksURL: URL(fileURLWithPath: "/opt/homebrew/bin/winetricks")
        )
        let steps = PhaseRecorderStrings()
        try await runner.run(recipe, in: bottle) { event in
            if case .step(_, _, let title) = event { steps.add(title) }
        }

        XCTAssertEqual(steps.values, ["Baixando setup.exe", "Registro: Mode", "winetricks corefonts", "Executando setup.exe"])

        let cached = work.appendingPathComponent("cache/app-teste/setup.exe")
        XCTAssertTrue(fm.fileExists(atPath: cached.path))

        // Ignora as chamadas ao wineserver (-w) e olha só os comandos.
        let commands = launcher.invocations.filter { $0.executable.lastPathComponent != "wineserver" }
        XCTAssertEqual(commands.count, 3)
        XCTAssertEqual(commands[0].arguments.prefix(3), ["reg", "add", #"HKCU\Software\App"#])
        XCTAssertEqual(commands[1].executable.path, "/opt/homebrew/bin/winetricks")
        XCTAssertEqual(commands[1].arguments, ["-q", "corefonts"])
        XCTAssertEqual(commands[1].environment["WINE"], "/opt/wine/bin/wine")
        XCTAssertEqual(commands[1].environment["WINEPREFIX"], bottle.url.path)
        XCTAssertEqual(commands[2].arguments, [cached.path, "/S"])
        XCTAssertEqual(commands[2].currentDirectory?.path, cached.deletingLastPathComponent().path)
    }

    func testChecksumMismatchStops() async throws {
        let (installer, _, bottle, runtime) = try setup()
        let recipe = try Recipe.parse("""
        id: app-ruim
        name: App
        steps:
          - download: { url: "https://example.com/s.exe", sha256: "\(String(repeating: "0", count: 64))", file: s.exe }
          - run: { file: s.exe }
        """)
        let launcher = RecordingLauncher()
        let runner = RecipeRunner(runtime: runtime, launcher: launcher,
                                  downloader: LocalFileDownloader(source: installer),
                                  cacheDirectory: work.appendingPathComponent("cache"), winetricksURL: nil)
        do {
            try await runner.run(recipe, in: bottle)
            XCTFail("deveria falhar")
        } catch let error as WineError {
            guard case .checksumMismatch = error else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(launcher.invocations.isEmpty, "nada pode executar depois de um checksum errado")
    }

    func testFailingInstallerThrowsAndWinetricksIsRequired() async throws {
        let (installer, sha, bottle, runtime) = try setup()
        let recipe = try Recipe.parse("""
        id: app-falha
        name: App
        steps:
          - download: { url: "https://example.com/s.exe", sha256: "\(sha)", file: s.exe }
          - run: { file: s.exe }
        """)
        let runner = RecipeRunner(runtime: runtime, launcher: RecordingLauncher(exitCode: 2),
                                  downloader: LocalFileDownloader(source: installer),
                                  cacheDirectory: work.appendingPathComponent("cache"), winetricksURL: nil)
        do {
            try await runner.run(recipe, in: bottle)
            XCTFail("deveria falhar")
        } catch let error as WineError {
            guard case .nonZeroExit(_, let code, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(code, 2)
        }

        let needsWinetricks = try Recipe.parse("id: wt\nname: x\nsteps:\n  - winetricks: [corefonts]")
        do {
            try await runner.run(needsWinetricks, in: bottle)
            XCTFail("deveria exigir winetricks")
        } catch let error as RecipeError {
            XCTAssertEqual(error, .winetricksMissing)
        }
    }
}

final class RecipeLibraryTests: XCTestCase {
    func testUserAndCommunityLayersOverrideBuiltIn() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vinho-lib-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let user = dir.appendingPathComponent("user")
        let community = dir.appendingPathComponent("community")
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: community.appendingPathComponent("recipes"), withIntermediateDirectories: true)

        try "id: 7zip\nname: 7-Zip (minha)\nsteps:\n  - run: { file: 'C:\\x.exe' }".write(to: user.appendingPathComponent("7zip.yaml"), atomically: true, encoding: .utf8)
        try "isto: [não é: receita".write(to: user.appendingPathComponent("quebrada.yml"), atomically: true, encoding: .utf8)

        try "recipes:\n  - recipes/jogo.yaml\n  - recipes/faltando.yaml\n".write(to: community.appendingPathComponent("index.yaml"), atomically: true, encoding: .utf8)
        try "id: jogo\nname: Jogo Comunitário\ncategory: game\nsteps:\n  - run: { file: 'C:\\j.exe' }".write(to: community.appendingPathComponent("recipes/jogo.yaml"), atomically: true, encoding: .utf8)

        let local = RecipeLibrary.loadUser(from: user)
        XCTAssertEqual(local.entries.map(\.id), ["7zip"])
        XCTAssertEqual(local.errors.count, 1)

        let remote = try await RecipeLibrary.loadCommunity(index: community.appendingPathComponent("index.yaml"))
        XCTAssertEqual(remote.entries.map(\.id), ["jogo"])
        XCTAssertEqual(remote.errors.count, 1, "arquivo faltando vira erro, não exceção")

        let merged = RecipeLibrary.merge([RecipeLibrary.builtIn(), remote.entries, local.entries])
        XCTAssertEqual(merged.first { $0.id == "7zip" }?.recipe.name, "7-Zip (minha)")
        XCTAssertEqual(merged.first { $0.id == "jogo" }?.source.label, "Comunidade")
        XCTAssertEqual(Set(merged.map(\.id)), ["7zip", "notepad-plus-plus", "steam", "left-4-dead-2", "jogo"])
    }
}

final class PhaseRecorderStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [String] = []
    func add(_ v: String) { lock.lock(); _values.append(v); lock.unlock() }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return _values }
}

final class CommunityFolderTests: XCTestCase {
    /// `community/` deve continuar válido e espelhar as receitas embutidas.
    func testRepositoryCommunityIndexIsValid() async throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let index = repo.appendingPathComponent("community/index.yaml")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: index.path), "community/ não encontrado")

        let result = try await RecipeLibrary.loadCommunity(index: index)
        XCTAssertEqual(result.errors, [])
        XCTAssertEqual(Set(result.entries.map(\.id)), Set(RecipeLibrary.builtIn().map(\.id)))
    }
}

final class CompatibilityReportTests: XCTestCase {
    private func report(notes: String = "Roda a 60 fps.\nSem som no menu.") -> CompatibilityReport {
        CompatibilityReport(
            program: "Steam", rating: .playable, notes: notes, recipes: ["steam": 1],
            runtime: "wine-stable-11.0_1+dxmt-v0.80", backend: .dxmt, windows: .win10,
            macOS: "26.1.0", hardware: "Apple M2 Pro", vinhoVersion: "0.4.0"
        )
    }

    func testMarkdownContainsContextButNoPaths() {
        let md = report().markdown
        XCTAssertTrue(md.contains("🟡 Steam: Funciona"))
        XCTAssertTrue(md.contains("`steam` r1"))
        XCTAssertTrue(md.contains("| Gráficos | DXMT |"))
        XCTAssertTrue(md.contains("Sem som no menu."))
        XCTAssertFalse(md.contains("/Users/"))
        XCTAssertTrue(report(notes: "  ").markdown.contains("_(sem observações)_"))
    }

    func testIssueURLIsEncodedAndValidatesRepository() throws {
        let url = try XCTUnwrap(report().issueURL(repository: "leandro/vinho"))
        XCTAssertEqual(url.host, "github.com")
        XCTAssertEqual(url.path, "/leandro/vinho/issues/new")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "title" }?.value, "[compat] Steam — Funciona")
        XCTAssertEqual(items.first { $0.name == "labels" }?.value, "compatibilidade")
        XCTAssertTrue(items.first { $0.name == "body" }?.value?.contains("Apple M2 Pro") == true)

        XCTAssertNil(report().issueURL(repository: ""))
        XCTAssertNil(report().issueURL(repository: "https://github.com/x/y"))
        XCTAssertNil(report().issueURL(repository: "x/y/z"))
    }

    func testSettingsPersistCompatibilityAndRecipes() throws {
        var s = BottleSettings(name: "b")
        s.compatibility["/x/steam.exe"] = .perfect
        s.installedRecipes["steam"] = 2
        let back = try BottleManager.decoder.decode(BottleSettings.self, from: BottleManager.encoder.encode(s))
        XCTAssertEqual(back.compatibility["/x/steam.exe"], .perfect)
        XCTAssertEqual(back.installedRecipes["steam"], 2)
    }
}


final class ShortcutAndDetachedRunTests: XCTestCase {
    func testLeft4Dead2IsASteamGameRecipe() throws {
        let recipe = try XCTUnwrap(RecipeLibrary.builtIn().first { $0.id == "left-4-dead-2" }?.recipe)
        let game = try XCTUnwrap(recipe.game)
        XCTAssertEqual(game.store, .steam)
        XCTAssertEqual(game.appid, 550)
        XCTAssertEqual(game.family, .classic, "DX9 vai para o bottle DX9–11")
        XCTAssertTrue(recipe.steps.isEmpty, "a Steam vem da receita que a fornece, não do jogo")
        XCTAssertFalse(recipe.guide?.isEmpty ?? true)
        XCTAssertTrue(RecipeLibrary.builtIn().contains { $0.recipe.provides.contains("steam") })
    }

    func testDetachedRunUsesStartAndSkipsWaitingForServer() async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("vinho-detach-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        let bottle = Bottle(url: work.appendingPathComponent("b"), settings: BottleSettings(name: "b"))
        let steam = bottle.driveC.appendingPathComponent("Program Files (x86)/Steam/steam.exe")
        try FileManager.default.createDirectory(at: steam.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: steam.path, contents: Data())

        let recipe = try Recipe.parse("""
        id: abre-steam
        name: x
        steps:
          - run: { file: 'C:\\Program Files (x86)\\Steam\\steam.exe', args: ["steam://install/550"], wait: false }
        """)
        let launcher = RecordingLauncher()
        let runtime = WineRuntime(id: "rt", rootURL: URL(fileURLWithPath: "/opt/wine"), capabilities: [])
        try await RecipeRunner(runtime: runtime, launcher: launcher,
                               downloader: LocalFileDownloader(source: work),
                               cacheDirectory: work.appendingPathComponent("cache"), winetricksURL: nil)
            .run(recipe, in: bottle)

        XCTAssertEqual(launcher.invocations.count, 1, "sem wineserver -w: a Steam continua aberta")
        XCTAssertEqual(launcher.invocations[0].arguments, ["start", "/unix", steam.path, "steam://install/550"])
    }

    func testShortcutProgramsHaveDistinctIDsAndArguments() {
        let exe = URL(fileURLWithPath: "/b/drive_c/Steam/steam.exe")
        let plain = Program(url: exe, kind: .executable)
        let l4d2 = ProgramShortcut(name: "Left 4 Dead 2", program: exe.path,
                                   arguments: ["steam://rungameid/550"], icon: "/b/l4d2.exe").asProgram
        XCTAssertNotEqual(plain.id, l4d2.id)
        XCTAssertEqual(l4d2.name, "Left 4 Dead 2")
        XCTAssertEqual(l4d2.iconURL?.path, "/b/l4d2.exe")
        XCTAssertEqual(WineRunner.launchArguments(for: l4d2).arguments, [exe.path, "steam://rungameid/550"])
    }

    func testSettingsPersistShortcuts() throws {
        var s = BottleSettings(name: "b")
        s.shortcuts = [ProgramShortcut(name: "L4D2", program: "/x/steam.exe", arguments: ["-a"])]
        let back = try BottleManager.decoder.decode(BottleSettings.self, from: BottleManager.encoder.encode(s))
        XCTAssertEqual(back.shortcuts, s.shortcuts)
    }
}


final class SteamAndGuideTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("vinho-steam-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func write(_ text: String, _ url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func bottle(_ name: String, graphics: GraphicsBackend = .dxmt, steam: Bool) throws -> Bottle {
        let b = Bottle(url: root.appendingPathComponent(name), settings: BottleSettings(name: name, graphics: graphics))
        if steam { try write("", Steam.executable(in: b)) }
        return b
    }

    func testGraphicsFamily() {
        XCTAssertEqual(GraphicsFamily(directX: 9), .classic)
        XCTAssertEqual(GraphicsFamily(directX: 11), .classic)
        XCTAssertEqual(GraphicsFamily(directX: 12), .dx12)
        XCTAssertEqual(GraphicsFamily(directX: nil), .classic)
        XCTAssertEqual(GraphicsFamily.dx12.preferredBackend, .d3dMetal)
        XCTAssertEqual(GraphicsFamily.steamBottleName, "Steam")
    }

    func testPlannerUsesASingleSteamAndPrefersGPTK() throws {
        let noSteam = try bottle("Office", steam: false)
        var steam = try bottle("Steam", steam: true)
        steam.settings.installedRecipes = ["left-4-dead-2": 2]
        let other = try bottle("Steam velha", steam: true)
        XCTAssertEqual(LauncherPlanner.steamBottle(in: [noSteam, other, steam])?.name, "Steam", "a que já tem jogos")
        XCTAssertNil(LauncherPlanner.steamBottle(in: [noSteam]))

        let wine = WineRuntime(id: "wine", rootURL: URL(fileURLWithPath: "/w"), capabilities: [.dxmt])
        let gptk = WineRuntime(id: "gptk", rootURL: URL(fileURLWithPath: "/g"), capabilities: [.d3dMetal])
        XCTAssertEqual(LauncherPlanner.preferredSteamBackend(runtimes: [wine]), .dxmt)
        XCTAssertEqual(LauncherPlanner.preferredSteamBackend(runtimes: [wine, gptk]), .d3dMetal)
        XCTAssertTrue(LauncherPlanner.runtime(wine, supports: .classic))
        XCTAssertFalse(LauncherPlanner.runtime(wine, supports: .dx12))
        XCTAssertTrue(LauncherPlanner.runtime(gptk, supports: .dx12))
    }

    func testLibraryFoldersParsingAndGameLookupInSecondaryLibrary() throws {
        let b = try bottle("Steam", steam: true)
        let vdf = #"""
        "libraryfolders"
        {
            "0"
            {
                "path"		"C:\\Program Files (x86)\\Steam"
            }
            "1"
            {
                "path"		"C:\\Jogos\\SteamLibrary"
            }
        }
        """#
        try write(vdf, Steam.directory(in: b).appendingPathComponent("steamapps/libraryfolders.vdf"))
        XCTAssertEqual(Steam.libraryPaths(in: b), [#"C:\Program Files (x86)\Steam"#, #"C:\Jogos\SteamLibrary"#])

        XCTAssertNil(Steam.gameExecutable(#"Left 4 Dead 2\left4dead2.exe"#, in: b))
        let exe = b.driveC.appendingPathComponent("Jogos/SteamLibrary/steamapps/common/Left 4 Dead 2/left4dead2.exe")
        try write("", exe)
        XCTAssertEqual(Steam.gameExecutable(#"Left 4 Dead 2\left4dead2.exe"#, in: b)?.path, exe.path)
    }

    func testSteamGuideTicksItselfOff() throws {
        let b = try bottle("Steam", steam: true)
        let shared = b.driveC.appendingPathComponent("Shared Library")

        var items = GuideBuilder.steam(bottle: b, sharedLibrary: shared)
        XCTAssertEqual(items.first { $0.id == "steam-installed" }?.status, .done)
        XCTAssertEqual(items.first { $0.id == "steam-login" }?.status, .todo)
        XCTAssertEqual(items.first { $0.id == "steam-library" }?.status, .todo)
        XCTAssertEqual(items.first { $0.id == "steam-library" }?.action, .mountSharedLibrary, "S: ainda não montado")
        try Steam.mountSharedLibrary(shared, in: b)
        XCTAssertTrue(Steam.isSharedLibraryMounted(shared, in: b))
        XCTAssertEqual(GuideBuilder.steam(bottle: b, sharedLibrary: shared).first { $0.id == "steam-library" }?.action, .mountSharedLibrary)
        XCTAssertEqual(items.first { $0.id == "steam-fix" }?.status, .todo)
        XCTAssertEqual(GuideBuilder.pendingCount(items), 3)

        try write(#""users" { "1" { "AccountName" "leandro" } }"#,
                  Steam.directory(in: b).appendingPathComponent("config/loginusers.vdf"))
        try write(#""libraryfolders" { "1" { "path" "C:\\Shared Library" } }"#,
                  Steam.directory(in: b).appendingPathComponent("steamapps/libraryfolders.vdf"))

        let cef = Steam.directory(in: b).appendingPathComponent("bin/cef/cef.win7x64")
        try write("REAL", cef.appendingPathComponent("steamwebhelper.exe"))
        try SteamFixes.deployWebHelperWrapper(in: b)

        items = GuideBuilder.steam(bottle: b, sharedLibrary: shared)
        XCTAssertEqual(items.first { $0.id == "steam-login" }?.status, .done)
        XCTAssertEqual(items.first { $0.id == "steam-library" }?.status, .done)
        XCTAssertEqual(GuideBuilder.pendingCount(items), 0)
    }

    func testGameGuideCompletesWhenDownloadFinishes() throws {
        let b = try bottle("Steam", steam: true)
        let recipe = try XCTUnwrap(RecipeLibrary.builtIn().first { $0.id == "left-4-dead-2" }?.recipe)

        var items = GuideBuilder.game(recipe, bottle: b)
        XCTAssertEqual(items.first { $0.id == "game-confirm" }?.action, .openSteam("steam://install/550"))
        XCTAssertEqual(items.first { $0.id == "game-download" }?.status, .todo)
        XCTAssertNil(items.first { $0.id == "game-play" }?.action)
        XCTAssertEqual(GuideBuilder.pendingCount(items), 1)
        XCTAssertEqual(items.filter { $0.id.hasPrefix("recipe-tip") }.count, recipe.guide?.count)

        try write("", Steam.directory(in: b).appendingPathComponent("steamapps/common/Left 4 Dead 2/left4dead2.exe"))
        items = GuideBuilder.game(recipe, bottle: b)
        XCTAssertEqual(items.first { $0.id == "game-download" }?.status, .done)
        XCTAssertEqual(items.first { $0.id == "game-play" }?.action, .launchShortcut("Left 4 Dead 2"))
        XCTAssertEqual(GuideBuilder.pendingCount(items), 0)
    }

    func testSteamShortcutResolvesIconFromAnyLibrary() throws {
        let b = try bottle("Steam", steam: true)
        let shortcut = ProgramShortcut(name: "Left 4 Dead 2", program: Steam.executable(in: b).path,
                                       arguments: [Steam.runURL(appID: 550)],
                                       steamGameExe: #"Left 4 Dead 2\left4dead2.exe"#)
        XCTAssertNil(shortcut.program(in: b).iconURL, "ainda baixando")
        let exe = Steam.directory(in: b).appendingPathComponent("steamapps/common/Left 4 Dead 2/left4dead2.exe")
        try write("", exe)
        XCTAssertEqual(shortcut.program(in: b).iconURL?.path, exe.path)
        XCTAssertEqual(shortcut.program(in: b).arguments, ["steam://rungameid/550"])
    }

    func testGameRecipeValidation() {
        XCTAssertNoThrow(try Recipe.parse("id: g\nname: G\ngame: { store: steam, appid: 10, directx: 11 }"))
        XCTAssertThrowsError(try Recipe.parse("id: g\nname: G\ngame: { store: steam, appid: 0 }"))
        XCTAssertThrowsError(try Recipe.parse("id: g\nname: G\ngame: { store: steam, appid: 10, exe: '..\\x.exe' }"))
        XCTAssertThrowsError(try Recipe.parse("id: g\nname: G\ngame: { store: steam, appid: 10, directx: 8 }"))
        XCTAssertThrowsError(try Recipe.parse("id: g\nname: G\ngame: { store: origin, appid: 10 }"))
    }
}

final class SteamFixesAndProfileTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("vinho-fix-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func write(_ data: Data, _ url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    func testEmbeddedWrapperIsAWindowsExecutable() {
        let data = SteamWebHelperWrapper.data
        XCTAssertEqual(data.prefix(2), Data("MZ".utf8))
        XCTAssertEqual(data.count, 16_384)
    }

    func testWrapperDeployIsIdempotentAndSurvivesSteamUpdates() throws {
        let bottle = Bottle(url: root, settings: BottleSettings(name: "Steam"))
        let x64 = Steam.directory(in: bottle).appendingPathComponent("bin/cef/cef.win7x64")
        let x86 = Steam.directory(in: bottle).appendingPathComponent("bin/cef/cef.win7")
        try write(Data("REAL-1".utf8), x64.appendingPathComponent("steamwebhelper.exe"))
        try write(Data("REAL-32".utf8), x86.appendingPathComponent("steamwebhelper.exe"))
        let wrapper = Data("WRAPPER".utf8)

        XCTAssertFalse(SteamFixes.isWrapperDeployed(in: bottle))
        XCTAssertEqual(try SteamFixes.deployWebHelperWrapper(in: bottle, wrapper: wrapper), 1, "só a pasta 64-bit")
        XCTAssertEqual(try Data(contentsOf: x64.appendingPathComponent("steamwebhelper.exe")), wrapper)
        XCTAssertEqual(try Data(contentsOf: x64.appendingPathComponent(SteamFixes.originalName)), Data("REAL-1".utf8))
        XCTAssertEqual(try Data(contentsOf: x86.appendingPathComponent("steamwebhelper.exe")), Data("REAL-32".utf8))

        XCTAssertEqual(try SteamFixes.deployWebHelperWrapper(in: bottle, wrapper: wrapper), 0, "idempotente")

        // A Steam se atualizou e trouxe um helper novo: ele vira o original.
        try write(Data("REAL-2".utf8), x64.appendingPathComponent("steamwebhelper.exe"))
        XCTAssertEqual(try SteamFixes.deployWebHelperWrapper(in: bottle, wrapper: wrapper), 1)
        XCTAssertEqual(try Data(contentsOf: x64.appendingPathComponent(SteamFixes.originalName)), Data("REAL-2".utf8))
    }

    func testRemoveWrapperRestoresOriginal() throws {
        let bottle = Bottle(url: root, settings: BottleSettings(name: "Steam"))
        let x64 = Steam.directory(in: bottle).appendingPathComponent("bin/cef/cef.win7x64")
        try write(Data("REAL".utf8), x64.appendingPathComponent("steamwebhelper.exe"))
        try SteamFixes.deployWebHelperWrapper(in: bottle)
        XCTAssertTrue(SteamFixes.isWrapperDeployed(in: bottle))
        try SteamFixes.removeWebHelperWrapper(in: bottle)
        XCTAssertEqual(try Data(contentsOf: x64.appendingPathComponent("steamwebhelper.exe")), Data("REAL".utf8))
        XCTAssertFalse(fm.fileExists(atPath: x64.appendingPathComponent(SteamFixes.originalName).path))
    }

    func testClearStaleLocks() throws {
        let bottle = Bottle(url: root, settings: BottleSettings(name: "Steam"))
        let cache = Steam.directory(in: bottle).appendingPathComponent("config/htmlcache")
        for name in ["SingletonLock", "SingletonCookie", "Cookies"] {
            try write(Data(), cache.appendingPathComponent(name))
        }
        XCTAssertEqual(SteamFixes.clearStaleLocks(in: bottle), 2)
        XCTAssertTrue(fm.fileExists(atPath: cache.appendingPathComponent("Cookies").path))
    }

    func testProfileFromRecipeAndRegistryCommands() throws {
        let recipe = try Recipe.parse("""
        id: jogo
        name: Jogo
        game:
          store: steam
          appid: 10
          exe: 'Jogo\\Bin\\jogo.exe'
          launchOptions: "-vulkan"
          profile: { renderer: vulkan, retina: true, dllOverrides: { xinput1_3: native } }
        """)
        let profile = try XCTUnwrap(recipe.game?.makeProfile())
        XCTAssertEqual(profile.exeName, "jogo.exe")
        XCTAssertEqual(profile.launchOptions, "-vulkan")

        let base = #"HKCU\Software\Wine\AppDefaults\jogo.exe"#
        XCTAssertEqual(WineConfigurator.commands(for: profile, previous: nil), [
            ["reg", "add", base + #"\DllOverrides"#, "/v", "xinput1_3", "/t", "REG_SZ", "/d", "n", "/f"],
            ["reg", "add", base + #"\Direct3D"#, "/v", "renderer", "/t", "REG_SZ", "/d", "vulkan", "/f"],
            ["reg", "add", base + #"\Mac Driver"#, "/v", "RetinaMode", "/t", "REG_SZ", "/d", "y", "/f"],
        ])

        var changed = profile
        changed.renderer = nil
        changed.dllOverrides = [:]
        XCTAssertEqual(WineConfigurator.commands(for: changed, previous: profile), [
            ["reg", "delete", base + #"\DllOverrides"#, "/v", "xinput1_3", "/f"],
            ["reg", "delete", base + #"\Direct3D"#, "/v", "renderer", "/f"],
        ])
        XCTAssertTrue(WineConfigurator.commands(for: profile, previous: profile).isEmpty)
    }
}


final class SharedLibraryDriveTests: XCTestCase {
    func testMountIsIdempotentAndGamesAreFoundThroughTheDrive() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("vinho-drive-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let bottle = Bottle(url: root.appendingPathComponent("Steam"), settings: BottleSettings(name: "Steam"))
        let shared = root.appendingPathComponent("Vinho Steam Library")

        try Steam.mountSharedLibrary(shared, in: bottle)
        try Steam.mountSharedLibrary(shared, in: bottle) // idempotente
        XCTAssertTrue(Steam.isSharedLibraryMounted(shared, in: bottle))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: bottle.url.appendingPathComponent("dosdevices/s:").path), shared.path)

        // A Steam registrou S:\SteamLibrary e o jogo foi baixado lá.
        let vdf = Steam.directory(in: bottle).appendingPathComponent("steamapps/libraryfolders.vdf")
        try fm.createDirectory(at: vdf.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #""libraryfolders" { "1" { "path" "S:\\SteamLibrary" } }"#.write(to: vdf, atomically: true, encoding: .utf8)
        XCTAssertTrue(Steam.hasLibrary(onDrive: "s", in: bottle))

        let exe = shared.appendingPathComponent("SteamLibrary/steamapps/common/Left 4 Dead 2/left4dead2.exe")
        try fm.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: exe.path, contents: Data())
        let found = try XCTUnwrap(Steam.gameExecutable(#"Left 4 Dead 2\left4dead2.exe"#, in: bottle))
        XCTAssertEqual(found.resolvingSymlinksInPath().path, exe.resolvingSymlinksInPath().path)
    }

    func testDoesNotReplaceARealDrive() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("vinho-drive2-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let bottle = Bottle(url: root, settings: BottleSettings(name: "b"))
        let real = root.appendingPathComponent("dosdevices/s:")
        try fm.createDirectory(at: real, withIntermediateDirectories: true)
        try Steam.mountSharedLibrary(root.appendingPathComponent("lib"), in: bottle)
        XCTAssertNil(try? fm.destinationOfSymbolicLink(atPath: real.path), "pasta real não é trocada")
    }
}

final class SteamLibraryRegistrarTests: XCTestCase {
    private let typical = """
    "libraryfolders"
    {
    \t"0"
    \t{
    \t\t"path"\t\t"C:\\\\Program Files (x86)\\\\Steam"
    \t\t"label"\t\t""
    \t\t"contentid"\t\t"111"
    \t\t"apps"
    \t\t{
    \t\t\t"228980"\t\t"12345"
    \t\t}
    \t}
    }

    """

    func testAddsNextIndexedBlockBeforeClosingBrace() {
        XCTAssertEqual(SteamLibraryRegistrar.nextIndex(in: typical), 1)
        let out = SteamLibraryRegistrar.addingLibrary(#"S:\SteamLibrary"#, contentID: "999", to: typical)
        XCTAssertEqual(Steam.parseLibraryPaths(out), [#"C:\Program Files (x86)\Steam"#, #"S:\SteamLibrary"#])
        XCTAssertTrue(out.contains("\t\"1\"\n"))
        XCTAssertTrue(out.contains("\"contentid\"\t\t\"999\""))
        XCTAssertTrue(out.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("}"))
        XCTAssertEqual(SteamLibraryRegistrar.nextIndex(in: out), 2)
    }

    func testCreatesFileWhenMissing() {
        let out = SteamLibraryRegistrar.addingLibrary(#"S:\SteamLibrary"#, contentID: "5", to: "")
        XCTAssertEqual(Steam.parseLibraryPaths(out), [#"C:\Program Files (x86)\Steam"#, #"S:\SteamLibrary"#])
        XCTAssertEqual(SteamLibraryRegistrar.nextIndex(in: out), 2)
    }

    func testRegisterEndToEndIsIdempotent() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("vinho-reg-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let bottle = Bottle(url: root.appendingPathComponent("Steam"), settings: BottleSettings(name: "Steam"))
        let shared = root.appendingPathComponent("Vinho Steam Library")
        let list = Steam.directory(in: bottle).appendingPathComponent("steamapps/libraryfolders.vdf")
        try fm.createDirectory(at: list.deletingLastPathComponent(), withIntermediateDirectories: true)
        try typical.write(to: list, atomically: true, encoding: .utf8)

        try Steam.mountSharedLibrary(shared, in: bottle)
        XCTAssertFalse(Steam.hasLibrary(onDrive: "s", in: bottle))
        XCTAssertTrue(try SteamLibraryRegistrar.register(in: bottle, contentID: "42"))
        XCTAssertTrue(Steam.hasLibrary(onDrive: "s", in: bottle))
        XCTAssertFalse(try SteamLibraryRegistrar.register(in: bottle), "não duplica")

        let identity = shared.appendingPathComponent("SteamLibrary/steamapps/libraryfolder.vdf")
        XCTAssertTrue(try String(contentsOf: identity, encoding: .utf8).contains("\"42\""))
        XCTAssertEqual(Steam.libraryPaths(in: bottle).count, 2)
    }
}
