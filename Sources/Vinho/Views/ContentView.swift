import AppKit
import SwiftUI
import WineKit

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            BottleSidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            if model.runtimes.isEmpty {
                RuntimeMissingView()
            } else if let bottle = model.selectedBottle {
                BottleDetailView(bottle: bottle)
                    .id(bottle.id)
            } else {
                ContentUnavailableView {
                    Label("Nenhum bottle", systemImage: "wineglass")
                } description: {
                    Text("Um bottle é um “Windows” isolado onde você instala programas.")
                } actions: {
                    Button("Criar Bottle") { model.isCreatingBottle = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if model.rosettaMissing { RosettaBanner() }
        }
        .overlay {
            if let message = model.busyMessage {
                BusyOverlay(message: message)
            }
        }
        .sheet(isPresented: $model.isCreatingBottle) {
            NewBottleSheet()
        }
        .alert(
            "Algo deu errado",
            isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onChange(of: model.selection) { model.rescanPrograms() }
    }
}

private struct BottleSidebar: View {
    @Environment(AppModel.self) private var model
    @State private var renaming: Bottle?
    @State private var newName = ""
    @State private var deleting: Bottle?

    var body: some View {
        @Bindable var model = model

        List(selection: $model.selection) {
            Section("Bottles") {
                ForEach(model.bottles) { bottle in
                    HStack {
                        Label(bottle.name, systemImage: "wineglass")
                        Spacer()
                        if (model.runningCount[bottle.id] ?? 0) > 0 {
                            Circle().fill(.green).frame(width: 7, height: 7)
                                .help("Processos em execução")
                        }
                    }
                    .tag(bottle.id)
                    .contextMenu {
                        Button("Renomear…") { newName = bottle.name; renaming = bottle }
                        Button("Mostrar no Finder") { NSWorkspace.shared.activateFileViewerSelecting([bottle.url]) }
                        Divider()
                        Button("Apagar…", role: .destructive) { deleting = bottle }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button { model.isCreatingBottle = true } label: { Label("Novo Bottle", systemImage: "plus") }
                    .disabled(model.runtimes.isEmpty)
            }
        }
        .alert("Renomear bottle", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Nome", text: $newName)
            Button("Renomear") {
                if let b = renaming { Task { await model.rename(b, to: newName) } }
            }
            Button("Cancelar", role: .cancel) {}
        }
        .confirmationDialog(
            "Apagar “\(deleting?.name ?? "")”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            Button("Mover para o Lixo", role: .destructive) {
                if let b = deleting { Task { await model.delete(b) } }
            }
        } message: {
            Text("Todos os programas instalados neste bottle serão movidos para o Lixo.")
        }
    }
}

private struct BusyOverlay: View {
    let message: String
    var body: some View {
        ZStack {
            Color.black.opacity(0.15).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                Text(message).multilineTextAlignment(.center)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

private struct RosettaBanner: View {
    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text("O Rosetta 2 não está instalado. Ele é necessário para rodar o Wine no Apple Silicon.")
            Spacer()
            Button("Copiar comando") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(SystemCheck.rosettaInstallCommand, forType: .string)
            }
        }
        .padding(10)
        .background(.yellow.opacity(0.12))
    }
}

struct RuntimeMissingView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let recommended = model.catalog.recommendedRuntime
        ContentUnavailableView {
            Label("Nenhum runtime Wine instalado", systemImage: "shippingbox")
        } description: {
            VStack(spacing: 10) {
                Text("O Vinho precisa de um build do Wine para rodar programas do Windows.")
                if let recommended {
                    Text("Recomendado: \(recommended.name) \(recommended.version) · \(ByteCountFormatter.string(fromByteCount: recommended.artifact.size, countStyle: .file))")
                        .foregroundStyle(.secondary)
                }
                if let recommended, let progress = model.installs[recommended.id] {
                    InstallProgressView(progress: progress) { model.cancelInstall(recommended.id) }
                        .frame(width: 320)
                }
            }
        } actions: {
            HStack {
                if let recommended, model.installs[recommended.id] == nil {
                    Button("Baixar e instalar") { model.install(recommended) }
                        .buttonStyle(.borderedProminent)
                }
                Button("Outras opções…") { openSettings() }
                Button("Procurar de novo") { Task { await model.refresh() } }
            }
        }
    }
}
