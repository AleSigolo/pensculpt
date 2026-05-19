# Grow Selection Aditiva Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tornar grow selection aditivo por default, com modo subtrativo simétrico (long-press em stroke já selecionado) e botão Deselect explícito.

**Architecture:** `GrowSession` ganha um `mode: GrowMode { add, subtract }` e um `candidatePool: [Stroke]` (substitui `allStrokes`). A lógica de admit/tick continua mode-agnostic — opera sobre o pool fornecido. O `DrawingViewModel` é quem detecta o modo (origin sobre selecionado → subtract), restringe o pool quando subtract, e aplica `union` ou `subtracting` sobre `selectionBeforeGrow` a cada tick e no finalize. UI ganha botão Deselect ao lado do Sculpt e paleta vermelha pro halo de subtract.

**Tech Stack:** Swift 5.x, SwiftUI/UIKit, XCTest, xcodebuild para tests no iOS Simulator.

**Spec:** [`docs/superpowers/specs/2026-05-19-grow-selection-additive-design.md`](../specs/2026-05-19-grow-selection-additive-design.md)

---

## Task 1: Introduzir `GrowMode` e refatorar API do `GrowSession`

Refactor puro: introduz `GrowMode` e renomeia `allStrokes`/`canvas` para `candidatePool`. Todos os testes existentes precisam ser atualizados para a nova assinatura e continuar passando.

**Files:**
- Modify: `PenSculpt/Drawing/Selection/GrowStrategy.swift`
- Modify: `PenSculpt/Views/DrawingViewModel.swift:97`
- Modify: `PenSculptTests/Selection/GrowStrategyTests.swift` (atualizar todos os call sites)

- [ ] **Step 1.1: Adicionar `GrowMode` e mode ao `GrowFrame`**

Em `PenSculpt/Drawing/Selection/GrowStrategy.swift`, no topo do arquivo (antes de `struct GrowFrame`), adicionar:

```swift
enum GrowMode {
    case add
    case subtract
}
```

Substituir a definição atual de `GrowFrame`:

```swift
struct GrowFrame {
    let radius: CGFloat
    let center: CGPoint
    let includedStrokeIDs: Set<UUID>
    let nextCandidateID: UUID?
    let isPaused: Bool
    let mode: GrowMode
}
```

- [ ] **Step 1.2: Refatorar `GrowSession` (mode + candidatePool)**

No mesmo arquivo, substituir a definição de `GrowSession` (o init e o campo `allStrokes`):

```swift
final class GrowSession {
    let origin: GrowOrigin
    let mode: GrowMode
    let candidatePool: [Stroke]

    private(set) var currentRadius: CGFloat = GrowStrategy.initialRadius
    private(set) var includedStrokeIDs: Set<UUID> = []
    private(set) var nextCandidateID: UUID?
    private(set) var isPaused: Bool = false

    init(origin: GrowOrigin, mode: GrowMode, candidatePool: [Stroke]) {
        self.origin = origin
        self.mode = mode
        self.candidatePool = candidatePool
    }
    // ... resto inalterado
}
```

Substituir todas as referências internas a `allStrokes` por `candidatePool` no mesmo arquivo. Os pontos são:
- `frontierPoints`: `for s in allStrokes where ...` → `for s in candidatePool where ...`
- `candidateStrokes`: `allStrokes.filter { ... }` → `candidatePool.filter { ... }`

- [ ] **Step 1.3: Propagar `mode` para todos os `GrowFrame` criados**

Em `GrowSession.tick(deltaTime:)`, ambos os `return GrowFrame(...)` (o early-return em `candidateStrokes.isEmpty` e o final) precisam incluir `mode: mode`:

```swift
return GrowFrame(
    radius: currentRadius,
    center: origin.anchor,
    includedStrokeIDs: includedStrokeIDs,
    nextCandidateID: nil,
    isPaused: false,
    mode: mode
)
```

e:

```swift
return GrowFrame(
    radius: currentRadius,
    center: origin.anchor,
    includedStrokeIDs: includedStrokeIDs,
    nextCandidateID: nextCandidateID,
    isPaused: isPaused,
    mode: mode
)
```

- [ ] **Step 1.4: Refatorar `GrowStrategy.start` para nova assinatura**

Substituir a definição atual de `GrowStrategy.start`:

```swift
static func start(origin: GrowOrigin, mode: GrowMode, candidatePool: [Stroke]) -> GrowSession {
    let session = GrowSession(origin: origin, mode: mode, candidatePool: candidatePool)
    session.admitInitial()
    return session
}
```

- [ ] **Step 1.5: Atualizar call site em `DrawingViewModel.handleGrowGestureStarted`**

Em `PenSculpt/Views/DrawingViewModel.swift`, linha 97, substituir:

```swift
let session = GrowStrategy.start(origin: origin, canvas: canvas)
```

por (temporariamente sempre `.add` — a detecção de subtract entra na Task 4):

