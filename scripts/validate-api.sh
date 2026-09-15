#!/usr/bin/env bash
# validate-api.sh — bateria end-to-end das rotas do backend KofWatch.
#
# Cobre todos os contratos de API do briefing: health/info, ingestão
# (válida e inválida), query/aggregate (válidos e inválidos), dashboards,
# alertas (GET puro, ack, 400/404/409). Serve como suíte de regressão
# das rotas: sai com exit != 0 se qualquer caso falhar.
#
# Uso: scripts/validate-api.sh [BASE_URL]   (default http://localhost:8080)
# O backend deve estar de pé: kof run --deps Main.kf web/Index.kf
set -u

BASE="${1:-http://localhost:8080}"
PASS=0
FAIL=0
FALHAS=""

# ---- helpers ---------------------------------------------------------

caso() { # caso <nome> <esperado> <codigo-obtido>
    local nome="$1" esperado="$2" obtido="$3"
    if [ "$obtido" = "$esperado" ]; then
        PASS=$((PASS + 1))
        echo "PASS  $nome"
    else
        FAIL=$((FAIL + 1))
        FALHAS="$FALHAS  $nome: esperado $esperado, obtido $obtido"
        echo "FAIL  $nome (esperado $esperado, obtido $obtido)"
    fi
}

corpo_tem() { # corpo_tem <corpo> <substring>  → 0 se contém
    python3 - "$1" "$2" <<'PYEOF'
import sys
corpo, esperado = sys.argv[1], sys.argv[2]
sys.exit(0 if esperado in corpo else 1)
PYEOF
}

verifica_corpo() { # verifica_corpo <nome> <corpo> <substring>
    if corpo_tem "$2" "$3"; then
        PASS=$((PASS + 1))
        echo "PASS  $1"
    else
        FAIL=$((FAIL + 1))
        FALHAS="$FALHAS  $1: corpo não contém '$3' (corpo: $(echo "$2" | head -c 200))"
        echo "FAIL  $1 (corpo sem '$3')"
    fi
}

RESP=$(mktemp)
get() { # get <path>; echo $RESP guarda o corpo da última resposta
    curl -s -m 5 -o "$RESP" -w '%{http_code}' "$BASE$1"
}

post() { # post <código-variável> <path> <data>
    curl -s -m 5 -o "$RESP" -w '%{http_code}' -X POST -H 'Content-Type: application/json' -d "$3" "$BASE$2"
}

get_body() { cat "$RESP" 2>/dev/null || echo ''; }

# ---- 0. health e info ------------------------------------------------

code=$(get /api/health); caso "GET /api/health → 200" 200 "$code"
verifica_corpo "health contém UP" "$(get_body)" 'UP'
code=$(get /api/info); caso "GET /api/info → 200" 200 "$code"

# ---- 1. ingestão -----------------------------------------------------

# (dados de semeadura para os casos de query/aggregate abaixo)
code=$(post x /api/metrics '{"name":"cpu.busy","valor":42.5,"ts":0,"labels":""}')
caso "POST /api/metrics cpu.busy → 201" 201 "$code"
code=$(post x /api/metrics '{"name":"gpu.temp","valor":65.0,"ts":0,"labels":""}')
caso "POST /api/metrics gpu.temp → 201" 201 "$code"
code=$(post x /api/metrics '{"name":"INVA LIDO","valor":1.0,"ts":0,"labels":""}')
caso "POST /api/metrics 'INVA LIDO' → 400" 400 "$code"
verifica_corpo "ingestão inválida menciona name inválido" "$(get_body)" 'name inválido'
code=$(post x /api/metrics '{"name":"","valor":1.0,"ts":0,"labels":""}')
caso "POST /api/metrics name vazio → 400" 400 "$code"
code=$(post x /api/metrics '{"name":"sem-valor","ts":0,"labels":""}')
caso "POST /api/metrics sem valor → 400" 400 "$code"
code=$(post x /api/metrics 'isto nao e json')
caso "POST /api/metrics corpo malformado → 400" 400 "$code"
code=$(post x /api/metrics '{"name":"nome-muito-grande-1234567890123456789012345678901234567890123456789012345678901","valor":1.0,"ts":0,"labels":""}')
caso "POST /api/metrics nome > 64 chars → 400" 400 "$code"

# ---- 2. query --------------------------------------------------------

AGORA_MS=$(python3 -c 'import time; print(int(time.time()*1000))')
FROM_MS=$((AGORA_MS - 60000))
code=$(get "/api/query/cpu.busy?from=$FROM_MS&to=$AGORA_MS")
caso "GET /api/query/cpu.busy → 200" 200 "$code"
verifica_corpo "query cpu.busy retorna amostras" "$(get_body)" '"valor"'
code=$(get "/api/query/INVA%20LIDO?from=$FROM_MS&to=$AGORA_MS")
caso "GET /api/query/INVA LIDO → 400" 400 "$code"
code=$(get "/api/query/cpu.busy?from=abc&to=$AGORA_MS")
caso "GET /api/query from não-inteiro → 400" 400 "$code"
code=$(get "/api/query/cpu.busy?from=$FROM_MS&to=$AGORA_MS&labels=a=1")
caso "GET /api/query com labels canônicos → 200" 200 "$code"

