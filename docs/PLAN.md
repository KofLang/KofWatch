# KofWatch — Plano de Implementação (MVP)

**Status:** MVP concluído (backend + dashboard com dados reais)
**Data:** 11/09/2026 (atualizado 12/09/2026)
**Linguagem:** Kof 0.3.22-beta (`/home/mel/Documentos/Kof4j`)
**Repo:** `/home/mel/KofWatch`

---

## 1. Investigação da plataforma (o que foi verificado EMPIRICAMENTE)

Cada item abaixo foi compilado e executado com `kof run` antes de entrar
neste plano — nada aqui é suposição.

### Verificado funcionando ✅

| Capacidade | API | Verificação |
|---|---|---|
| Servidor HTTP | `web.app()` + `app.get/post` + `app.listen(port)` | probe `/api/ping` respondeu `{"msg":"pong","n":42}` |
| HTTP client JVM | `http.get/post/...` | probe consultou o servidor acima |
| HTTP client KofJS (runner embarcado) | `http.get` via interop `Java HttpClient` | probe `--target=js` consultou o servidor acima |
| JSON | `json.encode(record/list)`, `json.decode<T>(body)` | round-trip de `record Point(Int x, Int y)` OK |
| H2 via kof.db | `db.connect("jdbc:h2:...")` + `db.execute/query` com bind Double | probe com `kofdeps` contendo `com.h2database:h2:2.2.224` + `kof run --deps` |
| Timestamp | `time.now()` → epoch millis (Long) | probe imprimiu `1789165139645` |
| kof-ui | `Window`, `Label`, `Button`, `Input`, `Table`, `Canvas`, `Column/Row/View/Style`, `Router` | app de teste abriu webview e renderizou |
| Execução UI | `kof run app.kf --target=js` → GraalJS embarcado + webview nativo (`bin/kof-webview`, WebKitGTK) | probe rodou com exit 0 |

### Gaps/limitações da plataforma que afetam o desenho ⚠️

1. **`json.encode(mapOf(...))` quebra no JVM** — `InaccessibleObjectException`
   (reflection sobre `java.util.HashMap` contra módulos fechados).
   **Consequência:** não serializar `Map` direto; usar records e listas.
2. **`http.get` no browser re-executado pelo webview retorna `""`** — o
   fallback fetch síncrono não existe (`JsRuntimeUiLayout.kofHttpRequest`).
   No runner embarcado funciona (interop Java). **Consequência:** ver §3
   (padrão de dados do front).
3. **`kof serve` não carrega `--deps`** — `kof serve` não injeta o classpath
   do `kofdeps`. **Consequência:** subir o backend com `kof run --deps`.
4. **`val` é palavra reservada da linguagem** — o campo do valor se chama
   `valor`, e `valor` é a chave correspondente no JSON (mesma situação de `fn`).
5. **PKG002** — um módulo (diretório raso compilado junto) aceita só um
   `main()`. **Consequência:** um único `main()` no main.kf; as rotas ficam
   registradas ali, sem camada `Api.kf` (ver §2).
6. **Sem `synchronized`/locks na linguagem** — concorrência é
   `spawn`/`await`/`channel`. Escrita concorrente no H2 passa pelo handle
   único do `kof.db`; para o MVP, o volume é baixo (virtual threads + H2
   MVStore toleram; risco registrado).
7. **`kof.web.App` não existe em runtime** — só em compile-time (em runtime
   um app é um handle `String`), então o app não atravessa fronteira de
   função. **Consequência:** as rotas ficam no `main()`, sem camada `Api.kf`
   (uma camada a mais seria cerimônia).
8. **`src/` quebra o decode tipado** — `kof.toml` + fontes em `src/` deriva
   o package `src` no JVM, e o `json.decode<T>`/`db.query<T>` tipados não
   resolvem o tipo do outro arquivo. **Consequência:** os fontes vivem na raiz
   do projeto (package default) — ver §2.
