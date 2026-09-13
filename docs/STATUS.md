# KofWatch — Estado Atual

**Atualizado em:** 13/09/2026
**Fonte da verdade:** este arquivo resume o estado; detalhes em
[PLAN.md](PLAN.md) (decisões e gaps) e [DEVELOPMENT.md](DEVELOPMENT.md)
(como rodar).

## O que está pronto e provado

- **Fase 2 — Observabilidade declarativa: pipeline de manifestos COMPLETO
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
  validação rejeita só negativos. Causa raiz: `json.decode` em record
  NPEia com campo `Long` ausente no JSON (PLAN §4, gap 13/09).

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
| Webview nativo (`kof run --target=js`) | interop Java HttpClient | mecanismo igual; pulso end-to-end não revalidado nesta sessão |

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

1. Revalidar um pulso do webview nativo end-to-end (mesmo mecanismo do
   browser, caminho de I/O diferente).
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
8. Front ainda não consome `/api/dashboard/:name` — o dashboard kof-ui
   continua listando séries cruas (`/api/metrics` + `/api/query`);
   próximo passo da Fase 2 é renderizar os painéis do manifesto
   (timeseries + gauge) a partir do manifesto.

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

- Backend: porta 8080, banco limpo com 3 séries de semeadura
  (cpu.busy, gpu.temp, mem) + validação Etapa A ativa; concorrência
  provada (20 POST + 20 GET paralelos, 20/20 amostras persistidas).
  Desde 13/09 também serve os manifestos: `/api/dashboards` e
  `/api/dashboard/system` ativos, manifesto `dashboards/system.json`
  com 3 painéis (CPU ocupada, GPU temperatura, Memória).
- Dashboard: `./scripts/build-dashboard.sh /tmp/kofwatch-dash-test` +
  `python3 -m http.server 8765 --directory /tmp/kofwatch-dash-test`
  — http://localhost:8765/ (build COM patch automático do fetch).
- Reproduzível: ver "Rodando" no [README.md](../README.md).
