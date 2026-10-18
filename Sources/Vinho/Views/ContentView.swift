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
    private let brew = "brew install --cask gcenx/wine/game-porting-toolkit"

    var body: some View {
        ContentUnavailableView {
            Label("Nenhum runtime Wine encontrado", systemImage: "shippingbox")
        } description: {
            VStack(alignment: .leading, spacing: 8) {
                Text("O Vinho precisa de um build do Wine. Opções:")
                Text("• Para jogos (D3DMetal), instale o Game Porting Toolkit via Homebrew:")
                Text(brew).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                Text("• Para apps em geral, rode scripts/install-runtime.sh no projeto (Wine 11), ou coloque um runtime em ~/Library/Application Support/Vinho/Runtimes/<nome>/.")
            }
            .frame(maxWidth: 520, alignment: .leading)
        } actions: {
            HStack {
                Button("Copiar comando") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(brew, forType: .string)
                }
                Button("Procurar de novo") { Task { await model.refresh() } }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}
