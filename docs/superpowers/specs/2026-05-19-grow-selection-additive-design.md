# Grow Selection Aditiva — Design

**Data:** 2026-05-19
**Status:** Aprovado (pendente review do usuário)
**Autor:** Alexandre + Claude
**Relacionado:** Estende [`2026-05-08-grow-selection-design.md`](2026-05-08-grow-selection-design.md)

## Problema

Hoje grow selection **substitui** a seleção atual a cada gesture: cada long-press zera o que estava selecionado e começa do zero. Construir uma seleção composta (ex: três pedaços visualmente desconectados de um desenho) só é possível com lasso fechando uma área que englobe tudo — exatamente o tedioso que grow deveria evitar.

Falta também uma maneira granular de **remover** strokes da seleção. Hoje o único "clear" é trocar de modo (`select` → `draw` → `select`), que é lento e descarta toda a seleção.

## Solução

**Grow aditivo por default + grow subtrativo simétrico, com botão Deselect explícito.**

- Long-press em espaço vazio ou em stroke não-selecionado → **add**: halo cresce, novos strokes somam à seleção existente.
- Long-press em stroke **já selecionado** → **subtract**: halo vermelho cresce, strokes que ele alcança (restrito ao pool de selecionados) saem da seleção.
- Lasso continua substituindo (intent diferente: "redefine área").
- Botão **Deselect** ao lado do Sculpt (mesma condição de visibilidade, `hasSelection`) limpa toda a seleção em uma ação.

## Decisões de produto

### 1. Default aditivo, lasso permanece substitutivo

Grow é o gesto de "construir seleção stroke a stroke / cluster a cluster" — natural que acumule. Lasso é o gesto de "marca essa área inteira" — natural que defina o conjunto do zero.

Misturar isso (lasso também aditivo) confundiria a separação semântica. Manter lasso substitutivo preserva fluxo conhecido e dá ao usuário um "reset rápido": fazer um lasso pequeno em torno do que quer começa fresh.

### 2. Subtract grow simétrico, ativado pela origem

Mesmo gesto (long-press), comportamento determinado pelo que está sob o anchor:

```
origin.initialStrokeID ∈ selectedStrokeIDs?
  ├─ sim → subtract mode (pool restrito a selectionBeforeGrow)
  └─ não → add mode (pool = canvas.strokes)
```

Pool restrito em subtract é importante: o halo não atravessa strokes não-selecionados (sem efeito semântico), e o cálculo é mais barato.

### 3. Distinção visual: paleta vermelha em subtract

Add mode mantém visual atual (já validado pelo usuário em 2026-05-12). Subtract mode usa as mesmas alphas, trocando o hue:

| Elemento                | Add (atual)             | Subtract (novo)         |
|-------------------------|-------------------------|-------------------------|
| `sphereStrokeColor`     | `systemBlue` α=0.7      | `systemRed` α=0.7       |
| `sphereFillColor`       | `systemBlue` α=0.08     | `systemRed` α=0.08      |
| `candidatePeak`         | `systemOrange` α=0.65   | `systemRed` α=0.65      |
| `candidateBase`         | `systemOrange` α=0.25   | `systemRed` α=0.25      |
| `haloColor` (pause)     | `systemYellow` α=0.85   | `systemYellow` α=0.85 (inalterado — semântica "pausa" é mode-agnostic) |

Pulse period e velocidades inalterados. Sinal inequívoco de "estou removendo".

### 4. Botão Deselect na action bar inferior

A `sculptButton` atual vira `selectionActionBar`: HStack horizontal `[Deselect (✕)]  [Sculpt]`. Mesma condição de aparecer (`appMode == .select && hasSelection`), mesma transição (`move(edge: .bottom).combined(with: .opacity)`).

Layout:
- **Deselect**: ícone `xmark`, fundo `.ultraThinMaterial` em Capsule, foreground primary. Discreto.
- **Sculpt**: inalterado — Label("Sculpt", systemImage: "cube") em Capsule azul preenchida.

