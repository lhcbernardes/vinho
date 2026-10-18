# Vinho 🍷

Rode programas e jogos do Windows no macOS — um front-end moderno em SwiftUI
sobre o Wine, inspirado na experiência do CrossOver, construído do zero.

> Status: **MVP (fase 1)**. Bottles, execução de programas, backends gráficos e logs.

## Requisitos

- macOS 14+ (Apple Silicon ou Intel)
- Xcode 16+ (Swift 5.10+)
- Rosetta 2 no Apple Silicon: `softwareupdate --install-rosetta --agree-to-license`
- Um **runtime Wine** (veja abaixo)

## Runtime Wine

Na primeira execução o Vinho oferece **Baixar e instalar** o Wine Stable.
Em **Ajustes ▸ Runtimes** dá para:

- instalar outros builds (Stable / Devel / Staging, builds Gcenx) — download verificado por **SHA-256**;
- **adicionar DXMT ou DXVK** a um runtime: o Vinho cria uma *variante*
  (`wine-stable-11.0_1+dxmt-v0.80`) via clone APFS, sem alterar o original;
- remover runtimes instalados pelo Vinho (vão para o Lixo).

Ao escolher um backend gráfico num bottle, o Vinho troca automaticamente
para um runtime que o suporte.

**D3DMetal** (Apple GPTK) não pode ser redistribuído; instale com
`brew install --cask gcenx/wine/game-porting-toolkit` e o Vinho detecta.

Runtimes ficam em `~/Library/Application Support/Vinho/Runtimes/`.
Pela linha de comando: `scripts/install-runtime.sh stable 11.0_1`.

## Build e execução

```bash
# Abrir no Xcode (recomendado): File ▸ Open… ▸ Package.swift, scheme "Vinho", ⌘R
open Package.swift

# Ou pela linha de comando
swift build
swift run Vinho
swift test            # testes do WineKit

# Gerar um Vinho.app (universal, ícone, assinatura ad-hoc)
scripts/bundle.sh

# …e instalar em ~/Applications com atalho na Mesa
scripts/bundle.sh --install
```

> O app **não** deve ser sandboxed: ele precisa executar o Wine e acessar os bottles.

## Arquitetura

```
Sources/
├── WineKit/                 núcleo, sem UI — testável
│   ├── Models/              Bottle, BottleSettings (vinho.json), GraphicsBackend, erros
│   ├── Runtime/             WineRuntime, RuntimeLocator (descoberta + capacidades)
│   ├── Process/             ProcessLauncher (Process + AsyncThrowingStream),
│   │                        WineEnvironment (env/overrides), WineRunner, WineConfigurator
│   ├── Bottles/             BottleManager (actor; CRUD em disco)
│   ├── Programs/            ProgramScanner (.lnk / .exe), WindowsPath
│   └── SystemCheck.swift    Rosetta
└── Vinho/                   app SwiftUI (Observation)
    ├── App/                 VinhoApp, AppModel
    └── Views/               ContentView, BottleDetailView, NewBottleSheet, SettingsView
```

Princípios:

- **Valores puros onde possível.** `WineInvocation`, `WineEnvironment.make` e
  `WineConfigurator.commands` são funções puras — os testes cobrem a lógica sem Wine instalado.
- **Um bottle = um WINEPREFIX** + `vinho.json`. Renomear não move a pasta.
- **Configuração incremental.** Só o que mudou é reaplicado no prefixo (`winecfg -v`, `reg add`).
- **Precedência de ambiente:** base → Vinho → `settings.environment` → extra.

Bottles ficam em `~/Library/Application Support/Vinho/Bottles/`.

## Roadmap

**Fase 2 — Runtimes gerenciados** ✅
- [x] Catálogo de runtimes com download verificado por SHA-256, progresso e cancelamento
- [x] DXMT/DXVK com um clique (variantes de runtime via clone APFS)
- [x] `wine --version` em background para exibir versão
- [x] Catálogo remoto (`runtimes.json` da release `runtimes`) somado ao embutido

