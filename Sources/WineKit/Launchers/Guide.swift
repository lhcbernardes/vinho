import Foundation

/// Um passo do guia "Próximos passos". O estado é recalculado a partir dos
/// arquivos do bottle, então o checklist se marca sozinho.
public struct GuideItem: Identifiable, Hashable, Sendable {
    public enum Status: Hashable, Sendable { case done, todo, tip }

    public enum Action: Hashable, Sendable {
        /// Abre a Steam (opcionalmente com uma URL steam://).
        case openSteam(String?)
        case copy(String)
        case revealFolder(URL)
        /// Abre o atalho com este nome na grade.
        case launchShortcut(String)
        /// Reaplica as correções da Steam e reinicia ela.
        case fixSteam
        /// Monta a biblioteca compartilhada como drive S: e reabre a Steam.
        case mountSharedLibrary
        /// Abre as configurações do jogo (id da receita).
        case gameSettings(String)
    }

    public let id: String
    public var title: String
    public var detail: String
    public var status: Status
    public var action: Action?
    public var actionLabel: String?

    public init(id: String, title: String, detail: String, status: Status, action: Action? = nil, actionLabel: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.status = status
        self.action = action
        self.actionLabel = actionLabel
    }
}

public enum GuideBuilder {
    /// Passos depois de instalar a Steam num bottle.
    public static func steam(bottle: Bottle, sharedLibrary: URL = VinhoPaths.sharedSteamLibrary) -> [GuideItem] {
        let family = GraphicsFamily(bottle: bottle)
        let installed = Steam.isInstalled(in: bottle)

        return [
            GuideItem(
                id: "steam-installed",
                title: "Steam instalada",
                detail: installed ? "Encontrada em C:\\Program Files (x86)\\Steam." : "Ainda não encontrei a Steam neste bottle.",
                status: installed ? .done : .todo
            ),
            GuideItem(
                id: "steam-fix",
                title: "Correção da tela preta",
                detail: SteamFixes.isWrapperDeployed(in: bottle)
                    ? "Ativa: a interface da Steam usa renderização por software (o CEF não consegue usar a GPU no Wine)."
                    : "Na primeira abertura a Steam se atualiza e a janela pode ficar preta. Quando a atualização terminar, o Vinho aplica a correção e reabre a Steam sozinho — ou clique em Corrigir.",
                status: SteamFixes.isWrapperDeployed(in: bottle) ? .done : .todo,
                action: .fixSteam, actionLabel: "Corrigir e reabrir"
            ),
            GuideItem(
                id: "steam-login",
                title: "Faça login na Steam",
                detail: "Na primeira abertura ela se atualiza sozinha (pode levar alguns minutos) e pede login. Marque “Lembrar senha” para não repetir.",
                status: Steam.isLoggedIn(in: bottle) ? .done : .todo,
                action: .openSteam(nil), actionLabel: "Abrir Steam"
            ),
            GuideItem(
                id: "steam-library",
                title: "Biblioteca compartilhada (drive S:)",
                detail: Steam.hasLibrary(onDrive: Steam.sharedLibraryDrive, in: bottle) || Steam.hasLibrary(sharedLibrary, in: bottle)
                    ? "Pronta: os jogos podem ir para S:\\SteamLibrary (a pasta “\(sharedLibrary.lastPathComponent)” do seu Mac). Na janela de instalação de um jogo, escolha o volume S:."
                    : "O Vinho monta o drive S: e registra a biblioteca na Steam automaticamente quando ela está fechada. Clique para fechar, configurar e reabrir agora.",
                status: Steam.hasLibrary(onDrive: Steam.sharedLibraryDrive, in: bottle) || Steam.hasLibrary(sharedLibrary, in: bottle) ? .done : .todo,
                action: .mountSharedLibrary,
                actionLabel: "Configurar e reabrir a Steam"
            ),
            GuideItem(
                id: "steam-single",
                title: "Uma Steam para todos os jogos",
                detail: family == .dx12
                    ? "Este bottle usa D3DMetal: roda jogos DirectX 9 a 12. Cada jogo tem suas próprias configurações (clique com o botão direito no atalho ▸ Configurações do jogo)."
                    : "Este bottle roda jogos DirectX 9 a 11. Para DirectX 12, instale o Game Porting Toolkit e crie a Steam nele. Cada jogo tem suas próprias configurações (botão direito no atalho ▸ Configurações do jogo).",
                status: .tip
            ),
            GuideItem(
                id: "steam-games",
                title: "Instale jogos pelas Receitas, não pela loja",
                detail: "Pelas Receitas (⇧⌘R) o Vinho escolhe o bottle certo, cria o atalho com ícone e aplica os ajustes do jogo. Pela loja da Steam também funciona, mas sem esses ajustes.",
                status: .tip
            ),
            GuideItem(
                id: "steam-overlay",
                title: "Se um jogo travar ao abrir",
                detail: "Desative a sobreposição: Steam ▸ Configurações ▸ Em jogo ▸ desmarque “Ativar a sobreposição Steam”.",
                status: .tip
            ),
        ]
    }