9. **`List` não tem `sort` nem `join` na stdlib (0.3.22-beta)** — a ordenação
   canônica de labels usa contorno local isolado em Labels.kf, rotulado e
   previsto para sumir quando a stdlib cobrir sort/join (§4).

---

## 2. Arquitetura do MVP

```
┌───────────────────────────────┐      ┌──────────────────────────────┐
│  Frontend kof-ui (target js)  │      │  Backend Kof (target jvm)    │
│  web/Index.kf                 │      │  src/Main.kf                 │
│                               │      │                              │
│  Window + Dashboard shell     │      │  web.app()                   │
│  - tabela de métricas         │      │  ├─ POST /api/metrics        │
│  - painel de consulta         │◄────►│  ├─ GET  /api/metrics        │
│  - polling via time.interval  │      │  ├─ GET  /api/query/:name    │
│    + http.get (runner         │      │  ├─ GET  /api/health         │
│      embarcado/webview)       │      │  └─ (H2 em arquivo data/)    │
└───────────────────────────────┘      └──────────────────────────────┘
```

### Targets

- **Backend:** `jvm` — único target com `web.app()` + `kof.db` hoje
  (WEB001/DB001 nos outros). Honestidade (R6/R7): o MVP é JVM-first, com
  gaps documentados, não fallback silencioso.
- **Frontend:** `js` (KofJS/kof-ui) — `kof run --target=js` abre o webview
  nativo; `http.get` funciona no runner embarcado (interop Java HttpClient),
  que é exatamente o modo de execução do kof-ui (ver §1, gap 2: a re-execução
  browser-side pura é que perde `http.*`).

> Detalhe do runtime (lido em `KofJsRunner`/`KofJsWebview`): o programa kof-ui
> roda no GraalJS embarcado; o webview recebe a página serializada e
> re-executa o módulo para eventos. O polling de dados usa
> `time.interval(ms, fn)` — a fila cooperativa é bombeada pelo runner; para
> o evento de refresh no browser, o fallback é o botão de atualizar (clique
> re-renderiza com `http.get` — no runner embarcado funciona; registrado
> como risco do target js alpha).

### Armazenamento — H2 em arquivo (kof.db, JVM)

```sql
CREATE TABLE IF NOT EXISTS samples(
  id BIGINT AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(128) NOT NULL,
  ts BIGINT NOT NULL,          -- epoch millis (time.now())
  val DOUBLE NOT NULL,         -- 'value' é reservado no H2
  labels VARCHAR(512)          -- "k=v,k=v" (ordenado) — dimensões do MVP
);
CREATE INDEX IF NOT EXISTS idx_samples_name_ts ON samples(name, ts);
```

- Modelo: **série temporal = (name, labels)**; cada amostra = (ts, val).
- Labels como string canônica `k=v,k=v` ordenada — extensível depois para
  tabela de dimensões normalizada (evolução, não MVP).
- Retenção: `DELETE FROM samples WHERE ts < ?` agendado por
  `scheduler.every` (config `retention.ms`, default 24h).
- Arquivo do banco: `data/kofwatch` (`jdbc:h2:./data/kofwatch;AUTO_SERVER=TRUE`).
- **Sem dependências além do driver H2** via `kofdeps` (mecanismo nativo da
  plataforma, `kof deps`).

### API (JSON)

| Rota | Método | Corpo/Query | Resposta |
|---|---|---|---|
| `/api/health` | GET | — | `{"status":"UP"}` (delega a `observability.health()`) |
| `/api/info` | GET | — | nome, versão, uptime, contadores |
| `/api/metrics` | POST | `{"name":"cpu","val":0.5,"ts":..., "labels":"host=a"}` | `201 {"ok":true,"id":N}` |
| `/api/metrics` | GET | — | lista de séries: `[{name, labels, last, lastTs, count}]` |
| `/api/query/:name` | GET | `?from=&to=&labels=` | amostras: `[{ts, val, labels}]` |
| `/api/aggregate/:name` | GET | `?fn=avg|sum|min|max|count&windowMs=` | `{"fn":"avg","value":x}` |

