import XCTest
@testable import WineKit

final class WindowsComponentsTests: XCTestCase {
    func testEveryComponentBuildsAValidRecipe() {
        var ids = Set<String>()
        for component in WindowsComponents.all {
            XCTAssertTrue(ids.insert(component.id).inserted, "id repetido: \(component.id)")
            let recipe = component.recipe
            XCTAssertTrue(recipe.id.hasPrefix("component-"))
            XCTAssertFalse(recipe.id.contains("_"), "ids de receita não aceitam _")
            XCTAssertFalse(recipe.steps.isEmpty)
            XCTAssertEqual(recipe.name, component.name)
        }
        XCTAssertNotNil(WindowsComponents.component("d3dcompiler_47"))
        XCTAssertEqual(WindowsComponents.component("d3dcompiler_47")?.recipe.id, "component-d3dcompiler-47")
    }

    func testWineMonoIsVerifiedAndDoesNotNeedWinetricks() {
        let mono = WindowsComponents.wineMono
        XCTAssertFalse(mono.needsWinetricks)
        XCTAssertTrue(mono.recipe.isVerified)
        XCTAssertTrue(WindowsComponents.component("vcrun2022")!.needsWinetricks)
        XCTAssertTrue(WindowsComponents.component("vcrun2022")!.recipe.needsWinetricks)
    }

    func testMscoreeStaysEnabledOnlyWithDotNet() {
        let runtime = WineRuntime(id: "t", rootURL: URL(fileURLWithPath: "/tmp/fake-wine"), capabilities: [])
        func env(_ components: [String]) -> [String: String] {
            var s = BottleSettings(name: "x")
            s.windowsComponents = components
            return WineEnvironment.make(bottle: Bottle(url: URL(fileURLWithPath: "/tmp/x"), settings: s), runtime: runtime, base: [:])
        }
        XCTAssertTrue(env([])["WINEDLLOVERRIDES"]!.contains("mscoree="))
        XCTAssertFalse(env(["wine-mono"])["WINEDLLOVERRIDES"]!.contains("mscoree="))
        XCTAssertFalse(env(["dotnet48"])["WINEDLLOVERRIDES"]!.contains("mscoree="))
    }

    func testDebugChannelsOverrideLogLevel() {
        let runtime = WineRuntime(id: "t", rootURL: URL(fileURLWithPath: "/tmp/fake-wine"), capabilities: [])
        var s = BottleSettings(name: "x")
        s.debugChannels = " +loaddll,+d3d11 "
        let env = WineEnvironment.make(bottle: Bottle(url: URL(fileURLWithPath: "/tmp/x"), settings: s), runtime: runtime, base: [:])
        XCTAssertEqual(env["WINEDEBUG"], "+loaddll,+d3d11")
        s.debugChannels = "  "
        let quiet = WineEnvironment.make(bottle: Bottle(url: URL(fileURLWithPath: "/tmp/x"), settings: s), runtime: runtime, base: [:])
        XCTAssertEqual(quiet["WINEDEBUG"], s.logLevel.winedebug)
    }

    func testSettingsDecodeWithoutNewFields() throws {
        let json = #"{"name":"Antigo"}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(BottleSettings.self, from: json)
        XCTAssertEqual(s.windowsComponents, [])
        XCTAssertNil(s.debugChannels)
    }
}

final class MissingComponentDetectorTests: XCTestCase {
    let log = [
        #"0124:err:module:import_dll Library MSVCP140.dll (which is needed by L"C:\\Games\\x\\game.exe") not found"#,
        #"0124:err:module:import_dll Library d3dx9_43.dll (which is needed by L"C:\\Games\\x\\game.exe") not found"#,
        #"0124:err:module:LdrInitializeThunk Importing dlls for L"C:\\Games\\x\\game.exe" failed, status c0000135"#,
        "linha qualquer",
    ]

    func testFindsMissingDLLs() {
        XCTAssertEqual(MissingComponentDetector.missingDLLs(in: log), ["msvcp140.dll", "d3dx9_43.dll"])
        XCTAssertEqual(MissingComponentDetector.missingDLLs(in: ["tudo certo"]), [])
    }

    func testSuggestsComponentsSkippingInstalled() {
        XCTAssertEqual(MissingComponentDetector.suggestions(for: log).map(\.id), ["vcrun2022", "d3dx9"])
        XCTAssertEqual(MissingComponentDetector.suggestions(for: log, installed: ["vcrun2022"]).map(\.id), ["d3dx9"])
    }
}

