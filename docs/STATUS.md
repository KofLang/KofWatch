# KofWatch — Estado Atual

**Atualizado em:** 13/09/2026
**Fonte da verdade:** este arquivo resume o estado; detalhes em
[PLAN.md](PLAN.md) (decisões e gaps) e [DEVELOPMENT.md](DEVELOPMENT.md)
(como rodar).

## O que está pronto e provado

- **Fase 4 — motor de alertas: COMPLETO e validado end-to-end (14/09)** —
  regras declarativas em JSON no diretório `alerts/` (config
  `alerts.dir`), mesmo formato de manifesto dos dashboards
  (`Alerts.kf`: decode → validação → normalização → estado no runtime).
  Cada regra declara `metric`, `fnc` (avg|sum|min|max|count), `operador`
  (gt|gte|lt|lte|eq|neq), `limiar`, `janelaMs` e `duracaoMs` (0 dispara
  direto; >0 exige condição sustentada, com estado intermediário
  `pending`). O scheduler `alerts.checkMs` reavalia todas as regras a
  cada tick via `agregar` (nenhum mecanismo de consulta paralelo);
  estado persistido em memória entre ticks; erro de consulta vira
  estado `error` isolado por regra. API: `GET /api/alerts` (todos os
  estados) e `GET /api/alerts/:name` (404 se não existe, 400 se nome
  inválido). Provas: suíte 16/16 em `kof test Alerts.kf`; ciclo
  completo end-to-end com `alerts.checkMs=5000` — ingestão `cpu=90` →
  `cpu-alta` firing (log "alertas disparados: 1 de 3"); `cpu=30` → ok;
  `gpu.temp=91` com `duracaoMs=12000` → pending (~6s) → firing
  (~12s) → ok após resfriar; 404/400 corretos.
- **Descoberta de plataforma (14/09): o `kof run` lê `kof.config`, não
  `config.properties`** — o template do `kof config gen` diz
  "descomente para sobrescrever", mas o arquivo gerado com
  `--output config.properties` é IGNORADO pelo runtime: todas as
  chaves ficam nos defaults. Probe mínimo em `/tmp/kofdbg` provou: o
  runtime procura `kof.config` no CWD (também aceita `KOF_CONFIG`
  apontando o caminho). Correção no KofWatch: renomear para
  `kof.config`. Sem isso, o teste de `duracaoMs` era impossível (tick
  default 60s apagava a amostra da janela antes da duração).
- **Fase 3 — painel `stat`, agregação e unidade: COMPLETO e validado
  end-to-end (13/09)** — terceiro tipo de painel e metadados de
  apresentação no manifesto: `stat` (número agregado em destaque, com
  `fn` ∈ avg|sum|min|max|count, padrão `avg`) e `unit` (sufixo de
  formatação, ex. `"pct"`, usado por stat e gauge). `PainelManifest`/
  `Painel` ganharam `fnc`/`unit`; `errosDePainel` valida `fnc` contra
  a whitelist e `normalizarPainel` aplica os padrões. O polling do
  front usa `/api/aggregate/:name?fn=<fnc>&windowMs=...` no stat.
  Manifesto de validação: `dashboards/validacao.json` (4 painéis).
  Provas: `kof check .` limpo (5 arquivos); curl provou
  `fn=count` → `{"funcao":"count","valor":N}` e `fn=avg` com valor real;
  browser (Playwright) abriu `validacao` com 4 canvases pintados, 0
  erros de console e pulsos sem duplicação.
- **Fase 2 — frontend consome o dashboard declarativo: COMPLETO e
  validado end-to-end (13/09)** — o dashboard kof-ui (`web/Index.kf`)
  trocou a tabela de séries cruas pelos painéis reais do manifesto:
  `GET /api/dashboards` alimenta o seletor; `GET /api/dashboard/:name`
  + `/api/dashboard/:name/panels` viram `PainelFront` no front; cada
  pulso reconsulta por painel — gauge → `GET /api/aggregate/:name?
  fn=avg&windowMs=...`, timeseries → `GET /api/query/:name?
  from=agora-fromMs&to=agora` — e renderiza `timeseries` (Canvas:
  grid + área + linha) e `gauge` (arco cinza + arco ciano proporcional
  + valor), com fallback "Painel nao suportado" para outros tipos.
  Provas no browser: 3 canvases fixos (sem duplicação) em 180+ pulsos;
  POST de `gpu.temp=0.72` refletiu sozinho no arco do gauge no pulso
  seguinte (20 → 2248 pixels cianos, texto central 5 → 105 px) sem
  reload; manifesto editado no disco apareceu na API sem tocar no
  front (desacoplamento provado) e foi restaurado.