```swift
let session = GrowStrategy.start(origin: origin, mode: .add, candidatePool: canvas.strokes)
```

Também substituir a construção do `growthFrame` logo abaixo (linhas ~102–108) — adicionar `mode: .add`:

```swift
growthFrame = GrowFrame(
    radius: session.currentRadius,
    center: origin.anchor,
    includedStrokeIDs: session.includedStrokeIDs,
    nextCandidateID: session.nextCandidateID,
    isPaused: session.isPaused,
    mode: .add
)
```

- [ ] **Step 1.6: Atualizar todos os call sites em `GrowStrategyTests`**

Em `PenSculptTests/Selection/GrowStrategyTests.swift`, encontrar cada chamada `GrowStrategy.start(origin: ..., canvas: ...)` e substituir por `GrowStrategy.start(origin: ..., mode: .add, candidatePool: ...)`. Os locais (referência rápida pela busca da string `GrowStrategy.start`):

- linha ~25: `testStrokeOriginIncludesItselfAtT0`
- linha ~35: `testPointOriginIncludesNothingAtT0WhenNoStrokeWithinInitialRadius`
- linha ~45: `testPointOriginIncludesStrokeWithinInitialRadius`
- linha ~56: `testRadiusGrowsMonotonically`
- linha ~70: `testTickIncludesCloseStrokeAfterEnoughTime`
- linha ~89: `testPauseTriggersWhenNextStrokeIsFar`
- linha ~130: `testEquidistantStrokesAdmittedOnSameTick`
- linha ~167: `testAsymmetricAnchorAdmitsSidesCloseTogether`
- linha ~201: `testFinalizeReturnsCurrentlyIncludedSet`
- linha ~212: `testFinalizeMatchesIncludedAfterTicks`

Em cada um, trocar:

```swift
GrowStrategy.start(origin: .point(.zero), canvas: canvas([s]))
```

por:

```swift
GrowStrategy.start(origin: .point(.zero), mode: .add, candidatePool: canvas([s]).strokes)
```

(Ou se preferir, criar uma helper local `private func startAdd(...) -> GrowSession` em cima do arquivo para reduzir verbosidade — opcional.)

- [ ] **Step 1.7: Rodar todos os tests; nada deve quebrar**

Run: `xcodebuild test -scheme PenSculpt -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' 2>&1 | tail -30`

Expected: todos os testes existentes passam. Nenhuma mudança de comportamento — só renomeação + adição de campo `mode`.

- [ ] **Step 1.8: Commit**

```bash
git add PenSculpt/Drawing/Selection/GrowStrategy.swift PenSculpt/Views/DrawingViewModel.swift PenSculptTests/Selection/GrowStrategyTests.swift
git commit -m "$(cat <<'EOF'
refactor(grow-selection): introduce GrowMode and candidatePool

Plumbing-only change: GrowSession now requires mode (.add/.subtract)
and candidatePool (renamed from allStrokes). GrowFrame carries the
mode for the visualization layer to read later. No behavior change —
all existing call sites pass mode: .add and candidatePool: canvas.strokes.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Travar comportamento de subtract no nível do `GrowSession`

Adicionar testes unit que fixam que o session opera corretamente em subtract: admite seed imediatamente, pool restrito não admite strokes externos, `frame.mode` reflete o modo. Como o session é mode-agnostic, esses tests devem passar imediatamente após a refatoração da Task 1.

**Files:**
- Modify: `PenSculptTests/Selection/GrowStrategyTests.swift` (adicionar tests no final, antes do último `}`)

- [ ] **Step 2.1: Adicionar tests de subtract**

Em `PenSculptTests/Selection/GrowStrategyTests.swift`, antes do `}` final da classe, adicionar:

```swift
    // MARK: subtract mode

    func testSubtractModeAdmitsSeedImmediately() {
        let id = UUID()
        let seed = stroke(at: [CGPoint(x: 100, y: 100)], id: id)
        let session = GrowStrategy.start(
            origin: .stroke(strokeID: id, anchor: CGPoint(x: 100, y: 100)),
            mode: .subtract,
            candidatePool: [seed]
        )
        XCTAssertEqual(session.mode, .subtract)
        XCTAssertTrue(session.includedStrokeIDs.contains(id),
                      "Subtract mode marks the seed for removal at t=0")
    }

    func testSubtractModePoolRestrictsAdmission() {
        // Strokes outside the candidatePool can never be admitted, no matter
        // how big the radius grows.
        let inPool = stroke(at: [CGPoint(x: 10, y: 0)])
        let outOfPool = stroke(at: [CGPoint(x: 12, y: 0)])
        let session = GrowStrategy.start(
            origin: .point(.zero),
            mode: .subtract,
            candidatePool: [inPool]  // outOfPool deliberately omitted
        )
        for _ in 0..<600 {
            _ = session.tick(deltaTime: 1.0 / 60.0)
        }
        XCTAssertTrue(session.includedStrokeIDs.contains(inPool.id),
                      "Stroke inside the pool is reachable")
        XCTAssertFalse(session.includedStrokeIDs.contains(outOfPool.id),
                       "Stroke outside the pool must never be admitted")
    }

    func testGrowFrameCarriesMode() {
        let session = GrowStrategy.start(
            origin: .point(.zero),
            mode: .subtract,
            candidatePool: []
        )
        let frame = session.tick(deltaTime: 1.0 / 60.0)
        XCTAssertEqual(frame.mode, .subtract)
    }
