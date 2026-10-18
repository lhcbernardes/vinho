# Contribuindo com o Vinho

## Código

```bash
swift test          # precisa passar
swift run Vinho     # rodar o app
```

- O núcleo (`Sources/WineKit`) não depende de UI e deve ter testes para lógica nova.
- Prefira funções puras (como `WineEnvironment.make`, `WineConfigurator.commands`) para facilitar testes.
- Mensagens e textos de interface em português.

## Receitas

1. Escreva o YAML seguindo [`docs/RECEITAS.md`](docs/RECEITAS.md).
2. Coloque em `community/recipes/<id>.yaml` e adicione ao `community/index.yaml`.
3. Inclua `sha256` em todo download (`shasum -a 256 arquivo.exe`).
4. Teste localmente: copie para `~/Library/Application Support/Vinho/Recipes/` e instale pelo app.
5. Abra um PR. O CI valida todas as receitas da pasta `community/`.

## Relatórios de compatibilidade

No app: clique com o botão direito num programa ▸ **Funcionou? Avaliar…**. O
Vinho abre uma issue pré-preenchida — revise e envie.

## Licenças de terceiros

Wine é LGPL; DXVK, DXMT e MoltenVK têm licenças próprias. **D3DMetal (Apple)
não pode ser redistribuído** — não adicione binários dele ao repositório nem a
receitas.
