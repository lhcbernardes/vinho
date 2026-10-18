import AppKit
import SwiftUI
import WineKit

/// Gerencia runtimes: instalados, variantes com DXMT/DXVK e downloads do catálogo.
struct RuntimesView: View {
    @Environment(AppModel.self) private var model
    @State private var removing: WineRuntime?

    var body: some View {
        @Bindable var model = model

        Form {
            Section("Instalados") {
                if model.runtimes.isEmpty {
                    Text("Nenhum runtime instalado.").foregroundStyle(.secondary)
                } else {
                    Picker("Padrão para novos bottles", selection: $model.defaultRuntimeID) {
                        ForEach(model.runtimes) { Text($0.id).tag(Optional($0.id)) }
                    }
                    ForEach(model.runtimes) { runtime in
                        InstalledRuntimeRow(runtime: runtime) { removing = runtime }
                    }
                }
            }

            Section {
                ForEach(model.catalog.runtimes) { descriptor in
                    CatalogRuntimeRow(descriptor: descriptor)
                }
            } header: {
                Text("Disponíveis para download")
            } footer: {
                Text("Builds do Wine para macOS publicados por Gcenx. Todo download é verificado por SHA-256.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("D3DMetal (Apple GPTK)") {
                    Button("Copiar comando") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("brew install --cask gcenx/wine/game-porting-toolkit", forType: .string)
                    }
                }
            } footer: {
                Text("O D3DMetal é distribuído pela Apple e não pode ser baixado pelo Vinho. Instale o Game Porting Toolkit via Homebrew — ele aparece aqui automaticamente.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Abrir pasta de runtimes") {
                        let dir = RuntimeLocator.managedRuntimesDirectory
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(dir)
                    }
                    Button("Procurar de novo") { Task { await model.refresh() } }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Remover “\(removing?.id ?? "")”?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })
        ) {
            Button("Mover para o Lixo", role: .destructive) {
                if let r = removing { Task { await model.uninstall(r) } }
            }
        }
    }
}

private struct InstalledRuntimeRow: View {
    @Environment(AppModel.self) private var model
    let runtime: WineRuntime
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(runtime.id).font(.body.weight(.medium))
                HStack(spacing: 6) {
                    if let version = model.displayVersion(runtime) {
                        Text(version).foregroundStyle(.secondary)
                    }
                    ForEach(runtime.capabilities.sorted { $0.rawValue < $1.rawValue }, id: \.self) { cap in
                        CapabilityBadge(capability: cap)
                    }
                    if !model.isManaged(runtime) {
                        Text("externo").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
            Spacer()

            let pending = model.catalog.components
                .map { (component: $0, id: RuntimeInstaller.variantID(base: runtime, component: $0)) }
                .first { model.installs[$0.id] != nil }

            if let pending, let progress = model.installs[pending.id] {
                InstallProgressView(progress: progress) { model.cancelInstall(pending.id) }
                    .frame(width: 200)
            } else {
                let components = model.availableComponents(for: runtime)
                if !components.isEmpty {
                    Menu("Adicionar") {
                        ForEach(components) { c in
                            Button("\(c.name) \(c.version)") { model.addComponent(c, to: runtime) }
                        }
                    }
                    .fixedSize()
                    .help("Cria uma variante deste runtime com a camada gráfica (clone APFS, quase sem custo de disco)")
                }
                if model.isManaged(runtime) {
                    Button(role: .destructive, action: onRemove) { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Remover")
                }
            }
        }
        .help(runtime.rootURL.path)
    }
}

private struct CatalogRuntimeRow: View {
    @Environment(AppModel.self) private var model
    let descriptor: RuntimeDescriptor

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(descriptor.name) \(descriptor.version)").font(.body.weight(.medium))
                Text([descriptor.notes, ByteCountFormatter.string(fromByteCount: descriptor.artifact.size, countStyle: .file)]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.isInstalled(descriptor) {
                Label("Instalado", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).labelStyle(.titleAndIcon).font(.callout)
            } else if let progress = model.installs[descriptor.id] {
                InstallProgressView(progress: progress) { model.cancelInstall(descriptor.id) }
                    .frame(width: 200)
            } else {
                Button("Instalar") { model.install(descriptor) }
            }
        }
    }
}

struct CapabilityBadge: View {
    let capability: RuntimeCapability

    private var label: String {
        switch capability {
        case .d3dMetal: "D3DMetal"
        case .dxmt: "DXMT"
        case .dxvk: "DXVK"
        }
    }

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.purple.opacity(0.15), in: Capsule())
            .foregroundStyle(.purple)
    }
}

struct InstallProgressView: View {
    let progress: InstallProgress
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                if let fraction = progress.fraction, progress.phase == .downloading {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                Text(progress.label).font(.caption2).foregroundStyle(.secondary)
            }
            Button(action: onCancel) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Cancelar")
        }
    }
}