- Decode tipado: `record MetricIn(String name, Double val, Long ts, String labels)`.
- Erros: `throw "mensagem"` no handler → runtime vira 500 com diagnóstico (R6).
- Logs: `log.info/warn/error` (kof.logging) nas rotas de ingestão/erro.
- Config: `config.int("server.port", 8080)`, `config.str("db.url", ...)`,
  `config.int("retention.ms", ...)` — template gerado com `kof config gen`.

### Frontend kof-ui (`web/Index.kf`, target js)

- `Window("KofWatch")` + tema escuro; `Table` de séries (nome, último valor,
  timestamp); `Input` de nome de métrica + `Button("consultar")` que faz
  `http.get` e renderiza o resultado (tabela/canvas).
- **Gráfico real:** `Canvas` 2D — o painel desenha a série consultada
  (moveTo/lineTo sobre janela de tempo), redesenho a cada refresh.
- Polling: `time.interval(5000, ...)` atualiza a tabela (no runner embarcado);
  botão de refresh manual cobre o modo browser (gap 2 do §1).
- Nenhum dado inventado: tudo que o painel mostra vem de `http.get` na API.

### Estrutura do projeto

```
KofWatch/
├── kof.toml                  # [project] name=kofwatch; backend jvm
├── kofdeps                   # com.h2database:h2:2.2.224
├── scripts/auto-loop.sh      # heartbeat autônomo (porta 9093)
├── docs/                     # este plano + DEVELOPMENT.md
├── Main.kf                   # main() único: config, db, rotas, scheduler
├── Model.kf                  # records de domínio (MetricIn, Serie, Amostra)
├── Storage.kf                # DDL, insert, séries, query, agregação, retenção
├── Labels.kf                 # canonicalização de labels + suíte `test`
├── web/
│   └── Index.kf              # front kof-ui (main() próprio)
```

- Fontes na RAIZ do projeto (gap 8: `src/` deriva package e quebra o decode
  tipado) — um único `main()` no diretório (PKG002).
- `kof run --deps Main.kf` sobe o backend (porta 8080).
- `kof run --target=js web/Index.kf` abre o dashboard (webview nativo);
  `kof build web --target js --output <dir>` gera `index.html` para browser.
- `kof test Labels.kf` roda a suíte (os `test` vivem no próprio arquivo).

---

## 3. Etapas (modo autônomo — uma unidade coesa por commit)

1. **Esqueleto compilável** — kof.toml, kofdeps, Main.kf mínimo
   (`/api/health`), `kof run --deps` sobe, curl valida. ✅
2. **Storage** — Model.kf + Storage.kf (DDL/insert/query/agregação) +
   testes `kof test`. Prova: suíte verde. ✅
3. **API completa** — rotas + logs + erros (CORS `*` nos GET). Prova: curl
   em cada rota com dados reais. ✅
4. **Collector** — auto-coleta periódica via `scheduler.every`; retenção.
   Prova: amostras automáticas no H2. ✅
5. **Front kof-ui** — web/Index.kf (tabela de séries + seletor + gráfico
   Canvas com área preenchida e grid). Prova: dashboard exibindo dados
   reais do backend, troca de série redesenhando (validado no browser com
   verificação de pixels do canvas). ✅
6. **Documentação** — DEVELOPMENT.md (como rodar/testar), atualização deste
   plano, registro de gaps novos do Kof descobertos no caminho. ✅

Condição de conclusão do MVP: ingestão via curl → consulta via curl →
dashboard kof-ui exibindo a série com gráfico Canvas — tudo em Kof. ✅

7. **Robustez (Etapa A da continuação)** — validação de entrada em todas
   as rotas com 400 + `{"erro": ...}`: `name`/`valor`/`ts` obrigatórios e
   tipados na ingestão; `from`/`to`/`windowMs` inteiros; `fn` na
   whitelist; `labels` canônico (try/catch em `canonicalLabels`); body
   body JSON malformado → 400; `ts=0` passa a preencher com `time.now()`
   (comportamento documentado no README que nunca tinha sido
   implementado — divergência doc/código resolvida no código). Prova:
   bateria curl completa (8 POST + 4 GET
   inválidos → 400; ingestão válida → 201; métrica inexistente →
   `[]`/`0.0` graceful; `/api/health` → `UP`; ingestão com `ts=0`
   aparece na agregação de 60s). ✅

