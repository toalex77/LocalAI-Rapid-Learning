#!/bin/bash

# Script per estrarre spezzoni audio da video lunghi
# Basato su rilevamento automatico dei silenzi

# Configurazione predefinita
INPUT_FILE=""
OUTPUT_DIR="./audio_segments"
MIN_DURATION=2400  # 40 minuti in secondi
MAX_DURATION=5400  # 90 minuti in secondi
SILENCE_THRESHOLD="-50dB"  # Soglia per rilevare il silenzio
SILENCE_DURATION="2.0"     # Durata minima del silenzio in secondi
AUDIO_FORMAT="mp3"         # Formato output (mp3, wav, flac, etc.)
AUDIO_QUALITY="80k"       # Bitrate per MP3
WHISPER_MODEL="whisper-large-turbo-q8_0" # Modello Whisper per trascrizione

# Funzione per mostrare l'aiuto
show_help() {
    echo "Uso: $0 -i INPUT_FILE [OPZIONI]"
    echo ""
    echo "Opzioni:"
    echo "  -i FILE       File video di input (obbligatorio)"
    echo "  -o DIR        Directory di output (default: ./audio_segments)"
    echo "  -min SECONDS  Durata minima spezzone in secondi (default: 2400 = 40min)"
    echo "  -max SECONDS  Durata massima spezzone in secondi (default: 5400 = 90min)"
    echo "  -st THRESHOLD Soglia silenzio in dB (default: -50dB)"
    echo "  -sd SECONDS   Durata minima silenzio in secondi (default: 2.0)"
    echo "  -h            Mostra questo aiuto"
    echo ""
    echo "Esempio:"
    echo "  $0 -i video.mp4 -o output -min 2400 -max 5400"
}

# Funzione per convertire secondi in formato HH:MM:SS
seconds_to_time() {
    local seconds=$1
    printf "%02d:%02d:%02d" $((seconds/3600)) $(((seconds%3600)/60)) $((seconds%60))
}

# Funzione per convertire formato HH:MM:SS in secondi
time_to_seconds() {
    local time=$1
    echo $time | awk -F: '{ print ($1 * 3600) + ($2 * 60) + $3 }'
}

# Parsing degli argomenti
while [[ $# -gt 0 ]]; do
    case $1 in
        -i)
            INPUT_FILE="$2"
            shift 2
            ;;
        -o)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -min)
            MIN_DURATION="$2"
            shift 2
            ;;
        -max)
            MAX_DURATION="$2"
            shift 2
            ;;
        -st)
            SILENCE_THRESHOLD="$2"
            shift 2
            ;;
        -sd)
            SILENCE_DURATION="$2"
            shift 2
            ;;
        -h)
            show_help
            exit 0
            ;;
        *)
            echo "Opzione sconosciuta: $1"
            show_help
            exit 1
            ;;
    esac
done

# Verifica parametri obbligatori
if [[ -z "$INPUT_FILE" ]]; then
    echo "Errore: File di input non specificato"
    show_help
    exit 1
fi

if [[ ! -f "$INPUT_FILE" ]]; then
    echo "Errore: File '$INPUT_FILE' non trovato"
    exit 1
fi

USE_WHISPER=0
WHISPER_API="http://localhost:8080/v1/audio/transcriptions"

echo "=== CONFIGURAZIONE ==="
echo "File input: $INPUT_FILE"
echo "Durata spezzone: $(seconds_to_time "$MIN_DURATION") - $(seconds_to_time "$MAX_DURATION")"
echo "Soglia silenzio: $SILENCE_THRESHOLD"
echo "Durata silenzio: ${SILENCE_DURATION}s"
# Rileva se il servizio Whisper API è attivo
if [ -n "$(docker container ls -f name=aio-gpu-vulkan-api -q)" ]; then
    if [ -n "$(curl -s http://localhost:8080/v1/models 2>/dev/null| jq --arg whisper_model $WHISPER_MODEL '.data[] | select(.id == $whisper_model)' 2>/dev/null)" ]; then
        echo ""
        echo "Rilevato servizio Whisper API in esecuzione. Verrà generata anche la trascrizione."
        USE_WHISPER=1
        touch Trascrizione.txt
    fi
fi
if [ $USE_WHISPER -eq 0 ]; then
    echo "Directory output: $OUTPUT_DIR"
    echo "Formato output: $AUDIO_FORMAT"
    echo "Servizio Whisper API non disponibile. Verranno estratti solo gli spezzoni audio."
fi
echo ""

# Step 1: Rileva la durata totale del video
echo "=== STEP 1: Analisi durata video ==="
TOTAL_DURATION=$(ffprobe -v quiet -show_entries format=duration -of csv=p=0 "$INPUT_FILE" | cut -d. -f1)
echo "Durata totale: $(seconds_to_time "$TOTAL_DURATION")"
echo ""

# Step 2: Rileva i silenzi
echo "=== STEP 2: Rilevamento silenzi ==="
echo "Rilevamento silenzi in corso... (può richiedere alcuni minuti)"
SILENCE_OUTPUT="$(ffmpeg -i "$INPUT_FILE" -af "silencedetect=noise=${SILENCE_THRESHOLD}:d=${SILENCE_DURATION}" -f null - 2>&1 | grep "silence_\(start\|end\)")"
SILENCE_DATA="$(echo "$SILENCE_OUTPUT" | grep "silence_\(start\|end\)" | sed 's/.*silence_\(start\|end\): \([0-9.]*\).*/\1: \2/')"

# Step 3: Calcola i segmenti audio
echo "=== STEP 3: Calcolo segmenti audio ==="

