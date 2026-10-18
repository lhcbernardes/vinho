import XCTest
@testable import WineKit

final class GraphicsAndEnvironmentTests: XCTestCase {
    private let runtime = WineRuntime(id: "test", rootURL: URL(fileURLWithPath: "/opt/wine"), capabilities: [.dxmt])
    private func bottle(_ configure: (inout BottleSettings) -> Void = { _ in }) -> Bottle {
        var s = BottleSettings(name: "Teste")
        configure(&s)
        return Bottle(url: URL(fileURLWithPath: "/tmp/bottles/Teste"), settings: s)
    }

    func testDLLOverrideFormatIsSortedAndStable() {
        let s = DLLOverrides.format(["dxgi": .nativeThenBuiltin, "d3d11": .native, "mscoree": .disabled])
        XCTAssertEqual(s, "d3d11=n;dxgi=n,b;mscoree=")
    }

    func testEnvironmentCoreVariables() {
        let env = WineEnvironment.make(bottle: bottle(), runtime: runtime, base: ["HOME": "/Users/x", "PATH": "/usr/bin", "SECRET": "1"])
        XCTAssertEqual(env["WINEPREFIX"], "/tmp/bottles/Teste")
        XCTAssertEqual(env["HOME"], "/Users/x")
        XCTAssertNil(env["SECRET"], "variáveis não listadas não devem vazar para o Wine")
        XCTAssertEqual(env["PATH"], "/opt/wine/bin:/usr/bin")
        XCTAssertEqual(env["WINEMSYNC"], "1")
        XCTAssertEqual(env["WINEDEBUG"], "-all")
        XCTAssertTrue(env["WINEDLLOVERRIDES"]!.contains("d3d11=n,b"))
        XCTAssertTrue(env["WINEDLLOVERRIDES"]!.contains("mscoree="))
    }

    func testUserOverridesWinOverBackend() {
        let b = bottle { $0.dllOverrides = ["d3d11": .builtin]; $0.environment = ["WINEDEBUG": "+all"] }
        let env = WineEnvironment.make(bottle: b, runtime: runtime, base: [:])
        XCTAssertTrue(env["WINEDLLOVERRIDES"]!.contains("d3d11=b"))
        XCTAssertEqual(env["WINEDEBUG"], "+all")
    }

    func testMetalHUDAndSync() {
        let b = bottle { $0.metalHUD = true; $0.sync = .esync; $0.graphics = .dxvk }
        let env = WineEnvironment.make(bottle: b, runtime: runtime, base: [:])
        XCTAssertEqual(env["MTL_HUD_ENABLED"], "1")
        XCTAssertEqual(env["DXVK_HUD"], "fps,devinfo")
        XCTAssertEqual(env["WINEESYNC"], "1")
        XCTAssertNil(env["WINEMSYNC"])
    }

    func testRuntimeBackendSupport() {
        XCTAssertTrue(runtime.supports(.dxmt))
        XCTAssertTrue(runtime.supports(.wined3d))
        XCTAssertFalse(runtime.supports(.d3dMetal))
    }
}

final class SettingsCodingTests: XCTestCase {
    func testDecodesMinimalJSONWithDefaults() throws {
        let json = #"{"name":"Antigo"}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(BottleSettings.self, from: json)
        XCTAssertEqual(s.name, "Antigo")
        XCTAssertEqual(s.windowsVersion, .win10)
        XCTAssertEqual(s.graphics, .dxmt)
        XCTAssertTrue(s.environment.isEmpty)
    }

    func testUnknownEnumValueFallsBackToDefault() throws {
        let json = #"{"name":"X","graphics":"backendDoFuturo"}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(BottleSettings.self, from: json)
        XCTAssertEqual(s.graphics, .dxmt)
    }

    func testRoundTrip() throws {
        var s = BottleSettings(name: "Jogos", windowsVersion: .win11, graphics: .d3dMetal)
        s.dllOverrides = ["xinput1_3": .native]
        let data = try BottleManager.encoder.encode(s)
        let back = try BottleManager.decoder.decode(BottleSettings.self, from: data)
        XCTAssertEqual(back.name, "Jogos")
        XCTAssertEqual(back.windowsVersion, .win11)
        XCTAssertEqual(back.dllOverrides["xinput1_3"], .native)
    }
}