8. **Concorrência e retenção (fechamento da Etapa A, 12/09)** — rajada
   de 20 POST paralelos + 20 GET paralelos: 20/20 amostras persistidas
   com valores distintos e ids sequenciais, 20/20 consultas `200`,
   `count=20` na agregação; nenhuma 5xx. Retenção: agendador
   `scheduler.every` ativo desde o boot sem erro no log (ciclo default
   1h de check — retenção efetiva validada apenas por não-crashar;
   teste de janela curta fica para a Etapa E). ✅

### Desenho real do front (ajustado na Etapa 5)

O §2 previa polling via `time.interval` e consulta por Input+Button; a
execução mostrou que no target js da 0.3.22 o correto é **pré-carregar tudo
no startup** (CONC003-JS-01: handlers de UI não podem usar await/spawn; e o
http browser-side é stub — §4):

- `main()` faz `await(spawn(() -> http.get(...)))` para `/api/metrics` e
  um `/api/query/:name` por série, popular `Estado`/widgets e desenhar.
- O handler `on("change")` do `Select` é síncrono: lê o histórico
  pré-carregado e redesenha o Canvas — sem I/O.
- Widgets só são manipulados dentro do corpo do `main`/lambdas dele (passar
  widget como parâmetro de função degrada o codegen js — §4, gap 12).

### Dashboard ao vivo (ajustado depois da Etapa 6)

Probes empíricos no browser mudaram três premissas (validados com
`kof build` + `http.server` + Playwright):

1. **`time.interval` FUNCIONA no target js** — a doc/stdlib lista
   "JVM+Native", mas `kofTimeInterval` no runtime js emite `setInterval`
   nativo do browser (probe: 21+ ticks sem falha).
2. **`await` direto em handler/timer continua proibido** (CONC003-JS-01 no
   compile), mas **`spawn { ... }` de bloco é permitido dentro deles** e o
   `await(http...)` interno gera async real — o fetch propaga pela Promise.
   É assim que o dashboard rebusca dados: clique no botão "atualizar" e o
   tick de 3s disparam `spawn { }` que recarrega séries+histórico,
   atualiza tabela/select e redesenha o canvas.
3. **O fallback fetch do runtime gerado segue stub** — build fresco da
   0.3.22-beta (12/09) ainda emite `return ""` no bloco "Fallback to
   fetch" do `kof-runtime.mjs`. Para o modo browser, o build precisa do
   patch manual (bloco → `fetch(url, {method, headers, body, signal})`
   real); com o patch, o `spawn { await(http.get(...)) }` funciona pois a
   Promise propaga pelo `kofSpawnResult`/`kofAwait`. No webview nativo o
   I/O resolve via interop Java e o patch é desnecessário.

Prova de atualização automática: ingerido `temp.cpu` via curl; no tick
seguinte (pulso 20) a série apareceu sozinha na tabela e no select, sem
reload da página. Canvas verificado por contagem de pixels (57.978 pintados).

### Painéis declarativos no front (Fase 2, concluída 13/09)

O front trocou a tabela de séries cruas pelos painéis do manifesto
(`web/Index.kf`): `/api/dashboards` → seletor; `/api/dashboard/:name` +
`/api/dashboard/:name/panels` → `PainelFront`; cada pulso consulta por
painel (gauge → `/api/aggregate`, timeseries → `/api/query` com
`from=agora-fromMs`) e rebinda a coluna. Tipos suportados: `timeseries`
(grid + área + linha no Canvas) e `gauge` (arco cinza + arco ciano
proporcional + valor); outros caem no fallback "Painel nao suportado".

Dois fatos novos de runtime, ambos resolvidos como patch idempotente no
`scripts/build-dashboard.sh` (aplicado pós-build):

