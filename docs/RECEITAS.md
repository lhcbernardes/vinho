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

launch:
  program: 'C:\Program Files\Notepad++\notepad++.exe'   # fixado no bottle ao final
```

Use aspas simples em caminhos do Windows (`'C:\…'`): em YAML a barra
invertida é literal dentro de aspas simples.

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
