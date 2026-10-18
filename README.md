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

# Gerar um Vinho.app (universal, assinatura ad-hoc)
scripts/bundle.sh
open build/Vinho.app
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
- [ ] Catálogo remoto (JSON) para atualizar versões sem novo release do app

**Fase 3 — Experiência**
- [ ] Ícones reais extraídos dos `.exe` (recursos PE `RT_GROUP_ICON`)
- [ ] Atalhos no Launchpad/Dock por programa (mini `.app` que chama o Vinho)
- [ ] Snapshots APFS de bottle (antes de instalar) e rollback
- [ ] Importar/exportar bottle (`.vinhobottle` = tar.zst)

**Fase 4 — Perfis abertos**
- [ ] Receitas YAML de instalação (dependências winetricks, overrides, env) por app/jogo
- [ ] Repositório comunitário de receitas + relatório de compatibilidade

Veja também [`docs/ANALISE-CROSSOVER.md`](docs/ANALISE-CROSSOVER.md).

## Licença

MIT (proposta). Wine é LGPL; DXVK/DXMT/MoltenVK têm licenças próprias;
D3DMetal pertence à Apple — verifique os termos antes de redistribuir.
