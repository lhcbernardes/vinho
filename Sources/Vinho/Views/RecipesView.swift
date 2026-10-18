import AppKit
import SwiftUI
import WineKit

/// Catálogo de receitas: escolher um app/jogo e instalar com um clique.
struct RecipesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var search = ""
    @State private var category: Recipe.Category?
    @State private var confirming: RecipeEntry?

    private var filtered: [RecipeEntry] {
        model.recipes.filter { entry in
            (category == nil || entry.recipe.category == category)
                && (search.isEmpty
                    || entry.recipe.name.localizedCaseInsensitiveContains(search)
                    || (entry.recipe.summary ?? "").localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Receitas").font(.title2.bold())
                Spacer()
                Picker("Categoria", selection: $category) {
                    Text("Todas").tag(Recipe.Category?.none)
                    ForEach(Recipe.Category.allCases, id: \.self) { Text($0.displayName).tag(Optional($0)) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                TextField("Buscar", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
            }
            .padding()

            Divider()

            if filtered.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                List(filtered) { entry in
                    RecipeRow(entry: entry) { confirming = entry }
                }
            }

            if !model.recipeErrors.isEmpty {
                DisclosureGroup("\(model.recipeErrors.count) receita(s) com problema") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(model.recipeErrors, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            }

            Divider()
            HStack {
                Button("Importar receita…") { model.importRecipe() }
                Button("Abrir pasta de receitas") {
                    let dir = RecipeLibrary.userDirectory
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(dir)
                }
                Button("Recarregar") { Task { await model.loadRecipes() } }
                Spacer()
                Button("Fechar") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(width: 720, height: 560)
        .task { await model.loadRecipes() }
        .sheet(item: $confirming) { entry in
            InstallRecipeSheet(entry: entry)
        }
    }
}

private struct RecipeRow: View {
    let entry: RecipeEntry
    let onInstall: () -> Void

    var body: some View {
        let recipe = entry.recipe
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon(recipe.category))
                .font(.title2)
                .frame(width: 36, height: 36)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(recipe.name).font(.headline)
                    Badge(entry.source.label, color: .secondary)
                    if recipe.isVerified {
                        Badge("SHA-256 ✓", color: .green)
                    } else {
                        Badge("não verificada", color: .orange)
                    }
                    if recipe.needsWinetricks { Badge("winetricks", color: .blue) }
                }
                if let summary = recipe.summary { Text(summary).foregroundStyle(.secondary) }
                HStack(spacing: 8) {
                    if let g = recipe.bottle?.graphics { Text(g.displayName) }
                    if let w = recipe.bottle?.windows { Text(w.displayName) }
                    Text("\(recipe.steps.count) passo(s)")
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Instalar", action: onInstall)
                .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 4)
    }

    private func icon(_ category: Recipe.Category) -> String {
        switch category {
        case .app: "app.dashed"
        case .game: "gamecontroller"
        case .tool: "wrench.and.screwdriver"
        }
    }
}

private struct Badge: View {
    let text: String
    let color: Color
    init(_ text: String, color: Color) { self.text = text; self.color = color }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

/// Confirma destino (bottle novo ou existente) e mostra o que vai rodar.
private struct InstallRecipeSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let entry: RecipeEntry
    @State private var target: Bottle.ID?

    var body: some View {
        let recipe = entry.recipe
        VStack(alignment: .leading, spacing: 14) {
            Text("Instalar \(recipe.name)").font(.title3.bold())

            Picker("Onde", selection: $target) {
                Text("Novo bottle “\(recipe.name)”").tag(Bottle.ID?.none)
                ForEach(model.bottles) { Text($0.name).tag(Optional($0.id)) }
            }

            GroupBox("Passos") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(recipe.steps.enumerated()), id: \.offset) { i, step in
                        Text("\(i + 1). \(step.title)").font(.system(.callout, design: .monospaced))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !recipe.isVerified {
                Label("Algum download desta receita não tem SHA-256: o arquivo baixado não pode ser verificado.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.callout)
            }
            if case .community = entry.source {
                Label("Receita da comunidade: ela executa instaladores do Windows no bottle escolhido.",
                      systemImage: "person.3.fill")
                    .foregroundStyle(.secondary).font(.callout)
            }

            HStack {
                Spacer()
                Button("Cancelar", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Instalar") {
                    let bottle = model.bottles.first { $0.id == target }
                    dismiss()
                    model.install(entry, into: bottle)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.runtimes.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// Barra de progresso da receita em andamento.
struct RecipeProgressBanner: View {
    @Environment(AppModel.self) private var model
    let state: RecipeRunState

    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("Instalando \(state.recipeName)").font(.callout.weight(.semibold))
                Text(state.step).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let fraction = state.fraction {
                    ProgressView(value: fraction).frame(maxWidth: 260)
                }
            }
            Spacer()
            Button("Cancelar") { model.cancelRecipe() }
        }
        .padding(10)
        .background(.purple.opacity(0.1))
    }
}
