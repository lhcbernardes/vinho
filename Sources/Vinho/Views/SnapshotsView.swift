import SwiftUI
import WineKit

struct SnapshotsView: View {
    @Environment(AppModel.self) private var model
    let bottle: Bottle

    @State private var newLabel = ""
    @State private var restoring: BottleSnapshot?

    private var snapshots: [BottleSnapshot] { model.snapshots[bottle.id] ?? [] }

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            HStack {
                TextField("Descrição (opcional)", text: $newLabel)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 280)
                Button("Criar snapshot") {
                    let label = newLabel.isEmpty ? "Manual" : newLabel
                    newLabel = ""
                    Task { await model.createSnapshot(bottle, label: label) }
                }
                Spacer()
                Toggle("Automático antes de instaladores", isOn: $model.autoSnapshotInstallers)
                    .toggleStyle(.checkbox)
            }
            .padding(10)
            Divider()

            if snapshots.isEmpty {
                ContentUnavailableView {
                    Label("Nenhum snapshot", systemImage: "camera.metering.unknown")
                } description: {
                    Text("Um snapshot guarda o estado do bottle para você voltar atrás se uma instalação der errado. Usa clone APFS: é instantâneo e quase não ocupa espaço.")
                }
            } else {
                List(snapshots) { snapshot in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(snapshot.label).font(.body.weight(.medium))
                            Text(snapshot.createdAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Restaurar") { restoring = snapshot }
                        Button(role: .destructive) {
                            model.deleteSnapshot(snapshot, in: bottle)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .onAppear { model.loadSnapshots(bottle) }
        .confirmationDialog(
            "Restaurar “\(restoring?.label ?? "")”?",
            isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } })
        ) {
            Button("Restaurar", role: .destructive) {
                if let s = restoring { Task { await model.restore(s, in: bottle) } }
            }
        } message: {
            Text("Os programas do bottle serão fechados e tudo que mudou depois deste snapshot será perdido.")
        }
    }
}
