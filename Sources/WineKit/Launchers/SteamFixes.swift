import Foundation

/// Correções para a Steam rodar no Wine do macOS.
///
/// Tela preta: o CEF da Steam (`steamwebhelper.exe`) não consegue usar a GPU
/// via D3D11 no Wine e desenha a janela em preto. As flags da Steam não chegam
/// ao steamwebhelper, então colocamos um wrapper no lugar dele que acrescenta
/// `--disable-gpu --single-process` (fonte em Tools/steamwebhelper-wrapper).
/// A Steam pode restaurar o arquivo original ao se atualizar, por isso o
/// wrapper é reaplicado antes de cada abertura.
public enum SteamFixes {
    public static let originalName = "steamwebhelper_vinho_orig.exe"

    /// Argumentos da Steam: não verificar arquivos (senão ela desfaz o wrapper)
    /// e desligar a composição por GPU do CEF.
    public static let launchArguments = ["-noverifyfiles", "-cef-disable-gpu-compositing"]

    /// bcrypt/ncrypt builtin (os stubs conflitam com o BoringSSL do Chromium);
    /// overlay desligado (o hook D3D11 trava jogos).
    public static let dllOverrides: [String: DLLOverrideMode] = [
        "bcrypt": .builtin,
        "ncrypt": .builtin,
        "gameoverlayrenderer": .disabled,
        "gameoverlayrenderer64": .disabled,
    ]

    /// Pastas do CEF 64-bit que contêm um steamwebhelper.exe.
    public static func cefDirectories(in bottle: Bottle) -> [URL] {
        let cef = Steam.directory(in: bottle).appendingPathComponent("bin/cef", isDirectory: true)
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: cef, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return dirs
            .filter { $0.lastPathComponent.contains("64") }
            .filter { fm.fileExists(atPath: $0.appendingPathComponent("steamwebhelper.exe").path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// O wrapper está ativo em todas as pastas do CEF? (falso se a Steam ainda
    /// não baixou o CEF — acontece só depois da primeira abertura.)
    public static func isWrapperDeployed(in bottle: Bottle) -> Bool {
        let dirs = cefDirectories(in: bottle)
        return !dirs.isEmpty && dirs.allSatisfy { dir in
            isWrapper(dir.appendingPathComponent("steamwebhelper.exe"))
                && FileManager.default.fileExists(atPath: dir.appendingPathComponent(originalName).path)
        }
    }

    /// Coloca o wrapper no lugar do steamwebhelper.exe. Se a Steam se atualizou
    /// (o arquivo atual não é o wrapper), o atual vira o novo "original".
    /// - Returns: número de pastas alteradas.
    @discardableResult
    public static func deployWebHelperWrapper(in bottle: Bottle, wrapper: Data = SteamWebHelperWrapper.data) throws -> Int {
        let fm = FileManager.default
        var changed = 0
        for dir in cefDirectories(in: bottle) {
            let helper = dir.appendingPathComponent("steamwebhelper.exe")
            let original = dir.appendingPathComponent(originalName)
            if isWrapper(helper, wrapper: wrapper) {
                if fm.fileExists(atPath: original.path) { continue }
                // Wrapper sem o original (não deveria acontecer): não há o que chamar.
                throw WineError.invalidArchive(reason: "steamwebhelper original ausente em \(dir.lastPathComponent)")
            }
            if fm.fileExists(atPath: original.path) { try fm.removeItem(at: original) }
            try fm.moveItem(at: helper, to: original)
            try wrapper.write(to: helper, options: .atomic)
            changed += 1
        }
        return changed
    }

    /// Volta ao steamwebhelper original (desfaz a correção).
    public static func removeWebHelperWrapper(in bottle: Bottle) throws {
        let fm = FileManager.default
        for dir in cefDirectories(in: bottle) {
            let helper = dir.appendingPathComponent("steamwebhelper.exe")
            let original = dir.appendingPathComponent(originalName)
            guard fm.fileExists(atPath: original.path), isWrapper(helper) else { continue }
            try fm.removeItem(at: helper)
            try fm.moveItem(at: original, to: helper)
        }
    }

    /// Remove travas do Chromium deixadas por uma Steam que caiu (impedem a janela de abrir).
    /// Só chame com a Steam fechada.
    @discardableResult
    public static func clearStaleLocks(in bottle: Bottle) -> Int {
        let fm = FileManager.default
        let dirs = ["config/htmlcache", "htmlcache"].map { Steam.directory(in: bottle).appendingPathComponent($0) }
        var removed = 0
        for dir in dirs {
            let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            for name in names where name.hasPrefix("Singleton") {
                if (try? fm.removeItem(at: dir.appendingPathComponent(name))) != nil { removed += 1 }
            }
        }
        return removed
    }

    static func isWrapper(_ url: URL, wrapper: Data = SteamWebHelperWrapper.data) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        return data == wrapper
    }
}

/// Renderer do WineD3D (afeta jogos DX9–11 que caem no WineD3D).
public enum WineD3DRenderer: String, Codable, CaseIterable, Sendable, Identifiable {
    case gl
    case vulkan

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .gl: "OpenGL"
        case .vulkan: "Vulkan (MoltenVK)"
        }
    }
}

