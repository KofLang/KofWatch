# KofWatch

Observador de métricas em Kof: backend JVM com HTTP + H2 e dashboard
kof-ui (target js) que se atualiza ao vivo. Stack 100% Kof 0.3.22-beta,
sem dependências além do driver H2 (`kofdeps`).

## Visão geral

- **Backend** (`Main.kf`, target `jvm`): API HTTP com ingestão e consulta
  de séries temporais; persistência em H2 em arquivo (`data/kofwatch`);
  auto-coleta periódica via `scheduler.every` e retenção de 24h.
- **Dashboard** (`web/Index.kf`, target `js`): tabela de séries, seletor
  e gráfico Canvas com área preenchida; atualização automática a cada 3s
  e botão "atualizar" manual.
- **Modelo**: série temporal = `(name, labels)`; cada amostra = `(ts, val)`.
  Labels em string canônica `k=v,k=v` ordenada.

## Rodando

```bash
KOF=./.tools/kof-0.3.22-beta-linux-x86_64/bin/kof

# 1. backend (porta 8080)
$KOF run --deps Main.kf

# 2. dashboard (outro terminal)
./scripts/build-dashboard.sh /tmp/kofbuild
python3 -m http.server 8099 --directory /tmp/kofbuild
# abrir http://127.0.0.1:8099/
```

Alternativa ao browser: webview nativo com
`$KOF run --target=js web/Index.kf` (precisa `libwebkit2gtk-4.1`).

## Ingestão

```bash
curl -s -X POST localhost:8080/api/metrics \
  -H 'Content-Type: application/json' \
  -d '{"name":"cpu","valor":0.42,"ts":0,"labels":"host=a"}'
# {"ok":true,"id":1}
```

- `ts=0` → o backend preenche com `time.now()`.
- A série aparece sozinha no dashboard no tick seguinte do polling.
- Entrada inválida devolve 400 com `{"erro": "..."}`: `name`, `valor`
  (numérico) e `ts` (inteiro >= 0) são obrigatórios; `labels` deve seguir
  o formato `chave=valor` (sem percent-encoding na query string).

## API

| Rota | Método | Descrição |
|---|---|---|
| `/api/health` | GET | `{"status":"UP"}` |
| `/api/info` | GET | nome, versão, uptime, contadores |
| `/api/metrics` | POST | ingestão `{name, valor, ts, labels}` |
| `/api/metrics` | GET | lista de séries (`name, labels, last, lastTs, count`) |
| `/api/query/:name` | GET | amostras (`?from=&to=&labels=`) |
| `/api/aggregate/:name` | GET | `?fn=avg\|sum\|min\|max\|count&windowMs=` |

GETs retornam `Access-Control-Allow-Origin: *`.

## Testes

```bash
$KOF test Labels.kf
```

A suíte (canonicalização de labels) vive no próprio arquivo de fonte.
Detalhes de desenvolvimento em [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md);
plano e gaps da plataforma em [docs/PLAN.md](docs/PLAN.md); retrato do
estado do projeto em [docs/STATUS.md](docs/STATUS.md).

## Estrutura

```
Main.kf      main() único: config, db, rotas, scheduler
Model.kf     records de domínio
Storage.kf   DDL/insert/query/agregação/retenção (kof.db + H2)
Labels.kf    canonicalização de labels + suíte test
web/Index.kf dashboard kof-ui ao vivo (polling + Canvas)
```
