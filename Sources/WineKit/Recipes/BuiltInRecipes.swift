/// Receitas que acompanham o app. Mantidas como texto (e não como recursos
/// do pacote) para funcionar igual em `swift run` e no `.app` gerado.
/// Os arquivos equivalentes ficam em `community/recipes/`.
enum BuiltInRecipes {
    static let yaml: [String] = [
        notepadPlusPlus, sevenZip, steam, epicGames, gogGalaxy,
        left4Dead2, portal2, halfLife2, teamFortress2, counterStrike2, ghostOfTsushima,
    ]

    // SHA-256 do campo `digest` da release no GitHub (24/09/2026).
    static let notepadPlusPlus = #"""
    id: notepad-plus-plus
    name: Notepad++
    revision: 1
    category: app
    description: Editor de texto e código leve.
    homepage: https://notepad-plus-plus.org
    bottle:
      windows: win10
      graphics: wined3d
    steps:
      - download:
          url: https://github.com/notepad-plus-plus/notepad-plus-plus/releases/download/v8.9.8.1/npp.8.9.8.1.Installer.x64.exe
          sha256: 26f3bcced788fadbac4e7e577b430ea2ce6060cf3bcad993ef4612ecd7d743da
          file: npp-installer.exe
      - run:
          file: npp-installer.exe
          args: ["/S"]
    launch:
      program: 'C:\Program Files\Notepad++\notepad++.exe'
    """#

    // SHA-256 do campo `digest` da release no GitHub (06/10/2026).
    static let sevenZip = #"""
    id: 7zip
    name: 7-Zip
    revision: 1
    category: tool
    description: Compactador de arquivos (7z, zip, rar…).
    homepage: https://www.7-zip.org
    bottle:
      windows: win10
      graphics: wined3d
    steps:
      - download:
          url: https://github.com/ip7z/7zip/releases/download/26.04/7z2604-x64.exe
          sha256: d54bf805f9f3704d1e8db2fa3498ae7ef2df0312b40b558e7c71c734430a665d
          file: 7zip-installer.exe
      - run:
          file: 7zip-installer.exe
          args: ["/S"]
    launch:
      program: 'C:\Program Files\7-Zip\7zFM.exe'
    """#

    // A Valve não publica hash do SteamSetup.exe e o arquivo muda a cada
    // versão: receita marcada como não verificada.
    static let steam = #"""
    id: steam
    name: Steam
    revision: 3
    category: game
    description: Loja e biblioteca de jogos da Valve.
    provides: [steam]
    homepage: https://store.steampowered.com
    notes: Na primeira abertura a Steam se atualiza; o Vinho aplica a correção da tela preta e reabre a Steam quando terminar.
    bottle:
      windows: win10
      graphics: dxmt
    steps:
      - download:
          url: https://cdn.cloudflare.steamstatic.com/client/installer/SteamSetup.exe
          file: SteamSetup.exe
      - run:
          file: SteamSetup.exe
          args: ["/S"]
    launch:
      program: 'C:\Program Files (x86)\Steam\steam.exe'
    """#

    // Source engine, DirectX 9: D3DMetal e DXMT não cobrem DX9, então o
    // bottle "Steam (DX9–11)" (WineD3D para DX9). O jogo também aceita
    // "-vulkan" (DXVK embutido) como alternativa.
    static let left4Dead2 = #"""
    id: left-4-dead-2
    name: Left 4 Dead 2
    revision: 2
    category: game
    description: Cooperativo de zumbis da Valve (Source engine, DirectX 9).
    homepage: https://store.steampowered.com/app/550/
    game:
      store: steam
      appid: 550
      exe: 'Left 4 Dead 2\left4dead2.exe'
      directx: 9
    guide:
      - O download tem cerca de 13 GB.
      - Se o FPS estiver baixo, teste "-vulkan" nas opções de inicialização (usa o DXVK que vem com o jogo).
      - O multiplayer usa VAC, que costuma funcionar no Wine. Se não conectar, avalie com “Funcionou?” e mande o log.
    """#
    // A Epic não publica hash do instalador (o .msi muda a cada versão).
    // Vai para o bottle de jogos (o mesmo da Steam) para compartilhar ajustes.
    static let epicGames = #"""
    id: epic-games-launcher
    name: Epic Games Launcher
    revision: 1
    category: game
    description: Loja e biblioteca de jogos da Epic.
    provides: [epic]
    homepage: https://store.epicgames.com
    notes: O Vinho abre a Epic com -opengl (a interface fica preta sem isso no Wine). Jogos com anti-cheat do kernel (Fortnite) não funcionam.
    bottle:
      windows: win10
      graphics: dxmt
    steps:
      - download:
          url: https://launcher-public-service-prod06.ol.epicgames.com/launcher/api/installer/download/EpicGamesLauncherInstaller.msi
          file: EpicGamesLauncherInstaller.msi
      - run:
          file: EpicGamesLauncherInstaller.msi
          args: ["/qn"]
    launch:
      program: 'C:\Program Files (x86)\Epic Games\Launcher\Portal\Binaries\Win64\EpicGamesLauncher.exe'
      name: Epic Games
      args: ["-opengl", "-SkipBuildPatchPrereq"]
    """#

    // O GOG publica só o instalador web (sem hash).
    static let gogGalaxy = #"""
    id: gog-galaxy
    name: GOG Galaxy
    revision: 1
    category: game
    description: Loja e biblioteca de jogos da GOG (sem DRM).
    provides: [gog]
    homepage: https://www.gog.com/galaxy
    notes: Ao fim da instalação o GOG Galaxy abre sozinho; feche-o para o Vinho terminar e criar o atalho.
    bottle:
      windows: win10
      graphics: dxmt
    steps:
      - download:
          url: https://webinstallers.gog-statics.com/download/GOG_Galaxy_2.0.exe
          file: GOG_Galaxy_2.0.exe
      - run:
          file: GOG_Galaxy_2.0.exe
    launch:
      program: 'C:\Program Files (x86)\GOG Galaxy\GalaxyClient.exe'
      name: GOG Galaxy
      args: ["--disable-gpu"]
    """#

    static let portal2 = #"""
    id: portal-2
    name: Portal 2
    revision: 1
    category: game
    description: Quebra-cabeças da Valve (Source engine, DirectX 9).
    homepage: https://store.steampowered.com/app/620/
    game:
      store: steam
      appid: 620
      exe: 'Portal 2\portal2.exe'
      directx: 9
    guide:
      - O download tem cerca de 12 GB.
      - O cooperativo online funciona pela Steam; a tela dividida local precisa de dois controles.
    """#

    static let halfLife2 = #"""
    id: half-life-2
    name: Half-Life 2
    revision: 1
    category: game
    description: Clássico da Valve (Source engine, DirectX 9). Inclui os Episódios 1 e 2.
    homepage: https://store.steampowered.com/app/220/
    game:
      store: steam
      appid: 220
      exe: 'Half-Life 2\hl2.exe'
      directx: 9
    guide:
      - Os episódios aparecem no menu do próprio jogo (atualização de aniversário).
      - Se o FPS estiver baixo, teste "-vulkan" nas opções de inicialização.
    """#

    static let teamFortress2 = #"""
    id: team-fortress-2
    name: Team Fortress 2
    revision: 1
    category: game
    description: Tiro multiplayer gratuito da Valve (Source engine 64-bit).
    homepage: https://store.steampowered.com/app/440/
    game:
      store: steam
      appid: 440
      exe: 'Team Fortress 2\tf_win64.exe'
      directx: 9
      launchOptions: -novid
    guide:
      - Usa VAC, que costuma funcionar no Wine.
      - Se não abrir, teste "-vulkan" nas opções de inicialização.
    """#

    static let counterStrike2 = #"""
    id: counter-strike-2
    name: Counter-Strike 2
    revision: 1
    category: game
    description: Tiro competitivo gratuito da Valve (Source 2, DirectX 11).
    homepage: https://store.steampowered.com/app/730/
    game:
      store: steam
      appid: 730
      exe: 'Counter-Strike Global Offensive\game\bin\win64\cs2.exe'
      directx: 11
      launchOptions: -novid -fullscreen
    guide:
      - O download tem cerca de 35 GB.
      - Partidas oficiais exigem VAC e o Wine pode ser bloqueado; avalie com “Funcionou?” para ajudar a comunidade.
      - Se a tela ficar preta ao abrir, aperte Alt+Enter ou rode em janela (-windowed).
    """#

    // DirectX 12: só roda com o Game Porting Toolkit (D3DMetal).
    static let ghostOfTsushima = #"""
    id: ghost-of-tsushima
    name: Ghost of Tsushima
    revision: 1
    category: game
    description: Mundo aberto da Sucker Punch (Director's Cut, DirectX 12).
    homepage: https://store.steampowered.com/app/2215430/
    game:
      store: steam
      appid: 2215430
      exe: 'Ghost of Tsushima DIRECTOR''S CUT\GhostOfTsushima.exe'
      directx: 12
    guide:
      - Precisa do Game Porting Toolkit (D3DMetal) e de um Mac com Apple Silicon e 16 GB de memória ou mais.
      - O download tem cerca de 75 GB; a biblioteca S: fica na pasta do seu Mac, não dentro do bottle.
      - O jogo pede login na PlayStation Network só para o modo online (Legends); a campanha roda sem.
      - Comece no preset Baixo e com escala de resolução (FSR/XeSS) ativada.
    """#
}