    /// Passos depois de pedir a instalação de um jogo de loja.
    public static func game(_ recipe: Recipe, bottle: Bottle, sharedLibrary: URL = VinhoPaths.sharedSteamLibrary) -> [GuideItem] {
        guard let game = recipe.game else { return [] }
        let exe = game.exe.flatMap { Steam.gameExecutable($0, in: bottle) }
        let downloaded = exe != nil
        var items = [
            GuideItem(
                id: "game-confirm",
                title: "Confirme a instalação na janela da Steam",
                detail: "A Steam abre a janela “Instalar \(recipe.name)”. Em “Local de instalação” escolha S:\\SteamLibrary (biblioteca compartilhada).",
                status: downloaded ? .done : .todo,
                action: .openSteam(Steam.installURL(appID: game.appid)), actionLabel: "Abrir instalação"
            ),
            GuideItem(
                id: "game-download",
                title: "Aguarde o download terminar",
                detail: downloaded
                    ? "Jogo encontrado. O ícone já aparece no atalho."
                    : "Acompanhe em Steam ▸ Biblioteca ▸ Downloads. Este passo se marca sozinho quando o jogo terminar de baixar.",
                status: downloaded ? .done : .todo
            ),
        ]

        if let options = game.launchOptions, !options.isEmpty {
            items.append(GuideItem(
                id: "game-options",
                title: "Opções de inicialização recomendadas",
                detail: "Na Steam: clique com o botão direito em \(recipe.name) ▸ Propriedades ▸ Geral ▸ Opções de inicialização e cole: \(options)",
                status: .tip,
                action: .copy(options), actionLabel: "Copiar opções"
            ))
        }

        items.append(GuideItem(
            id: "game-settings",
            title: "Configurações só deste jogo",
            detail: "Renderer, Retina e overrides de DLL valem só para \(game.exeName ?? recipe.name) — os outros jogos da mesma Steam não são afetados.",
            status: .tip,
            action: .gameSettings(recipe.id), actionLabel: "Configurar"
        ))

        for (index, tip) in (recipe.guide ?? []).enumerated() {
            items.append(GuideItem(id: "recipe-tip-\(index)", title: "Dica", detail: tip, status: .tip))
        }

        items.append(GuideItem(
            id: "game-play",
            title: "Jogue pelo atalho “\(recipe.launch?.name ?? recipe.name)”",
            detail: "O atalho abre o jogo pela Steam com as configurações do bottle. Depois, use “Funcionou? Avaliar…” para ajudar a comunidade.",
            status: downloaded ? .todo : .tip,
            action: downloaded ? .launchShortcut(recipe.launch?.name ?? recipe.name) : nil,
            actionLabel: downloaded ? "Jogar" : nil
        ))
        return items
    }

    /// Quantos passos ainda dependem do usuário.
    public static func pendingCount(_ items: [GuideItem]) -> Int {
        items.filter { $0.status == .todo && $0.action != nil && !$0.id.hasPrefix("game-play") }.count
    }
}