```

- [ ] **Step 2.2: Rodar os novos tests; devem passar imediatamente**

Run: `xcodebuild test -scheme PenSculpt -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' -only-testing:PenSculptTests/GrowStrategyTests 2>&1 | tail -20`

Expected: todos os testes do `GrowStrategyTests` passam, incluindo os 3 novos.

- [ ] **Step 2.3: Commit**

```bash
git add PenSculptTests/Selection/GrowStrategyTests.swift
git commit -m "$(cat <<'EOF'
test(grow-selection): lock in subtract-mode session behavior

Confirms GrowSession is mode-agnostic at the algorithm level: seed
admission happens regardless of mode, restricted candidate pools cap
the admission universe, and GrowFrame carries the session's mode for
the visualization to read.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Aplicar grow aditivamente sobre a seleção prévia (add mode)

Substituir `selectedStrokeIDs = session.includedStrokeIDs` (replace) por `selectionBeforeGrow ∪ session.includedStrokeIDs` (union) no tick e no finalize. Modo continua sempre `.add` neste passo — detecção de subtract entra na Task 4.

**Files:**
- Modify: `PenSculpt/Views/DrawingViewModel.swift`
- Modify: `PenSculptTests/DrawingViewModelTests.swift`

- [ ] **Step 3.1: Escrever test falhando — grow add une com seleção prévia**

Em `PenSculptTests/DrawingViewModelTests.swift`, na seção "Grow selection lifecycle" (antes do `}` final da classe), adicionar:

```swift
    func testGrowAddUnionsWithPriorSelection() {
        let vm = makeVM()
        let priorID = UUID()
        let prior = Stroke(id: priorID, points: [
            StrokePoint(location: CGPoint(x: 1000, y: 1000), pressure: 1, tilt: 0, azimuth: 0, timestamp: 0)
        ])
        let growID = UUID()
        let target = Stroke(id: growID, points: [
            StrokePoint(location: .zero, pressure: 1, tilt: 0, azimuth: 0, timestamp: 0)
        ])
        vm.canvas.strokes = [prior, target]
        vm.selectedStrokeIDs = [priorID]

        vm.handleGrowGestureStarted(origin: .stroke(strokeID: growID, anchor: .zero))
        XCTAssertEqual(vm.selectedStrokeIDs, [priorID, growID],
                       "during hold, selection mirrors prior ∪ grown")

        vm.handleGrowGestureEnded()
        XCTAssertEqual(vm.selectedStrokeIDs, [priorID, growID],
                       "finalize commits prior ∪ grown")
    }
```

- [ ] **Step 3.2: Rodar test e verificar que falha**

Run: `xcodebuild test -scheme PenSculpt -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' -only-testing:PenSculptTests/DrawingViewModelTests/testGrowAddUnionsWithPriorSelection 2>&1 | tail -15`

Expected: FAIL. Mensagem indica que `selectedStrokeIDs` contém só `[growID]` (replace), não `[priorID, growID]` (union).

- [ ] **Step 3.3: Implementar `applyGrowToSelection` + integrar em tick/finalize**

Em `PenSculpt/Views/DrawingViewModel.swift`, dentro da classe (depois do método `handleGrowGestureCancelled` e antes de `startDisplayLink`), adicionar:

```swift
    /// Combines the pre-gesture selection snapshot with the session's affected
    /// set. Add mode unions; subtract mode (added in a later step) will
    /// difference. Returns the set to assign to `selectedStrokeIDs`.
    private func applyGrowToSelection(prior: Set<UUID>, session: GrowSession) -> Set<UUID> {
        switch session.mode {
        case .add:      return prior.union(session.includedStrokeIDs)
        case .subtract: return prior.subtracting(session.includedStrokeIDs)
        }
    }
```

Substituir o corpo de `handleGrowGestureStarted` para refletir a união já na admissão inicial. Localizar o trecho atual (linhas ~94–110):

```swift
    func handleGrowGestureStarted(origin: GrowOrigin) {
        cancelLasso()
        selectionBeforeGrow = selectedStrokeIDs
        let session = GrowStrategy.start(origin: origin, mode: .add, candidatePool: canvas.strokes)
        growSession = session
        // Reflect the initial admission in the highlight layer so the user
        // immediately sees what's being captured.
        selectedStrokeIDs = session.includedStrokeIDs
        growthFrame = GrowFrame(
            radius: session.currentRadius,
            center: origin.anchor,
            includedStrokeIDs: session.includedStrokeIDs,
            nextCandidateID: session.nextCandidateID,
            isPaused: session.isPaused,
            mode: .add
        )
        startDisplayLink()
    }
```

