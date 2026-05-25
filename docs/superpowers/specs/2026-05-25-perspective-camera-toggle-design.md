# Perspective Camera Toggle — Design

**Data:** 2026-05-25
**Status:** Aprovado em UX (pendente review do usuário)
**Autor:** Alexandre + Claude
**Relacionado:** [`2026-03-13-pensculpt-design.md`](2026-03-13-pensculpt-design.md) — câmera ortográfica como default original

## Problema

A câmera do Sculpt é exclusivamente **ortográfica** (`SculptRenderer.combinedProjection` em `SculptRenderer.swift:241` usa só `orthographicProjection`). Ortho mantém a estética 2D quando você acabou de sair do desenho, mas remove pistas de profundidade — o usuário não consegue **julgar volume / proporção 3D** com confiança antes de exportar ou apresentar o trabalho.

Quem está acostumado com ferramentas 3D (Blender, Maya, ZBrush) espera poder alternar pra perspective pra "ver de verdade" como a forma se comporta com convergência. Hoje não há esse switch.

## Solução

**1 botão no toolbar do Sculpt que alterna entre câmera ortográfica e perspective, com slider de FOV oculto atrás de long-press.**

- Tap rápido: alterna `.orthographic ↔ .perspective` com animação suave de ~0.3s
- Long-press (só em perspective): abre popover com slider de FOV (20°–90°)
- Default sempre ortho ao entrar no Sculpt — perspective é opt-in
- FOV preserva valor enquanto a tela do Sculpt está ativa; reseta a 50° ao sair e voltar

## Decisões de produto

### 1. Opt-in puro, sem persistência

Toda vez que o usuário entra no Sculpt, começa em ortho com FOV default (50°). Não há persistência por projeto nem global.

**Por quê:**
- Mantém a estética de "saí do 2D, ainda parece 2D" que ortho oferece como entrada natural
- Reduz superfície de bug — não precisa migrar `.pensculpt` schema, não precisa lidar com prefs globais
- O ajuste de FOV é tipicamente exploratório/temporário (avaliar volume), não setting permanente

### 2. FOV preserva valor dentro da sessão

Dentro de uma mesma sessão no Sculpt, alternar ortho ↔ perspective preserva o último FOV ajustado. Se o usuário levou tempo pra ajustar pra 75°, alternar ortho de volta e ativar perspective de novo mantém 75°.

**Por quê:** respeita o trabalho de ajuste fino do usuário. Reset só na transição sair → voltar é suficiente pra "limpar o estado".

### 3. Slider escondido atrás de long-press

UX limpa: 1 botão no toolbar, comportamento óbvio (tap = alterna). FOV é detalhe avançado — escondido até ser pedido com long-press. Em ortho, long-press é no-op porque não há FOV pra ajustar.

**Alternativa rejeitada:** botão separado pra FOV. Adiciona ruído visual permanente pra um controle que nem sempre é necessário.

### 4. Animação suave na alternância

A transição ortho → perspective anima a projeção em ~0.3s ease-in-out. Mantém a sensação de "câmera real" em vez de "switch técnico". Custo extra é interpolação entre matrizes de projeção, controlada por uma fase normalizada.

**Alternativa rejeitada:** snap instantâneo. Mais simples, mas perde polimento e pode desorientar (mudança grande no enquadramento no mesmo frame).

### 5. Live update do FOV no slider

Cada movimento do slider atualiza a câmera em tempo real. Padrão pra ferramentas de ajuste fino — sem live feedback, o usuário não consegue calibrar visualmente.

## Arquitetura

Quatro mudanças localizadas. Nenhum schema novo, nenhum arquivo na persistência tocado.

### `ProjectionMode` (novo enum em `SculptRenderer`)

```swift
enum ProjectionMode {
    case orthographic
    case perspective
}
```

Vive como nested type no `SculptRenderer` por escopo limitado (não exposto fora do módulo de render).

### `SculptRenderer` — estado novo

Duas propriedades públicas (mutáveis pela view):

- `var projectionMode: ProjectionMode = .orthographic`
- `var perspectiveFOV: Float = .pi / 180 * 50` — radianos, default 50°

Mais uma interna pra animação:

- `var projectionTransition: Float = 0` — 0 = ortho puro, 1 = perspective puro. Animado pela view via SwiftUI binding.

### `combinedProjection(viewSize:)` — modificado

Lê `projectionTransition`:
- Se `0`: retorna `orthographicProjection(...)` como hoje
- Se `1`: retorna `perspectiveProjection(...)` com FOV atual
- Intermediário: interpola componente a componente entre as duas matrizes (linear sobre o `transition`, suficiente pra animação curta de 0.3s; ease aplicado externamente pela curva de animação SwiftUI)

### `perspectiveProjection(fovRadians:aspect:near:far:)` (nova static func)

Matriz de projeção em perspective padrão. Câmera posicionada conceptualmente a distância `combinedRadius / tan(fov/2)` do centro do objeto pra preservar o enquadramento — em qualquer FOV, o objeto ocupa a mesma fração da viewport que em ortho. Isso evita o efeito "tudo muda de tamanho quando troco modo" que confunde o usuário.

Near/far: derivados da `combinedRadius` (mesma lógica do ortho atual: `10x` de margem).

### `SculptScreen` — UI

