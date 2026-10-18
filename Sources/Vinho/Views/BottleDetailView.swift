import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WineKit

struct BottleDetailView: View {
    @Environment(AppModel.self) private var model
    let bottle: Bottle
    @State private var tab: Tab = .programs

    enum Tab: String, CaseIterable, Identifiable {
        case programs = "Programas"
        case settings = "Configurações"
        case snapshots = "Snapshots"
        case logs = "Logs"
        var id: String { rawValue }
    }

    private static let launchableTypes: [UTType] = ["exe", "msi", "lnk", "bat"]
        .compactMap { UTType(filenameExtension: $0) }

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            header
            GuideBanner(bottle: bottle)
            Divider()
            switch tab {
            case .programs: ProgramsGrid(bottle: bottle)
            case .settings: BottleSettingsForm(bottle: bottle)
            case .snapshots: SnapshotsView(bottle: bottle)
            case .logs: LogConsole(bottle: bottle)
            }
        }
        .navigationTitle(bottle.name)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Seção", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            ToolbarItemGroup {
                Button { model.isPickingProgram = true } label: {
                    Label("Executar…", systemImage: "play.fill")
                }
                .help("Executar um .exe, .msi ou .lnk neste bottle")

                if Steam.isInstalled(in: bottle) {
                    Button { model.guide = GuideState(kind: .steam, bottleID: bottle.id) } label: {
                        Label("Guia da Steam", systemImage: "list.bullet.clipboard")
                    }
                    .help("Próximos passos: login, biblioteca compartilhada e dicas")
                }

                Menu {
                    Button("Configuração do Wine (winecfg)") { model.runTool("winecfg", in: bottle) }
                    Button("Editor de Registro") { model.runTool("regedit", in: bottle) }
                    Button("Gerenciador de Tarefas") { model.runTool("taskmgr", in: bottle) }
                    Button("Painel de Controle") { model.runTool("control", in: bottle) }
                    Button("Prompt de Comando") { model.runTool("wineconsole", in: bottle) }
                    Divider()
                    Button("Abrir drive C: no Finder") { model.openDriveC(bottle) }
                    Divider()
                    Button("Encerrar todos os processos") { Task { await model.killAllInSelectedBottle() } }
                } label: {
                    Label("Ferramentas", systemImage: "wrench.and.screwdriver")
                }
            }
        }
        .fileImporter(isPresented: $model.isPickingProgram, allowedContentTypes: Self.launchableTypes.isEmpty ? [.item] : Self.launchableTypes) { result in
            if case .success(let url) = result {
                model.launch(url, in: bottle)
                tab = .logs
            }
        }
        .sheet(item: $model.reporting) { program in
            ReportCompatibilitySheet(program: program, bottle: bottle)
        }
        .dropDestination(for: URL.self) { urls, _ in
            let launchable = urls.filter { ["exe", "msi", "lnk", "bat"].contains($0.pathExtension.lowercased()) }
            launchable.forEach { model.launch($0, in: bottle) }
            if !launchable.isEmpty { tab = .logs }
            return !launchable.isEmpty
        }
    }

    private var header: some View {
        let runtime = model.runtime(for: bottle)
        return HStack(spacing: 16) {
            Image(systemName: "wineglass.fill")
                .font(.system(size: 30))
                .foregroundStyle(.purple.gradient)
            VStack(alignment: .leading, spacing: 4) {
                Text(bottle.name).font(.title2.bold())
                HStack(spacing: 8) {
                    Tag(bottle.settings.windowsVersion.displayName)
                    Tag(bottle.settings.graphics.displayName,
                        warning: runtime.map { !$0.supports(bottle.settings.graphics) } ?? false)
                    Tag(runtime?.displayName ?? "sem runtime", warning: runtime == nil)
                }
            }
            Spacer()
            Text("Arraste um instalador .exe aqui")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

private struct Tag: View {
    let text: String
    var warning = false
    init(_ text: String, warning: Bool = false) { self.text = text; self.warning = warning }

    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background((warning ? Color.orange : Color.secondary).opacity(0.15), in: Capsule())
            .foregroundStyle(warning ? .orange : .secondary)
    }
}

// MARK: - Programas

private struct ProgramsGrid: View {
    @Environment(AppModel.self) private var model
    let bottle: Bottle

    var body: some View {
        if model.programs.isEmpty {
            ContentUnavailableView {
                Label("Nenhum programa instalado", systemImage: "square.dashed")
            } description: {
                Text("Arraste um instalador para esta janela ou use “Executar…”.")
            }
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 16)], spacing: 16) {
                    ForEach(model.programs) { program in
                        Button { model.launch(program, in: bottle) } label: {
                            VStack(spacing: 8) {
                                ProgramIconView(program: program, bottle: bottle)
                                    .overlay(alignment: .topTrailing) {
                                        if let rating = model.rating(for: program, in: bottle) {
                                            Text(rating.symbol).font(.caption).offset(x: 4, y: -4)
                                                .help(rating.displayName)
                                        }
                                    }
                                Text(program.name)
                                    .font(.callout)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(([WindowsPath.from(program.url, in: bottle)] + program.arguments).joined(separator: " "))
                        .contextMenu {
                            Button("Executar") { model.launch(program, in: bottle) }
                            if program.kind == .custom {
                                Button("Remover atalho") { Task { await model.removeShortcut(program, from: bottle) } }
                            } else {
                                Button("Fixar") { Task { await model.pin(program.url, in: bottle) } }
                            }
                            Button("Criar atalho no Launchpad") { model.createShortcut(for: program, in: bottle) }
                            Divider()
                            Button("Funcionou? Avaliar…") { model.reporting = program }
                            Button("Mostrar no Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([program.url])
                            }
                        }
                    }
                }
                .padding()
            }
        }
    }
}

