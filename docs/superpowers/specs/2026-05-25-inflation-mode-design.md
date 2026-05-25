# Inflation Mode Toggle — Design

**Data:** 2026-05-25
**Status:** Aprovado em UX (pendente review do usuário)
**Autor:** Alexandre + Claude
**Relacionado:** [`2026-03-13-pensculpt-design.md`](2026-03-13-pensculpt-design.md) — ShapeInflater pipeline original

## Problema

O `ShapeInflater` atual usa um perfil de profundidade esférico: `depth = sqrt(d * (2*maxDist - d))`, onde `d` é a distância de cada pixel até a borda do contorno. Isso produz formas **orgânicas** — qualquer 2D vira uma abóbada/blob 3D arredondada.

Resultado: quem desenha um quadrado **não consegue criar um cubo**. Vira sempre uma esfera-cubo arredondada. Limita o vocabulário de formas — não dá pra fazer caixas, blocos, prédios, mobília simples.

## Solução

**Modo de inflação alternativo: extrusão reta (cookie-cutter).** Toggle no Sculpt entre dois modos:

- **Orgânico** (default, atual): perfil esférico, formas arredondadas
- **Reto** (novo): perfil constante, lados verticais, topo plano — vira cubo/prisma

Toggle vive no toolbar do Sculpt. Alternar re-infere o objeto ativo com a nova fórmula, preservando os surface strokes existentes via reprojeção (mesmo caminho do botão `🔄` atual).

## Decisões de produto

### 1. Cubo perfeito como modo reto

O modo reto produz **cubo matemático**: lados verticais, topo totalmente plano, cantos vivos (a 90°). Sem chanfros, sem rampas suaves.

**Por quê:** o usuário pediu explicitamente isso ("Cubo perfeito"). Chanfros e rampas adicionam parâmetros (raio do chanfro, ângulo da rampa) que sobrepõem a interface. Se virar problema, ataca depois.

### 2. Per-object, persistido no documento

Cada `SculptObject` lembra seu próprio `inflationMode`. Toggle no Sculpt afeta só o objeto ativo. Modo é salvo no `.pensculpt` — abrir o arquivo de novo preserva a escolha.

**Por quê:**
- Cenas com múltiplos objetos podem combinar (uma casa cubo + uma árvore orgânica)
- Persistência mantém intenção do usuário
- Default `.organic` no decode garante retro-compatibilidade com arquivos antigos

### 3. Toggle no 3D apenas, re-infere ao tocar

Sem botão no DrawingScreen. O usuário entra no Sculpt em modo `organic` (padrão de novos objetos), avalia a forma, e decide se quer trocar. Tocar o toggle:
1. Atualiza `activeObject.inflationMode`
2. Dispara `reInfer` (mesmo caminho do botão `🔄`) com o modo novo
3. Surface strokes existentes são reprojetados no mesh novo (já existe via `reprojectStrokes`)

**Alternativa rejeitada:** toggle no 2D antes de entrar no Sculpt. Adiciona um botão a mais, e o usuário não tem feedback visual da escolha até entrar no 3D. Mais simples deixar a decisão sempre no 3D.

### 4. Default = orgânico para novos objetos

Novos objetos (via `inferNewObject`) começam com `inflationMode = .organic`. Não há "modo global atual" que se aplique a novos objetos.

**Por quê:** Comportamento atual do app é orgânico. Mantém retro-compatibilidade visual. Usuário decide caso a caso depois.

### 5. Altura do cubo = mesma do orgânico (maxDist)

A altura do cubo é igual ao `maxDist` (raio do círculo inscrito do contorno) — o mesmo valor que daria a altura da abóbada no modo orgânico.

**Por quê:**
- Quadrado 100×100 vira cubo de altura 50 (proporcional, parece cubo de verdade)
- Retângulo fino 100×10 vira slab de altura 5 (parece tijolo/laje)
- Consistente com orgânico — alternar não muda dramaticamente o tamanho
- Sem slider de altura por simplicidade (pode vir depois se necessário)

## Arquitetura

Três mudanças localizadas. Persistência muda schema do `.pensculpt`, mas com fallback decodable garante backwards-compat.

### `InflationMode` (novo enum em `SculptObject.swift`)

```swift
enum InflationMode: String, Codable, Equatable, Sendable {
    case organic
    case straight
}
```

String-raw pra estabilidade do JSON (futuros valores não quebram arquivos antigos).

### `SculptObject` — nova propriedade

```swift
var inflationMode: InflationMode = .organic
```

`init(from decoder:)` usa `decodeIfPresent(...) ?? .organic` pra carregar arquivos antigos sem o campo.

### `ShapeInflater.inflate` — branch no perfil de depth

Modificar o loop que computa `depths[row][col]`:

```swift
switch inflationMode {
case .organic:
    depths[row][col] = sqrt(d * (2 * maxDist - d))  // atual
case .straight:
    depths[row][col] = d > 0 ? maxDist : 0  // novo: constante dentro, zero fora
}
```

