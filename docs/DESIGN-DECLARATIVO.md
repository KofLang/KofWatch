# KofWatch — Design: Observabilidade Declarativa (Etapa 9)

**Data:** 12/09/2026
**Status:** implementação iniciada
**Escopo:** dashboards e painéis declarados em arquivos versionáveis; alertas ficam fora desta etapa (desenho futuro).

---

## 1. Decisões (e por quê)

### 1.1 Formato do manifesto: JSON, não YAML

O pedido original citava YAML como referência conceitual, com liberdade
explícita para decidir a sintaxe depois de estudar a plataforma. Investigação
empírica da 0.3.22-beta:

| Capacidade | Status verificado |
|---|---|
| Parser YAML (stdlib/runtime/compiler) | **não existe** — único match no fonte é um content-type num switch |
| Parser TOML exposto a código usuário | não existe — `kof.config` é `chave=valor` plano, parseado dentro do runtime em Java, sem API |
| `json.decode<Record>` tipado | funciona (probes): records aninhados, `List<record>`, `List<String>`, `Bool`, campos ausentes → `null`, extras ignorados |
| `File.readText` em app-mode | funciona (absoluto e relativo) |
| `Directory.list()` | funciona, retorna `List<String>` ordenado |
| `http.get` com query string | funciona client e server-side (probes A/E) |

Escrever um parser de YAML dentro do KofWatch significaria manter um
interpretador de sintaxe em produção — custo alto, e qualquer divergência
silenciosa (o mesmo padrão de risco do decoder tipado, que coage
número→String sem erro) vira bug de manifest. JSON dá:

- zero parser novo (o decode tipado é o parser);
- validação por records + função de validação explícita;
- erro tipado e mensurável (400 com lista de erros) em vez de crash.

Se a plataforma ganhar YAML no futuro, **só o Manifest.kf troca** — o resto do
pipeline (modelo interno, runtime, front) não fica espalhado pelo código.

### 1.2 Pipeline isolado

```
dashboards/*.json ──► Manifest.kf ──► records de runtime ──► rotas API ──► front
   (arquivos)         (única porta      (Painel, Dashboard)     (/api/        (render
                       de entrada        já normalizados         dashboards)   declarativo)
                       de arquivo)       para consumo)
```

Regra do pedido respeitada: parsing/acesso a arquivo só existe dentro do
Manifest.kf. O resto do sistema consome records validados.

### 1.3 Formato do manifesto

```json
{
  "name": "system",
  "title": "Sistema",
  "refreshMs": 3000,
  "panels": [
    {
      "title": "CPU",
      "type": "timeseries",
      "metric": "cpu.busy",
      "fromMs": 3600000
    },
    {
      "title": "GPU temp",
      "type": "gauge",
      "metric": "gpu.temp",
      "windowMs": 60000
    }
  ]
}
```

- `name` (obrigatório): identificador, `[a-z0-9._-]`, igual ao nome do arquivo.
- `title` (obrigatório): título exibido.
- `refreshMs` (opcional, default 3000): intervalo de atualização do front.
- `panels` (obrigatório, mínimo 1):
  - `title` (obrigatório), `type` (`timeseries` | `gauge`, obrigatório),
    `metric` (obrigatório).
  - `fromMs` (opcional, default 3600000): janela de histórico do painel
    timeseries.
  - `windowMs` (opcional, default 60000): janela do último valor (gauge e
    fallback).

Critério: o menor formato que cobre o dashboard que hoje é hardcoded, sem
campos "para o futuro". Alertas entram depois com o mesmo mecanismo
(arquivo + records + validação), sem mudar o que existe.

## 2. Componentes

### 2.1 `Manifest.kf` (novo, na raiz — ver gap 8 do PLAN)

- Records: `PainelManifest`, `DashboardManifest` (entrada crua), e
  `Dashboard`/`Painel` normalizados (defaults preenchidos).
- `carregarManifestos(diretorio)`: `Directory.list()`, filtra `.json`,
  `File.readText` + `json.decode<DashboardManifest>` + validação.
  Erro de parse/validação em UM arquivo não derruba os outros: o dashboard
  inválido é reportado com o motivo (registro `erro` por dashboard) e fica
  visível na API — falha visível, não silenciosa.
- `validar(...)`: retorna `List<String>` de erros legíveis
  (`"panels[2].type inválido: 'pie'"`).

### 2.2 Rotas no `Main.kf`

- `GET /api/dashboards` → `[{name, title, panels, erro}]` (lista curta).
- `GET /api/dashboard/:name` → manifesto normalizado completo, `404` se não
  existe, `400` com erros se inválido.
- CORS `*` nos GETs (padrão existente).

### 2.3 Front declarativo (`web/Index.kf`)

- Boot: `GET /api/dashboards`; sem dashboard → tela "sem dashboards" com
  instrução de diretório (estado honesto, não branco).
- Com dashboard: título do manifesto, grid de painéis
  (`timeseries` full-width com Canvas; `gauge` ao lado do anterior, 2 por
  linha), cada painel busca `/api/query/:metric?from=..&to=..` (query string
  provada na 0.3.22).
- Atualização ao vivo: mesmo mecanismo atual (`time.interval(refreshMs)` +
  `spawn { await(http.get(...)) }`), só que o intervalo e a lista de séries
  vêm do manifesto.
- Gaps js respeitados (§4 do PLAN): widgets só no escopo do `main`; estado
  capturado em variáveis locais; nenhum widget por parâmetro.

### 2.4 Exemplo versionado: `dashboards/system.json`

O manifesto acima com as séries seed (`cpu.busy`, `gpu.temp`, `mem`), para o
repositório já nascer com um dashboard declarativo funcional.

## 3. Compatibilidade (zero regressão)

- O comportamento atual do dashboard continua existindo: sem manifestos, o
  front mostra estado vazio explícito; com `dashboards/system.json`, mostra o
  sistema. A tabela "todas as séries" do dashboard antigo permanece como
  componente (agora alimentada pelo mesmo `/api/metrics`).
- Toda a API atual permanece intocada (`/api/metrics`, `/api/query/:name`,
  `/api/aggregate/:name`, `/api/health`, `/api/info`).
- Validação obrigatória pós-implementação (receita da fase anterior):
  build backend sem erro; curl em todas as rotas (novas e antigas);
  `build-dashboard.sh`; Playwright com contagem de pixels do canvas e prova
  de polling ao vivo.

## 4. Riscos registrados

- Decoder tipado coage número→String silenciosamente em run-mode: a validação
  explícita (`validar`) é a barreira — confiar no decode sozinho seria frágil.
- `Directory.list()` ordenado alfabeticamente: a ordem de exibição dos
  dashboards segue a ordem dos arquivos (documentado; ordenação custom fica
  para quando houver necessidade real).
- diretório `dashboards/` inexistente = zero dashboards (estado válido, não
  erro) — API responde `[]` e o front mostra o estado vazio.
