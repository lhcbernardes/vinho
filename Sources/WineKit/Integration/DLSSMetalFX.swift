import Foundation

/// DLSS → MetalFX (D3DMetal do Game Porting Toolkit 3+).
///
/// Além de `D3DM_ENABLE_METALFX=1` (ver `WineEnvironment`), o jogo precisa achar
/// `nvngx.dll` e `nvapi64.dll` no system32. O GPTK traz a ponte como
/// `nvngx-on-metalfx.*`; aqui ela é copiada com o nome que o jogo procura.
public enum DLSSMetalFX {
    public struct Result: Equatable, Sendable {
        public var installed: [String] = []
        public var missing: [String] = []
    }

    /// O runtime tem a ponte DLSS → MetalFX?
    public static func isSupported(by runtime: WineRuntime) -> Bool {
        bridgeFiles(in: runtime).windowsBridge != nil
    }

    static func bridgeFiles(in runtime: WineRuntime) -> (windowsBridge: URL?, nvapi: URL?, unixBridge: URL?) {
        let files = ProgramScanner.files(in: runtime.libURL, extensions: ["dll", "so"], maxDepth: 5)
        func find(_ prefix: String, ext: String, under folder: String) -> URL? {
            files.first {
                let name = $0.lastPathComponent.lowercased()
                return name.hasPrefix(prefix) && $0.pathExtension.lowercased() == ext
                    && $0.deletingLastPathComponent().lastPathComponent.lowercased().contains(folder)
            }
        }
        return (find("nvngx-on-metalfx", ext: "dll", under: "x86_64-windows"),
                find("nvapi64", ext: "dll", under: "x86_64-windows"),
                find("nvngx-on-metalfx", ext: "so", under: "x86_64-unix"))
    }

    /// Copia as DLLs para `C:\windows\system32` do bottle.
    @discardableResult
    public static func install(runtime: WineRuntime, in bottle: Bottle) throws -> Result {
        let fm = FileManager.default
        let system32 = bottle.driveC.appendingPathComponent("windows/system32", isDirectory: true)
        try fm.createDirectory(at: system32, withIntermediateDirectories: true)
        let files = bridgeFiles(in: runtime)
        var result = Result()

        for (source, name) in [(files.windowsBridge, "nvngx.dll"), (files.nvapi, "nvapi64.dll")] {
            guard let source else { result.missing.append(name); continue }
            let dest = system32.appendingPathComponent(name)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: source, to: dest)
            result.installed.append(name)
        }
        // Metade unix da ponte, quando o runtime a separa (só copia, não altera o original).
        if let unix = files.unixBridge {
            let dest = unix.deletingLastPathComponent().appendingPathComponent("nvngx.so")
            if !fm.fileExists(atPath: dest.path) { try? fm.copyItem(at: unix, to: dest) }
        }
        return result
    }

    /// Remove a ponte (ao desligar a opção). O nvapi64 fica: o próprio
    /// runtime pode tê-lo instalado no wineboot.
    public static func uninstall(from bottle: Bottle) {
        let dll = bottle.driveC.appendingPathComponent("windows/system32/nvngx.dll")
        try? FileManager.default.removeItem(at: dll)
    }
}
