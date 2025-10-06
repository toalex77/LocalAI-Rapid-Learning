#!/bin/bash

LOCALAI=0

if [ -n "$(docker container ls -f name=aio-gpu-vulkan-api -q)" ]; then
    if [ -n "$(curl -s http://localhost:8080/v1/models 2>/dev/null| jq '.data[] | select(.id == "gpt-oss-20b")' 2>/dev/null)" ]; then
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

read -r -d '' LINE_BREAK_LUA_FILTER <<'EOF'
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

# Leggo i contenuti
TESTO=$(<"$TESTO_FILE")
PROMPT_TITLE=$(head -n 1 "$PROMPT_FILE")
PROMPT=$(tail -n +2 "$PROMPT_FILE")
PROMPT="${PROMPT/\%LESSON_NAME\%/$LESSON_NAME}"
if [ -z "$PROMPT_TITLE" ]; then
  echo "Impossibile determinare il nome del file di destinazione."
  exit 1
fi
MODEL="gpt-oss-20b"
BACKEND="vulkan-llama-cpp"
API_ENDPOINT="http://localhost:8080/v1/chat/completions"

JSON_PAYLOAD=$(jq -n \
  --arg backend "${BACKEND}" \
  --arg model "${MODEL}" \
  --arg prompt "$PROMPT" \
  --arg testo "$TESTO" \
  --arg language "it" \
  '{
     model: $model,
     messages: [
       {role: "system", content: $prompt},
       {role: "user", content: $testo}
     ]
   }')


# Richiesta alle API
RESPONSE=$(curl -s "${API_ENDPOINT}" \
  -H "Content-Type: application/json" \
  -d "$JSON_PAYLOAD")

# Estrai solo il testo della risposta con jq
echo "$RESPONSE" | jq -r '.choices[0].message.content' | sed ':a;N;$!ba;s/<|channel|>.*<|message|>//' | pandoc --lua-filter <(echo "$LINE_BREAK_LUA_FILTER") --metadata lang=it-IT -f markdown -t odt -o "${PROMPT_TITLE}.odt"

echo "Risultato salvato in: ${PROMPT_TITLE}.odt"