final class BottleManagerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vinho-tests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCreateListRenameDelete() async throws {
        let manager = BottleManager(rootURL: root)
        let a = try await manager.create(BottleSettings(name: "  Steam  "))
        XCTAssertEqual(a.name, "Steam")
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.metadataURL.path))

        _ = try await manager.create(BottleSettings(name: "Office"))
        var all = try await manager.list()
        XCTAssertEqual(all.map(\.name), ["Office", "Steam"])

        let renamed = try await manager.rename(a, to: "Steam Jogos")
        XCTAssertEqual(renamed.url, a.url, "renomear não move a pasta")
        all = try await manager.list()
        XCTAssertEqual(all.map(\.name), ["Office", "Steam Jogos"])

        try await manager.delete(renamed, moveToTrash: false)
        all = try await manager.list()
        XCTAssertEqual(all.map(\.name), ["Office"])
    }

    func testDuplicateNamesRejected() async throws {
        let manager = BottleManager(rootURL: root)
        _ = try await manager.create(BottleSettings(name: "Steam"))
        do {
            _ = try await manager.create(BottleSettings(name: "steam"))
            XCTFail("deveria rejeitar nome duplicado")
        } catch let error as WineError {
            XCTAssertEqual(error, .bottleAlreadyExists(name: "steam"))
        }
    }

    func testFolderNamesAreUniqueAndSlugged() async throws {
        let manager = BottleManager(rootURL: root)
        let a = try await manager.create(BottleSettings(name: "Jogo: Edição!"))
        XCTAssertEqual(a.url.lastPathComponent, "Jogo-Edicao")
        // pasta existente sem vinho.json não deve colidir
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Outro"), withIntermediateDirectories: true)
        let b = try await manager.create(BottleSettings(name: "Outro"))
        XCTAssertEqual(b.url.lastPathComponent, "Outro-2")
    }

    func testSlug() {
        XCTAssertEqual(BottleManager.slug("Meu Jogo: Edição GOTY!"), "Meu-Jogo-Edicao-GOTY")
        XCTAssertEqual(BottleManager.slug("???"), "bottle")
    }
}

final class ConfiguratorTests: XCTestCase {
    func testFreshBottleGetsAllCommands() {
        let cmds = WineConfigurator.commands(for: BottleSettings(name: "x", windowsVersion: .win11), previous: nil)
        XCTAssertEqual(cmds.first, ["winecfg", "-v", "win11"])
        XCTAssertEqual(cmds.count, 2)
    }