Substituir por:

```swift
    func handleGrowGestureStarted(origin: GrowOrigin) {
        cancelLasso()
        let prior = selectedStrokeIDs
        selectionBeforeGrow = prior
        let session = GrowStrategy.start(origin: origin, mode: .add, candidatePool: canvas.strokes)
        growSession = session
        // Reflect the initial admission in the highlight layer so the user
        // immediately sees what's being captured.
        selectedStrokeIDs = applyGrowToSelection(prior: prior, session: session)
        growthFrame = GrowFrame(
            radius: session.currentRadius,
            center: origin.anchor,
            includedStrokeIDs: session.includedStrokeIDs,
            nextCandidateID: session.nextCandidateID,
            isPaused: session.isPaused,
            mode: .add
        )
        startDisplayLink()
    }
```

Substituir o corpo de `handleGrowGestureEnded`:

```swift
    func handleGrowGestureEnded() {
        stopDisplayLink()
        if let session = growSession, let prior = selectionBeforeGrow {
            // Already mirrored in selectedStrokeIDs by ticks; recomputing from
            // the snapshot guarantees the canonical commit even if a tick was
            // skipped between the last frame and release.
            selectedStrokeIDs = applyGrowToSelection(prior: prior, session: session)
        }
        growSession = nil
        growthFrame = nil
        selectionBeforeGrow = nil
    }
```

Substituir o corpo de `displayLinkTick`:

```swift
    fileprivate func displayLinkTick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = max(0, now - lastTickTimestamp)
        lastTickTimestamp = now
        guard let session = growSession, let prior = selectionBeforeGrow else { return }
        let frame = session.tick(deltaTime: dt)
        growthFrame = frame
        // Mirror the running session into the published selection so the
        // highlight layer paints captured strokes as they get admitted.
        selectedStrokeIDs = applyGrowToSelection(prior: prior, session: session)
    }
```

- [ ] **Step 3.4: Rodar test novamente; deve passar**

Run: `xcodebuild test -scheme PenSculpt -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' -only-testing:PenSculptTests/DrawingViewModelTests/testGrowAddUnionsWithPriorSelection 2>&1 | tail -10`

Expected: PASS.

- [ ] **Step 3.5: Rodar suite completa do `DrawingViewModelTests`**

Run: `xcodebuild test -scheme PenSculpt -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' -only-testing:PenSculptTests/DrawingViewModelTests 2>&1 | tail -20`

Expected: todos passam, incluindo os preexistentes (`testGrowGestureStartReflectsAdmittedStrokesImmediately`, `testGrowGestureEndCommitsSelection`, `testGrowGestureCancelRevertsSelection`, `testToggleModeCancelsActiveGrow`).

Atenção em particular a `testGrowGestureEndCommitsSelection` — ele espera que após end com seleção prévia vazia, `selectedStrokeIDs == [id]`. Como `prior = []`, `applyGrowToSelection` retorna `[] ∪ {id} = {id}`. Continua válido.

- [ ] **Step 3.6: Commit**