- **Bug do `View.bind` acumulativo corrigido via patch de runtime** —
  `kofUiViewBind` do runtime só fazia `appendChild` (painéis
  duplicavam a cada pulso). O `scripts/build-dashboard.sh` agora
  aplica DOIS patches pós-build, idempotentes: (1) fetch real no bloco
  fallback, (2) semântica de substituição no bind (limpa filhos antes
  de append). Com (2), os laços manuais de remoção no `Index.kf`
  foram removidos (eram frágeis: emissor embaralha incremento/acesso
  em `while` — ver Lições).
- **Fase 2 — pipeline de manifestos COMPLETO
  e validado end-to-end (13/09)** — dashboards declarados em JSON no Git
  (`dashboards/system.json`), carregados por `Manifest.kf`
  (`carregarManifestos` → validação → normalização → runtime model) e
  servidos pelo backend: `GET /api/dashboards` (resumo), 
  `GET /api/dashboard/:name` (Dashboard completo, 404 se não existe, 400
  se nome inválido). Prova: curl nos 4 caminhos com o manifesto real —
  3 painéis decodificados do arquivo, normalização aplicada (gauge
  recebeu `fromMs=3600000`, timeseries recebeu `windowMs=60000`), sem
  regressão em health/info/metrics.
- **Convenção do manifesto (workaround do gap do decoder)** — todo painel
  declara SEMPRE `fromMs` e `windowMs`; `0` significa "não se aplica" e
  `normalizarPainel` mapeia `0`/nulo para os padrões (3600000/60000);
  validação rejeita só negativos. A função de agregação chama-se `"fnc"`
  no JSON (não `"fn"`): `json.decode` casa chaves pelo nome EXATO do
  campo do record, sem alias (PLAN §1, gaps 13/09). Stat sem `"fnc"`
  vira `avg`; demais tipos forçam agregação vazia.

- **Backend JVM completo** (`Main.kf` + `Model.kf` + `Storage.kf`):
  ingestão e consulta de séries temporais em H2 em arquivo
  (`data/kofwatch`), rotas `/api/health`, `/api/info`, `/api/metrics`
  (GET/POST), `/api/query/:name`, `/api/aggregate/:name`; auto-coleta via
  `scheduler.every` e retenção de 24h. Sobe com `kof run --deps Main.kf`
  na porta 8080, CORS aberto nos GETs.
- **Validação de entrada (Etapa A da continuação, 12/09)** — todas as
  rotas devolvem 400 com `{"erro": ...}` para entrada inválida:
  ingestão exige `name`, `valor` numérico e `ts` inteiro não-negativo
  (contrato novo: record `MetricaIn` com campos String — ver PLAN §4);
  `from`/`to`/`windowMs` devem ser inteiros; `fn` restrito a
  avg/sum/min/max/count; `labels` fora do formato canônico → 400; body
  JSON malformado → 400. Métrica inexistente responde `[]`/`0.0`
  (graceful). Prova: bateria curl com 12 casos inválidos → 12×400,
  ingestão válida → 201, health → `UP`.
- **Dashboard kof-ui ao vivo** (`web/Index.kf`): tabela de séries,
  seletor, gráfico Canvas com grid + área preenchida, atualização
  automática a cada 3s (`time.interval`) e botão "atualizar" manual.
- **Atualização ao vivo PROVADA no browser** (duas vezes): métrica
  ingerida via curl apareceu sozinha na tabela/select no tick seguinte,
  sem reload (provas: `temp.cpu` pulso 20; `temp.gpu` id 12, pulso 1).
  Canvas validado por contagem de pixels (57.978 pintados).
- **Testes**: suíte de labels 10/10 verde (`kof test Labels.kf`).
- **Documentação**: README de uso, DEVELOPMENT.md, PLAN.md (MVP Etapas
  1-6 concluídas).

## Estado do modo de execução do front

| Modo | I/O do runtime | Status |
|---|---|---|
| Browser (http.server + build js) | fetch (precisa patch no `kof-runtime.mjs`) | ao vivo, PROVADO |
| Webview nativo (`kof run --target=js`) | GraalJS → Java HttpClient (síncrono) | ao vivo, PROVADO (13/09) |

Prova do webview nativo (13/09): `kof run --target=js web/Index.kf` via
`flatpak-spawn --host` na sessão Wayland do host abre a janela
`kof-webview` (WebKitWebProcess ativo). Testemunha server-side: o
backend saltou de ~19-20 consultas/min de `cpu.busy` (só o browser) para
**39-40 consultas/min** com o webview em pé — dois clientes puxando por
painel no tick de 3s. O I/O nativo resolve via Java HttpClient do
GraalJS interop (síncrono, em `kofHttpRequest` do runtime), sem
precisar do patch do fetch. Obervação: `DISPLAY=:0` do host é headless
(só daemons X); a janela renderiza pelo Wayland — screenshot não é
possível por X11, e a prova é server-side.

