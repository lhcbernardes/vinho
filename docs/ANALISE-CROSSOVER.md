# Análise do CrossOver 26.3 (referência para o Vinho)

Feita por inspeção estática do bundle instalado (`~/Applications/CrossOver.app`),
sem executar nem decompilar código. Objetivo: entender a arquitetura para
construir um equivalente **clean-room**. Nenhum código ou recurso do CrossOver
é copiado para o Vinho.

## Visão geral

| Item | Valor |
|---|---|
| Bundle ID | `com.codeweavers.CrossOver` |
| Versão | 26.3 (13/07/2026) |
| Tamanho | ~1 GB |
| Binário principal | Mach-O universal (x86_64 + arm64), Objective-C/Cocoa |
| macOS mínimo | 10.15 |

## Camadas

```
CrossOver.app/Contents
├── MacOS/CrossOver                  UI Cocoa (ObjC)
├── Frameworks/
│   ├── Python.framework (3.13)      embutido; a UI chama via _InitializePython
│   └── Sparkle.framework            auto-update
├── Resources/                       nibs, ícones, 40+ idiomas, libcxsetup.py
└── SharedSupport/CrossOver/
    ├── bin/  → "CrossOver-Hosted Application"   ferramentas cx* em Perl (cxbottle, cxstart, cxmenu…)
    ├── lib/python/*.pyc             ~50 módulos de lógica
    ├── lib/wine/                    Wine (fork CodeWeavers) — i386-windows, x86_64-windows, x86_64-unix
    ├── lib/dxvk, lib/dxmt           camadas D3D
    ├── lib64/apple_gptk/            D3DMetal.framework (Apple GPTK)
    ├── lib64/libMoltenVK.dylib      Vulkan → Metal
    ├── lib64/gstreamer-1.0, SDL2…   mídia / input
    └── share/crossover/bottle_templates, bottle_data
```

## Fluxo de controle observado

1. **UI ObjC** (`MainWindowController`, `BottleViewController`, `InstallOptionsSheetController`…)
2. → **Python embutido** para regras de negócio: `bottlemanagement`, `bottlequery`,
   `c4profiles`/`c4parser` (perfis de instalação `.c4p`), `cxaiengine*`
   (motor de instalação automática: baixa dependências, aplica fixes),
   `appdetector`, `cxfixes`, `downloaddetector`.
3. → **NSTask** chamando scripts **Perl** (`cxbottle`, `cxstart`) que finalmente
   executam `wine`/`wineserver`.

Três linguagens (ObjC → Python → Perl) para chegar no Wine. É aqui que o Vinho
simplifica: tudo em Swift, `Process` direto.

## O que é proprietário vs. aberto

| Componente | Licença | Estratégia no Vinho |
|---|---|---|
| Wine (fork CodeWeavers) | LGPL — fonte publicado pela CodeWeavers | usar build open source (ex. Gcenx `wine-crossover`) ou compilar |
| DXVK, DXMT, MoltenVK | zlib / Apache 2.0 | usar diretamente |
| D3DMetal (GPTK) | licença Apple | **verificar termos antes de redistribuir**; suportar se o usuário instalar |
| UI, Python, perfis C4P, CrossTie | proprietário | reimplementar do zero com design próprio |

## Ideias de produto (onde o Vinho pode ser melhor)

- Stack única em Swift (menos peso, startup mais rápido, sem Python/Perl).
- Runtimes desacoplados e trocáveis por bottle.
- Perfis de instalação abertos (YAML) num repositório comunitário, no lugar do C4P/CrossTie.
- Diagnóstico de primeira classe: console de log filtrável, HUD Metal, "por que não abriu?".
- Snapshots APFS de bottles antes de instalar algo (rollback instantâneo).
- Extração de ícones dos `.exe` (recurso PE) para a grade de programas.

## Comparação atual (out/2026)

| CrossOver | Vinho |
|---|---|
| Wine com patches da CodeWeavers | Gcenx (stable/devel/staging) + workflow `wine-runtime` que compila o código-fonte do CrossOver (experimental) |
| Wine Mono/Gecko e dependências pelo CrossTie | Aba **Componentes**: Wine Mono (SHA-256) e verbos do winetricks fixado |
| Detecção de dependências | `MissingComponentDetector` lê `Library X.dll … not found` no log |
| Ajustes por aplicativo | Perfis por executável (AppDefaults), criados também para jogos baixados direto pela Steam |
| Steam, Epic, GOG, EA, Ubisoft | Steam (correções automáticas), Epic, GOG |
| Abrir .exe pelo Finder, bottle padrão | `CFBundleDocumentTypes` + bottle padrão ★ ou folha “Abrir com” |
| Atualização automática | `AppUpdater` (releases do GitHub, 1×/dia) |
| Executar comando, canais de debug, duplicar bottle | ⇧⌘O, campo “Canais de debug”, ⇧⌘D |

### Ainda faltando
- D3DMetal próprio: o Vinho usa o do Game Porting Toolkit instalado pelo usuário (a licença da Apple não permite redistribuir).
- EA app e Ubisoft Connect (anti-cheat e CEF ainda instáveis no Wine do macOS).
- Wine Gecko (o domínio da WineHQ não está no allowlist usado no desenvolvimento; o mshtml segue desativado).
