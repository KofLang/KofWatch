# Build do dashboard para browser com o patch do fetch embutido.

O binário kof 0.3.22-beta emite um stub `return ""` no bloco
"Fallback to fetch" do `kof-runtime.mjs`; sem o patch, toda chamada
HTTP do dashboard no browser responde vazio. Este script gera o build
e aplica o patch pós-build automaticamente, tornando o passo manual
desnecessário (contexto em docs/PLAN.md §4).

Uso: ./scripts/build-dashboard.sh [diretório-de-saída]  (padrão: /tmp/kofwatch-dashboard)