No browser, o build fresco da 0.3.22-beta emite stub `""` no bloco
"Fallback to fetch" do `kof-runtime.mjs`. O patch agora é aplicado
automaticamente por `scripts/build-dashboard.sh` (pendência 2
resolvida): o script gera o build e substitui o corpo do `if` stub por
fetch assíncrono que devolve uma Promise de string — o `kofAwait` do
runtime e o `kofSpawnResult` achatam a Promise corretamente. Detalhes
que custaram debugging: um patch que só troca a linha `return ""`
deixa um `}` órfão (SyntaxError "Missing catch or finally after try");
retornar um handle customizado quebra o flatten do `kofSpawnResult`
(JSON.parse recebe objeto); `await` direto na função síncrona é
"Unexpected reserved word"; e o `headers` chega como string
`"K: V\n..."`, precisando parse antes do fetch. Prova: build de
23:18 com 3 séries reais — tabela, select, rótulo, Canvas (61k pixels
pintados), polling ao vivo (gpu.temp apareceu sozinha no pulso
seguinte) e botão atualizar, tudo sem erros no console.

## Pendências conhecidas (não bloqueiam o MVP)

1. ~~Revalidar um pulso do webview nativo end-to-end~~ RESOLVIDA (13/09):
   provado server-side (39-40 consultas/min no backend com webview em
   pé vs ~20 só com browser); ver tabela acima.
2. ~~`kof build` do dashboard com patch embutido no fluxo~~ RESOLVIDA:
   `scripts/build-dashboard.sh` (12/09) gera o build e aplica o patch
   do fetch automaticamente; validado no browser end-to-end.
3. Labels dinâmicos: `json.encode(Map)` quebrado no JVM — segue string
   canônica `k=v,k=v`.
4. `sort`/`join` ausentes na stdlib 0.3.22 — contorno local em
   `Labels.kf` (some quando a stdlib cobrir).
5. Arredondamento/formatação numérica no front: `Double` js é número JS,
   exibição via `.toString()`.
6. Query string sem URL-decode no runtime: clientes não devem
   percent-encode os valores de `labels` (ver PLAN §4).
7. Suíte de testes multi-arquivo: `kof test <dir>` compila cada arquivo
   isolado e falha em dependências (ver PLAN §4); cobrir rotas com
   bateria curl em script.
8. ~~Front ainda não consome `/api/dashboard/:name`~~ RESOLVIDA (13/09):
   o dashboard kof-ui agora renderiza os painéis do manifesto
   (timeseries + gauge) com live update por `time.interval`; tipos
   desconhecidos caem no fallback "Painel nao suportado".

## Lições de execução Kof (13/09)

- `kof script` (.ks) não resolve `File`/`kof.io` (SEM011) e rejeita
  `import` (PARSE041): todo teste de leitura de arquivo via .ks alimenta
  `decode(null)`. Testar File/JSON sempre com `.kf` + `kof run`.
- `json.decode` em record com campo `Long` ausente no JSON → NPE no
  `kof_json_bind` (PLAN §4); comportamento difere entre modos (`kof run`
  vs `kof script`).
- Indexar lista decodificada com `[i]` gera `VerifyError` (aaload sobre
  ArrayList) — usar `for-in`.

## Como está rodando agora (ambiente desta sessão)

- Backend: porta 8080, subido com `kof run --deps Main.kf web/Index.kf`
  e `kof.config` em vigor (`alerts.checkMs=5000` para validação
  rápida); banco com 3 séries de semeadura (cpu.busy, gpu.temp, mem) +
  validação Etapa A ativa; concorrência provada (20 POST + 20 GET
  paralelos, 20/20 amostras persistidas). Desde 13/09 também serve os
  manifestos: `/api/dashboards` e `/api/dashboard/system` ativos,
  manifesto `dashboards/system.json` com 3 painéis (CPU ocupada, GPU
  temperatura, Memória). Desde 14/09, motor de alertas ativo com
  `alerts/latencia.json` (3 regras, `cpu-alta`, `memoria-critica`,
  `gpu-quente`).
- Dashboard: `./scripts/build-dashboard.sh /tmp/kofwatch-dash-test` +
  `python3 -m http.server 8765 --directory /tmp/kofwatch-dash-test`
  — http://localhost:8765/ (build COM patch automático do fetch).
- Reproduzível: ver "Rodando" no [README.md](../README.md).
