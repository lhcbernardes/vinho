import XCTest
@testable import WineKit

final class RegistryFileTests: XCTestCase {
    static let system = #"""
    WINE REGISTRY Version 2
    ;; All keys relative to \\Machine

    #arch=win64

    [Software\\Classes\\.txt] 1700000000
    #time=1d9
    @="txtfile"
    "Content Type"="text/plain"

    [Software\\Classes\\txtfile\\shell\\open\\command] 1700000000
    @=str(2):"%SystemRoot%\\system32\\NOTEPAD.EXE %1"

    [Software\\Classes\\.docx] 1700000000
    @="Word.Document.12"

    [Software\\Classes\\Word.Document.12] 1700000000
    @="Documento do Microsoft Word"

    [Software\\Classes\\Word.Document.12\\shell] 1700000000
    @="Edit"

    [Software\\Classes\\Word.Document.12\\shell\\Edit\\command] 1700000000
    @="\"C:\\Program Files\\Microsoft Office\\root\\Office16\\WINWORD.EXE\" /n \"%1\" /o \"%u\""

    [Software\\Classes\\.rtf] 1700000000
    @="Word.RTF.8"

    [Software\\Classes\\Word.RTF.8\\shell\\open\\command] 1700000000
    @="%ProgramFiles%\\Microsoft Office\\root\\Office16\\WINWORD.EXE %1"

    [Software\\Classes\\.pdf] 1700000000
    @="wordpad"

    [Software\\Classes\\wordpad\\shell\\open\\command] 1700000000
    @="C:\\windows\\system32\\wordpad.exe \"%1\""

    [Software\\Wine\\Test] 1700000000
    "Count"=dword:00000002
    "Escapes"="a\\b \"c\""
    """#

    func testParsesKeysAndValues() {
        let reg = RegistryFile(text: Self.system)
        XCTAssertEqual(reg.value(#"Software\Classes\.txt"#), "txtfile")
        XCTAssertEqual(reg.value(#"software\classes\.TXT"#, "content type"), "text/plain")
        XCTAssertEqual(reg.value(#"Software\Classes\txtfile\shell\open\command"#), #"%SystemRoot%\system32\NOTEPAD.EXE %1"#)
        XCTAssertEqual(reg.value(#"Software\Wine\Test"#, "Escapes"), #"a\b "c""#)
        XCTAssertNil(reg.value(#"Software\Wine\Test"#, "Count"), "dword é ignorado")
        XCTAssertTrue(reg.subkeys(of: #"Software\Classes"#).contains(".docx"))
    }

    func testFileAssociationsSkipWineProgramsAndGroupByExe() throws {
        let system = RegistryFile(text: Self.system)
        let assocs = MacIntegration.fileAssociations(system: system, user: RegistryFile(text: ""))
        XCTAssertEqual(assocs.map(\.fileExtension), ["docx", "rtf"], "txt (notepad) e pdf (wordpad) são do Wine")
        let docx = try XCTUnwrap(assocs.first)
        XCTAssertEqual(docx.program, #"C:\Program Files\Microsoft Office\root\Office16\WINWORD.EXE"#)
        XCTAssertEqual(docx.arguments, ["/n", "%1", "/o"], "verbo padrão Edit; %u descartado")
        XCTAssertEqual(docx.description, "Documento do Microsoft Word")

        let programs = MacIntegration.programs(from: assocs)
        XCTAssertEqual(programs.count, 1)
        XCTAssertEqual(programs.first?.extensions, ["docx", "rtf"])
        XCTAssertEqual(programs.first?.displayName, "WINWORD")
    }

    func testParseCommandVariants() {
        XCTAssertEqual(MacIntegration.parseCommand(#""C:\A B\app.exe" "%1""#)?.program, #"C:\A B\app.exe"#)
        XCTAssertEqual(MacIntegration.parseCommand(#"C:\A B\app.exe /x"#)?.arguments, ["/x", "%1"], "sem %1: acrescenta")
        XCTAssertEqual(MacIntegration.parseCommand(#"%ProgramFiles(x86)%\X\x.exe "%L""#)?.program, #"C:\Program Files (x86)\X\x.exe"#)
        XCTAssertEqual(MacIntegration.parseCommand(#"%ProgramFiles(x86)%\X\x.exe "%L""#)?.arguments, ["%1"])
        XCTAssertTrue(MacIntegration.isSystemProgram(#"C:\windows\system32\winebrowser.exe"#))
        XCTAssertTrue(MacIntegration.isSystemProgram("rundll32.exe"))
        XCTAssertFalse(MacIntegration.isSystemProgram(#"C:\Program Files\App\app.exe"#))
    }

    func testNativeOpenOperationsAreIdempotent() {
        let system = RegistryFile(text: Self.system)
        let ops = MacIntegration.nativeOpenOperations(system: system, user: RegistryFile(text: ""))
        XCTAssertTrue(ops.contains(.set(key: #"Software\Classes\.pdf"#, name: nil, data: MacIntegration.nativeOpenProgID)),
                      "pdf só tem o wordpad do Wine: abre no Mac")
        XCTAssertFalse(ops.contains { if case .set(let k, _, _) = $0 { return k == #"Software\Classes\.docx"# } else { return false } },
                       "docx tem o Word: não mexe")
        XCTAssertTrue(ops.contains(.set(key: #"Software\Wine\WineBrowser"#, name: "Browsers", data: "/usr/bin/open")))

        // Depois de aplicar, nada mais a fazer.
        let applied = Self.userReg(from: ops)
        XCTAssertEqual(MacIntegration.nativeOpenOperations(system: system, user: applied), [])
    }

    func testNativeOpenStepsAsideWhenAWindowsAppClaimsTheType() {
        let user = RegistryFile(text: "[Software\\\\Classes\\\\.png] 1\n@=\"Vinho.MacOpen\"\n")
        let system = RegistryFile(text: Self.system + """

