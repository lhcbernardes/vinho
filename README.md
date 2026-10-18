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

O Vinho não embute o Wine; ele procura runtimes em:

1. `~/Library/Application Support/Vinho/Runtimes/<nome>/` (precisa ter `bin/wine` ou `bin/wine64`)
2. `/Applications/Wine*.app` e `~/Applications/Wine*.app` (layout `Contents/Resources/wine`)

Caminho mais rápido — build open source do Wine da CodeWeavers, empacotado pelo Gcenx:

```bash
brew install --cask gcenx/wine/wine-crossover
# se o Gatekeeper bloquear:
xattr -dr com.apple.quarantine "/Applications/Wine Crossover.app"
```

Recursos detectados automaticamente por runtime:

| Backend | Detectado quando o runtime tem |
|---|---|
| D3DMetal | `lib/external/D3DMetal.framework` |
| DXMT | `lib/dxmt/` ou `lib/wine/x86_64-unix/winemetal.so` |
| DXVK | `lib/dxvk/` + `libMoltenVK.dylib` |
| WineD3D | sempre |

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

**Fase 2 — Runtimes gerenciados**
- [ ] Download/instalação de runtimes (manifesto JSON + verificação SHA-256)
- [ ] Instalar DXMT/DXVK no `system32` do bottle com um clique
- [ ] `wine --version` em background para exibir versão

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
