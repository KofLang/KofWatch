#!/usr/bin/env bash
# Build do dashboard para browser com o patch do fetch embutido.
# O binário kof 0.3.22-beta emite stub `return ""` no bloco
# "Fallback to fetch" do kof-runtime.mjs; este script aplica o patch
# pós-build automaticamente (ver PLAN.md §4).
set -euo pipefail

KOF="${KOF:-./.tools/kof-0.3.22-beta-linux-x86_64/bin/kof}"
SAIDA="${1:-/tmp/kofwatch-dashboard}"

cd "$(dirname "$0")/.."

"$KOF" build web --target js --output "$SAIDA"

RUNTIME="$SAIDA/kof-runtime.mjs"
if [ ! -f "$RUNTIME" ]; then
    echo "erro: $RUNTIME não encontrado" >&2
    exit 1
fi

if grep -q "await fetch(url" "$RUNTIME"; then
    echo "fetch real já presente; patch desnecessário"
    exit 0
fi

if ! grep -q "typeof fetch !== 'undefined'" "$RUNTIME"; then
    echo "erro: bloco de fetch não encontrado em $RUNTIME" >&2
    exit 1
fi

python3 - "$RUNTIME" <<'PYEOF'
import sys

caminho = sys.argv[1]
with open(caminho, "r", encoding="utf-8") as arquivo:
    conteudo = arquivo.read()

marcador = """            if (typeof fetch !== 'undefined') {
                // synchronous fallback not possible - use deasync via Atomics if available
                // For MVP, do blocking via fetch sync is not supported; return empty
                kofHttpCircuitRecordSuccess();
                return "";
            }"""
indice = conteudo.find(marcador)
if indice == -1:
    sys.exit("bloco de fetch não encontrado")

patch = """            if (typeof fetch !== 'undefined') {
                let cabecalhos = undefined;
                if (headers) {
                    cabecalhos = {};
                    for (let linha of headers.split("\\n")) {
                        const doisPontos = linha.indexOf(":");
                        if (doisPontos > 0) cabecalhos[linha.substring(0, doisPontos).trim()] = linha.substring(doisPontos + 1).trim();
                    }
                }
                const promessa = fetch(url, {method: method, headers: cabecalhos, body: body})
                    .then((resposta) => {
                        if (!resposta.ok) { throw new Error("HTTP " + resposta.status + " from " + url); }
                        return resposta.text();
                    })
                    .then((texto) => {
                        kofHttpCircuitRecordSuccess();
                        return texto;
                    });
                return promessa;
            }"""
conteudo = conteudo[:indice] + patch + conteudo[indice + len(marcador):]

with open(caminho, "w", encoding="utf-8") as arquivo:
    arquivo.write(conteudo)
print("patch do fetch aplicado em", caminho)
PYEOF

echo "dashboard pronto em $SAIDA"