Tooltip do Deselect: `"Deselect"`.

### 5. Cancelamento herda comportamento existente

`handleGrowGestureCancelled` já restaura `selectionBeforeGrow`. Funciona corretamente pros dois modos sem mudança — em qualquer modo, o snapshot pré-gesture é o estado canônico.

### 6. Co-admit clustering ativo nos dois modos

O co-admit pass introduzido em 2026-05-12 (`coAdmitCatchUpFactor = 15.0`) roda também em subtract. Significa que ao remover um stroke, vizinhos selecionados são removidos juntos com o mesmo "catch-up". Decisão revisável no teste manual: se subtract ficar agressivo demais, restringir co-admit ao add mode.

## Mudanças por arquivo

### `PenSculpt/Drawing/Selection/GrowStrategy.swift`

- Adicionar:
  ```swift
  enum GrowMode { case add, subtract }
  ```
- `GrowSession`:
  - Novo campo `let mode: GrowMode`.
  - Init aceita `mode` e `candidatePool: [Stroke]` (rename interno; antes era `allStrokes`).
  - Lógica de admit/tick **não muda** — opera mode-agnostic sobre o pool fornecido.
- `GrowStrategy.start(origin:canvas:)` vira `start(origin:mode:candidatePool:)`.
- `GrowFrame` ganha `let mode: GrowMode` (para o visualization).

### `PenSculpt/Drawing/Selection/GrowOrigin.swift`

Sem mudança.

### `PenSculpt/Views/DrawingViewModel.swift`

- Novo state privado: `private var growMode: GrowMode?` (paralelo a `selectionBeforeGrow`, limpo em ended/cancelled).
- `handleGrowGestureStarted(origin:)`:
  - Snapshot `selectionBeforeGrow = selectedStrokeIDs`.
  - Determina `mode`: `subtract` se `origin.initialStrokeID` ∈ `selectedStrokeIDs`, senão `add`.
  - Constrói `candidatePool`: em subtract, `canvas.strokes.filter { selectedStrokeIDs.contains($0.id) }`; em add, `canvas.strokes`.
  - Chama `GrowStrategy.start(origin: origin, mode: mode, candidatePool: pool)`.
  - Atualiza `selectedStrokeIDs` via `applyGrowToSelection`.
- Novo helper privado:
  ```swift
  private func applyGrowToSelection(prior: Set<UUID>, session: GrowSession) -> Set<UUID> {
      switch session.mode {
      case .add:      return prior.union(session.includedStrokeIDs)
      case .subtract: return prior.subtracting(session.includedStrokeIDs)
      }
  }
  ```
- `displayLinkTick` e `handleGrowGestureEnded` chamam `applyGrowToSelection` em vez de atribuir `session.includedStrokeIDs` direto.
- Novo método público:
  ```swift
  func clearSelection() {
      selectedStrokeIDs = []
  }
  ```

### `PenSculpt/Views/GrowthVisualization.swift`

- Ler `frame.mode`.
- Em `.subtract`: aplicar substituições da tabela de paleta (decisão 3). Implementação: ou ramo `if mode == .subtract` dentro de `draw(_:)` escolhendo cores, ou par estático `subtractSphere*/subtractCandidate*` e seleção via dicionário. Decisão final na fase de plano.
- Em `.add`: paleta atual inalterada.
- `haloColor` (pausa) inalterado nos dois modos.

### `PenSculpt/Views/DrawingScreen.swift`

- `sculptButton` (linha 127–138) vira `selectionActionBar` com HStack `[Deselect, Sculpt]`.
- Deselect chama `vm.clearSelection()`.
- Importar tooltip `.deselect`.

### `PenSculpt/Views/Tooltips/TooltipID.swift`

- Adicionar `case deselect` com string `"Deselect"`.

## Testes

### Unit (`PenSculptTests/Selection/GrowStrategyTests.swift`)