```bash
git add PenSculpt/Views/DrawingViewModel.swift PenSculptTests/DrawingViewModelTests.swift
git commit -m "$(cat <<'EOF'
feat(grow-selection): grow now adds to the existing selection

Replaces the implicit "replace" semantics with selectionBeforeGrow ∪
session.includedStrokeIDs at both tick and finalize. Lasso is
unchanged. Subtract mode wiring lands in the next commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Detectar subtract mode no `DrawingViewModel`

Quando `origin.initialStrokeID` está em `selectedStrokeIDs`, criar a session com `mode: .subtract` e `candidatePool` restrito aos strokes selecionados.

**Files:**
- Modify: `PenSculpt/Views/DrawingViewModel.swift`
- Modify: `PenSculptTests/DrawingViewModelTests.swift`

- [ ] **Step 4.1: Escrever tests falhando para subtract**

Em `PenSculptTests/DrawingViewModelTests.swift`, na seção "Grow selection lifecycle", adicionar:

```swift
    func testGrowSubtractRemovesSeedFromSelection() {
        // Long-press on an already-selected stroke must subtract: the seed
        // comes out of the selection immediately.
        let vm = makeVM()
        let keepID = UUID()
        let keep = Stroke(id: keepID, points: [
            StrokePoint(location: CGPoint(x: 1000, y: 1000), pressure: 1, tilt: 0, azimuth: 0, timestamp: 0)
        ])
        let removeID = UUID()
        let remove = Stroke(id: removeID, points: [
            StrokePoint(location: .zero, pressure: 1, tilt: 0, azimuth: 0, timestamp: 0)
        ])
        vm.canvas.strokes = [keep, remove]
        vm.selectedStrokeIDs = [keepID, removeID]

        vm.handleGrowGestureStarted(origin: .stroke(strokeID: removeID, anchor: .zero))
        XCTAssertEqual(vm.selectedStrokeIDs, [keepID],
                       "subtract removes the seed from the live selection")

        vm.handleGrowGestureEnded()
        XCTAssertEqual(vm.selectedStrokeIDs, [keepID],
                       "finalize commits the difference")
    }

    func testGrowSubtractRestrictsPoolToSelected() {
        // A non-selected stroke between the seed and another selected one
        // must NOT block or be touched by the subtract halo.
        let vm = makeVM()
        let aID = UUID()
        let bID = UUID()
        let outsiderID = UUID()
        let a = Stroke(id: aID, points: [
            StrokePoint(location: .zero, pressure: 1, tilt: 0, azimuth: 0, timestamp: 0)
        ])
        let outsider = Stroke(id: outsiderID, points: [
            StrokePoint(location: CGPoint(x: 5, y: 0), pressure: 1, tilt: 0, azimuth: 0, timestamp: 0)
        ])
        let b = Stroke(id: bID, points: [
            StrokePoint(location: CGPoint(x: 10, y: 0), pressure: 1, tilt: 0, azimuth: 0, timestamp: 0)
        ])
        vm.canvas.strokes = [a, outsider, b]
        vm.selectedStrokeIDs = [aID, bID]  // outsider is NOT selected

        vm.handleGrowGestureStarted(origin: .stroke(strokeID: aID, anchor: .zero))
        guard let session = vm.growSession else {
            return XCTFail("Session not created")
        }
        XCTAssertEqual(session.mode, .subtract)
        XCTAssertEqual(Set(session.candidatePool.map { $0.id }), [aID, bID],
                       "candidatePool must exclude non-selected strokes")
    }

    func testGrowAddOnEmptySpaceWithPriorSelection() {
        // Long-press on empty space with prior selection → add mode (not
        // subtract, since origin has no initialStrokeID).
        let vm = makeVM()
        let priorID = UUID()
        let prior = Stroke(id: priorID, points: [
            StrokePoint(location: CGPoint(x: 1000, y: 1000), pressure: 1, tilt: 0, azimuth: 0, timestamp: 0)
        ])
        vm.canvas.strokes = [prior]
        vm.selectedStrokeIDs = [priorID]

        vm.handleGrowGestureStarted(origin: .point(.zero))
        XCTAssertEqual(vm.growSession?.mode, .add,
                       "empty-space origin must be add mode regardless of prior selection")
        XCTAssertTrue(vm.selectedStrokeIDs.contains(priorID),
                      "prior selection must be preserved during the hold")
    }

    func testGrowSubtractCancelRevertsToPriorSelection() {
        let vm = makeVM()
        let aID = UUID()
        let bID = UUID()
        let a = Stroke(id: aID, points: [
            StrokePoint(location: .zero, pressure: 1, tilt: 0, azimuth: 0, timestamp: 0)
        ])
        let b = Stroke(id: bID, points: [
            StrokePoint(location: CGPoint(x: 1000, y: 1000), pressure: 1, tilt: 0, azimuth: 0, timestamp: 0)
        ])
        vm.canvas.strokes = [a, b]
        vm.selectedStrokeIDs = [aID, bID]

        vm.handleGrowGestureStarted(origin: .stroke(strokeID: aID, anchor: .zero))
        XCTAssertEqual(vm.selectedStrokeIDs, [bID], "seed removed during hold")

        vm.handleGrowGestureCancelled()
        XCTAssertEqual(vm.selectedStrokeIDs, [aID, bID],
                       "cancel restores the full pre-grow selection")
    }
```

Nota: `testGrowSubtractRestrictsPoolToSelected` lê `vm.growSession?.candidatePool`. Esse campo já é `let candidatePool: [Stroke]` no `GrowSession` (da Task 1), então o acesso é direto.

- [ ] **Step 4.2: Rodar tests; devem falhar**

Run: `xcodebuild test -scheme PenSculpt -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' -only-testing:PenSculptTests/DrawingViewModelTests 2>&1 | tail -30`

Expected: `testGrowSubtractRemovesSeedFromSelection`, `testGrowSubtractRestrictsPoolToSelected`, `testGrowSubtractCancelRevertsToPriorSelection` falham (modo sempre `.add` hoje). `testGrowAddOnEmptySpaceWithPriorSelection` passa.

- [ ] **Step 4.3: Implementar detecção de modo + restrição de pool**

Em `PenSculpt/Views/DrawingViewModel.swift`, substituir o corpo atual de `handleGrowGestureStarted` (da Task 3) por:

