import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WineKit

extension AppModel {
    // MARK: Integração com o Mac (cxmenu + cxassoc + cxnativeopen)

    /// Sincroniza o bottle com o Mac:
    /// - atalhos do Menu Iniciar viram apps no Launchpad (`~/Applications/Vinho/<bottle>/`);
    /// - programas que abrem tipos de arquivo aparecem no "Abrir com" do Finder;
    /// - links e arquivos sem programa do Windows abrem nos apps do Mac.
    func integrateWithMac(_ bottle: Bottle, announce: Bool = false) async {
        let current = bottles.first { $0.id == bottle.id } ?? bottle
        guard let runtime = runtime(for: current) else { return }
        guard current.settings.macIntegration else {
            await removeMacIntegration(current)
            return
        }
        let runner = WineRunner(runtime: runtime)
        try? await runner.waitForServer(current) // o registro só é gravado no disco quando o wineserver sai

        // 1. Arquivos e links abrindo no Mac.
        let (system, user) = MacIntegration.registries(of: current)
        let operations = MacIntegration.nativeOpenOperations(system: system, user: user)
        if !operations.isEmpty {
            let temp = current.driveC.appendingPathComponent("windows/temp", isDirectory: true)
            let file = temp.appendingPathComponent("vinho-integracao.reg")
            do {
                try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
                try MacIntegration.regFile(operations).write(to: file, atomically: true, encoding: .utf8)
                try await runner.runToCompletion(["regedit", "/S", #"C:\windows\temp\vinho-integracao.reg"#], in: current).check()
                try? await runner.waitForServer(current)
            } catch {
                log(current.id, "⚠️ Não consegui ajustar a abertura de arquivos no Mac: \(error.localizedDescription)")
            }
        }

        // 2. Apps no Launchpad e no "Abrir com".
        let directory = MacIntegration.appsDirectory(for: current)
        let plan = MacIntegration.plan(for: current)
        var created: [String] = []
        var changed: [String] = []
        for item in plan {
            let app = directory.appendingPathComponent("\(LauncherBuilder.sanitize(item.name)).app")
            created.append(app.path)
            if LauncherBuilder.spec(of: app) == item.spec { continue }
            let program = Program(url: item.program, kind: item.program.pathExtension.lowercased() == "lnk" ? .shortcut : .executable)
            let (args, cwd) = WineRunner.launchArguments(for: program)
            let invocation = runner.invocation(args, in: current, currentDirectory: cwd)
            do {
                let built = try await LauncherBuilder.makeDocumentApp(
                    named: item.name, invocation: invocation, template: item.template,
                    extensions: item.extensions, typeName: item.typeName, in: directory,
                    icns: Self.icns(for: item.program, in: current), spec: item.spec
                )
                await LauncherBuilder.register(built)
                changed.append(item.name)
            } catch {
                log(current.id, "⚠️ Não consegui criar o app de “\(item.name)”: \(error.localizedDescription)")
            }
        }

        // 3. Apps de programas que sumiram (desinstalados).
        let stale = current.settings.integratedApps.filter { !created.contains($0) }
        for path in stale { await Self.trashApp(URL(fileURLWithPath: path)) }

        if created != current.settings.integratedApps {
            await update(current) { $0.integratedApps = created }
        }
        if !changed.isEmpty || !stale.isEmpty {
            var parts: [String] = []
            if !changed.isEmpty { parts.append("no Launchpad: \(changed.joined(separator: ", "))") }
            if !stale.isEmpty { parts.append("\(stale.count) removido(s)") }
            log(current.id, "🍎 Integração com o Mac — \(parts.joined(separator: "; ")).")
        } else if announce {
            log(current.id, "🍎 Integração com o Mac em dia (\(plan.count) app(s)).")
        }
    }

    /// Tira os apps do Launchpad/"Abrir com" deste bottle.
    func removeMacIntegration(_ bottle: Bottle) async {
        let current = bottles.first { $0.id == bottle.id } ?? bottle
        guard !current.settings.integratedApps.isEmpty else { return }
        for path in current.settings.integratedApps { await Self.trashApp(URL(fileURLWithPath: path)) }
        try? FileManager.default.removeItem(at: MacIntegration.appsDirectory(for: current)) // só se ficou vazia
        if bottles.contains(where: { $0.id == current.id }) {
            await update(current) { $0.integratedApps = [] }
        }
        log(current.id, "🍎 Apps da integração com o Mac removidos.")
    }

    func setMacIntegration(_ enabled: Bool, for bottle: Bottle) async {
        await update(bottle) { $0.macIntegration = enabled }
        if enabled { await integrateWithMac(bottle, announce: true) } else { await removeMacIntegration(bottle) }
    }

    private static func trashApp(_ app: URL) async {
        guard FileManager.default.fileExists(atPath: app.path) else { return }
        await LauncherBuilder.unregister(app)
        try? FileManager.default.trashItem(at: app, resultingItemURL: nil)
    }

    /// Ícone do programa como .icns (ImageIO), para o applet.
    static func icns(for program: URL, in bottle: Bottle) -> Data? {
        guard let data = ProgramIconResolver.iconData(for: program, in: bottle),
              let image = NSImage(data: data),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.icns.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, Self.resized(cg, to: 512) ?? cg, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    private static func resized(_ image: CGImage, to size: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return ctx.makeImage()
    }

    // MARK: Atualizar o prefixo quando o Wine muda (cxupgrade)

    /// Na primeira execução depois de trocar/atualizar o runtime, roda
    /// `wineboot -u` e reaplica as configurações do bottle.
    func preparePrefixIfNeeded(_ bottle: Bottle) async {
        let current = bottles.first { $0.id == bottle.id } ?? bottle
        guard let runtime = runtime(for: current) else { return }
        let fingerprint = WineRunner.fingerprint(runtime, version: displayVersion(runtime))
        guard current.settings.preparedRuntime != fingerprint else { return }
        // Bottle antigo sem registro: assume que já está no runtime atual.
        if current.settings.preparedRuntime == nil {
            await update(current) { $0.preparedRuntime = fingerprint }
            return
        }
        busyMessage = "Atualizando “\(current.name)” para \(runtime.displayName)…"
        defer { busyMessage = nil }
        log(current.id, "⬆️ O Wine mudou (\(current.settings.preparedRuntime ?? "?") → \(fingerprint)); atualizando o prefixo…")
        do {
            let runner = WineRunner(runtime: runtime)
            try await runner.updatePrefix(current)
            try await runner.apply(current.settings, previous: nil, to: current)
            if current.settings.dlssMetalFX { _ = try? DLSSMetalFX.install(runtime: runtime, in: current) }
            await update(current) { $0.preparedRuntime = fingerprint }
            log(current.id, "✅ Prefixo atualizado.")
        } catch {
            log(current.id, "⚠️ Falha ao atualizar o prefixo: \(error.localizedDescription)")
        }
    }

    // MARK: DLSS → MetalFX

    func setDLSSMetalFX(_ enabled: Bool, for bottle: Bottle) async {
        guard let runtime = runtime(for: bottle) else { return show(WineError.noRuntimeAvailable) }
        if enabled {
            do {
                let result = try DLSSMetalFX.install(runtime: runtime, in: bottle)
                if !result.missing.isEmpty {
                    errorMessage = "O runtime \(runtime.id) não traz \(result.missing.joined(separator: " e ")). DLSS → MetalFX precisa do Game Porting Toolkit 3 ou mais novo."
                    return
                }
                log(bottle.id, "✨ DLSS → MetalFX ativado (\(result.installed.joined(separator: ", ")) em system32). Ligue o DLSS nas opções do jogo.")
            } catch {
                return show(error)
            }
        } else {
            DLSSMetalFX.uninstall(from: bottle)
        }
        await update(bottle) { $0.dlssMetalFX = enabled }
    }

    // MARK: Modelos de bottle

    /// Cria o bottle e instala os componentes do modelo, um de cada vez.
    func createBottle(name: String, template: BottleTemplate) async {
        var graphics = template.graphics
        if graphics == .d3dMetal && !runtimes.contains(where: { $0.supports(.d3dMetal) }) {
            errorMessage = Self.gptkMissingMessage("O modelo “\(template.name)”")
            return
        }
        if graphics != .wined3d && !runtimes.contains(where: { $0.supports(graphics) }) { graphics = .wined3d }
        var preset = template.preset
        preset.graphics = graphics
        guard let bottle = await createBottle(name: name, windows: template.windows, graphics: graphics, preset: preset) else { return }
        for component in template.windowsComponents {
            installComponent(component, in: bottle)
            await recipeTask?.value
        }
        if !template.components.isEmpty { log(bottle.id, "📦 Modelo “\(template.name)” pronto.") }
    }
}
