# KofWatch — Estado Atual

**Atualizado em:** 12/09/2026
**Fonte da verdade:** este arquivo resume o estado; detalhes em
[PLAN.md](PLAN.md) (decisões e gaps) e [DEVELOPMENT.md](DEVELOPMENT.md)
(como rodar).

## O que está pronto e provado

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
"Fallback to fetch" do `kof-runtime.mjs` — o patch manual (bloco →
`fetch(url, {method, headers, body, signal})` real) continua necessário
(negado duas vezes: build de 18:47 com patch manual funcionando; build
fresco de 19:22 sem patch voltou ao stub).

## Pendências conhecidas (não bloqueiam o MVP)

1. Revalidar um pulso do webview nativo end-to-end (mesmo mecanismo do
   browser, caminho de I/O diferente).
2. `kof build` do dashboard com patch embutido no fluxo (script que
   aplica o patch no `kof-runtime.mjs` pós-build) para não depender de
   patch manual a cada build.
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

## Como está rodando agora (ambiente desta sessão)

- Backend: porta 8080, 7 séries (cpu ×2, cpu.busy, disk.used, mem,
  temp.cpu, temp.gpu) + validação Etapa A ativa.
- Dashboard: `python3 -m http.server 8099 --directory /tmp/idxbuild`
  (build COM patch do fetch) — http://127.0.0.1:8099/
- Reproduzível: ver "Rodando" no [README.md](../README.md).