```swift
    func handleGrowGestureStarted(origin: GrowOrigin) {
        cancelLasso()
        let prior = selectedStrokeIDs
        selectionBeforeGrow = prior

        let mode: GrowMode = {
            if let seedID = origin.initialStrokeID, prior.contains(seedID) {
                return .subtract
            }
            return .add
        }()
        let candidatePool: [Stroke] = (mode == .subtract)
            ? canvas.strokes.filter { prior.contains($0.id) }
            : canvas.strokes

        let session = GrowStrategy.start(origin: origin, mode: mode, candidatePool: candidatePool)
        growSession = session
        selectedStrokeIDs = applyGrowToSelection(prior: prior, session: session)
        growthFrame = GrowFrame(
            radius: session.currentRadius,
            center: origin.anchor,
            includedStrokeIDs: session.includedStrokeIDs,
            nextCandidateID: session.nextCandidateID,
            isPaused: session.isPaused,
            mode: mode
        )
        startDisplayLink()
    }
```

- [ ] **Step 4.4: Rodar tests; todos devem passar**

Run: `xcodebuild test -scheme PenSculpt -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' -only-testing:PenSculptTests/DrawingViewModelTests 2>&1 | tail -25`

Expected: todos os testes do `DrawingViewModelTests` passam, incluindo os 4 novos.

- [ ] **Step 4.5: Rodar suite completa pra garantir que nada quebrou**

Run: `xcodebuild test -scheme PenSculpt -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' 2>&1 | tail -30`

Expected: todos os testes do projeto passam.

- [ ] **Step 4.6: Commit**

```bash
git add PenSculpt/Views/DrawingViewModel.swift PenSculptTests/DrawingViewModelTests.swift
git commit -m "$(cat <<'EOF'
feat(grow-selection): subtract mode when long-pressing a selected stroke

Origin on a stroke that's already selected → subtract grow: halo
removes strokes from the selection. CandidatePool is restricted to
the prior selection so the halo can't touch non-selected strokes.
Empty-space origin stays add even with a prior selection.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: `clearSelection()` no `DrawingViewModel`

Método público pra zerar a seleção, consumido pelo botão Deselect.

**Files:**
- Modify: `PenSculpt/Views/DrawingViewModel.swift`
- Modify: `PenSculptTests/DrawingViewModelTests.swift`

- [ ] **Step 5.1: Escrever test falhando**

Em `PenSculptTests/DrawingViewModelTests.swift`, na seção "Grow selection lifecycle" (depois dos tests de Task 4), adicionar:

```swift
    func testClearSelectionEmptiesSelectedStrokeIDs() {
        let vm = makeVM()
        let s = makeStroke()
        vm.addStroke(s)
        vm.selectedStrokeIDs = [s.id]
        XCTAssertTrue(vm.hasSelection)

        vm.clearSelection()
        XCTAssertFalse(vm.hasSelection)
        XCTAssertTrue(vm.selectedStrokeIDs.isEmpty)
    }
```

- [ ] **Step 5.2: Rodar; deve falhar com "no member 'clearSelection'"**

Run: `xcodebuild test -scheme PenSculpt -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' -only-testing:PenSculptTests/DrawingViewModelTests/testClearSelectionEmptiesSelectedStrokeIDs 2>&1 | tail -10`

Expected: FAIL — compilation error sobre `clearSelection` não encontrado.

- [ ] **Step 5.3: Implementar `clearSelection`**

Em `PenSculpt/Views/DrawingViewModel.swift`, na seção `// MARK: - Selection` (depois de `handleGrowGestureCancelled`), adicionar:

```swift
    /// Clears the current selection. Used by the Deselect button in the
    /// selection action bar.
    func clearSelection() {
        selectedStrokeIDs = []
    }
```

- [ ] **Step 5.4: Rodar test; deve passar**

Run: `xcodebuild test -scheme PenSculpt -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' -only-testing:PenSculptTests/DrawingViewModelTests/testClearSelectionEmptiesSelectedStrokeIDs 2>&1 | tail -10`

Expected: PASS.

- [ ] **Step 5.5: Commit**

```bash
git add PenSculpt/Views/DrawingViewModel.swift PenSculptTests/DrawingViewModelTests.swift
git commit -m "$(cat <<'EOF'
feat(grow-selection): add clearSelection() to DrawingViewModel

Public method consumed by the Deselect button (lands next).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Paleta vermelha em `GrowthVisualization` quando `frame.mode == .subtract`

Mudança puramente visual no `draw(_:)`. Verificação só por teste manual (UIKit drawing não é coberto por unit tests aqui).

**Files:**
- Modify: `PenSculpt/Views/GrowthVisualization.swift`

- [ ] **Step 6.1: Adicionar paleta subtract + ramo de seleção em `draw`**

Em `PenSculpt/Views/GrowthVisualization.swift`, no struct `GrowthVisualization`, depois das constantes estáticas existentes (linha ~14), adicionar:

```swift
    // Subtract-mode palette: same alphas, red hue.
    static let subtractSphereStrokeColor = UIColor.systemRed.withAlphaComponent(0.7)
    static let subtractSphereFillColor = UIColor.systemRed.withAlphaComponent(0.08)
    static let subtractCandidatePeak = UIColor.systemRed.withAlphaComponent(0.65)
    static let subtractCandidateBase = UIColor.systemRed.withAlphaComponent(0.25)
