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
                Text("Receitas da comunidade")
            } footer: {
                Text("Um arquivo index.yaml com `recipes: [arquivo.yaml, …]`. Veja community/ no repositório do Vinho.")
                    .font(.caption).foregroundStyle(.secondary)
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
