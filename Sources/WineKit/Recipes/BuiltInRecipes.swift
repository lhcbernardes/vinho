/// Receitas que acompanham o app. Mantidas como texto (e não como recursos
/// do pacote) para funcionar igual em `swift run` e no `.app` gerado.
/// Os arquivos equivalentes ficam em `community/recipes/`.
enum BuiltInRecipes {
    static let yaml: [String] = [notepadPlusPlus, sevenZip, steam]

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
    revision: 1
    category: game
    description: Loja e biblioteca de jogos da Valve.
    homepage: https://store.steampowered.com
    notes: Se a janela da Steam ficar preta, troque o backend gráfico para WineD3D.
    bottle:
      windows: win10
      graphics: dxmt
    requires:
      capabilities: [dxmt]
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
}
