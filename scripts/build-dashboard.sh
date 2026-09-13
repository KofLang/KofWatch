#!/usr/bin/env bash
# Build do dashboard para browser com patches de runtime embutidos.
#
# Patches necessarios no binario kof 0.3.22-beta (apos `kof build web`):
#   1. fetch: o emissor gera stub `return ""` no bloco "Fallback to fetch"
#      do kof-runtime.mjs; substituimos por fetch real (ver PLAN.md §4).
#   2. view.bind: o runtime acumula filhos no appendChild; o dashboard
#      espera semantica de substituicao (bind = setar conteudo).
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

python3 - "$RUNTIME" <<'PYEOF'
import sys

caminho = sys.argv[1]
with open(caminho, "r", encoding="utf-8") as arquivo:
    linhas = arquivo.readlines()

# ── patch 1: fetch real no fallback do browser ──
if "const promessa = fetch(url" not in "".join(linhas):
    inicio = -1
    for i, linha in enumerate(linhas):
        if "typeof fetch !== 'undefined'" in linha:
            inicio = i
            break
    if inicio == -1:
        sys.exit("bloco de fetch não encontrado")

    fim = -1
    # fecha o bloco do if(fetch): primeira linha `}` no nivel do proprio if
    # (12 espacos), ignorando blocos internos mais indentados.
    for j in range(inicio + 1, min(inicio + 40, len(linhas))):
        if linhas[j].rstrip("\n") == "            }":
            fim = j
            break
    if fim == -1:
        sys.exit("fecho do bloco de fetch não encontrado")

    patch = '''            if (typeof fetch !== 'undefined') {
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
            }
'''
    linhas[inicio:fim + 1] = [patch]
    print("patch do fetch aplicado em", caminho)
else:
    print("patch do fetch ja presente")

conteudo = "".join(linhas)

# ── patch 2: View.bind com semantica de substituicao ──
velho_bind = """        window.__kofNodes[view].appendChild(window.__kofNodes[child]);"""
novo_bind = """        const pai = window.__kofNodes[view];
        while (pai.firstChild) pai.removeChild(pai.firstChild);
        pai.appendChild(window.__kofNodes[child]);"""
if velho_bind in conteudo:
    conteudo = conteudo.replace(velho_bind, novo_bind)
    print("patch do view.bind (substituicao) aplicado")
elif "while (pai.firstChild)" in conteudo:
    print("patch do view.bind ja presente")
else:
    sys.exit("bloco do kofUiViewBind nao encontrado")

with open(caminho, "w", encoding="utf-8") as arquivo:
    arquivo.write(conteudo)
PYEOF

echo "dashboard pronto em $SAIDA"
