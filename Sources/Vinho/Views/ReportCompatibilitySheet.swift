import SwiftUI
import WineKit

/// "Funcionou?" — avalia um programa e gera um relatório para a comunidade.
struct ReportCompatibilitySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let program: Program
    let bottle: Bottle

    @State private var rating: CompatibilityRating = .playable
    @State private var notes = ""
    @State private var showPreview = false

    private var report: CompatibilityReport {
        model.makeReport(for: program, in: bottle, rating: rating, notes: notes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(program.name) funcionou?").font(.title3.bold())

            Picker("Avaliação", selection: $rating) {
                ForEach(CompatibilityRating.allCases) { Text("\($0.symbol) \($0.displayName)").tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text("Observações (desempenho, falhas, ajustes que ajudaram)").font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $notes)
                .font(.body)
                .frame(height: 110)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

            DisclosureGroup("Pré-visualizar relatório", isExpanded: $showPreview) {
                ScrollView {
                    Text(report.markdown)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 160)
            }

            Text("O relatório inclui versão do macOS, chip, runtime e configurações do bottle — nenhum caminho de arquivo ou nome de usuário. Nada é enviado sem você confirmar no GitHub.")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Button("Copiar Markdown") { model.copyReport(report) }
                Spacer()
                Button("Cancelar", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Salvar só aqui") {
                    let r = report
                    dismiss()
                    Task { await model.submit(r, program: program, in: bottle, openGitHub: false) }
                }
                Button("Enviar no GitHub…") {
                    let r = report
                    dismiss()
                    Task { await model.submit(r, program: program, in: bottle, openGitHub: true) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.communityRepo.trimmingCharacters(in: .whitespaces).isEmpty)
                .help(model.communityRepo.isEmpty ? "Configure o repositório em Ajustes ▸ Geral" : "Abre uma issue pré-preenchida em \(model.communityRepo)")
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            if let existing = model.rating(for: program, in: bottle) { rating = existing }
        }
    }
}
