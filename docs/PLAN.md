# KofWatch — Plano de Implementação (MVP)

**Status:** em desenvolvimento
**Data:** 11/09/2026
**Linguagem:** Kof 0.3.0-beta (`/home/mel/Kof4j`)
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
4. **`value` é palavra reservada no H2** — colunas de valor usam `val`.
5. **PKG002** — um módulo (diretório raso compilado junto) aceita só um
   `main()`. **Consequência:** um único `main()` no projeto backend.
6. **Sem `synchronized`/locks na linguagem** — concorrência é
   `spawn`/`await`/`channel`. Escrita concorrente no H2 passa pelo handle
   único do `kof.db`; para o MVP, o volume é baixo (virtual threads + H2
   MVStore toleram; risco registrado).

---

## 2. Arquitetura do MVP

```
┌───────────────────────────────┐      ┌──────────────────────────────┐
│  Frontend kof-ui (target js)  │      │  Backend Kof (target jvm)    │
│  web/Index.kf                 │      │  src/Main.kf                 │
│                               │      │                              │
│  Window + Dashboard shell     │      │  web.app()                   │
│  - tabela de métricas         │ HTTP │  ├─ POST /api/metrics        │
│  - painel de consulta         │◄────►│  ├─ GET  /api/metrics        │
│  - polling via time.interval  │ JSON │  ├─ GET  /api/query/:name    │
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
├── src/                      # backend (package kofwatch)
│   ├── Main.kf               # main() único: config, db, rotas, scheduler
│   ├── Model.kf              # records de domínio (MetricIn, Serie, Amostra)
│   ├── Storage.kf            # DDL, insert, séries, query, agregação, retenção
│   ├── Api.kf                # registro das rotas web.app()
│   └── Collector.kf          # auto-coleta: uptime/samples via scheduler
├── web/
│   └── Index.kf              # front kof-ui (package vazio, main() próprio)
└── tests/
    └── Storage.kf            # `test "..." { assert }` — storage/query/labels
```

- `kof run --deps src/Main.kf` sobe o backend (module root: `src/`).
- `kof run --target=js web/Index.kf` abre o dashboard.
- `kof test tests/` roda a suíte estruturada.

---

## 3. Etapas (modo autônomo — uma unidade coesa por commit)

1. **Esqueleto compilável** — kof.toml, kofdeps, src/Main.kf mínimo
   (`/api/health`), `kof run --deps` sobe, curl valida.
2. **Storage** — Model.kf + Storage.kf (DDL/insert/query/agregação) +
   testes `kof test`. Prova: suíte verde.
3. **API completa** — Api.kf com as 6 rotas + logs + erros. Prova: curl em
   cada rota com dados reais.
4. **Collector** — auto-coleta periódica (uptime, count de amostras) via
   `scheduler.every`; retenção. Prova: amostras automáticas no H2.
5. **Front kof-ui** — web/Index.kf (tabela + consulta + Canvas). Prova:
   webview exibindo dados reais do backend.
6. **Documentação** — DEVELOPMENT.md (como rodar/testar), atualização deste
   plano, registro de gaps novos do Kof descobertos no caminho.

Condição de conclusão do MVP: ingestão via curl → consulta via curl →
dashboard kof-ui exibindo a série com gráfico Canvas — tudo em Kof.

## 4. Gaps do Kof a registrar (não contornar em silêncio)

- `json.encode(Map)` quebrado no JVM (JDK modules) — afeta serialização de
  labels dinâmicos; workaround no KofWatch (labels string canônica).
- `http.*` browser-side do KofJS retorna `""` (sem fetch síncrono) — afeta
  o modo "puro browser" do dashboard; mitigação: botão de refresh + execução
  via runner embarcado; solução definitiva é do Kof (XHR síncrono ou API
  async), registrada para a mantenedora.
- `kof serve` sem `--deps` — backend sobe com `kof run --deps`.