        [Software\\\\Classes\\\\.png] 1
        @="Photoshop.PNG"

        [Software\\\\Classes\\\\Photoshop.PNG\\\\shell\\\\open\\\\command] 1
        @="\\"C:\\\\Program Files\\\\Adobe\\\\Photoshop.exe\\" \\"%1\\""
        """)
        let ops = MacIntegration.nativeOpenOperations(system: system, user: user)
        XCTAssertTrue(ops.contains(.deleteKey(#"Software\Classes\.png"#)))
    }

    func testRegFileFormat() {
        let text = MacIntegration.regFile([
            .set(key: #"Software\Classes\.pdf"#, name: nil, data: "Vinho.MacOpen"),
            .set(key: #"Software\Classes\Vinho.MacOpen\shell\open\command"#, name: nil, data: #""C:\w.exe" "%1""#),
            .set(key: #"Software\Wine\WineBrowser"#, name: "Browsers", data: "/usr/bin/open"),
            .deleteKey(#"Software\Classes\.png"#),
        ])
        XCTAssertTrue(text.hasPrefix("REGEDIT4\r\n"))
        XCTAssertTrue(text.contains(#"[HKEY_CURRENT_USER\Software\Classes\.pdf]"# + "\r\n@=\"Vinho.MacOpen\""))
        XCTAssertTrue(text.contains(#"@="\"C:\\w.exe\" \"%1\"""#))
        XCTAssertTrue(text.contains(#""Browsers"="/usr/bin/open""#))
        XCTAssertTrue(text.contains(#"[-HKEY_CURRENT_USER\Software\Classes\.png]"#))
    }

    /// Simula o user.reg depois de importar as operações.
    static func userReg(from ops: [MacIntegration.RegistryOperation]) -> RegistryFile {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        var text = ""
        for case .set(let key, let name, let data) in ops {
            text += "[\(esc(key))] 1\n\(name.map { "\"\($0)\"" } ?? "@")=\"\(esc(data))\"\n\n"
        }
        return RegistryFile(text: text)
    }
}

final class MacIntegrationPlanTests: XCTestCase {
    func testPlanCreatesAppForAssociatedProgram() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("vinho-int-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let bottle = Bottle(url: root, settings: BottleSettings(name: "Office"))
        let exe = bottle.driveC.appendingPathComponent("Program Files/Microsoft Office/root/Office16/WINWORD.EXE")
        try fm.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("MZ".utf8).write(to: exe)
        try RegistryFileTests.system.write(to: root.appendingPathComponent("system.reg"), atomically: true, encoding: .utf8)

        let plan = MacIntegration.plan(for: bottle)
        XCTAssertEqual(plan.count, 1)
        XCTAssertEqual(plan.first?.name, "WINWORD")
        XCTAssertEqual(plan.first?.extensions, ["docx", "rtf"])
        XCTAssertEqual(plan.first?.program.lastPathComponent, "WINWORD.EXE")
        XCTAssertEqual(MacIntegration.appsDirectory(for: bottle, base: URL(fileURLWithPath: "/x")).path, "/x/Office")
    }

    func testDocumentScriptConvertsPathsAndKeepsTemplate() {
        let inv = WineInvocation(executable: URL(fileURLWithPath: "/opt/wine/bin/wine"),
                                 arguments: [#"C:\Office\WINWORD.EXE"#],
                                 environment: ["WINEPREFIX": "/b/Office", "HOME": "/Users/x"])
        let script = LauncherBuilder.documentScript(for: inv, template: ["/n", "%1"])
        XCTAssertTrue(script.contains("export WINEPREFIX='/b/Office'"))
        XCTAssertFalse(script.contains("HOME="), "variáveis herdadas não são gravadas")
        XCTAssertTrue(script.contains(#"w="Z:$(printf '%s' "$f" | tr '/' '\\')""#))
        XCTAssertTrue(script.contains(#"'/opt/wine/bin/wine' 'C:\Office\WINWORD.EXE' '/n' ''"$w"'' &"#))
        XCTAssertTrue(script.contains(#"exec '/opt/wine/bin/wine' 'C:\Office\WINWORD.EXE' '/n'"#))
    }

    func testAppletPlistDeclaresDocumentTypes() throws {
        let plist = LauncherBuilder.documentPlistEntries(name: "Word", identifier: "x.y", extensions: ["docx"], typeName: "Documento")
        let types = try XCTUnwrap(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        XCTAssertEqual(types.first?["CFBundleTypeExtensions"] as? [String], ["docx"])
        XCTAssertEqual(types.first?["LSHandlerRank"] as? String, "Alternate")
        XCTAssertTrue(LauncherBuilder.documentAppletSource.contains("on open theFiles"))
    }
}

final class PrefixAndExtrasTests: XCTestCase {
    func testNewSettingsDefaultsAndEnvironment() throws {
        let old = try JSONDecoder().decode(BottleSettings.self, from: Data(#"{"name":"Antigo"}"#.utf8))
        XCTAssertTrue(old.macIntegration)
        XCTAssertEqual(old.integratedApps, [])
        XCTAssertNil(old.preparedRuntime)
        XCTAssertFalse(old.dlssMetalFX)

        let runtime = WineRuntime(id: "gptk", rootURL: URL(fileURLWithPath: "/tmp/gptk"), capabilities: [.d3dMetal])
        var s = BottleSettings(name: "x", graphics: .d3dMetal)
        s.dlssMetalFX = true
        s.advertiseAVX = true
        let env = WineEnvironment.make(bottle: Bottle(url: URL(fileURLWithPath: "/tmp/x"), settings: s), runtime: runtime, base: [:])
        XCTAssertEqual(env["D3DM_ENABLE_METALFX"], "1")
        XCTAssertEqual(env["ROSETTA_ADVERTISE_AVX"], "1")

        s.graphics = .dxmt
        let env2 = WineEnvironment.make(bottle: Bottle(url: URL(fileURLWithPath: "/tmp/x"), settings: s), runtime: runtime, base: [:])
        XCTAssertNil(env2["D3DM_ENABLE_METALFX"], "MetalFX só com D3DMetal")

        let back = try JSONDecoder().decode(BottleSettings.self, from: JSONEncoder().encode(s))
        XCTAssertTrue(back.dlssMetalFX && back.advertiseAVX)
    }

    func testFingerprint() {
        let r = WineRuntime(id: "wine-stable-11.0_1", rootURL: URL(fileURLWithPath: "/x"), capabilities: [])
        XCTAssertEqual(WineRunner.fingerprint(r, version: "wine-11.0"), "wine-stable-11.0_1|wine-11.0")
    }

    func testDLSSBridgeInstall() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("vinho-dlss-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let runtime = WineRuntime(id: "gptk", rootURL: root.appendingPathComponent("rt"), capabilities: [.d3dMetal])
        let win = runtime.libURL.appendingPathComponent("wine/x86_64-windows")
        try fm.createDirectory(at: win, withIntermediateDirectories: true)
        let bottle = Bottle(url: root.appendingPathComponent("b"), settings: BottleSettings(name: "b"))

        XCTAssertFalse(DLSSMetalFX.isSupported(by: runtime))
        XCTAssertEqual(try DLSSMetalFX.install(runtime: runtime, in: bottle).missing, ["nvngx.dll", "nvapi64.dll"])

        try Data("ponte".utf8).write(to: win.appendingPathComponent("nvngx-on-metalfx.dll"))
        try Data("nvapi".utf8).write(to: win.appendingPathComponent("nvapi64.dll"))
        XCTAssertTrue(DLSSMetalFX.isSupported(by: runtime))
        let result = try DLSSMetalFX.install(runtime: runtime, in: bottle)
        XCTAssertEqual(result.installed, ["nvngx.dll", "nvapi64.dll"])
        let nvngx = bottle.driveC.appendingPathComponent("windows/system32/nvngx.dll")
        XCTAssertEqual(try String(contentsOf: nvngx, encoding: .utf8), "ponte")

        DLSSMetalFX.uninstall(from: bottle)
        XCTAssertFalse(fm.fileExists(atPath: nvngx.path))
        XCTAssertTrue(fm.fileExists(atPath: bottle.driveC.appendingPathComponent("windows/system32/nvapi64.dll").path))
    }

    func testCabextractLinkedIntoToolsDirectory() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("vinho-cab-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let fake = root.appendingPathComponent("CrossOver/bin/cabextract")
        try fm.createDirectory(at: fake.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: fake, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let tools = root.appendingPathComponent("Tools/bin")
        XCTAssertNil(WinetricksManager.prepareTools(candidates: [root.appendingPathComponent("nada")], into: tools))
        let link = try XCTUnwrap(WinetricksManager.prepareTools(candidates: [root.appendingPathComponent("nada"), fake], into: tools))
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), fake.path)
        XCTAssertNotNil(WinetricksManager.prepareTools(candidates: [fake], into: tools), "idempotente")
        XCTAssertTrue(WinetricksManager.toolPath.hasPrefix(WinetricksManager.toolsBinDirectory.path))
    }

    func testTemplatesReferenceRealComponents() {
        XCTAssertEqual(Set(BottleTemplate.all.map(\.id)).count, BottleTemplate.all.count)
        for t in BottleTemplate.all {
            XCTAssertEqual(t.windowsComponents.count, t.components.count, t.id)
        }
        XCTAssertEqual(BottleTemplate.all.first { $0.id == "games-dx12" }?.requiredBackend, .d3dMetal)
        XCTAssertNil(BottleTemplate.all.first { $0.id == "apps" }?.requiredBackend)
    }

    func testBattleNetLauncher() throws {
        let recipe = try XCTUnwrap(RecipeLibrary.builtIn().first { $0.id == "battle-net" }?.recipe)
        XCTAssertEqual(recipe.provides, ["battlenet"])
        XCTAssertEqual(recipe.launch?.program, GameLauncher.battlenet.windowsExecutable)
        XCTAssertEqual(GameLauncher.detect(URL(fileURLWithPath: "/x/Battle.net Launcher.exe")), .battlenet)
    }
}
