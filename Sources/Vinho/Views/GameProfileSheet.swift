import AppKit
import SwiftUI
import WineKit

/// Configurações só de um jogo, dentro da Steam compartilhada.
struct GameProfileSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let editing: ProfileEditing

    @State private var profile = GameProfile(exeName: "")
    @State private var overrideName = ""
    @State private var overrideMode: DLLOverrideMode = .nativeThenBuiltin
    @State private var loaded = false

    private var bottle: Bottle? { model.bottles.first { $0.id == editing.bottleID } }
    private var recipe: Recipe? { model.recipe(withID: editing.profileID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Configurações de \(recipe?.name ?? profile.exeName)").font(.title3.bold())
                Text("Valem só para \(profile.exeName). Os outros jogos da mesma Steam não mudam.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Form {
                Section("Gráficos") {
                    Picker("Renderer do WineD3D", selection: $profile.renderer) {
                        Text("Padrão").tag(WineD3DRenderer?.none)
                        ForEach(WineD3DRenderer.allCases) { Text($0.displayName).tag(Optional($0)) }
                    }
                    Text("Afeta jogos DirectX 9 (e DX10/11 quando não há DXMT/D3DMetal). Vulkan usa o MoltenVK do runtime.")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("Modo Retina", selection: $profile.retina) {
                        Text("Igual ao bottle").tag(Bool?.none)
                        Text("Ligado").tag(Bool?.some(true))
                        Text("Desligado").tag(Bool?.some(false))
                    }
                }

                Section("Overrides de DLL só deste jogo") {
                    ForEach(profile.dllOverrides.keys.sorted(), id: \.self) { dll in
                        HStack {
                            Text(dll).font(.system(.body, design: .monospaced))
                            Spacer()
                            Text(label(profile.dllOverrides[dll] ?? .builtin)).foregroundStyle(.secondary)
                            Button { profile.dllOverrides[dll] = nil } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                        }
                    }
                    HStack {
                        TextField("dll (ex.: xinput1_3)", text: $overrideName)
                            .textFieldStyle(.roundedBorder)
                        Picker("", selection: $overrideMode) {
                            ForEach(DLLOverrideMode.allCases, id: \.self) { Text(label($0)).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Button("Adicionar") {
                            let dll = overrideName.trimmingCharacters(in: .whitespaces).lowercased()
                                .replacingOccurrences(of: ".dll", with: "")
                            guard !dll.isEmpty else { return }
                            profile.dllOverrides[dll] = overrideMode
                            overrideName = ""
                        }
                    }
                }

                Section("Steam") {
                    TextField("Opções de inicialização", text: Binding(
                        get: { profile.launchOptions ?? "" },
                        set: { profile.launchOptions = $0.isEmpty ? nil : $0 }
                    ), prompt: Text("ex.: -vulkan -novid"))
                    HStack {
                        Text("Cole em Steam ▸ \(recipe?.name ?? "jogo") ▸ Propriedades ▸ Opções de inicialização.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Copiar") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(profile.launchOptions ?? "", forType: .string)
                        }
                        .disabled((profile.launchOptions ?? "").isEmpty)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancelar", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Salvar") {
                    let p = profile
                    dismiss()
                    if let bottle { Task { await model.saveProfile(p, id: editing.profileID, in: bottle) } }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(profile.exeName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 540, height: 600)
        .onAppear {
            guard !loaded, let bottle else { return }
            loaded = true
            if let existing = model.profile(editing.profileID, in: bottle) {
                profile = existing
            } else if let fresh = recipe?.game?.makeProfile() {
                profile = fresh
            }
        }
    }

    private func label(_ mode: DLLOverrideMode) -> String {
        switch mode {
        case .native: "nativa"
        case .builtin: "embutida (Wine)"
        case .nativeThenBuiltin: "nativa, depois Wine"
        case .builtinThenNative: "Wine, depois nativa"
        case .disabled: "desativada"
        }
    }
}