/// Configuração por jogo dentro de um bottle compartilhado (ex.: uma Steam só).
/// Aplicada pelo Wine via `HKCU\Software\Wine\AppDefaults\<exe>` — vale só
/// para aquele executável, mesmo que ele seja aberto pela Steam.
public struct GameProfile: Codable, Hashable, Sendable {
    /// Nome do executável, ex. `left4dead2.exe`.
    public var exeName: String
    public var dllOverrides: [String: DLLOverrideMode]
    public var renderer: WineD3DRenderer?
    public var retina: Bool?
    /// Sugeridas para colar nas Propriedades do jogo na Steam.
    public var launchOptions: String?

    public init(exeName: String, dllOverrides: [String: DLLOverrideMode] = [:], renderer: WineD3DRenderer? = nil,
                retina: Bool? = nil, launchOptions: String? = nil) {
        self.exeName = exeName
        self.dllOverrides = dllOverrides
        self.renderer = renderer
        self.retina = retina
        self.launchOptions = launchOptions
    }

    public var appDefaultsKey: String {
        #"HKCU\Software\Wine\AppDefaults\"# + exeName
    }
}

extension WineConfigurator {
    /// Comandos `reg` para levar o perfil do jogo de `previous` para `profile`.
    public static func commands(for profile: GameProfile, previous: GameProfile?) -> [[String]] {
        let base = profile.appDefaultsKey
        var commands: [[String]] = []

        let old = previous?.exeName == profile.exeName ? previous?.dllOverrides ?? [:] : [:]
        for (dll, mode) in profile.dllOverrides.sorted(by: { $0.key < $1.key }) where old[dll] != mode {
            commands.append(regAdd(key: base + #"\DllOverrides"#, value: dll, type: "REG_SZ", data: mode.rawValue))
        }
        for dll in old.keys.sorted() where profile.dllOverrides[dll] == nil {
            commands.append(regDelete(key: base + #"\DllOverrides"#, value: dll))
        }

        let sameExe = previous?.exeName == profile.exeName
        if !sameExe || previous?.renderer != profile.renderer {
            if let renderer = profile.renderer {
                commands.append(regAdd(key: base + #"\Direct3D"#, value: "renderer", type: "REG_SZ", data: renderer.rawValue))
            } else if sameExe {
                commands.append(regDelete(key: base + #"\Direct3D"#, value: "renderer"))
            }
        }
        if !sameExe || previous?.retina != profile.retina {
            if let retina = profile.retina {
                commands.append(regAdd(key: base + #"\Mac Driver"#, value: "RetinaMode", type: "REG_SZ", data: retina ? "y" : "n"))
            } else if sameExe {
                commands.append(regDelete(key: base + #"\Mac Driver"#, value: "RetinaMode"))
            }
        }
        return commands
    }

    public static func regDelete(key: String, value: String) -> [String] {
        ["reg", "delete", key, "/v", value, "/f"]
    }
}