- `@State private var projectionMode: ProjectionMode = .orthographic`
- `@State private var perspectiveFOV: Float = .pi / 180 * 50`
- `@State private var showFOVPopover: Bool = false`
- Novo botão no toolbar, posicionado entre o `rotate.3d` e o eraser/deform (área de "view controls")
- Ícone: `cube.transparent` em ortho, `cube.transparent.fill` em perspective (sinaliza estado ativo com fill)
- `.simultaneousGesture(LongPressGesture(minimumDuration: 0.4))` no botão pra abrir popover quando em perspective
- Tap normal alterna `projectionMode` dentro de `withAnimation(.easeInOut(duration: 0.3))`
- Popover contém `Slider(value: $perspectiveFOV, in: ...)` com binding ao vivo

## Algoritmo de transição (detalhe)

O `combinedProjection` interpola entre as duas matrizes:

1. Calcula `M_ortho` (matriz ortográfica como hoje)
2. Calcula `M_persp` (matriz perspectiva com FOV atual)
3. Retorna `lerp(M_ortho, M_persp, transition)` por componente

Linear lerp de matrizes não é "fisicamente correto" (a interpolação ideal seria via decomposição polar), mas pra uma transição curta entre dois enquadramentos similares (mesmo bounds, mesma rotação), é visualmente suave o suficiente. Caso surja artefato perceptível durante teste, fallback é interpolar só o FOV efetivo (perspective com FOV variando de "quase-zero" → target).

A animação é dirigida por SwiftUI:

```swift
withAnimation(.easeInOut(duration: 0.3)) {
    projectionMode = (projectionMode == .orthographic) ? .perspective : .orthographic
}
```

`projectionTransition` é uma propriedade animatable do renderer (ou um valor SwiftUI que dispara `setNeedsDisplay` em cada tick).

## Testes

Em `PenSculptTests/`:

- **`SculptRendererProjectionTests.swift` (novo)**:
  - `perspectiveProjection` produz matriz com componente w correto (perspective divide funciona)
  - `combinedProjection` em modo ortho retorna mesmo resultado que antes do refactor (regressão zero)
  - `combinedProjection` em transition=0 == ortho puro; transition=1 == perspective puro
  - Em ambos modos, um ponto no centro do `combinedRadius` projeta perto do centro da viewport (preservação de enquadramento)

Verificação manual no iPad:
- Entrar no Sculpt → confirma que abre em ortho
- Tap no botão → animação suave por ~0.3s, agora em perspective com FOV 50°
- Long-press → popover abre, slider mexe FOV ao vivo
- Tap de novo → volta pra ortho com animação
- Tap mais uma vez → volta pra perspective com o FOV que tinha ajustado (persistiu na sessão)
- Sair do Sculpt e reentrar → começa em ortho com FOV default
- Rotação (two-finger arcball) continua funcionando idêntica em ambos os modos
- Stroke surface drawing continua acertando corretamente em perspective (raycast usa MVP atual)

## Plano de iteração

Default FOV (50°), faixa do slider (20°–90°), e duração da animação (0.3s) são valores iniciais. Tuning durante teste manual:
- Se 50° parecer "quase igual a ortho", subir o default
- Se a faixa 20°–90° tiver valores inutilizáveis, apertar
- Se 0.3s parecer lento ou abrupto, ajustar

Ícone (`cube.transparent` / `cube.transparent.fill`) é tentativa — se outro SF Symbol comunicar melhor (ex: `view.3d`, `perspective` se existir), trocar durante impl.

## Ordem de implementação

Dois commits:

1. **Renderer**: adiciona `ProjectionMode` enum, `perspectiveProjection` static func, props `projectionMode`/`perspectiveFOV`/`projectionTransition`, e modifica `combinedProjection` pra interpolar. Testes unitários cobrindo as matrizes. Sem mudança de comportamento visível (modo continua sempre ortho).

2. **UI**: adiciona o botão ao toolbar do `SculptScreen`, popover com slider, gestures, e fia o estado SwiftUI nas props do renderer com `withAnimation`. Verificação manual no iPad.

## Out of scope

- Persistência (por projeto ou global) — opt-in puro elimina essa necessidade
- Múltiplas câmeras pré-definidas (front, 3/4, top) — fora do escopo, considerar se demanda real aparecer
- Pan da câmera — câmera continua orbital (centrada no objeto) como em ortho
- Pinch zoom em perspective — fora do escopo, comportamento de pinch atual (se houver) preservado
- Mudança no raycast pra surface stroke — usa MVP atual via `combinedProjection`, funciona em ambos os modos automaticamente

## Postscript — ajustes pós-implementação (2026-05-25)

Dois ajustes de UX descobertos durante a verificação manual no iPad:

1. **Long-press → botão de slider dedicado.** O design original abria o popover de FOV via long-press no botão de toggle. Na prática isso se mostrou inviável: `simultaneousGesture(LongPressGesture)` em cima de um `Button` produziu detecção intermitente, e quando o popover abria o slider interno ficava bloqueado pelo gesture ainda ativo. Substituído por um botão de engrenagem (`slider.horizontal.3`) que aparece **só quando perspective está ativo**, com tap simples pra abrir/fechar o popover. A "alternativa rejeitada" do design ("Adiciona ruído visual permanente") foi resolvida tornando o botão **condicional ao modo perspective** — em ortho ele some, evitando o ruído. Commit: `2edf64e`.

2. **Realocação do `.bottomTrailing` → `.topTrailing`.** O design colocava o toggle perto do `rotate.3d` no canto inferior, junto com eraser/deform. Esse cluster já estava apertado e os botões novos pioraram a precisão de toque. Movidos pra um overlay `.topTrailing` separado — agrupando-os com os outros controles de "view" (close, share, color, etc.) ao invés de com as ferramentas de interação. Estilo dos botões ajustado pra combinar com o toolbar do topo (`.font(.title)` + `.symbolRenderingMode(.hierarchical)`, sem o círculo material que os botões inferiores usam). Commit: `e243ab8`.
