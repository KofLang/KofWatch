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

### Webview nativo (caminho principal)

```bash
flatpak-spawn --host env DISPLAY=:0 \
  $KOF run --target=js web/Index.kf
```

O dashboard carrega as séries e o histórico de cada uma no startup e
desenha o gráfico da primeira; o `Select` troca a série desenhada.

### Browser (modo prova)

```bash
$KOF build web --target js --output /tmp/kofbuild
python3 -m http.server 8099 --directory /tmp/kofbuild
# abrir http://127.0.0.1:8099/
```

No browser puro, o `http.get` do runtime 0.3.22 é um stub que devolve
`""` — o build 0.4.0 do compiler traz o fallback fetch real. Enquanto o
binário não é repacotado, o caminho principal é o webview (o `main` roda no
GraalJS embarcado, com interop Java para HTTP).

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
web/Index.kf  dashboard kof-ui: pré-carga HTTP no main, Table+Select+Canvas
```

Regras que o codepen js da 0.3.22 impõe ao front (ver PLAN.md §4):

- Handlers de widget não fazem I/O (CONC003-JS-01): dados pré-carregados no
  `main` via `await(spawn(...))`.
- Widgets só são tocados no escopo do `main`/lambdas dele.
- Estado entre eventos: variáveis locais capturadas (estáticos com
  inicializador ficam `undefined` no browser).