1. **`kofUiViewBind` acumula filhos** (só `appendChild`): sem correção,
   os painéis duplicavam a cada pulso. O patch injeta semântica de
   substituição (limpa filhos antes de append); os laços manuais de
   remoção no front foram removidos — o emissor embaralha incremento e
   acesso em `while` de remoção (`Index out of bounds`) e solta
   `kofListGet(...).remove()` cru no código gerado (`.remove is not a
   function`).
2. **Stub do fetch no fallback** (já registrado acima) — mesmo script
   aplica os dois patches.

Provas (browser, 13/09): 3 canvases fixos após 180+ pulsos (sem
duplicação); POST de `gpu.temp=0.72` refletiu sozinho no arco do gauge no
pulso seguinte (pixels cianos 20 → 2248) sem reload; manifesto editado no
disco mudou o título do painel na API sem tocar no front (desacoplamento
provado; manifesto restaurado em seguida).

## 4. Gaps do Kof a registrar (não contornar em silêncio)

- `json.encode(Map)` quebrado no JVM (JDK modules) — afeta serialização de
  labels dinâmicos; workaround no KofWatch (labels string canônica).
- `http.*` browser-side: **stub `""` no binário 0.3.22-beta** — build fresco
  de 12/09 confirma o stub `return ""` no bloco "Fallback to fetch" do
  `kof-runtime.mjs` gerado. **Causa raiz investigada no fonte do Kof4j
  (branch `beta-0.4.0`, commit 94b40118): o fallback fetch real JÁ EXISTE
  em `JsRuntimeUiLayout.java` (~L475, com AbortController/timeout/retry
  circuit)** — o binário distribuído é anterior à correção. Reconstruir o
  compilador do fonte resolve sem patch (bloqueado neste ambiente: sem
  maven/java no host). Workaround atual: patch pós-build automatizado em
  `scripts/build-dashboard.sh`. Detalhes de engenharia do patch
  (custaram 4 tentativas em 12/09): (a) trocar só a linha `return ""`
  deixa um `}` órfão → SyntaxError; (b) retornar handle customizado
  quebra o flatten de Promise do `kofSpawnResult` → `JSON.parse` recebe
  objeto; (c) `await` dentro de `kofHttpRequest` (síncrona) →
  "Unexpected reserved word"; (d) `headers` chega como string
  `"K: V\n..."` e precisa ser parseada para objeto antes do fetch.
  Forma correta: substituir o corpo inteiro do `if (typeof fetch...)`
  por uma Promise de string (`resposta.text()`), parseando headers.
  No webview não precisa: I/O resolve via interop Java HttpClient.
  Classificação: Kof compiler (solução já no fonte; falta build), KofWatch (patch transitório).
- `kof serve` sem `--deps` — backend sobe com `kof run --deps`.
- **CONC003-JS-01** — handlers de widget (`on("change", ...)`) e callbacks
  de `time.interval` não podem usar `await` direto/`spawn()`/`channel.receive`.
  A forma permitida é o **bloco** `spawn { ... }` com `await(...)` dentro —
  é o mecanismo de atualização ao vivo do dashboard (§3, "Dashboard ao vivo").
- **Estáticos js (gap novo)** — campos `static` de classe com inicializador
  de runtime (`listOf<>()`) são emitidos no construtor de instância
  (`this.`) e ficam `undefined` no browser. Workaround: estado como
  variáveis locais do `main` (o compilador boxa capturas reatribuídas).
- **Widget como parâmetro (gap novo)** — no target js, manipular um widget
  dentro de função auxiliar que o recebe por parâmetro emite chamadas de
  método inexistentes (`canvas.clearRect is not a function`). O mesmo
  código inline no corpo do `main` emite as funções de runtime corretas
  (`kofUiCanvasClearRect`). Regra: tocar widgets só no escopo do `main`.
- **Canvas fill no js** — a API é `setFill` (o `setFillColor` do esboço
  inicial não existe); cores `Palette.*` e `Color.rgba(r,g,b,a)`.
- **`Double` no js é número JS** — sem `longValue()`; formatação numérica
  via `.toString()` (sem arredondamento de centavos no front do MVP).