SEGMENT_START=0
SEGMENT_SEARCH=0 # 0 = cerca inizio, 1 = cerca fine
while IFS= read -r SILENCE_LINE; do
    if [[ $SILENCE_LINE == start* ]] && [[ $SEGMENT_SEARCH -eq 0 ]]; then
        SEGMENT_START=${SILENCE_LINE//start: /}
        SEGMENT_SEARCH=1
    elif [[ $SILENCE_LINE == end* ]] && [[ $SEGMENT_SEARCH -eq 1 ]]; then
        SEGMENT_END=${SILENCE_LINE//end: /}
        DURATION=$(echo "$SEGMENT_END - $SEGMENT_START" | bc)
        DURATION=${DURATION%.*} # Converti in intero
        if (( $(bc <<< "$DURATION > 0") )); then
            if (( DURATION >= MIN_DURATION && DURATION <= MAX_DURATION )); then
                VALID_SEGMENTS+=("$SEGMENT_START $SEGMENT_END")
                SEGMENT_SEARCH=0
            fi
        fi
    fi
done <<< "$SILENCE_DATA"
# Aggiungi l'ultimo segmento se necessario
RESIDUE_DURATION=$(echo "$TOTAL_DURATION - ${SEGMENT_END%.*}" | bc)
RESIDUE_DURATION=${RESIDUE_DURATION%.*} # Converti in intero
if [ "$RESIDUE_DURATION" -ne 0 ]; then
    VALID_SEGMENTS+=("$SEGMENT_END $TOTAL_DURATION")
fi

# Step 4: Estrazione degli spezzoni
if [[ ${#VALID_SEGMENTS[@]} -eq 0 ]]; then
    echo "Nessun segmento valido trovato. Prova ad aggiustare i parametri:"
    echo "  - Ridurre la soglia di silenzio (-st)"
    echo "  - Modificare la durata minima del silenzio (-sd)"
    echo "  - Aggiustare i range di durata (-min/-max)"
    exit 1
fi

echo "=== STEP 4: Estrazione spezzoni audio ==="

for ((i=0; i<${#VALID_SEGMENTS[@]}; i++)); do
    read -r start_time end_time <<< "${VALID_SEGMENTS[i]}"


    echo "Estraendo spezzone $((i+1))/${#VALID_SEGMENTS[@]}..."
    echo "  Da: $(seconds_to_time "${start_time%.*}")"
    echo "  A: $(seconds_to_time "${end_time%.*}")"

    if [ $USE_WHISPER -eq 0 ]; then
        # Crea directory di output
        mkdir -p "$OUTPUT_DIR"

        OUTPUT_FILE="$OUTPUT_DIR/spezzone_$(printf "%02d" $((i+1)))_$(seconds_to_time "${start_time%.*}" | tr ':' '-').${AUDIO_FORMAT}"
        echo "  File: $(basename "$OUTPUT_FILE")"

        if [[ "$AUDIO_FORMAT" == "mp3" ]]; then
            ffmpeg -y -i "$INPUT_FILE" -ss "$start_time" -to "$end_time" -vn -acodec libmp3lame -ac 1 -ar 11025 -q:a 9 -b:a "$AUDIO_QUALITY" -filter:a "speechnorm=e=12.5:r=0.0001:l=1" "$OUTPUT_FILE" -v quiet
        elif [[ "$AUDIO_FORMAT" == "wav" ]]; then
            ffmpeg -y -i "$INPUT_FILE" -ss "$start_time" -to "$end_time" -vn -acodec pcm_s16le -filter:a "speechnorm=e=12.5:r=0.0001:l=1" "$OUTPUT_FILE" -v quiet
        elif [[ "$AUDIO_FORMAT" == "flac" ]]; then
            ffmpeg -y -i "$INPUT_FILE" -ss "$start_time" -to "$end_time" -vn -acodec flac -filter:a "speechnorm=e=12.5:r=0.0001:l=1" "$OUTPUT_FILE" -v quiet
        else
            ffmpeg -y -i "$INPUT_FILE" -ss "$start_time" -to "$end_time" -vn -filter:a "speechnorm=e=12.5:r=0.0001:l=1" "$OUTPUT_FILE" -v quiet
        fi
    else
        ffmpeg -nostdin -loglevel panic -hide_banner -y -i "$INPUT_FILE" -ss "$start_time" -to "$end_time" -vn -acodec libmp3lame -ac 1 -ar 11025 -q:a 9 -b:a "$AUDIO_QUALITY" -v quiet -f mp3 -filter:a "speechnorm=e=12.5:r=0.0001:l=1" pipe:1 | curl -s "$WHISPER_API" -H "Content-Type: multipart/form-data" -F file=@- -F backend="vulkan-whisper" -F model="${WHISPER_MODEL}" -F language=it | jq -r '.segments[].text' >> Trascrizione.txt
    fi

    if [[ $? -eq 0 ]]; then
        echo "  ✓ Completato"
    else
        echo "  ✗ Errore durante l'estrazione"
    fi
    echo ""
done

echo "=== COMPLETATO ==="
echo "Spezzoni estratti: ${#VALID_SEGMENTS[@]}"
if [ $USE_WHISPER -eq 0 ]; then
    echo "Directory output: $OUTPUT_DIR"
fi

if [ $USE_WHISPER -eq 1 ]; then
    echo "Trascrizione salvata in: Trascrizione.txt"
else
    echo "File generati:"
    ls -lh "$OUTPUT_DIR"/*.${AUDIO_FORMAT} 2>/dev/null || echo "Nessun file audio generato"
fi

echo ""
if [ $USE_WHISPER -eq 0 ]; then
    echo "Estrazione audio completata!"
else
    echo "Trascrizione completata!"
fi
