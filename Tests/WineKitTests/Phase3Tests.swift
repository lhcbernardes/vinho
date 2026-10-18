import XCTest
@testable import WineKit

// MARK: - Construtor de bytes para PE/LNK sintéticos

private struct Bytes {
    var data: [UInt8]
    init(size: Int) { data = Array(repeating: 0, count: size) }

    mutating func u16(_ o: Int, _ v: UInt16) { data[o] = UInt8(v & 0xFF); data[o + 1] = UInt8(v >> 8) }
    mutating func u32(_ o: Int, _ v: UInt32) { for i in 0..<4 { data[o + i] = UInt8((v >> (8 * UInt32(i))) & 0xFF) } }
    mutating func raw(_ o: Int, _ bytes: [UInt8]) { for (i, b) in bytes.enumerated() { data[o + i] = b } }
    mutating func ascii(_ o: Int, _ s: String) { raw(o, Array(s.utf8) + [0]) }
}

/// PE32+ mínimo com uma seção .rsrc contendo 1 RT_ICON e 1 RT_GROUP_ICON.
private func makeSyntheticPE(icon: [UInt8]) -> Data {
    var b = Bytes(size: 0x200 + 0x100)
    b.u16(0, 0x5A4D)                 // "MZ"
    b.u32(0x3C, 0x40)                // e_lfanew
    b.u32(0x40, 0x0000_4550)         // "PE\0\0"
    let coff = 0x44
    b.u16(coff, 0x8664)              // Machine x64
    b.u16(coff + 2, 1)               // 1 seção
    b.u16(coff + 16, 240)            // SizeOfOptionalHeader (PE32+)
    let opt = coff + 20              // 0x58
    b.u16(opt, 0x20B)                // PE32+
    b.u32(opt + 108, 16)             // NumberOfRvaAndSizes
    b.u32(opt + 112 + 16, 0x1000)    // Resource RVA (dir 2)
    b.u32(opt + 112 + 20, 0xBC)      // Resource size
    let sec = opt + 240              // 0x148
    b.ascii(sec, ".rsrc")
    b.u32(sec + 8, 0xBC)             // VirtualSize
    b.u32(sec + 12, 0x1000)          // VirtualAddress
    b.u32(sec + 16, 0x100)           // SizeOfRawData
    b.u32(sec + 20, 0x200)           // PointerToRawData

    let r = 0x200
    func dir(_ at: Int, ids: [(UInt32, UInt32)]) {
        b.u16(r + at + 14, UInt16(ids.count))
        for (i, e) in ids.enumerated() {
            b.u32(r + at + 16 + i * 8, e.0)
            b.u32(r + at + 16 + i * 8 + 4, e.1)
        }
    }
    let sub: UInt32 = 0x8000_0000
    dir(0x00, ids: [(3, sub | 0x20), (14, sub | 0x38)])   // raiz: RT_ICON, RT_GROUP_ICON
    dir(0x20, ids: [(1, sub | 0x50)])                     // RT_ICON → id 1
    dir(0x38, ids: [(1, sub | 0x68)])                     // RT_GROUP_ICON → id 1
    dir(0x50, ids: [(0x409, 0x80)])                       // idioma → data entry
    dir(0x68, ids: [(0x409, 0x90)])
    b.u32(r + 0x80, 0x1000 + 0xA0); b.u32(r + 0x84, UInt32(icon.count))
    b.u32(r + 0x90, 0x1000 + 0xA8); b.u32(r + 0x94, 20)
    b.raw(r + 0xA0, icon)
    // GRPICONDIR: reserved, type=1, count=1 + GRPICONDIRENTRY (14 bytes)
    b.u16(r + 0xA8 + 2, 1); b.u16(r + 0xA8 + 4, 1)
    b.raw(r + 0xA8 + 6, [16, 16, 0, 0]); b.u16(r + 0xA8 + 10, 1); b.u16(r + 0xA8 + 12, 32)
    b.u32(r + 0xA8 + 14, UInt32(icon.count)); b.u16(r + 0xA8 + 18, 1)
    return Data(b.data)
}

final class PEIconTests: XCTestCase {
    func testExtractsGroupIconAsICO() throws {
        let payload = Array("ICONDATA".utf8)
        let ico = try XCTUnwrap(PEIconExtractor.icoData(fromPE: makeSyntheticPE(icon: payload)))
        let expected: [UInt8] = [0, 0, 1, 0, 1, 0,                 // ICONDIR
                                 16, 16, 0, 0, 1, 0, 32, 0,        // entry: 16x16, 1 plano, 32 bpp
                                 8, 0, 0, 0, 22, 0, 0, 0]          // 8 bytes no offset 22
            + payload
        XCTAssertEqual([UInt8](ico), expected)
    }

    func testRejectsNonPE() {
        XCTAssertNil(PEIconExtractor.icoData(fromPE: Data("not an exe".utf8)))
        XCTAssertNil(PEIconExtractor.icoData(fromPE: Data()))
        var truncated = [UInt8](makeSyntheticPE(icon: [1, 2, 3]))
        truncated.removeLast(0x80)
        XCTAssertNil(PEIconExtractor.icoData(fromPE: Data(truncated)), "não pode crashar com arquivo truncado")
    }
}

