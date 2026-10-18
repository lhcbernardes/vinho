import SwiftUI
import WineKit

struct NewBottleSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var windows: WindowsVersion = .win10
    @State private var graphics: GraphicsBackend = .dxmt

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var nameTaken: Bool {
        model.bottles.contains { $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame }
    }

    var body: some View {
        let runtime = model.defaultRuntime
        VStack(alignment: .leading, spacing: 16) {
            Text("Novo Bottle").font(.title2.bold())

            Form {
                TextField("Nome", text: $name, prompt: Text("ex.: Steam, Office, Jogos"))
                if nameTaken {
                    Text("Já existe um bottle com esse nome.").font(.caption).foregroundStyle(.red)
                }
                Picker("Windows", selection: $windows) {
                    ForEach(WindowsVersion.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("Gráficos", selection: $graphics) {
                    ForEach(GraphicsBackend.allCases) { backend in
                        Text(backend.displayName).tag(backend)
                    }
                }
                Text(graphics.summary).font(.caption).foregroundStyle(.secondary)
                if let runtime, !runtime.supports(graphics) {
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
                    let (n, w, g) = (trimmedName, windows, graphics)
                    dismiss()
                    Task { await model.createBottle(name: n, windows: w, graphics: g) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty || nameTaken || runtime == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            if let runtime, !runtime.supports(graphics) {
                graphics = GraphicsBackend.allCases.first(where: runtime.supports) ?? .wined3d
            }
        }
    }
}