A função `inflate` recebe `inflationMode` como parâmetro (default `.organic` pra não quebrar callers existentes). `sculpt(from:config:)` aceita um `inflationMode` parameter ou lê do config.

### `SculptScreen` — toggle button

Novo botão no toolbar do topo (junto com close, re-infer, sparkles, etc.) — ou no topo direito ao lado do perspective toggle. **Recomendação:** topo esquerdo, junto com re-infer/sparkles (são todos controles que modificam o mesh ativo).

Ícone:
- `circle` (ortho-like, abóbada) quando em `.organic`
- `cube.fill` (cubo sólido) quando em `.straight`

Cor secondary quando orgânico, blue quando reto (consistente com outros toggles azuis do app).

Tooltip: "Inflation mode" com subtitle "Switch between organic (curved) and straight (cube)".

Tap:
1. Computa newMode toggling current
2. Atualiza `sculptObjects[activeObjectIndex].inflationMode = newMode`
3. Dispara `reInfer()` (já existe) — vai usar o novo modo via `SculptObject.inflationMode`
4. Spinner aparece como sempre durante re-infer (~30s no iPad)

Disabled durante `isReInferring` (igual aos outros botões de inferência).

## Algoritmo do modo reto (detalhe)

Pra cada pixel `(row, col)` no grid:
1. Calcular `d = distância do ponto até a borda do contorno` (já existe via `containsAndDistance`)
2. Se `d > 0` (ponto está dentro do contorno): `depth = maxDist`
3. Senão (`d == 0`, fora ou na borda): `depth = 0`

Resultado: um campo de altura tipo "plateau" — todo o interior do contorno no mesmo nível, queda vertical na borda.

O `buildMesh` existente já lida com essa topologia (gera vértices em XYZ, conecta triângulos) — não precisa mudar nada lá. A transição abrupta de `maxDist` pra `0` na borda gera quinas verticais naturalmente.

**Limitação conhecida:** triângulos da borda terão normais ambíguas (alguns apontando pra cima, outros pra fora). O renderer atual usa lighting básica — pode dar shading levemente estranho na borda. Avaliar manualmente.

## Testes

Em `PenSculptTests/`:

- **`ShapeInflaterInflationModeTests.swift` (novo)**:
  - `.straight` mode: pixel no centro de um contorno tem `depth == maxDist`
  - `.straight` mode: pixel fora do contorno tem `depth == 0`
  - `.organic` mode: pixel no centro tem `depth == maxDist` (sphere top), pixel próximo da borda tem `depth < maxDist`
  - Backwards-compat: `SculptObject` decodado de JSON sem o campo `inflationMode` resulta em `.organic`

Verificação manual no iPad:
- Desenhar um quadrado e entrar no Sculpt → confirma que aparece como esfera-abóbada (modo orgânico default)
- Tocar o novo toggle → spinner aparece ~30s → confirma que vira cubo perfeito
- Tocar de novo → volta pro orgânico
- Desenhar uma forma irregular (estrela, coração) e testar nos dois modos
- Pintar surface strokes em modo orgânico, trocar pra reto → strokes reprojetados no novo mesh
- Salvar e reabrir o `.pensculpt` → modo preservado
- Múltiplos objetos na cena com modos diferentes → confirma independência

## Plano de iteração

Valores e ícones podem mudar durante teste manual:
- Se `cube.fill` / `circle` não comunicarem bem, trocar por outros SF Symbols (`square` / `circle.dotted`, etc.)
- Se a altura do cubo (= `maxDist`) parecer baixa demais, considerar fator multiplicador
- Se shading da borda do cubo ficar ruim, gerar normais explícitas no `buildMesh` pra borda vertical

Tuning fino fica pra depois — primeiro shippa funcional.

## Ordem de implementação

Três commits sugeridos:

1. **Model + algoritmo**: adiciona `InflationMode` enum + propriedade `inflationMode` no `SculptObject` + branch no `ShapeInflater.inflate`. Testes unitários cobrindo as duas branches e o decode backwards-compat. Sem mudança UI ainda.

2. **UI**: adiciona o toggle button no `SculptScreen.topToolbar` (extraído no commit `56b22ac`). Wire up: tap → atualiza `sculptObjects[idx].inflationMode` → chama `reInfer()`. Tooltip case nova.

3. **Verificação manual no iPad**: roda o checklist da seção "Testes" e ajusta o que precisar.

## Out of scope

- Slider de altura independente da forma 2D — usa `maxDist` sempre
- Modos intermediários (chamfered, rampa suave) — só os 2 modos puros
- Toggle no 2D antes de entrar no Sculpt — só no 3D
- Aplicar modo automaticamente a novos objetos baseado em uma config global — sempre default `.organic`
- Animação suave entre os modos (tipo o perspective transition) — re-infer abrupto, já existe spinner
- Mudança no algoritmo de surface stroke reprojection — usa o existente
