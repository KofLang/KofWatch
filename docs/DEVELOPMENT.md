# KofWatch — Guia de Desenvolvimento

Stack 100% Kof 0.3.22-beta: backend JVM (HTTP + H2) e frontend kof-ui
(target js, WebKit). Sem dependências além do driver H2 (`kofdeps`).

## Pré-requisitos

- Toolchain em `.tools/kof-0.3.22-beta-linux-x86_64/bin/kof`
  (os comandos abaixo assumem `KOF=./.tools/kof-0.3.22-beta-linux-x86_64/bin/kof`).
- Webview nativo precisa de `libwebkit2gtk-4.1` no host (em Flatpak, usar
  `flatpak-spawn --host` com `DISPLAY=:0`).
- Java (JVM) para o backend.

## Rodando o backend

```bash
$KOF run --deps Main.kf
```

- Porta `8080`; H2 em `./data/kofwatch` (criado na primeira subida).
- `kof serve` NÃO carrega `kofdeps` (gap registrado) — usar `kof run --deps`.

Sanidade:

```bash
curl -s localhost:8080/api/health   # {"status":"UP"} (delega a observability)
curl -s localhost:8080/api/info     # nome, versão, uptime, total de amostras
```

Ingestão:

```bash
curl -s -X POST localhost:8080/api/metrics \
  -H 'Content-Type: application/json' \
  -d '{"name":"cpu","valor":0.42,"ts":0,"labels":"host=a"}'
```

- `ts=0` → o backend preenche com `time.now()`.
- Consultas: `GET /api/metrics` (séries), `/api/query/:name?from=&to=`
  (amostras), `/api/aggregate/:name?fn=avg|sum|min|max|count&windowMs=`.
- GETs retornam `Access-Control-Allow-Origin: *` (CORS aberto para o front).

## Rodando o dashboard

### Browser (modo principal)

```bash
./scripts/build-dashboard.sh /tmp/kofbuild
python3 -m http.server 8099 --directory /tmp/kofbuild
# abrir http://127.0.0.1:8099/
```

O script gera o build com `kof build web` e aplica automaticamente DOIS
patches idempotentes no `kof-runtime.mjs` (ver detalhes em PLAN.md §4):

1. **fetch real** no bloco fallback (o emissor 0.3.22-beta gera stub `""`);
2. **View.bind com semântica de substituição** — o `kofUiViewBind` do
   runtime só fazia `appendChild` e acumulava filhos (painéis duplicando
   a cada pulso); o patch limpa os filhos antes de append. Com isso o
   front não precisa de laços manuais de remoção (que o emissor embaralha
   em `while`).

No browser, o dashboard renderiza os painéis do manifesto
(`dashboards/*.json`): `time.interval(3000)` e o botão "atualizar"
disparam blocos `spawn { ... }` que reconsultam por painel — gauge via
`/api/aggregate/:name`, timeseries via `/api/query/:name` — e rebindam a
coluna de painéis via `View.bind` (substituição). O backend precisa estar
de pé na 8080 (CORS já aberto nos GETs).

Alternativa webview nativo (GraalJS embarcado + WebKitGTK):

```bash
flatpak-spawn --host env DISPLAY=:0 \
  $KOF run --target=js web/Index.kf
```

- A toolchain 0.3.22-beta emite um stub `""` no `http` browser-side (o
  fallback do `kof-runtime.mjs` gerado não faz fetch). O patch é
  aplicado automaticamente pelo `scripts/build-dashboard.sh`; se
  precisar fazer manualmente, substitua o corpo inteiro do bloco
  `if (typeof fetch !== 'undefined')` por uma Promise de
  `resposta.text()` (parseando `headers`, que chega como string
  `"K: V\n..."`). Cheque com `grep -c "await fetch\|fetch(url,"
  kof-runtime.mjs` no build (0 = sem patch, dashboard não carrega
  dados). No webview nativo não precisa: o I/O resolve via interop
  Java.
- Handlers/timers não aceitam `await` direto (CONC003-JS-01); a forma
  permitida é `spawn { ... await(...) ... }` em bloco.

## Testes

```bash
$KOF test Labels.kf
```

- Os `test "..." { assert }` vivem nos próprios arquivos de fonte (aqui, em
  `Labels.kf`); `kof test <arquivo>` compila e executa a suíte do arquivo.
- Lógica SQL/ORM não está coberta por testes: `kof test` compila o arquivo
  isolado (sem `--deps`/siblings) e o handle do `kof.db` exige runtime.

## Arquitetura em uma passada

```
Main.kf    main() único: config, db.connect, rotas app.get/post, scheduler
Model.kf   records de domínio (MetricIn, Serie, Amostra, agregações)
Storage.kf DDL/insert/query/agregação/retenção sobre o handle do kof.db
Labels.kf  canonicalização "k=v,k=v" ordenada (contorno: List sem sort)
web/Index.kf  dashboard kof-ui ao vivo: polling 3s + botão de refresh,
              Table+Select+Canvas, I/O em spawn { } de bloco
```

Regras que o codepen js da 0.3.22 impõe ao front (ver PLAN.md §4):

- Handlers de widget e ticks de `time.interval` não fazem `await` direto
  (CONC003-JS-01): I/O vai em `spawn { ... await(...) ... }` de bloco.
- Widgets só são tocados no escopo do `main`/lambdas dele.
- Estado entre eventos: variáveis locais capturadas (estáticos com
  inicializador ficam `undefined` no browser).