final class CommandLineSplitterTests: XCTestCase {
    func testSplitsRespectingQuotes() {
        XCTAssertEqual(CommandLineSplitter.split(#"-windowed "-config=C:\meu arquivo.cfg" 'a b'  c"#),
                       ["-windowed", #"-config=C:\meu arquivo.cfg"#, "a b", "c"])
        XCTAssertEqual(CommandLineSplitter.split(#"C:\Games\x.exe"#), [#"C:\Games\x.exe"#])
        XCTAssertEqual(CommandLineSplitter.split(#"a "" b"#), ["a", "", "b"])
        XCTAssertEqual(CommandLineSplitter.split("   "), [])
    }
}

final class WinetricksManagerTests: XCTestCase {
    func testInstallVerifiesChecksum() async throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("vinho-wt-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: work) }
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let fake = work.appendingPathComponent("fake")
        try "#!/bin/sh\necho falso\n".write(to: fake, atomically: true, encoding: .utf8)
        let target = work.appendingPathComponent("Tools/winetricks")

        do {
            try await WinetricksManager.install(downloader: LocalFileDownloader(source: fake), into: target)
            XCTFail("deveria rejeitar um arquivo com hash diferente")
        } catch WineError.checksumMismatch {
            // esperado
        }
        XCTAssertFalse(fm.fileExists(atPath: target.path))
        XCTAssertFalse(fm.fileExists(atPath: target.appendingPathExtension("part").path), "não deixa lixo")
    }

    func testToolPathIncludesHomebrew() {
        XCTAssertTrue(WinetricksManager.toolPath.contains("/opt/homebrew/bin"))
        XCTAssertTrue(WinetricksManager.toolPath.contains("/usr/local/bin"))
    }
}

final class DuplicateBottleTests: XCTestCase {
    func testDuplicateCopiesPrefixAndRewritesPaths() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("vinho-dup-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let manager = BottleManager(rootURL: root)
        var original = try await manager.create(BottleSettings(name: "Jogos"))
        let exe = original.driveC.appendingPathComponent("Games/x.exe")
        try fm.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("MZ".utf8).write(to: exe)
        original.settings.shortcuts = [ProgramShortcut(name: "X", program: exe.path, icon: exe.path)]
        original.settings.pinnedPrograms = [exe.path]
        try await manager.save(original)

        let copy = try await manager.duplicate(original)
        XCTAssertEqual(copy.name, "Jogos (cópia)")
        XCTAssertNotEqual(copy.url, original.url)
        let copiedExe = copy.driveC.appendingPathComponent("Games/x.exe")
        XCTAssertTrue(fm.fileExists(atPath: copiedExe.path))
        XCTAssertEqual(copy.settings.shortcuts.first?.program, copiedExe.path)
        XCTAssertEqual(copy.settings.shortcuts.first?.icon, copiedExe.path)
        XCTAssertEqual(copy.settings.pinnedPrograms, [copiedExe.path])

        let second = try await manager.duplicate(original)
        XCTAssertEqual(second.name, "Jogos (cópia) 2")
        let names = try await manager.list().map(\.name)
        XCTAssertEqual(Set(names), ["Jogos", "Jogos (cópia)", "Jogos (cópia) 2"])
    }
}

final class AppUpdaterTests: XCTestCase {
    func testVersionParsingAndOrdering() {
        XCTAssertEqual(AppVersion("v0.5.0")?.description, "0.5.0")
        XCTAssertEqual(AppVersion("0.5.0-3-gabc123")?.description, "0.5.0")
        XCTAssertEqual(AppVersion("1.2")?.description, "1.2.0")
        XCTAssertNil(AppVersion("cee2c0f"))
        XCTAssertNil(AppVersion("dev"))
        XCTAssertLessThan(AppVersion("0.9.9")!, AppVersion("0.10.0")!)
        XCTAssertLessThan(AppVersion("v1.0.0")!, AppVersion("1.0.1")!)
    }

    func testParsesGitHubRelease() throws {
        let json = """
        {"tag_name":"v0.6.0","body":"Novidades","html_url":"https://github.com/lhcbernardes/vinho/releases/tag/v0.6.0",
         "assets":[{"name":"checksums.txt","browser_download_url":"https://example.com/c.txt"},
                   {"name":"Vinho-v0.6.0.zip","browser_download_url":"https://example.com/Vinho-v0.6.0.zip"}]}
        """
        let release = try XCTUnwrap(AppUpdater.parse(Data(json.utf8)))
        XCTAssertEqual(release.version, AppVersion("0.6.0"))
        XCTAssertEqual(release.zipURL.lastPathComponent, "Vinho-v0.6.0.zip")
        XCTAssertEqual(release.notes, "Novidades")

        let noZip = #"{"tag_name":"v0.6.0","html_url":"https://x.y","assets":[]}"#
        XCTAssertNil(try AppUpdater.parse(Data(noZip.utf8)))
    }
}

final class CatalogMergeTests: XCTestCase {
    func testMergeReplacesByIDAndAppends() {
        let art = DownloadableArtifact(url: URL(string: "https://example.com/a.tar.xz")!, sha256: "AB", size: 1)
        let cx = RuntimeDescriptor(id: "wine-cx-25.0", name: "Wine CX", version: "25.0", channel: .crossover, artifact: art)
        let replaced = RuntimeDescriptor(id: "wine-stable-11.0_1", name: "Substituído", version: "11.0", channel: .stable, artifact: art)
        let merged = Catalog.builtIn.merging(Catalog(runtimes: [cx, replaced], components: []))
        XCTAssertEqual(merged.runtimes.count, Catalog.builtIn.runtimes.count + 1)
        XCTAssertEqual(merged.runtimes.first { $0.id == "wine-stable-11.0_1" }?.name, "Substituído")
        XCTAssertEqual(merged.runtimes.last?.channel, .crossover)
        XCTAssertEqual(merged.components, Catalog.builtIn.components)
        XCTAssertEqual(art.sha256, "ab")
    }

    func testCrossoverChannelDecodes() throws {
        let json = """
        {"schemaVersion":1,"components":[],"runtimes":[{"id":"wine-cx-25.0","name":"Wine CX","version":"25.0","channel":"crossover",
          "artifact":{"url":"https://example.com/w.tar.xz","sha256":"00","size":10}}]}
        """
        let catalog = try JSONDecoder().decode(Catalog.self, from: Data(json.utf8))
        XCTAssertEqual(catalog.runtimes.first?.channel, .crossover)
    }
}

final class SteamLibraryScannerTests: XCTestCase {
    private var root: URL!
    private var bottle: Bottle!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vinho-scan-\(UUID().uuidString)")
        bottle = Bottle(url: root.appendingPathComponent("Steam"), settings: BottleSettings(name: "Steam"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func manifest(_ appid: Int, _ name: String, _ dir: String, flags: Int = 4) -> String {
        """
        "AppState"
        {
        \t"appid"\t\t"\(appid)"
        \t"name"\t\t"\(name)"
        \t"StateFlags"\t\t"\(flags)"
        \t"installdir"\t\t"\(dir)"
        }
        """
    }

    func testFindsGamesInSteamAndSharedLibrary() throws {
        let fm = FileManager.default
        let steamapps = Steam.directory(in: bottle).appendingPathComponent("steamapps")
        try fm.createDirectory(at: steamapps, withIntermediateDirectories: true)
        try manifest(620, "Portal 2", "Portal 2").write(to: steamapps.appendingPathComponent("appmanifest_620.acf"), atomically: true, encoding: .utf8)
        try manifest(228980, "Steamworks Common Redistributables", "Steamworks Shared")
            .write(to: steamapps.appendingPathComponent("appmanifest_228980.acf"), atomically: true, encoding: .utf8)

        // Biblioteca compartilhada no drive S:.
        let shared = root.appendingPathComponent("Shared")
        try Steam.mountSharedLibrary(shared, in: bottle)
        let sharedApps = shared.appendingPathComponent("SteamLibrary/steamapps")
        try fm.createDirectory(at: sharedApps, withIntermediateDirectories: true)
        try manifest(550, "Left 4 Dead 2", "Left 4 Dead 2").write(to: sharedApps.appendingPathComponent("appmanifest_550.acf"), atomically: true, encoding: .utf8)
        try manifest(730, "Counter-Strike 2", "Counter-Strike Global Offensive", flags: 1026)
            .write(to: sharedApps.appendingPathComponent("appmanifest_730.acf"), atomically: true, encoding: .utf8)
        let vdf = """
        "libraryfolders"
        {
        \t"0" { "path" "C:\\\\Program Files (x86)\\\\Steam" }
        \t"1" { "path" "S:\\\\SteamLibrary" }
        }
        """
        try vdf.write(to: steamapps.appendingPathComponent("libraryfolders.vdf"), atomically: true, encoding: .utf8)

        let games = SteamLibraryScanner.installedGames(in: bottle)
        XCTAssertEqual(games.map(\.appid), [730, 550, 620], "ordenado por nome, sem redistribuíveis")
        XCTAssertEqual(games.first { $0.appid == 730 }?.isFullyInstalled, false, "ainda baixando")
        XCTAssertEqual(games.first { $0.appid == 550 }?.isFullyInstalled, true)
        XCTAssertEqual(games.first { $0.appid == 550 }?.installDirectory.lastPathComponent, "Left 4 Dead 2")
    }

    func testGuessExecutablePrefersLargestNonNoiseExe() throws {
        let fm = FileManager.default
        let dir = root.appendingPathComponent("common/Jogo")
        try fm.createDirectory(at: dir.appendingPathComponent("bin/win64"), withIntermediateDirectories: true)
        try Data(count: 10).write(to: dir.appendingPathComponent("launcher.exe"))
        try Data(count: 500).write(to: dir.appendingPathComponent("bin/win64/jogo.exe"))
        try Data(count: 900).write(to: dir.appendingPathComponent("unins000.exe"))
        try Data(count: 800).write(to: dir.appendingPathComponent("CrashReportClient.exe"))
        XCTAssertEqual(SteamLibraryScanner.guessExecutable(in: dir)?.lastPathComponent, "jogo.exe")
        XCTAssertNil(SteamLibraryScanner.guessExecutable(in: root.appendingPathComponent("vazio")))
    }
}

final class GameLauncherTests: XCTestCase {
    func testDetectsLaunchersByExecutable() {
        XCTAssertEqual(GameLauncher.detect(URL(fileURLWithPath: "/x/Steam/steam.exe")), .steam)
        XCTAssertEqual(GameLauncher.detect(URL(fileURLWithPath: "/x/EpicGamesLauncher.exe")), .epic)
        XCTAssertEqual(GameLauncher.detect(URL(fileURLWithPath: "/x/GalaxyClient.exe")), .gog)
        XCTAssertNil(GameLauncher.detect(URL(fileURLWithPath: "/x/notepad.exe")))
        XCTAssertEqual(GameLauncher.steam.launchArguments, SteamFixes.launchArguments)
        XCTAssertTrue(GameLauncher.epic.launchArguments.contains("-opengl"))
    }

    func testLauncherRecipesProvideAndMatchExecutables() throws {
        let all = RecipeLibrary.builtIn().map(\.recipe)
        for launcher in [GameLauncher.epic, .gog] {
            let recipe = try XCTUnwrap(all.first { $0.provides.contains(launcher.providesKey) }, launcher.rawValue)
            XCTAssertEqual(recipe.launch?.program, launcher.windowsExecutable)
            XCTAssertEqual(recipe.launch?.args, launcher.launchArguments)
        }
        let bottle = Bottle(url: URL(fileURLWithPath: "/tmp/vinho-none"), settings: BottleSettings(name: "x"))
        XCTAssertFalse(GameLauncher.epic.isInstalled(in: bottle))
        XCTAssertEqual(GameLauncher.gog.executable(in: bottle)?.lastPathComponent, "GalaxyClient.exe")
    }

    func testNewGameRecipes() throws {
        let all = RecipeLibrary.builtIn().map(\.recipe)
        let expected: [(String, Int, GraphicsFamily, String)] = [
            ("portal-2", 620, .classic, "portal2.exe"),
            ("half-life-2", 220, .classic, "hl2.exe"),
            ("team-fortress-2", 440, .classic, "tf_win64.exe"),
            ("counter-strike-2", 730, .classic, "cs2.exe"),
            ("ghost-of-tsushima", 2215430, .dx12, "GhostOfTsushima.exe"),
        ]
        for (id, appid, family, exe) in expected {
            let game = try XCTUnwrap(all.first { $0.id == id }?.game, id)
            XCTAssertEqual(game.appid, appid, id)
            XCTAssertEqual(game.family, family, id)
            XCTAssertEqual(game.exeName, exe, id)
            XCTAssertNotNil(game.makeProfile(), id)
        }
        XCTAssertEqual(all.first { $0.id == "ghost-of-tsushima" }?.game?.exe, #"Ghost of Tsushima DIRECTOR'S CUT\GhostOfTsushima.exe"#)
        XCTAssertEqual(all.first { $0.id == "counter-strike-2" }?.game?.launchOptions, "-novid -fullscreen")
    }
}