**Fase 3 — Experiência** ✅
- [x] Ícones reais extraídos dos `.exe` (recursos PE `RT_GROUP_ICON`) e dos atalhos `.lnk`
- [x] Atalhos no Launchpad/Spotlight/Dock (`~/Applications/Vinho/<Programa>.app`)
- [x] Snapshots de bottle (clone APFS), automáticos antes de instaladores, com restauração
- [x] Exportar/importar bottle (`.vinhobottle`, tar.gz)

**Fase 4 — Receitas abertas** ✅
- [x] Receitas YAML (bottle preset, download com SHA-256, run, winetricks, registro, programa principal)
- [x] Catálogo no app (⇧⌘R) com instalação em bottle novo ou existente, progresso e cancelamento
- [x] Camadas: embutidas < comunidade (`index.yaml` remoto) < do usuário
- [x] Pasta `community/` pronta para virar repositório — formato em [`docs/RECEITAS.md`](docs/RECEITAS.md)
- [x] Relatórios de compatibilidade ("Funcionou?") como issues pré-preenchidas no GitHub

**Launchers e jogos** ✅
- [x] Uma Steam só para todos os jogos, com **perfil por jogo** (renderer, Retina, DLLs via Wine AppDefaults)
- [x] Correção automática da tela preta da Steam (wrapper do steamwebhelper em `Tools/`)
- [x] Receitas de jogo (`game: { store: steam, appid, directx, profile }`)
- [x] Biblioteca de jogos compartilhada entre os bottles de Steam
- [x] Guia "Próximos passos" que se marca sozinho (login, biblioteca, download) e aviso no bottle quando há pendências
- [x] Detecção da Steam instalada manualmente (arrastando o SteamSetup.exe)

**Paridade com o CrossOver** ✅
- [x] **Componentes do Windows** num clique (aba Componentes): Wine Mono, Visual C++ 2008–2022, .NET 4.8, d3dx9, d3dcompiler_47, XACT, XInput, PhysX, fontes — winetricks fixado e verificado por SHA-256
- [x] **DLLs faltando**: o Vinho lê o log do Wine e sugere o componente certo
- [x] **Ajustes automáticos por jogo**: jogos baixados pela Steam viram atalhos com perfil próprio, com ou sem receita
- [x] **Epic Games e GOG Galaxy** (receitas; abrem com as flags que evitam a tela preta)
- [x] Receitas de Portal 2, Half-Life 2, TF2, Counter-Strike 2 e Ghost of Tsushima
- [x] **Abrir .exe/.msi/.lnk pelo Finder** (Abrir com ▸ Vinho) e **bottle padrão** (★)
- [x] **Atualização automática** do app pelas releases do GitHub
- [x] **Executar comando** com argumentos (⇧⌘O), **canais de debug** com predefinições e **duplicar bottle** (⇧⌘D)
- [x] Workflow **Wine runtime (CrossOver)** — compila o Wine com os patches da CodeWeavers a partir do código-fonte (experimental)

**Fase 5 — Comunidade** ✅
- [x] CI (GitHub Actions) com testes e validação das receitas de `community/`
- [x] Release automático do `Vinho.app` ao criar uma tag `v*`
- [x] Templates de issue (compatibilidade, pedido de receita) e de PR
- [x] Licença MIT e [`CONTRIBUTING.md`](CONTRIBUTING.md)

Veja também [`docs/ANALISE-CROSSOVER.md`](docs/ANALISE-CROSSOVER.md).

## Publicando no GitHub

```bash
gh repo create vinho --public --source . --push
git tag v0.5.0 && git push --tags   # dispara o release com o Vinho.app
```

Depois, em **Ajustes ▸ Geral ▸ Comunidade**, configure `seu-usuario/vinho` e a URL raw de
`community/index.yaml`.

## Licença

MIT — veja [LICENSE](LICENSE). Wine é LGPL; DXVK/DXMT/MoltenVK têm licenças próprias;
D3DMetal pertence à Apple — verifique os termos antes de redistribuir.
