import Foundation

public struct InstallProgress: Sendable, Equatable {
    public enum Phase: String, Sendable, Equatable {
        case downloading, verifying, extracting, installing
    }

    public var phase: Phase
    /// 0...1 quando conhecido (só durante o download).
    public var fraction: Double?
    public var receivedBytes: Int64

    public init(phase: Phase, fraction: Double? = nil, receivedBytes: Int64 = 0) {
        self.phase = phase
        self.fraction = fraction
        self.receivedBytes = receivedBytes
    }

    public var label: String {
        switch phase {
        case .downloading:
            let mb = Double(receivedBytes) / 1_048_576
            if let fraction { return String(format: "Baixando… %.0f%% (%.0f MB)", fraction * 100, mb) }
            return String(format: "Baixando… %.0f MB", mb)
        case .verifying: return "Verificando SHA-256…"
        case .extracting: return "Extraindo…"
        case .installing: return "Instalando…"
        }
    }
}

/// Instala, remove e deriva runtimes em `Runtimes/`.
///
/// Toda operação acontece num diretório de staging dentro de `Runtimes/`
/// (mesmo volume → `moveItem` atômico) e só aparece no destino final
/// depois de verificada. Falhas não deixam lixo para trás.
public struct RuntimeInstaller: Sendable {
    public let runtimesDirectory: URL
    public let downloader: any Downloading

    public init(
        runtimesDirectory: URL = RuntimeLocator.managedRuntimesDirectory,
        downloader: any Downloading = URLSessionDownloader()
    ) {
        self.runtimesDirectory = runtimesDirectory
        self.downloader = downloader
    }

    // MARK: - Runtime

    @discardableResult
    public func install(
        _ descriptor: RuntimeDescriptor,
        progress: @escaping @Sendable (InstallProgress) -> Void = { _ in }
    ) async throws -> URL {
        let fm = FileManager.default
        let destination = runtimesDirectory.appendingPathComponent(descriptor.id, isDirectory: true)
        guard !fm.fileExists(atPath: destination.path) else {
            throw WineError.alreadyInstalled(id: descriptor.id)
        }

        let staging = try makeStaging()
        defer { try? fm.removeItem(at: staging) }

        let archive = staging.appendingPathComponent(descriptor.artifact.url.lastPathComponent)
        try await fetchVerified(descriptor.artifact, to: archive, progress: progress)

        progress(InstallProgress(phase: .extracting))
        let extracted = staging.appendingPathComponent("extracted", isDirectory: true)
        try await Archive.extract(archive, to: extracted)
        try Task.checkCancellation()

        guard let root = Self.findWineRoot(in: extracted) else {
            throw WineError.invalidArchive(reason: "nenhum bin/wine encontrado no pacote")
        }

        progress(InstallProgress(phase: .installing))
        try "\(descriptor.version)\n".write(to: root.appendingPathComponent("VERSION"), atomically: true, encoding: .utf8)
        try fm.moveItem(at: root, to: destination)
        return destination
    }

    /// Remove um runtime instalado pelo Vinho (vai para o Lixo).
    public func uninstall(_ runtime: WineRuntime) throws {
        let root = runtime.rootURL.standardizedFileURL.path
        let managed = runtimesDirectory.standardizedFileURL.path + "/"
        guard root.hasPrefix(managed) else { throw WineError.notManagedRuntime(id: runtime.id) }
        #if os(macOS)
        try FileManager.default.trashItem(at: runtime.rootURL, resultingItemURL: nil)
        #else
        try FileManager.default.removeItem(at: runtime.rootURL)
        #endif
    }

    // MARK: - Variantes (DXMT / DXVK)

    public static func variantID(base: WineRuntime, component: ComponentDescriptor) -> String {
        "\(base.id)+\(component.id)"
    }