// MARK: - Configurações

private struct BottleSettingsForm: View {
    @Environment(AppModel.self) private var model
    let bottle: Bottle

    private func binding<T>(_ keyPath: WritableKeyPath<BottleSettings, T>) -> Binding<T> {
        Binding(
            get: { bottle.settings[keyPath: keyPath] },
            set: { newValue in Task { await model.update(bottle) { $0[keyPath: keyPath] = newValue } } }
        )
    }

    var body: some View {
        let runtime = model.runtime(for: bottle)
        Form {
            Section("Windows") {
                Picker("Versão", selection: binding(\.windowsVersion)) {
                    ForEach(WindowsVersion.allCases) { Text($0.displayName).tag($0) }
                }
            }

            Section {
                Picker("Backend gráfico", selection: binding(\.graphics)) {
                    ForEach(GraphicsBackend.allCases) { backend in
                        let ok = model.runtimes.contains { $0.supports(backend) }
                        Text(ok ? backend.displayName : "\(backend.displayName) (indisponível)")
                            .tag(backend)
                    }
                }
                Text(bottle.settings.graphics.summary).font(.caption).foregroundStyle(.secondary)
                if let runtime, !runtime.supports(bottle.settings.graphics) {
                    Text("O runtime atual não inclui \(bottle.settings.graphics.displayName). Adicione-o em Ajustes ▸ Runtimes.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Toggle("HUD de performance (Metal)", isOn: binding(\.metalHUD))
                Toggle("Modo Retina (alta resolução)", isOn: binding(\.retinaMode))
            } header: {
                Text("Gráficos")
            }

            Section("Desempenho e diagnóstico") {
                Picker("Sincronização", selection: binding(\.sync)) {
                    ForEach(SyncMode.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("Log do Wine", selection: binding(\.logLevel)) {
                    ForEach(WineLogLevel.allCases) { Text($0.displayName).tag($0) }
                }
            }

            Section("Runtime") {
                Picker("Wine", selection: binding(\.runtimeID)) {
                    Text("Padrão (\(model.defaultRuntime?.id ?? "—"))").tag(String?.none)
                    ForEach(model.runtimes) { Text($0.displayName).tag(Optional($0.id)) }
                }
                LabeledContent("Prefixo", value: bottle.url.path)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Logs

private struct LogConsole: View {
    @Environment(AppModel.self) private var model
    let bottle: Bottle
    @State private var filter = ""

    private var lines: [LogLine] {
        let all = model.logs[bottle.id] ?? []
        guard !filter.isEmpty else { return all }
        return all.filter { $0.text.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Filtrar", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Spacer()
                Button("Copiar") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(lines.map(\.text).joined(separator: "\n"), forType: .string)
                }
                Button("Limpar") { model.clearLogs(bottle) }
            }
            .padding(8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(lines) { line in
                            Text(line.text)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(color(line.source))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .id(line.id)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: lines.last?.id) { _, last in
                    if let last { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private func color(_ source: LogLine.Source) -> Color {
        switch source {
        case .stdout: .primary
        case .stderr: .orange
        case .vinho: .purple
        }
    }
}