- `testSubtractModeRestrictsCandidatesToSelectedPool` — em subtract, stroke fora do `candidatePool` nunca é admitido mesmo com raio gigante.
- `testSubtractModeAdmitsSeedImmediately` — origin em stroke selecionado → `includedStrokeIDs` contém seed no t=0.
- `testAddModePoolIsAllStrokes` — em add, qualquer stroke do canvas pode ser admitido.
- `testGrowFrameCarriesMode` — `GrowFrame.mode` reflete o modo do session.

### ViewModel-level (`PenSculptTests/DrawingViewModelTests.swift`)

- `testGrowAddUnionsWithPriorSelection` — selecionar A via lasso, depois grow-add em B → seleção final = {A, B…}.
- `testGrowSubtractDiffersFromPriorSelection` — seleção = {A, B, C}, grow-subtract em A → seleção final = {B, C} (ou {B,C}-co-admitidos).
- `testGrowCancelRevertsBothModes` — cancel durante add E durante subtract → ambos voltam pra `selectionBeforeGrow`.
- `testClearSelectionEmptiesSelectedStrokeIDs` — `vm.clearSelection()` zera `selectedStrokeIDs`.
- `testGrowAddOnEmptySpaceWithPriorPreservesPrior` — origin sem stroke, seleção prévia, halo nem cresce → seleção preservada.

### Manual

1. **Add básico**: selecionar A via lasso → long-press espaço vazio em outra área → grow capta strokes próximos → solta. Seleção final inclui A + novos.
2. **Add em stroke não-selecionado**: long-press em stroke X (não selecionado), com seleção prévia {A, B} → halo nasce em X, cresce → seleção final = {A, B, X, …vizinhos}.
3. **Subtract em stroke isolado**: seleção = {A, B, C}. Long-press em A → halo vermelho, soltar imediatamente → seleção = {B, C}.
4. **Subtract em cluster**: seleção = {A, B, C} próximos. Long-press em A, segurar até halo cobrir B → soltar → seleção = {C}.
5. **Subtract em cluster com não-selecionados próximos**: seleção = {A, B}, com stroke D não-selecionado entre A e B. Long-press em A, halo deve "pular" D (não está no pool) e remover B se raio crescer o suficiente.
6. **Deselect**: com qualquer seleção, tocar botão `xmark` → seleção limpa, action bar some.
7. **Lasso após grow**: grow-add resulta em {A, B, C}. Fazer lasso em torno de D → seleção vira {D} (lasso substitui, comportamento preservado).
8. **Cancel via mode toggle durante subtract**: long-press em A (subtract), enquanto halo cresce → tocar pencil-tip toggle → seleção reverte pra `selectionBeforeGrow`, sai pra draw mode.
9. **Hit-tolerance edge**: long-press perto (mas não em cima) de stroke selecionado → confirmar se vira subtract sem querer. Tolerance atual é 8pt — ajustar se gerar falsos positivos.

## Riscos e decisões finas

- **Co-admit em subtract**: se na prática remover for agressivo demais (puxa strokes que o usuário não queria tirar), restringir `coAdmitCatchUpFactor` a 0 em subtract mode. Decisão no teste manual.
- **Hit-tolerance de subtract trigger**: `SelectionView.beginGrow` usa `strokeHitTolerance: 8.0` pra decidir se origin é `.stroke` ou `.point`. Long-press próximo a stroke selecionado pode virar subtract sem intenção. Mitigação se ocorrer: reduzir tolerance só pra propósito de detectar subtract (manter 8pt pra origin geral).
- **Strokes recém-adicionados em subtract**: subtract mode em select mode não permite adicionar strokes novos (`isInteractive == false`). Pool é estável durante o gesture. Sem risco.
- **Deselect button durante hold**: UILongPressGesture é exclusivo de touch; botão não recebe tap durante hold. Sem race condition.

## Logs

Esta feature **não adiciona logs novos**. Os logs `[GROW-DIAG]`, `[GROW-SYNC]`, `[GESTURE-DIAG]`, etc. atualmente no código devem ser removidos no commit final desta feature (já pendente da sessão anterior, listado em `grow_selection_ready_to_test.md`).
