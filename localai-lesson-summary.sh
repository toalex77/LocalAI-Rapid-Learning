#!/bin/bash
set -euo pipefail
MODEL="gpt-oss-20b"
BACKEND="vulkan-llama-cpp"
API_ENDPOINT="http://localhost:8080/v1/chat/completions"

# Controlla la presenza delle dipendenze
for cmd in jq curl; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "Errore: comando '$cmd' non trovato"; exit 1; }
done

LOCALAI=0

if [ -n "$(docker container ls -f name=aio-gpu-vulkan-api -q)" ]; then
    if [ -n "$(curl -s http://localhost:8080/v1/models 2>/dev/null| jq --arg model $MODEL'.data[] | select(.id == $model)' 2>/dev/null)" ]; then
        LOCALAI=1
    fi
fi

if [ $LOCALAI -eq 0 ]; then
  echo "Servizio LocalAI non rilevato. Impossibile continuare."
fi

if [ $# -lt 3 ]; then
    echo "Uso: $0 PROMPT_FILE LESSON_NAME TESTO_FILE"
    echo " - PROMPT_FILE: file contenente le istruzioni/parametri"
    echo " - LESSON_NAME: titolo della lezione"
    echo " - TESTO_FILE:  file TXT da analizzare"
    exit 1
fi

read -r LINE_BREAK_LUA_FILTER <<'EOF'
--- Transform a raw HTML element which contains only a `<br>`
-- into a format-indepentent line break.
function RawInline (el)
  if el.format:match '^html' and el.text:match '%<br ?/?%>' then
    return pandoc.LineBreak()
  end
end
EOF

PROMPT_FILE="$1"
LESSON_NAME="$2"
TESTO_FILE="$3"

if [ ! -f "$PROMPT_FILE" ]; then
  echo "File di prompt non trovato: $PROMPT_FILE"
  exit 1
fi

if [ ! -f "$TESTO_FILE" ]; then
  echo "Trascrizione della lezione non trovata: $TESTO_FILE"
  exit 1
fi

# Leggo i contenuti
PROMPT_TITLE=$(head -n 1 "$PROMPT_FILE")
PROMPT=$(tail -n +2 "$PROMPT_FILE")
PROMPT="${PROMPT/\%LESSON_NAME\%/$LESSON_NAME}"
if [ -z "$PROMPT_TITLE" ]; then
  echo "Impossibile determinare il nome del file di destinazione."
  exit 1
fi

echo "Inizio generazione del file: ${PROMPT_TITLE}.odt"
# Esegue la chiamata API, recupera il risultato e converte in ODT
(
  jq -n \
    --arg backend "${BACKEND}" \
    --arg model "${MODEL}" \
    --arg prompt "$PROMPT" \
    --arg language "it" \
    --rawfile testo "$TESTO_FILE" \
    '{
      model: $model,
      messages: [
        {role: "system", content: $prompt},
        {role: "user", content: $testo}
      ]
    }' | \
  curl -s "${API_ENDPOINT}" \
      -H "Content-Type: application/json" \
      -d @- | \
  jq -r '.choices[0].message.content' | \
  sed ':a;N;$!ba;s/<|channel|>.*<|message|>//' | \
  pandoc --lua-filter <(echo "$LINE_BREAK_LUA_FILTER") \
        --metadata lang=it-IT \
        -f markdown \
        -t odt \
        -o "${PROMPT_TITLE}.odt"
) &
PIPE_PID=$!

# Spinner ASCII
frames=("( ●    )" "(  ●   )"	"(   ●  )" "(    ● )" "(     ●)" "(    ● )"	"(   ●  )" "(  ●   )" "( ●    )" "(●     )")
i=0
trap 'kill "$PIPE_PID" 2>/dev/null || true; wait "$PIPE_PID" 2>/dev/null; exit 1' INT TERM

while kill -0 "$PIPE_PID" 2>/dev/null; do
  printf "\rIn attesa di risposta %s" "${frames[i]}"
  i=$(( (i + 1) % ${#frames[@]} ))
  sleep 0.12
done

wait "$PIPE_PID"
STATUS=$?

printf "\r"
if [ $STATUS -ne 0 ]; then
  echo "Errore nella generazione (exit $STATUS)"
  exit $STATUS
fi
echo "Risultato salvato in: ${PROMPT_TITLE}.odt"
