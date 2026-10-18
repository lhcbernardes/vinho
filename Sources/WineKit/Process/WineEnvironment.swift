import Foundation

/// Monta o ambiente de execução do Wine a partir das configurações do bottle.
///
/// Ordem de precedência (o último vence):
/// ambiente base → variáveis do Vinho → `settings.environment` → `extra`.
public enum WineEnvironment {
    /// Variáveis herdadas do processo do app que fazem sentido repassar.
    public static let inheritedKeys = ["HOME", "USER", "LOGNAME", "LANG", "LC_ALL", "TMPDIR", "SHELL"]

    public static func make(
        bottle: Bottle,
        runtime: WineRuntime,
        base: [String: String] = ProcessInfo.processInfo.environment,
        extra: [String: String] = [:]
    ) -> [String: String] {
        let s = bottle.settings
        var env: [String: String] = [:]

        for key in inheritedKeys {
            if let value = base[key] { env[key] = value }
        }

        let systemPath = base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = "\(runtime.binURL.path):\(systemPath)"
        env["WINEPREFIX"] = bottle.prefixURL.path
        let channels = s.debugChannels?.trimmingCharacters(in: .whitespaces) ?? ""
        env["WINEDEBUG"] = channels.isEmpty ? s.logLevel.winedebug : channels

        // Overrides: backend gráfico primeiro, overrides do usuário por cima.
        var overrides = s.graphics.dllOverrides
        overrides.merge(s.dllOverrides) { _, user in user }
        // Evita o diálogo "instalar Mono/Gecko" a cada wineboot — a não ser que
        // um .NET (Wine Mono ou o da Microsoft) tenha sido instalado pelo Vinho:
        // aí o mscoree precisa carregar. (A env var ganharia do registro.)
        if !s.windowsComponents.contains(where: WindowsComponents.dotNetIDs.contains) {
            overrides["mscoree"] = overrides["mscoree"] ?? .disabled
        }
        overrides["mshtml"] = overrides["mshtml"] ?? .disabled
        env["WINEDLLOVERRIDES"] = DLLOverrides.format(overrides)

        switch s.sync {
        case .msync: env["WINEMSYNC"] = "1"
        case .esync: env["WINEESYNC"] = "1"
        case .none: break
        }

        if s.metalHUD {
            env["MTL_HUD_ENABLED"] = "1"
            if s.graphics == .dxvk { env["DXVK_HUD"] = "fps,devinfo" }
        }

        if s.graphics == .d3dMetal {
            // Necessário para que o loader encontre o D3DMetal.framework nos builds GPTK.
            let external = runtime.libURL.appendingPathComponent("external").path
            env["DYLD_FALLBACK_LIBRARY_PATH"] = [external, runtime.libURL.path, "/usr/lib"].joined(separator: ":")
        } else if FileManager.default.fileExists(atPath: runtime.rootURL.appendingPathComponent(WineRuntime.bundledLibsMarker).path) {
            // Builds do workflow `wine-runtime` (CrossOver) trazem freetype, gnutls,
            // MoltenVK etc. em lib/, carregados por dlopen.
            env["DYLD_FALLBACK_LIBRARY_PATH"] = [runtime.libURL.path, "/usr/lib"].joined(separator: ":")
        }

        env.merge(s.environment) { _, user in user }
        env.merge(extra) { _, new in new }
        return env
    }
}
