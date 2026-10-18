import XCTest
@testable import WineKit

/// "Baixa" copiando um arquivo local — sem rede nos testes.
struct LocalFileDownloader: Downloading {
    let source: URL
    func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
        let size = (try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value ?? 0
        try FileManager.default.copyItem(at: source, to: destination)
        progress(size, size)
    }
}

final class RuntimeInstallerTests: XCTestCase {
    private var work: URL!
    private var runtimes: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        work = fm.temporaryDirectory.appendingPathComponent("vinho-inst-\(UUID().uuidString)")
        runtimes = work.appendingPathComponent("Runtimes")
        try fm.createDirectory(at: runtimes, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: work)
    }

    // MARK: helpers

    private func write(_ text: String, to url: URL, executable: Bool = false) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: url.path, contents: Data(text.utf8),
                      attributes: executable ? [.posixPermissions: 0o755] : nil)
    }

    /// Cria um .tar.gz de `dir` (conteúdo relativo) com o tar do sistema.
    private func tarball(of dir: URL, named name: String) async throws -> URL {
        let out = work.appendingPathComponent(name)
        let r = try await FoundationProcessLauncher().collect(WineInvocation(
            executable: URL(fileURLWithPath: "/usr/bin/tar"),
            arguments: ["-czf", out.path, "-C", dir.path, "."],
            environment: [:]
        ))
        XCTAssertEqual(r.exitCode, 0, r.stderr.joined(separator: "\n"))
        return out
    }

    private func fakeWinePackage() async throws -> URL {
        let src = work.appendingPathComponent("pkg-src")
        try write("#!/bin/sh\necho wine-11.0\n", to: src.appendingPathComponent("Wine Stable.app/Contents/Resources/wine/bin/wine"), executable: true)
        try write("orig", to: src.appendingPathComponent("Wine Stable.app/Contents/Resources/wine/lib/wine/x86_64-windows/d3d11.dll"))
        return try await tarball(of: src, named: "wine.tar.gz")
    }

    private func descriptor(for archive: URL, sha: String? = nil) throws -> RuntimeDescriptor {
        RuntimeDescriptor(
            id: "wine-test-1.0", name: "Wine Test", version: "1.0", channel: .stable,
            artifact: DownloadableArtifact(
                url: URL(string: "https://example.invalid/wine.tar.gz")!,
                sha256: try sha ?? Checksum.sha256(of: archive),
                size: 0))
    }

    // MARK: testes

    func testChecksumKnownVector() throws {
        let f = work.appendingPathComponent("abc.txt")
        try write("abc", to: f)
        XCTAssertEqual(try Checksum.sha256(of: f), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testInstallExtractsVerifiesAndIsDiscoverable() async throws {
        let archive = try await fakeWinePackage()
        let installer = RuntimeInstaller(runtimesDirectory: runtimes, downloader: LocalFileDownloader(source: archive))

        let phases = PhaseRecorder()
        let dest = try await installer.install(try descriptor(for: archive)) { phases.add($0.phase) }

        XCTAssertTrue(fm.isExecutableFile(atPath: dest.appendingPathComponent("bin/wine").path))
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("VERSION"), encoding: .utf8), "1.0\n")
        XCTAssertEqual(phases.unique, [.downloading, .verifying, .extracting, .installing])

        let found = RuntimeLocator(searchDirectories: [runtimes]).discover()
        XCTAssertEqual(found.map(\.id), ["wine-test-1.0"])
        XCTAssertEqual(found.first?.version, "1.0")

        let leftovers = try fm.contentsOfDirectory(atPath: runtimes.path).filter { $0.hasPrefix(".staging") }
        XCTAssertTrue(leftovers.isEmpty, "staging deve ser limpo")
    }

    func testChecksumMismatchAbortsWithoutInstalling() async throws {
        let archive = try await fakeWinePackage()
        let installer = RuntimeInstaller(runtimesDirectory: runtimes, downloader: LocalFileDownloader(source: archive))
        let bad = try descriptor(for: archive, sha: String(repeating: "0", count: 64))

        do {
            try await installer.install(bad)
            XCTFail("deveria falhar")
        } catch let error as WineError {
            guard case .checksumMismatch = error else { return XCTFail("erro inesperado: \(error)") }
        }
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: runtimes.path), [])
    }

    func testInstallTwiceIsRejected() async throws {
        let archive = try await fakeWinePackage()
        let installer = RuntimeInstaller(runtimesDirectory: runtimes, downloader: LocalFileDownloader(source: archive))
        let d = try descriptor(for: archive)
        try await installer.install(d)
        do {
            try await installer.install(d)
            XCTFail("deveria rejeitar")
        } catch let error as WineError {
            XCTAssertEqual(error, .alreadyInstalled(id: d.id))
        }
    }

    func testVariantOverlaysComponentAndKeepsBaseIntact() async throws {
        // runtime base instalado
        let archive = try await fakeWinePackage()
        try await RuntimeInstaller(runtimesDirectory: runtimes, downloader: LocalFileDownloader(source: archive))
            .install(try descriptor(for: archive))
        let base = try XCTUnwrap(RuntimeLocator(searchDirectories: [runtimes]).discover().first)
        XCTAssertFalse(base.capabilities.contains(.dxmt))

        // pacote DXMT falso com o mesmo layout do real (v0.80/<arch>/…)
        let src = work.appendingPathComponent("dxmt-src")
        try write("dxmt", to: src.appendingPathComponent("v0.80/x86_64-windows/d3d11.dll"))
        try write("dxmt32", to: src.appendingPathComponent("v0.80/i386-windows/d3d11.dll"))
        try write("so", to: src.appendingPathComponent("v0.80/x86_64-unix/winemetal.so"))
        let pkg = try await tarball(of: src, named: "dxmt.tar.gz")
        let component = ComponentDescriptor(
            id: "dxmt-test", kind: .dxmt, name: "DXMT", version: "0.80",
            artifact: DownloadableArtifact(url: URL(string: "https://example.invalid/dxmt.tar.gz")!,
                                           sha256: try Checksum.sha256(of: pkg), size: 0))

        let installer = RuntimeInstaller(runtimesDirectory: runtimes, downloader: LocalFileDownloader(source: pkg))
        let variantURL = try await installer.makeVariant(of: base, with: component)

        XCTAssertEqual(variantURL.lastPathComponent, "wine-test-1.0+dxmt-test")
        XCTAssertEqual(try String(contentsOf: variantURL.appendingPathComponent("lib/wine/x86_64-windows/d3d11.dll"), encoding: .utf8), "dxmt")
        XCTAssertEqual(try String(contentsOf: variantURL.appendingPathComponent("lib/wine/i386-windows/d3d11.dll"), encoding: .utf8), "dxmt32")
        XCTAssertEqual(try String(contentsOf: base.rootURL.appendingPathComponent("lib/wine/x86_64-windows/d3d11.dll"), encoding: .utf8), "orig",
                       "o runtime base não pode ser alterado")

        let all = RuntimeLocator(searchDirectories: [runtimes]).discover()
        let variant = try XCTUnwrap(all.first { $0.id == "wine-test-1.0+dxmt-test" })
        XCTAssertTrue(variant.capabilities.contains(.dxmt))
        XCTAssertTrue(variant.supports(.dxmt))
        XCTAssertEqual(RuntimeComponentsManifest.read(from: variant.rootURL)?.baseRuntimeID, "wine-test-1.0")
    }

    func testUninstallRefusesUnmanagedRuntime() throws {
        let installer = RuntimeInstaller(runtimesDirectory: runtimes, downloader: LocalFileDownloader(source: work))
        let external = WineRuntime(id: "Game Porting Toolkit", rootURL: URL(fileURLWithPath: "/Applications/Game Porting Toolkit.app/Contents/Resources/wine"), capabilities: [])
        XCTAssertThrowsError(try installer.uninstall(external))
    }

    func testBuiltInCatalogIsWellFormed() {
        let catalog = Catalog.builtIn
        let ids = catalog.runtimes.map(\.id) + catalog.components.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "ids únicos")
        for artifact in catalog.runtimes.map(\.artifact) + catalog.components.map(\.artifact) {
            XCTAssertEqual(artifact.url.scheme, "https")
            XCTAssertEqual(artifact.sha256.count, 64)
            XCTAssertTrue(artifact.sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase })
            XCTAssertGreaterThan(artifact.size, 0)
        }
        XCTAssertEqual(catalog.recommendedRuntime?.channel, .stable)
    }

    func testCatalogJSONRoundTrip() throws {
        let data = try JSONEncoder().encode(Catalog.builtIn)
        XCTAssertEqual(try JSONDecoder().decode(Catalog.self, from: data), Catalog.builtIn)
    }
}

/// Coleta fases reportadas por closures @Sendable.
final class PhaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var phases: [InstallProgress.Phase] = []

    func add(_ phase: InstallProgress.Phase) {
        lock.lock(); defer { lock.unlock() }
        if phases.last != phase { phases.append(phase) }
    }

    var unique: [InstallProgress.Phase] {
        lock.lock(); defer { lock.unlock() }
        return phases
    }
}