```

No método `draw(_ rect:)` do `GrowthVisualizationView`, logo após `let center = convert(model.center)` (linha ~56), adicionar uma seleção das cores em uso:

```swift
        let sphereFill: UIColor
        let sphereStroke: UIColor
        let candidateBase: UIColor
        switch model.mode {
        case .add:
            sphereFill = GrowthVisualization.sphereFillColor
            sphereStroke = GrowthVisualization.sphereStrokeColor
            candidateBase = GrowthVisualization.candidateBase
        case .subtract:
            sphereFill = GrowthVisualization.subtractSphereFillColor
            sphereStroke = GrowthVisualization.subtractSphereStrokeColor
            candidateBase = GrowthVisualization.subtractCandidateBase
        }
```

Substituir as três referências às cores estáticas no corpo de `draw`:

- `ctx.setFillColor(GrowthVisualization.sphereFillColor.cgColor)` → `ctx.setFillColor(sphereFill.cgColor)`
- `ctx.setStrokeColor(GrowthVisualization.sphereStrokeColor.cgColor)` → `ctx.setStrokeColor(sphereStroke.cgColor)`
- `ctx.setStrokeColor(GrowthVisualization.candidateBase.withAlphaComponent(CGFloat(opacity)).cgColor)` → `ctx.setStrokeColor(candidateBase.withAlphaComponent(CGFloat(opacity)).cgColor)`

A halo amarela (pausa) permanece sem ramo — é mode-agnostic.

- [ ] **Step 6.2: Build de verificação**

Run: `xcodebuild build -scheme PenSculpt -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' 2>&1 | tail -20`

Expected: build succeeds. Sem unit test novo (mudança puramente de pintura).

- [ ] **Step 6.3: Rodar suite completa pra garantir que nada quebrou**

Run: `xcodebuild test -scheme PenSculpt -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' 2>&1 | tail -10`

Expected: todos os tests continuam passando.

- [ ] **Step 6.4: Commit**

```bash
git add PenSculpt/Views/GrowthVisualization.swift
git commit -m "$(cat <<'EOF'
feat(grow-selection): red halo + candidate pulse in subtract mode

Same alphas, red hue replaces blue/orange when frame.mode == .subtract.
Pause halo (yellow) stays mode-agnostic.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Tooltip `.deselect`

Adiciona o case ao enum `TooltipID` com título e subtítulo apropriados.

**Files:**
- Modify: `PenSculpt/Views/Tooltips/TooltipID.swift`

- [ ] **Step 7.1: Adicionar o case**

Em `PenSculpt/Views/Tooltips/TooltipID.swift`, na seção `// Drawing — overlay` (depois de `case toolbarCollapse`, linha ~20), adicionar:

```swift
    case deselect
```

No switch dentro de `var content`, depois do case `.toolbarCollapse`, adicionar:

```swift
        case .deselect:           return .init(title: "Deselect", subtitle: "Clear the current stroke selection")
```

- [ ] **Step 7.2: Build de verificação**

Run: `xcodebuild build -scheme PenSculpt -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' 2>&1 | tail -10`

Expected: build succeeds.

- [ ] **Step 7.3: Commit**

```bash
git add PenSculpt/Views/Tooltips/TooltipID.swift
git commit -m "$(cat <<'EOF'
feat(tooltips): add .deselect case for the new selection action bar

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: Selection action bar com botão Deselect

Renomear `sculptButton` → `selectionActionBar` em `DrawingScreen.swift` e transformá-lo num HStack `[Deselect, Sculpt]`. Mesma condição de visibilidade e mesma transição.

**Files:**
- Modify: `PenSculpt/Views/DrawingScreen.swift`

- [ ] **Step 8.1: Substituir `sculptButton` por `selectionActionBar`**

Em `PenSculpt/Views/DrawingScreen.swift`, substituir o método atual `sculptButton` (linhas ~127–138):

```swift
    private var sculptButton: some View {
        Button { vm.showSculptScreen = true } label: {
            Label("Sculpt", systemImage: "cube")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.blue, in: Capsule())
                .foregroundStyle(.white)
        }
        .padding(.bottom, 30)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
```

por:

```swift
    private var selectionActionBar: some View {
        HStack(spacing: 16) {
            Button {
                vm.clearSelection()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: Capsule())
                    .foregroundStyle(.primary)
            }
            .tooltip(.deselect)

            Button { vm.showSculptScreen = true } label: {
                Label("Sculpt", systemImage: "cube")
                    .font(.headline)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(.blue, in: Capsule())
                    .foregroundStyle(.white)
            }
        }
        .padding(.bottom, 30)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
```

- [ ] **Step 8.2: Atualizar a chamada no `body`**

No `body` (linha ~32):

```swift
            if vm.appMode == .select && vm.hasSelection { sculptButton }
```

substituir por:

```swift
            if vm.appMode == .select && vm.hasSelection { selectionActionBar }
