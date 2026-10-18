# Receitas do Vinho

Uma receita é um arquivo YAML que descreve como preparar um bottle e instalar
um app ou jogo. É o equivalente aberto dos perfis C4P do CrossOver: qualquer
pessoa pode ler, revisar e contribuir.

## Exemplo

```yaml
id: notepad-plus-plus          # minúsculas, números e hífen; único
name: Notepad++
revision: 1                    # aumente ao mudar a receita
category: app                  # app | game | tool
description: Editor de texto e código leve.
homepage: https://notepad-plus-plus.org
notes: Dica exibida no log ao final da instalação.

bottle:                        # usado quando a receita cria um bottle novo
  windows: win10               # win11 | win10 | win81 | win7 | winxp64
  graphics: wined3d            # d3dMetal | dxmt | dxvk | wined3d
  sync: msync                  # msync | esync | none
  retina: false
  environment: { DXMT_LOG_LEVEL: error }
  dllOverrides: { xinput1_3: native, d3dcompiler_47: "native,builtin" }

requires:
  capabilities: [dxmt]         # avisa se o runtime não tiver

steps:
  - download:
      url: https://…/instalador.exe      # https obrigatório
      sha256: 26f3bc…                   # recomendado; sem ele a receita é "não verificada"
      file: instalador.exe              # nome no cache (padrão: último trecho da URL)
  - winetricks: [corefonts, vcrun2019] # requer `brew install winetricks`
  - registry:
      key: 'HKCU\Software\Wine\Mac Driver'
      value: RetinaMode
      type: REG_SZ                      # padrão REG_SZ
      data: "y"
  - run:
      file: instalador.exe              # arquivo baixado acima, ou 'C:\…'
      args: ["/S"]                      # instalação silenciosa
      okExitCodes: [0, 3010]            # padrão
  - run:
      file: 'C:\Program Files (x86)\Steam\steam.exe'
      args: ["steam://install/550"]
      wait: false                       # abre e segue (programas que ficam abertos)

launch:
  program: 'C:\Program Files\Notepad++\notepad++.exe'   # fixado no bottle ao final
  # Opcionais — com qualquer um deles, vira um atalho personalizado na grade:
  # name: Left 4 Dead 2
  # args: ["steam://rungameid/550"]
  # icon: 'C:\…\left4dead2.exe'     # de onde tirar o ícone
```

Use aspas simples em caminhos do Windows (`'C:\…'`): em YAML a barra
invertida é literal dentro de aspas simples.

## Jogos da Steam

Receitas de jogo **não** instalam a Steam nem baixam o jogo: elas descrevem o
jogo e o Vinho cuida do resto.

```yaml
id: left-4-dead-2
name: Left 4 Dead 2
category: game
game:
  store: steam
  appid: 550                                # da URL da loja: store.steampowered.com/app/550
  exe: 'Left 4 Dead 2\left4dead2.exe'       # relativo a steamapps\common — ícone e status do download
  directx: 9                                # 9/10/11 → bottle "Steam (DX9–11)"; 12 → "Steam (DX12)"
  launchOptions: "-vulkan"                  # opcional: sugerido no guia, com botão de copiar
guide:                                      # dicas extras no guia de próximos passos
  - O download tem cerca de 13 GB.
steps: []                                   # opcional: winetricks, registro… rodam no bottle da Steam
```

Ao instalar, o Vinho:

1. procura um bottle com a Steam da família certa (**DX9–11** ou **DX12**) e, se não houver,
   cria `Steam (DX9–11)` ou `Steam (DX12)` usando a receita que tem `provides: [steam]`;
2. roda os `steps` do jogo (se houver) nesse bottle;
3. abre `steam://install/<appid>` e cria o atalho com `steam://rungameid/<appid>`;
4. mostra o **guia de próximos passos**, que se marca sozinho: login feito, biblioteca
   compartilhada adicionada, download concluído.

Jogos DX12 exigem o runtime Game Porting Toolkit (D3DMetal); o Vinho avisa se faltar.

### Biblioteca compartilhada

`~/Games/Vinho Steam Library` é criada automaticamente. Adicione-a nas duas Steams
(Configurações ▸ Armazenamento) — o guia mostra o caminho `Z:\…` com botão de copiar.
Jogos instalados ali aparecem nos dois bottles sem baixar de novo, e o atalho acha o
ícone do jogo em qualquer biblioteca.

### Backend por versão do DirectX

| DirectX | Bottle | Backend |
|---|---|---|
| 9 | Steam (DX9–11) | WineD3D (ou `-vulkan` se o jogo trouxer DXVK) |
| 10 / 11 | Steam (DX9–11) | DXMT |
| 12 | Steam (DX12) | D3DMetal (Game Porting Toolkit) |

## Onde o Vinho procura receitas

| Camada | Local | Prioridade |
|---|---|---|
| Embutidas | dentro do app | menor |
| Comunidade | URL de um `index.yaml` (Ajustes ▸ Geral) | média |
| Suas | `~/Library/Application Support/Vinho/Recipes/*.yaml` | maior |

Uma receita com o mesmo `id` numa camada de prioridade maior substitui a outra.

## Repositório comunitário

A pasta [`community/`](../community) tem o formato esperado:

```
community/
├── index.yaml        # recipes: [recipes/7zip.yaml, …]
└── recipes/*.yaml
```

Publique no GitHub e aponte o Vinho para a URL *raw* do `index.yaml`.

## Validação e segurança

O Vinho rejeita receitas com: `id` inválido, download sem https, `sha256`
mal formado, nome de arquivo com `/` ou começando com `.`, `run` de um arquivo
que não foi baixado nem é `C:\…`, verbos de winetricks com caracteres de shell
e overrides de DLL desconhecidos. Um download com `sha256` errado interrompe a
receita antes de qualquer execução.

Lembre: uma receita executa instaladores do Windows. Só use receitas de fontes
em que você confia e prefira as verificadas (SHA-256 ✓).