# ---- 3. aggregate ----------------------------------------------------

code=$(get "/api/aggregate/cpu.busy?fn=avg&windowMs=60000")
caso "GET /api/aggregate cpu.busy fn=avg → 200" 200 "$code"
verifica_corpo "aggregate retorna funcao avg" "$(get_body)" '"funcao":"avg"'
code=$(get "/api/aggregate/cpu.busy?fn=count&windowMs=60000")
verifica_corpo "aggregate fn=count retorna funcao count" "$(get_body)" '"funcao":"count"'
code=$(get "/api/aggregate/INVA%20LIDO?fn=avg&windowMs=60000")
caso "GET /api/aggregate/INVA LIDO → 400" 400 "$code"
code=$(get "/api/aggregate/cpu.busy?fn=mediana&windowMs=60000")
caso "GET /api/aggregate fn=mediana → 400" 400 "$code"
code=$(get "/api/aggregate/cpu.busy?fn=avg&windowMs=abc")
caso "GET /api/aggregate windowMs não-inteiro → 400" 400 "$code"

# ---- 4. dashboards ---------------------------------------------------

code=$(get /api/dashboards); caso "GET /api/dashboards → 200" 200 "$code"
verifica_corpo "dashboards lista inclui system" "$(get_body)" '"name":"system"'
code=$(get /api/dashboard/system); caso "GET /api/dashboard/system → 200" 200 "$code"
verifica_corpo "dashboard system tem painéis" "$(get_body)" '"panels"'
code=$(get /api/dashboard/system/panels); caso "GET /api/dashboard/system/panels → 200" 200 "$code"
code=$(get /api/dashboard/INVA%20LIDO); caso "GET /api/dashboard/INVA LIDO → 400" 400 "$code"
code=$(get /api/dashboard/nao-existe); caso "GET /api/dashboard/nao-existe → 404" 404 "$code"

# ---- 5. alerts (GET puro + ack) --------------------------------------

# nomes das regras vêm de alerts/*.json (latencia.json: cpu-alta etc.)
code=$(get /api/alerts); caso "GET /api/alerts → 200" 200 "$code"
ALERTA=$(python3 -c "import json; lista=json.load(open('$RESP')); print(lista[0]['name'] if lista else '')" 2>/dev/null || echo "")

if [ -n "$ALERTA" ]; then
    code=$(get "/api/alerts/$ALERTA"); caso "GET /api/alerts/$ALERTA → 200" 200 "$code"
    ACKED1=$(python3 -c "import json; print(json.load(open('$RESP'))['ackedMs'])")
    code=$(get "/api/alerts/$ALERTA"); caso "GET duplo (consulta pura) → 200" 200 "$code"
    ACKED2=$(python3 -c "import json; print(json.load(open('$RESP'))['ackedMs'])")
    if [ "$ACKED1" = "$ACKED2" ]; then
        PASS=$((PASS + 1)); echo "PASS  GET não muta ackedMs ($ACKED1)"
    else
        FAIL=$((FAIL + 1)); FALHAS="$FALHAS  GET mutou ackedMs: $ACKED1 -> $ACKED2"
        echo "FAIL  GET mutou ackedMs ($ACKED1 → $ACKED2)"
    fi
    # ack só é aceito em firing/pending; ambos os caminhos são contratos válidos
    code=$(post x "/api/alerts/$ALERTA/ack" '')
    if [ "$code" = "200" ] || [ "$code" = "409" ]; then
        PASS=$((PASS + 1)); echo "PASS  POST ack ($ALERTA) → $code (estado-dependente)"
    else
        FAIL=$((FAIL + 1)); FALHAS="$FALHAS  ack devolveu $code (esperado 200 ou 409)"
        echo "FAIL  POST ack ($ALERTA) → $code"
    fi
    code=$(get "/api/alerts/INVA%20LIDO"); caso "GET /api/alerts/INVA LIDO → 400" 400 "$code"
    code=$(get "/api/alerts/nao-existe"); caso "GET /api/alerts/nao-existe → 404" 404 "$code"
    code=$(post x "/api/alerts/nao-existe/ack" '')
    caso "POST ack de alerta inexistente → 404" 404 "$code"
else
    FAIL=$((FAIL + 1))
    FALHAS="$FALHAS  nenhum alerta carregado (alerts/*.json vazio ou backend sem regras)"
    echo "FAIL  nenhum alerta disponível para testar GET/ack"
fi

# ---- 6. métricas listadas -------------------------------------------

code=$(get /api/metrics); caso "GET /api/metrics → 200" 200 "$code"
verifica_corpo "metrics lista inclui cpu.busy" "$(get_body)" 'cpu.busy'

# ---- resumo ----------------------------------------------------------

echo ""
echo "==== resumo: $PASS passaram, $FAIL falharam ===="
if [ -n "$FALHAS" ]; then
    echo "Falhas:"
    printf '%s\n' "$FALHAS" | sed 's/^  /  - /'
fi
rm -f "$RESP"
[ "$FAIL" -eq 0 ] || exit 1