```

- [ ] **Step 8.3: Build + suite completa pra garantir que nada quebrou**

Run: `xcodebuild test -scheme PenSculpt -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' 2>&1 | tail -15`

Expected: build succeeds; todos os tests passam.

- [ ] **Step 8.4: Commit**

```bash
git add PenSculpt/Views/DrawingScreen.swift
git commit -m "$(cat <<'EOF'
feat(grow-selection): add Deselect button next to Sculpt

sculptButton becomes selectionActionBar — HStack with [Deselect (X),
Sculpt]. Same visibility condition (hasSelection) and bottom transition.
Deselect calls vm.clearSelection().

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 9: Teste manual e checklist final

Não é uma task de código — é a validação de UX no iPad antes de considerar a feature pronta.

**Files:** nenhum.

- [ ] **Step 9.1: Build e run no iPad**

Run: `xcodebuild build -scheme PenSculpt -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' 2>&1 | tail -5`

Expected: build succeeds. Deploy no iPad físico do usuário pra testar com Pencil.

- [ ] **Step 9.2: Executar o checklist manual do spec**

Validar cada cenário em ordem (do spec, seção "Testes — Manual"):

1. Add básico: lasso seleciona A → long-press em outra área → grow capta novos → seleção final inclui A + novos.
2. Add em stroke não-selecionado com seleção prévia: long-press em X (não selecionado), prior = {A, B} → halo nasce em X, cresce → seleção final inclui A + B + X + vizinhos.
3. Subtract em stroke isolado: seleção = {A, B, C}. Long-press em A, soltar imediato → seleção = {B, C}.
4. Subtract em cluster: seleção = {A, B, C} próximos. Long-press em A, segurar até halo cobrir B → soltar → seleção = {C}.
5. Subtract com não-selecionados próximos: seleção = {A, B}, D não-selecionado entre. Long-press em A → halo pula D (fora do pool), pode remover B.
6. Deselect button: com seleção qualquer, tocar `xmark` → seleção limpa, action bar some.
7. Lasso após grow: grow-add deixa {A, B, C}. Fazer lasso em torno de D → seleção vira {D}. Lasso substitui (preservado).
8. Cancel via mode toggle durante subtract: long-press em A (halo vermelho aparece), enquanto cresce → tocar `pencil.tip` → seleção reverte pra `selectionBeforeGrow`.
9. Hit-tolerance edge: long-press perto (não em cima) de stroke selecionado → confirmar se vira subtract sem querer. Tolerance = 8pt; ajustar se gerar falsos positivos.

- [ ] **Step 9.3: Anotar achados**

Se algum cenário falhar ou indicar ajuste de parâmetro (co-admit factor, hit-tolerance), criar uma nova task ou ajuste em isolado. Casos esperados:
- Co-admit em subtract agressivo demais: zerar `coAdmitCatchUpFactor` só pra subtract mode (decisão revisável, listada como risco no spec).
- Hit-tolerance falso positivo de subtract: reduzir tolerância só pra detecção de subtract, mantendo 8pt pro origin geral.

- [ ] **Step 9.4: Limpar logs pendentes (separadamente)**

Os logs `[GROW-DIAG]`, `[GESTURE-DIAG]`, `[GROW-SYNC]`, `[CV-DDC]`, `[ADD-STROKE]`, `[UNDO-ADD]`, `[ERASE]`, `[LASSO-DIAG]` permanecem pendentes da sessão de 2026-05-11 (ver `grow_selection_ready_to_test.md`). Esta feature **não adiciona logs novos**. A limpeza deles é uma tarefa separada que pode ser feita em commit dedicado depois da validação manual desta feature.

---

## Resumo das mudanças por arquivo

| Arquivo | Mudança |
|---|---|
| `PenSculpt/Drawing/Selection/GrowStrategy.swift` | + `enum GrowMode`; `GrowSession.init(origin:mode:candidatePool:)`; `GrowFrame.mode`; `start(origin:mode:candidatePool:)` |
| `PenSculpt/Views/DrawingViewModel.swift` | `handleGrowGestureStarted` detecta modo e restringe pool; novo helper `applyGrowToSelection`; tick e end usam union/difference; novo `clearSelection()` |
| `PenSculpt/Views/GrowthVisualization.swift` | + paleta `subtract*`; ramo `switch model.mode` selecionando paleta no `draw` |
| `PenSculpt/Views/DrawingScreen.swift` | `sculptButton` → `selectionActionBar` (HStack `[Deselect, Sculpt]`) |
| `PenSculpt/Views/Tooltips/TooltipID.swift` | + `case deselect` |
| `PenSculptTests/Selection/GrowStrategyTests.swift` | atualiza call sites pra nova assinatura; + 3 tests de subtract |
| `PenSculptTests/DrawingViewModelTests.swift` | + 6 tests: add union, subtract remove seed, pool restriction, empty-space add com prior, subtract cancel, clearSelection |
