import AppKit
import SwiftUI
import WineKit

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("Geral", systemImage: "gearshape") }
            RuntimesView()
                .tabItem { Label("Runtimes", systemImage: "shippingbox") }
        }
        .frame(width: 640, height: 520)
    }
}

private struct GeneralSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        Form {
            Section {
                TextField("Repositório (owner/repo)", text: $model.communityRepo,
                          prompt: Text("leandro/vinho"))
                TextField("URL do índice", text: $model.communityIndexURL,
                          prompt: Text("https://raw.githubusercontent.com/<você>/vinho-recipes/main/index.yaml"))
                HStack {
                    Button("Recarregar receitas") { Task { await model.loadRecipes() } }
                    Button("Abrir pasta de receitas") {
                        let dir = RecipeLibrary.userDirectory
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(dir)
                    }
                }
            } header: {
                Text("Comunidade")
            } footer: {
                Text("O repositório recebe os relatórios “Funcionou?” como issues. O índice é um index.yaml com `recipes: [arquivo.yaml, …]` — veja community/ no projeto.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("Bottle padrão", selection: Binding(
                    get: { model.defaultBottle?.id },
                    set: { id in model.setDefault(model.bottles.first { $0.id == id }) }
                )) {
                    Text("Perguntar sempre").tag(Bottle.ID?.none)
                    ForEach(model.bottles) { Text($0.name).tag(Optional($0.id)) }
                }
            } header: {
                Text("Abrir pelo Finder")
            } footer: {
                Text("Clique com o botão direito num .exe, .msi ou .lnk ▸ Abrir com ▸ Vinho. Com um bottle padrão, ele roda direto; sem, o Vinho pergunta.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Atualizações") {
                Toggle("Procurar atualizações automaticamente (1× por dia)", isOn: $model.autoCheckUpdates)
                LabeledContent("Versão", value: AppModel.vinhoVersion)
                Button("Procurar agora") { Task { await model.checkForUpdates(userInitiated: true) } }
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
    }
}