    func testOnlyChangedSettingsProduceCommands() {
        let old = BottleSettings(name: "x")
        var new = old
        new.retinaMode = true
        let cmds = WineConfigurator.commands(for: new, previous: old)
        XCTAssertEqual(cmds, [["reg", "add", #"HKCU\Software\Wine\Mac Driver"#, "/v", "RetinaMode", "/t", "REG_SZ", "/d", "y", "/f"]])
        XCTAssertTrue(WineConfigurator.commands(for: old, previous: old).isEmpty)
    }
}

final class RunnerTests: XCTestCase {
    struct FakeLauncher: ProcessLaunching {
        let events: [ProcessEvent]
        func run(_ invocation: WineInvocation) -> AsyncThrowingStream<ProcessEvent, Error> {
            AsyncThrowingStream { c in
                events.forEach { c.yield($0) }
                c.finish()
            }
        }
    }

    private let bottle = Bottle(url: URL(fileURLWithPath: "/tmp/b"), settings: BottleSettings(name: "b"))
    private let runtime = WineRuntime(id: "t", rootURL: URL(fileURLWithPath: "/opt/wine"), capabilities: [])

    func testRunToCompletionCollectsOutput() async throws {
        let runner = WineRunner(runtime: runtime, launcher: FakeLauncher(events: [.stdout("ok"), .stderr("warn"), .exited(0)]), baseEnvironment: [:])
        let r = try await runner.runToCompletion(["wineboot"], in: bottle)
        XCTAssertEqual(r.stdout, ["ok"])
        XCTAssertEqual(r.stderr, ["warn"])
        XCTAssertNoThrow(try r.check())
    }

    func testNonZeroExitThrows() async throws {
        let runner = WineRunner(runtime: runtime, launcher: FakeLauncher(events: [.stderr("boom"), .exited(3)]), baseEnvironment: [:])
        let r = try await runner.runToCompletion(["x"], in: bottle)
        XCTAssertThrowsError(try r.check())
    }

    func testLaunchArguments() {
        let exe = URL(fileURLWithPath: "/b/drive_c/Games/Jogo/jogo.exe")
        let (args, cwd) = WineRunner.launchArguments(for: exe)
        XCTAssertEqual(args, ["/b/drive_c/Games/Jogo/jogo.exe"])
        XCTAssertEqual(cwd?.path, "/b/drive_c/Games/Jogo")

        let lnk = URL(fileURLWithPath: "/b/x.lnk")
        XCTAssertEqual(WineRunner.launchArguments(for: lnk).arguments, ["start", "/unix", "/b/x.lnk"])
    }
}

final class PathAndScannerTests: XCTestCase {
    func testWindowsPath() {
        let b = Bottle(url: URL(fileURLWithPath: "/tmp/b"), settings: BottleSettings(name: "b"))
        XCTAssertEqual(WindowsPath.from(URL(fileURLWithPath: "/tmp/b/drive_c/Games/a.exe"), in: b), #"C:\Games\a.exe"#)
        XCTAssertEqual(WindowsPath.from(URL(fileURLWithPath: "/Users/x/a.exe"), in: b), #"Z:\Users\x\a.exe"#)
    }

    func testScannerFindsProgramsAndSkipsNoise() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vinho-scan-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let b = Bottle(url: root, settings: BottleSettings(name: "b"))
        let game = b.driveC.appendingPathComponent("Program Files/Jogo", isDirectory: true)
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        for f in ["Jogo.exe", "unins000.exe", "UnityCrashHandler64.exe"] {
            FileManager.default.createFile(atPath: game.appendingPathComponent(f).path, contents: Data())
        }
        let menu = b.driveC.appendingPathComponent("ProgramData/Microsoft/Windows/Start Menu/Programs", isDirectory: true)
        try FileManager.default.createDirectory(at: menu, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: menu.appendingPathComponent("Jogo.lnk").path, contents: Data())

        let found = ProgramScanner.scan(b)
        XCTAssertEqual(Set(found.map(\.url.lastPathComponent)), ["Jogo.exe", "Jogo.lnk"])
    }
}

final class RuntimeLocatorTests: XCTestCase {
    func testDiscoversDirectoryAndAppLayouts() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("vinho-rt-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }

        func makeWine(at dir: URL) throws {
            let bin = dir.appendingPathComponent("bin")
            try fm.createDirectory(at: bin, withIntermediateDirectories: true)
            let wine = bin.appendingPathComponent("wine")
            fm.createFile(atPath: wine.path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        }

        let plain = root.appendingPathComponent("wine-10")
        try makeWine(at: plain)
        try fm.createDirectory(at: plain.appendingPathComponent("lib/dxmt"), withIntermediateDirectories: true)
        try "10.0".write(to: plain.appendingPathComponent("VERSION"), atomically: true, encoding: .utf8)

        let app = root.appendingPathComponent("Wine Crossover.app")
        try makeWine(at: app.appendingPathComponent("Contents/Resources/wine"))

        try fm.createDirectory(at: root.appendingPathComponent("lixo"), withIntermediateDirectories: true)

        let runtimes = RuntimeLocator(searchDirectories: [root]).discover()
        XCTAssertEqual(runtimes.map(\.id), ["Wine Crossover", "wine-10"])
        let wine10 = try XCTUnwrap(runtimes.first { $0.id == "wine-10" })
        XCTAssertEqual(wine10.version, "10.0")
        XCTAssertEqual(wine10.capabilities, [.dxmt])
    }
}