final class LnkTests: XCTestCase {
    private func makeLnk(target: String, arguments: String) -> Data {
        var b = Bytes(size: 0x200)
        b.u32(0, 0x4C)
        b.u32(0x14, 0x02 | 0x20 | 0x80)   // HasLinkInfo | HasArguments | IsUnicode
        let li = 0x4C
        let volume = 0x1C, volumeSize = 0x11
        let base = volume + volumeSize
        let suffix = base + target.utf8.count + 1
        let size = suffix + 1
        b.u32(li, UInt32(size)); b.u32(li + 4, 0x1C); b.u32(li + 8, 1)
        b.u32(li + 0x0C, UInt32(volume)); b.u32(li + 0x10, UInt32(base)); b.u32(li + 0x18, UInt32(suffix))
        b.u32(li + volume, UInt32(volumeSize)); b.u32(li + volume + 0x0C, 0x10)
        b.ascii(li + base, target)
        var o = li + size
        let units = Array(arguments.utf16)
        b.u16(o, UInt16(units.count)); o += 2
        for u in units { b.u16(o, u); o += 2 }
        return Data(b.data.prefix(o))
    }

    func testParsesTargetAndArguments() throws {
        let lnk = try XCTUnwrap(LnkFile.parse(makeLnk(target: #"C:\Games\Jogo\jogo.exe"#, arguments: "-windowed é")))
        XCTAssertEqual(lnk.targetPath, #"C:\Games\Jogo\jogo.exe"#)
        XCTAssertEqual(lnk.arguments, "-windowed é")
        XCTAssertNil(lnk.iconLocation)
    }

    func testRejectsGarbage() {
        XCTAssertNil(LnkFile.parse(Data([1, 2, 3])))
    }

    func testWindowsPathToUnixIsCaseInsensitive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vinho-lnk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bottle = Bottle(url: root, settings: BottleSettings(name: "b"))
        let dir = bottle.driveC.appendingPathComponent("Program Files/Jogo")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("Jogo.exe").path, contents: Data())

        let url = try XCTUnwrap(WindowsPath.toUnix(#"c:\PROGRAM FILES\jogo\JOGO.EXE"#, in: bottle))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(WindowsPath.toUnix("relativo\\x.exe", in: bottle))
    }
}

final class LauncherTests: XCTestCase {
    func testScriptQuotesAndRuns() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vinho-launch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // "wine" falso: /bin/sh imprimindo uma variável exportada e um argumento com aspas.
        let inv = WineInvocation(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", #"printf '%s|%s' "$VINHO_T" "$1""#, "sh", "it's a b"],
            environment: ["VINHO_T": "x y", "HOME": "/nao/deve/aparecer", "BAD-KEY": "1"],
            currentDirectory: dir
        )
        let app = try LauncherBuilder.makeApp(named: "Meu: Jogo", invocation: inv, in: dir)
        XCTAssertEqual(app.lastPathComponent, "Meu- Jogo.app")

        let launcher = app.appendingPathComponent("Contents/MacOS/launcher")
        let script = try String(contentsOf: launcher, encoding: .utf8)
        XCTAssertFalse(script.contains("HOME="), "variáveis herdadas não são gravadas")
        XCTAssertFalse(script.contains("BAD-KEY"), "nomes inválidos são ignorados")

        let result = try await FoundationProcessLauncher().collect(WineInvocation(executable: launcher, arguments: [], environment: [:]))
        XCTAssertEqual(result.exitCode, 0, result.stderr.joined())
        XCTAssertEqual(result.stdout.joined(), "x y|it's a b")

        let plist = try XCTUnwrap(NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")))
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "launcher")
    }
}

final class SnapshotAndArchiveTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("vinho-snap-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func write(_ text: String, _ url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func testSnapshotRestoreRoundTrip() async throws {
        let manager = BottleManager(rootURL: root)
        let bottle = try await manager.create(BottleSettings(name: "Jogos"))
        let file = bottle.driveC.appendingPathComponent("a.txt")
        try write("1", file)

        let snapshots = SnapshotManager()
        let snap = try snapshots.create(bottle, label: "Antes do setup")

        try write("2", file)
        try write("novo", bottle.driveC.appendingPathComponent("b.txt"))

        XCTAssertEqual(snapshots.list(bottle).map(\.label), ["Antes do setup"])
        try snapshots.restore(snap, to: bottle)

        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "1")
        XCTAssertFalse(fm.fileExists(atPath: bottle.driveC.appendingPathComponent("b.txt").path))
        let listed = try await manager.list()
        XCTAssertEqual(listed.map(\.name), ["Jogos"], "pastas ocultas (.snapshots/.old) não viram bottles")

        try snapshots.delete(snap)
        XCTAssertTrue(snapshots.list(bottle).isEmpty)
    }

    func testExportImportWithNameCollision() async throws {
        let manager = BottleManager(rootURL: root)
        let bottle = try await manager.create(BottleSettings(name: "Steam", windowsVersion: .win11))
        try write("save", bottle.driveC.appendingPathComponent("users/x/save.dat"))

        let archive = fm.temporaryDirectory.appendingPathComponent("steam-\(UUID().uuidString).\(BottleArchiver.fileExtension)")
        defer { try? fm.removeItem(at: archive) }
        try await BottleArchiver.export(bottle, to: archive)

        let imported = try await manager.importBottle(from: archive)
        XCTAssertEqual(imported.name, "Steam 2")
        XCTAssertEqual(imported.settings.windowsVersion, .win11)
        XCTAssertNotEqual(imported.url, bottle.url)
        XCTAssertEqual(try String(contentsOf: imported.driveC.appendingPathComponent("users/x/save.dat"), encoding: .utf8), "save")

        let names = try await manager.list().map(\.name)
        XCTAssertEqual(names, ["Steam", "Steam 2"])
        let leftovers = try fm.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".import") }
        XCTAssertTrue(leftovers.isEmpty)
    }
}
