import SwiftUI
import WineKit

/// "Próximos passos": checklist que se atualiza sozinho lendo o bottle.
struct GuideView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let state: GuideState

    private var title: String {
        switch state.kind {
        case .steam: return "Steam: próximos passos"
        case .game(let id): return "\(model.recipe(withID: id)?.name ?? "Jogo"): próximos passos"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "list.bullet.clipboard").font(.title2).foregroundStyle(.purple)
                Text(title).font(.title3.bold())
                Spacer()
            }
            .padding()

            Divider()

            // Reavalia a cada 2 s: login, biblioteca e download se marcam sozinhos.
            TimelineView(.periodic(from: .now, by: 2)) { _ in
                let items = model.guideItems(for: state)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            GuideRow(number: index + 1, item: item) { action in
                                model.perform(action, bottleID: state.bottleID)
                            }
                        }
                    }
                    .padding()
                }
            }

            Divider()
            HStack {
                Button("Abrir pasta da biblioteca compartilhada") {
                    model.perform(.revealFolder(VinhoPaths.sharedSteamLibrary), bottleID: state.bottleID)
                }
                Spacer()
                Button("Fechar") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 560, height: 560)
    }
}

private struct GuideRow: View {
    let number: Int
    let item: GuideItem
    let perform: (GuideItem.Action) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon
                .font(.title3)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.body.weight(.semibold))
                    .strikethrough(item.status == .done, color: .secondary)
                    .foregroundStyle(item.status == .done ? .secondary : .primary)
                Text(item.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let action = item.action, let label = item.actionLabel, item.status != .done {
                    Button(label) { perform(action) }
                        .controlSize(.small)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(background, in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private var statusIcon: some View {
        switch item.status {
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .todo: Image(systemName: "\(min(number, 50)).circle").foregroundStyle(.purple)
        case .tip: Image(systemName: "lightbulb").foregroundStyle(.yellow)
        }
    }

    private var background: Color {
        switch item.status {
        case .done: Color.green.opacity(0.06)
        case .todo: Color.purple.opacity(0.08)
        case .tip: Color.secondary.opacity(0.06)
        }
    }
}

/// Aviso no topo do bottle quando há passos pendentes (Steam ou jogos).
struct GuideBanner: View {
    @Environment(AppModel.self) private var model
    let bottle: Bottle

    var body: some View {
        // Recalcula periodicamente para sumir quando tudo estiver feito.
        TimelineView(.periodic(from: .now, by: 5)) { _ in
            let pending = model.pendingGuides(for: bottle)
            if let first = pending.first?.0 {
                let total = pending.reduce(0) { $0 + $1.1 }
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(.purple)
                    Text(total == 1 ? "1 passo pendente para terminar a configuração." : "\(total) passos pendentes para terminar a configuração.")
                        .font(.callout)
                    Spacer()
                    Button("Ver o que fazer") { model.guide = first }
                        .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.purple.opacity(0.08))
            }
        }
    }
}
