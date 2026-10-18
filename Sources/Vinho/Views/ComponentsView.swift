import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WineKit

// MARK: - Componentes do Windows

struct ComponentsView: View {
    @Environment(AppModel.self) private var model
    let bottle: Bottle

    var body: some View {
        let suggested = Set(model.missingComponentSuggestions(for: bottle).map(\.id))
        Form {
            if !WinetricksManager.cabextractAvailable {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Falta o cabextract (usado para extrair os instaladores da Microsoft).")
                            Text("brew install cabextract").font(.system(.caption, design: .monospaced))
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    }
                    Button("Copiar comando") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("brew install cabextract", forType: .string)
                    }
                }
            }
            ForEach(WindowsComponent.Group.allCases, id: \.self) { group in
                let items = WindowsComponents.all.filter { $0.group == group }
                if !items.isEmpty {
                    Section(group.rawValue) {
                        ForEach(items) { component in
                            row(component, suggested: suggested.contains(component.id))
                        }
                    }
                }
            }
            Section {
                Text("Wine Mono vem do GitHub com SHA-256 verificado. Os demais usam o winetricks \(WinetricksManager.version) (baixado e verificado pelo Vinho), que baixa os instaladores oficiais da Microsoft. Um snapshot é criado antes de cada instalação.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func row(_ component: WindowsComponent, suggested: Bool) -> some View {
        let installed = model.isComponentInstalled(component, in: bottle)
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(component.name)
                    if suggested && !installed {
                        Text("sugerido pelo log")
                            .font(.caption2).padding(.horizontal, 6).padding(.vertical, 1)
                            .background(.orange.opacity(0.15), in: Capsule()).foregroundStyle(.orange)
                    }
                }
                Text(component.summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if installed {
                Label("Instalado", systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly).foregroundStyle(.green)
                    .help("Instalado. Clique em Reinstalar para repetir.")
                Button("Reinstalar") { model.installComponent(component, in: bottle) }
                    .buttonStyle(.borderless)
                    .disabled(model.recipeRun != nil)
            } else {
                Button("Instalar") { model.installComponent(component, in: bottle) }
                    .disabled(model.recipeRun != nil)
            }
        }
    }
}

/// Aviso quando o log mostra DLLs faltando que um componente resolve.
struct MissingComponentsBanner: View {
    @Environment(AppModel.self) private var model
    let bottle: Bottle

    var body: some View {
        let suggestions = model.missingComponentSuggestions(for: bottle)
        if let first = suggestions.first, model.recipeRun == nil {
            HStack {
                Image(systemName: "puzzlepiece.extension.fill").foregroundStyle(.orange)
                Text(suggestions.count == 1
                     ? "O programa procurou uma DLL que falta. Instalar \(first.name) deve resolver."
                     : "O programa procurou DLLs que faltam: \(suggestions.map(\.name).joined(separator: ", ")).")
                    .lineLimit(2)
                Spacer()
                Button(suggestions.count == 1 ? "Instalar" : "Instalar todos") {
                    // Um por vez: o próximo começa quando o anterior termina.
                    Task {
                        for component in suggestions {
                            model.installComponent(component, in: bottle)
                            await model.recipeTask?.value
                        }
                    }
                }
            }
            .padding(10)
            .background(.orange.opacity(0.10))
        }
    }
}

// MARK: - Abrir com…

struct OpenWithSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: OpenRequest
    @State private var chosen: Bottle.ID?
    @State private var always = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Abrir “\(request.url.lastPathComponent)”").font(.title3.bold())
                Text("Em qual bottle?").foregroundStyle(.secondary)
            }
            List(model.bottles, selection: $chosen) { bottle in
                Label(bottle.name, systemImage: "wineglass").tag(bottle.id)
            }
            .frame(minHeight: 160)
            Toggle("Usar sempre este bottle para arquivos abertos pelo Finder", isOn: $always)
            HStack {
                Button("Novo bottle…") {
                    dismiss()
                    model.isCreatingBottle = true
                }
                Spacer()
                Button("Cancelar", role: .cancel) { model.openRequest = nil; dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Abrir") {
                    if let bottle = model.bottles.first(where: { $0.id == chosen }) {
                        model.open(request, in: bottle, always: always)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { chosen = model.selection ?? model.bottles.first?.id }
    }
}

// MARK: - Executar comando

struct RunCommandSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let bottle: Bottle

    @State private var program = ""
    @State private var arguments = ""
    @State private var saveShortcut = false
    @State private var shortcutName = ""
    @State private var picking = false

    private static let types: [UTType] = ["exe", "msi", "bat", "lnk"].compactMap { UTType(filenameExtension: $0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Executar comando em “\(bottle.name)”").font(.title3.bold())
            Form {
                HStack {
                    TextField("Programa", text: $program, prompt: Text(verbatim: #"C:\Games\jogo.exe ou regedit"#))
                    Button("Escolher…") { picking = true }
                }
                TextField("Argumentos", text: $arguments, prompt: Text(verbatim: #"-windowed "-config=C:\meu arquivo.cfg""#))
                Toggle("Salvar como atalho na grade", isOn: $saveShortcut)
                if saveShortcut {
                    TextField("Nome do atalho", text: $shortcutName)
                }
                if !arguments.isEmpty {
                    LabeledContent("Argumentos lidos") {
                        Text(CommandLineSplitter.split(arguments).map { "[\($0)]" }.joined(separator: " "))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Text("Use aspas para argumentos com espaço.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancelar", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Executar") {
                    let (p, a, n) = (program, arguments, saveShortcut ? shortcutName : nil)
                    dismiss()
                    Task { await model.runCommand(program: p, arguments: a, in: bottle, saveAs: n) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(program.trimmingCharacters(in: .whitespaces).isEmpty || (saveShortcut && shortcutName.isEmpty))
            }
        }
        .padding(20)
        .frame(width: 560)
        .fileImporter(isPresented: $picking, allowedContentTypes: Self.types.isEmpty ? [.item] : Self.types) { result in
            if case .success(let url) = result {
                program = WindowsPath.from(url, in: bottle)
                if shortcutName.isEmpty { shortcutName = url.deletingPathExtension().lastPathComponent }
            }
        }
    }
}

// MARK: - Atualização

struct UpdateBanner: View {
    @Environment(AppModel.self) private var model
    let release: AppUpdater.Release

    var body: some View {
        HStack {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
            Text("Vinho \(release.version.description) disponível (você tem \(AppModel.vinhoVersion)).")
            Spacer()
            Button("Novidades") { NSWorkspace.shared.open(release.pageURL) }
            Button("Depois") { model.availableUpdate = nil }
            Button("Atualizar e reabrir") { model.installUpdate(release) }
                .buttonStyle(.borderedProminent)
        }
        .padding(10)
        .background(.blue.opacity(0.08))
    }
}