- **Record com campo numérico nullable apagado no JVM (gap novo, 12/09)** —
  `record MetricIn(String, Double?, Long?, String)` gera accessors
  primitivos `double`/`long` no bytecode (`javap` prova): a checagem
  `campo == null` é eliminada como morta e o decoder JSON passa `null`
  para o accessor primitivo → NPE 500 ("Cannot invoke Number.longValue()")
  quando o campo falta, e 500 "argument type mismatch" quando o tipo erra.
  Em `kof script` o mesmo record mantém os campos boxed (comportamento
  inconsistente entre modos). `json.decode<Map<String,Object>>` não existe
  no runtime (`kof_json_decode_Map` sem implementação), então não há como
  decodificar mapa genérico para validar antes. Solução no KofWatch: record
  de entrada com campos `String` (`MetricaIn`) tolerante a campo ausente,
  com validação/conversão explícita → 400 com mensagem clara. Classificação:
  Kof compiler (apagamento de nullable em record) + Kof runtime (decoder
  sem mapa genérico). Solução ideal: manter boxing em record nullable e
  decoder tolerante que retorne erro tipado em vez de estourar 500.
- **`kof test <dir>` não resolve multi-arquivo (gap novo, 12/09)** — roda
  cada `.kf` como programa isolado; arquivos que dependem de outros
  (`Main.kf` usa `Storage.kf`/`Labels.kf`) falham na compilação do teste
  com "Undefined function". Suíte multi-arquivo só via `kof run` do app +
  curl. Classificação: Kof toolchain.
- **Query string sem URL-decode (gap novo, 12/09)** — `query("labels")`
  devolve o valor cru; `?labels=a%3D1` chega como literal `a%3D1` e o
  `canonicalLabels` rejeita ("label inválido"). O cliente deve enviar os
  valores sem percent-encoding (`?labels=a=1,b=2` — vírgulas e `=` passam
  ilesos). Classificação: Kof runtime (web).
- **`&&` não protege unboxing em comparação (gap novo, 12/09)** —
  `if (x != null && x < 0)` com `x: Long?` compila mas o lado direito
  unboxa mesmo assim (NPE) quando o nullable é apagado para primitivo;
  regra local: checar null em `if` separado (ver gap do record acima).
  Classificação: Kof compiler.
- **`json.decode` em record quebra com campo `Long` ausente no JSON (gap
  novo, 13/09)** — decodificar um objeto cujo painel omite uma chave
  (`fromMs` XOR `windowMs`) estoura no runtime:
  `IllegalArgumentException: NullPointerException: Cannot invoke
  "java.lang.Number.longValue()" because the return value of
  "sun.invoke.util.ValueConversions.primitiveConversion(...)" is null`, em
  `KofRuntime.kof_json_bind` (KofRuntime.java:295) — a chave ausente vira
  `null` e o caminho de bind aplica conversão primitiva sobre `null`.
  Repro mínima (modo `kof run`, arquivo lido com `File.readText`):
  `record P(String t, Long a, Long b)` + JSON `{"t":"x","a":1}` → NPE;
  com `"a":1,"b":2` explícitos decodifica perfeito (inclui Unicode). O
  mesmo conteúdo como literal embutido em `kof script` NÃO reproduz —
  comportamento difere entre modos (ver gap do record acima). Nota: em
  `kof script` (.ks) o tipo `File`/`kof.io` nem resolve (SEM011
  "Undefined variable or type: 'File'"), e `import` é rejeitado
  (PARSE041) — todo teste de leitura de arquivo via `.ks` na verdade
  alimentou `decode(null)`; a investigação só avançou no modo `kof run`.
  Workaround no KofWatch: manifesto declara SEMPRE `fromMs` e `windowMs`,
  usando `0` para "não se aplica"; `normalizarPainel` já mapeia
  `null || <= 0` para os padrões (3600000/60000) e a validação passou a
  rejeitar só negativos. Classificação: Kof runtime (decoder), mesma
  família do apagamento de nullable em record.
