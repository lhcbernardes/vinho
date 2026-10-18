import AppKit
import SwiftUI
import WineKit

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Form {
            Section("Runtimes Wine") {
                if model.runtimes.isEmpty {
                    Text("Nenhum runtime encontrado.").foregroundStyle(.secondary)
                } else {
                    Picker("Padrão para novos bottles", selection: $model.defaultRuntimeID) {
                        ForEach(model.runtimes) { Text($0.displayName).tag(Optional($0.id)) }
                    }
                    ForEach(model.runtimes) { runtime in
                        LabeledContent(runtime.displayName) {
                            Text(runtime.capabilities.isEmpty
                                 ? "WineD3D apenas"
                                 : runtime.capabilities.map(\.rawValue).sorted().joined(separator: " · "))
                                .foregroundStyle(.secondary)
                        }
                        .help(runtime.rootURL.path)
                    }
                }
                HStack {
                    Button("Abrir pasta de runtimes") {
                        let dir = RuntimeLocator.managedRuntimesDirectory
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(dir)
                    }
                    Button("Procurar de novo") { Task { await model.refresh() } }
                }
            }

            Section("Armazenamento") {
                LabeledContent("Bottles", value: VinhoPaths.bottles.path)
                    .textSelection(.enabled)
                Button("Abrir no Finder") {
                    try? FileManager.default.createDirectory(at: VinhoPaths.bottles, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(VinhoPaths.bottles)
                }
            }

            Section("Sistema") {
                LabeledContent("Rosetta 2") {
                    if !SystemCheck.needsRosetta {
                        Text("não necessário (Intel)")
                    } else if SystemCheck.isRosettaInstalled {
                        Label("instalado", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Label("ausente", systemImage: "xmark.circle.fill").foregroundStyle(.red)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 420)
    }
}