    /// Cria `<base>+<componente>`: copia o runtime base (clone APFS — quase
    /// sem custo de disco) e sobrepõe as DLLs builtin do componente.
    /// O runtime base fica intocado, então WineD3D continua disponível nele.
    @discardableResult
    public func makeVariant(
        of base: WineRuntime,
        with component: ComponentDescriptor,
        progress: @escaping @Sendable (InstallProgress) -> Void = { _ in }
    ) async throws -> URL {
        let fm = FileManager.default
        let id = Self.variantID(base: base, component: component)
        let destination = runtimesDirectory.appendingPathComponent(id, isDirectory: true)
        guard !fm.fileExists(atPath: destination.path) else { throw WineError.alreadyInstalled(id: id) }

        let staging = try makeStaging()
        defer { try? fm.removeItem(at: staging) }

        let archive = staging.appendingPathComponent(component.artifact.url.lastPathComponent)
        try await fetchVerified(component.artifact, to: archive, progress: progress)

        progress(InstallProgress(phase: .extracting))
        let extracted = staging.appendingPathComponent("extracted", isDirectory: true)
        try await Archive.extract(archive, to: extracted)
        guard let package = Self.findComponentRoot(in: extracted) else {
            throw WineError.invalidArchive(reason: "pasta x86_64-windows não encontrada")
        }

        progress(InstallProgress(phase: .installing))
        let variant = staging.appendingPathComponent("variant", isDirectory: true)
        try fm.copyItem(at: base.rootURL, to: variant) // APFS: clonefile
        try ComponentOverlay.apply(package: package, to: variant)

        var manifest = RuntimeComponentsManifest.read(from: variant)
            ?? RuntimeComponentsManifest(baseRuntimeID: base.id, components: [])
        manifest.components.removeAll { $0.kind == component.kind }
        manifest.components.append(.init(id: component.id, kind: component.kind, version: component.version))
        try manifest.write(to: variant)

        let baseVersion = base.version ?? base.id
        try "\(baseVersion) + \(component.name) \(component.version)\n"
            .write(to: variant.appendingPathComponent("VERSION"), atomically: true, encoding: .utf8)

        try fm.moveItem(at: variant, to: destination)
        return destination
    }

    // MARK: - Internos

    func fetchVerified(
        _ artifact: DownloadableArtifact,
        to file: URL,
        progress: @escaping @Sendable (InstallProgress) -> Void
    ) async throws {
        let expected = artifact.size
        progress(InstallProgress(phase: .downloading, fraction: 0))
        try await downloader.download(artifact.url, to: file) { received, total in
            let denominator = total ?? (expected > 0 ? expected : nil)
            let fraction = denominator.map { min(1, Double(received) / Double($0)) }
            progress(InstallProgress(phase: .downloading, fraction: fraction, receivedBytes: received))
        }
        try Task.checkCancellation()

        progress(InstallProgress(phase: .verifying))
        let actual = try Checksum.sha256(of: file)
        guard actual == artifact.sha256.lowercased() else {
            throw WineError.checksumMismatch(expected: artifact.sha256, actual: actual)
        }
    }

    private func makeStaging() throws -> URL {
        let url = runtimesDirectory.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Busca em largura (até 4 níveis) por um diretório com `bin/wine`.
    static func findWineRoot(in directory: URL) -> URL? {
        breadthFirst(directory, maxDepth: 4) { RuntimeLocator.resolveRoot($0) }
    }

    /// Diretório que contém `x86_64-windows/` (ex.: `v0.80/` no DXMT).
    static func findComponentRoot(in directory: URL) -> URL? {
        breadthFirst(directory, maxDepth: 3) { dir in
            var isDir: ObjCBool = false
            let path = dir.appendingPathComponent("x86_64-windows").path
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue ? dir : nil
        }
    }

    private static func breadthFirst(_ start: URL, maxDepth: Int, match: (URL) -> URL?) -> URL? {
        var level = [start]
        for _ in 0...maxDepth {
            var next: [URL] = []
            for dir in level {
                if let found = match(dir) { return found }
                let children = (try? FileManager.default.contentsOfDirectory(
                    at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
                )) ?? []
                next += children
                    .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
            }
            level = next
        }
        return nil
    }
}

/// Copia `x86_64-windows/`, `i386-windows/` e `x86_64-unix/` de um pacote
/// builtin para `lib/wine/<arch>/` de um runtime.
public enum ComponentOverlay {
    public static let architectures = ["x86_64-windows", "i386-windows", "x86_64-unix"]

    @discardableResult
    public static func apply(package: URL, to runtimeRoot: URL) throws -> [URL] {
        let fm = FileManager.default
        var written: [URL] = []
        for arch in architectures {
            let source = package.appendingPathComponent(arch, isDirectory: true)
            guard let files = try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                continue
            }
            let target = runtimeRoot.appendingPathComponent("lib/wine/\(arch)", isDirectory: true)
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            for file in files {
                let destination = target.appendingPathComponent(file.lastPathComponent)
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                try fm.copyItem(at: file, to: destination)
                written.append(destination)
            }
        }
        guard !written.isEmpty else {
            throw WineError.invalidArchive(reason: "pacote sem DLLs")
        }
        return written
    }
}
