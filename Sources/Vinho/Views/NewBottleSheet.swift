import SwiftUI
import WineKit

struct NewBottleSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var templateID = "apps"
    @State private var windows: WindowsVersion = .win10
    @State private var graphics: GraphicsBackend = .wined3d

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var nameTaken: Bool {
        model.bottles.contains { $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame }
    }
    private var template: BottleTemplate {
        BottleTemplate.all.first { $0.id == templateID } ?? BottleTemplate.all[0]
    }

    var body: some View {
        let runtime = model.defaultRuntime
        VStack(alignment: .leading, spacing: 16) {
            Text("Novo Bottle").font(.title2.bold())

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
                ForEach(BottleTemplate.all) { t in
                    let available = t.requiredBackend.map { b in model.runtimes.contains { $0.supports(b) } } ?? true
                    Button { choose(t) } label: {
                        VStack(spacing: 6) {
                            Image(systemName: t.symbol).font(.title2)
                            Text(t.name).font(.callout.bold()).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, minHeight: 64)
                        .padding(8)
                        .background(templateID == t.id ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08),
                                    in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .stroke(templateID == t.id ? Color.accentColor : .clear, lineWidth: 1.5))
                        .opacity(available ? 1 : 0.5)
                    }
                    .buttonStyle(.plain)
                    .help(available ? t.summary : "\(t.summary) — precisa do Game Porting Toolkit.")
                }
            }

            Form {
                TextField("Nome", text: $name, prompt: Text(verbatim: "ex.: \(template.name)"))
                if nameTaken {
                    Text("Já existe um bottle com esse nome.").font(.caption).foregroundStyle(.red)
                }
                Text(template.summary).font(.caption).foregroundStyle(.secondary)
                if !template.windowsComponents.isEmpty {
                    LabeledContent("Instala depois", value: template.windowsComponents.map(\.name).joined(separator: ", "))
                        .font(.caption)
                }
                Picker("Windows", selection: $windows) {
                    ForEach(WindowsVersion.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("Gráficos", selection: $graphics) {
                    ForEach(GraphicsBackend.allCases) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
                if let runtime, !model.runtimes.contains(where: { $0.supports(graphics) }) {
                    Text("\(runtime.id) não inclui \(graphics.displayName); o bottle usará WineD3D.")
                        .font(.caption).foregroundStyle(.orange)
                }
                LabeledContent("Runtime", value: runtime?.displayName ?? "nenhum")
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancelar", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Criar") {
                    let n = trimmedName.isEmpty ? template.name : trimmedName
                    let t = BottleTemplate(id: template.id, name: template.name, summary: template.summary,
                                           symbol: template.symbol, windows: windows, graphics: graphics,
                                           sync: template.sync, components: template.components)
                    dismiss()
                    Task { await model.createBottle(name: n, template: t) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(nameTaken || runtime == nil
                          || model.bottles.contains { $0.name.caseInsensitiveCompare(template.name) == .orderedSame } && trimmedName.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { choose(template) }
    }

    private func choose(_ t: BottleTemplate) {
        templateID = t.id
        windows = t.windows
        graphics = model.runtimes.contains { $0.supports(t.graphics) } ? t.graphics : .wined3d
    }
}
