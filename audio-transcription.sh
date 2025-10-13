#!/bin/bash
set -euo pipefail

# Controlla la presenza delle dipendenze
for cmd in ffmpeg ffprobe bc jq curl nproc; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "Errore: comando '$cmd' non trovato"; exit 1; }
done

# Script per estrarre spezzoni audio da video lunghi
# Basato su rilevamento automatico dei silenzi

# Configurazione predefinita
DEBUG=0
MAX_JOBS=$(nproc --all)  # Numero massimo di processi ffmpeg in parallelo (modifica secondo le tue CPU)
JOBS=0
INPUT_FILE=""
OUTPUT_DIR="./audio_segments"
AUDIO_LANGUAGE="it"  # Lingua per la trascrizione (it, en, etc.)
MIN_DURATION=480  # 8 minuti in secondi
MAX_DURATION=720  # 12 minuti in secondi
SILENCE_THRESHOLD="-35dB"  # Soglia per rilevare il silenzio
SILENCE_DURATION="1"     # Durata minima del silenzio in secondi
REMOVE_SILENCE_DURATION="0.5"     # Durata minima del silenzio in secondi
AUDIO_FORMAT="mp3"         # Formato output (mp3, wav, flac, etc.)
AUDIO_QUALITY="32k"       # Bitrate per MP3
SAMPLERATE="16000"      # Frequenza di campionamento
WHISPER_API="http://localhost:8080/v1/audio/transcriptions"
WHISPER_MODEL="whisper-large-turbo-q8_0" # Modello Whisper per trascrizione
WHISPER_API_OPTIONS=(-F backend=vulkan-whisper -F model="${WHISPER_MODEL}" -F model_size=large -F beam_size=5 -F patience=2 -F condition_on_previous_text=true -F without_timestamps=true -F multilingual=true -F language="${AUDIO_LANGUAGE}") # Opzioni API Whisper
AUDIO_FILTERS="afftdn=nr=0.21:nf=-25,highpass=f=80,equalizer=f=1000:t=q:w=1:g=6,silenceremove=start_periods=1:start_duration=${REMOVE_SILENCE_DURATION}:start_threshold=${SILENCE_THRESHOLD}:stop_periods=-1:stop_duration=${REMOVE_SILENCE_DURATION}:stop_threshold=${SILENCE_THRESHOLD}:detection=peak,loudnorm=I=-23:LRA=11:tp=-2" # Filtri audio per migliorare la qualità
TRANSCRIPTION_FILE="Trascrizione.txt"

# Elimina directory temporanea e file contenuti in essa
cleanup() {
    if [[ -v TMP_SEGMENTS_DIR ]]; then
        if [ -n "$TMP_SEGMENTS_DIR" ]; then
            if [ -d "$TMP_SEGMENTS_DIR" ]; then
                rm -rf "$TMP_SEGMENTS_DIR"
            fi
        fi
    fi
}

trap_error() {
    echo "Errore durante l'esecuzione dello script."
    if [ -e "${TRANSCRIPTION_FILE}.part" ]; then
        echo "Trascrizione parziale salvata in: ${TRANSCRIPTION_FILE%.*}_errore.${TRANSCRIPTION_FILE##*.}"
        mv "${TRANSCRIPTION_FILE}.part" "${TRANSCRIPTION_FILE%.*}_errore.${TRANSCRIPTION_FILE##*.}"
    fi
}
trap cleanup EXIT ERR
trap trap_error ERR

# Funzione per mostrare l'aiuto
show_help() {
    echo "Uso: $0 -i INPUT_FILE [OPZIONI]"
    echo ""
    echo "Opzioni:"
    echo "  -i FILE       File video di input (obbligatorio)"
    echo "  -o DIR        Directory di output (default: ./audio_segments)"
    echo "  -min SECONDS  Durata minima spezzone in secondi (default: ${MIN_DURATION} = $(seconds_to_time "${MIN_DURATION}"))"
    echo "  -max SECONDS  Durata massima spezzone in secondi (default: ${MAX_DURATION} = $(seconds_to_time "${MAX_DURATION}"))"
    echo "  -st THRESHOLD Soglia silenzio in dB (default: ${SILENCE_THRESHOLD})"
    echo "  -sd SECONDS   Durata minima silenzio in secondi (default: ${SILENCE_DURATION})"
    echo "  -h            Mostra questo aiuto"
    echo ""
    echo "Esempio:"
    echo "  $0 -i video.mp4 -o output -min ${MIN_DURATION} -max ${MAX_DURATION}"
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
TOTAL_DURATION=$(ffprobe -v quiet -show_entries format=duration -of csv=p=0 "$INPUT_FILE")
echo "Durata totale: $(seconds_to_time "$TOTAL_DURATION")"
echo ""

# Step 2: Rileva i silenzi
echo "=== STEP 2: Rilevamento silenzi ==="
echo "Rilevamento silenzi in corso... (può richiedere alcuni minuti)"
SILENCE_OUTPUT="$(ffmpeg -nostdin -i "$INPUT_FILE" -vn -sn -dn -af "silencedetect=noise=${SILENCE_THRESHOLD}:d=${SILENCE_DURATION}" -f null - < /dev/null 2>&1 | grep "silence_\(start\|end\)")"
SILENCE_DATA="$(echo "$SILENCE_OUTPUT" | grep "silence_\(start\|end\)" | sed 's/.*silence_\(start\|end\): \([0-9.]*\).*/\1: \2/')"
if [ $DEBUG -eq 1 ]; then
    echo "Intervalli di silenzio rilevati:"
    while IFS= read -r SILENCE_LINE; do
        echo "$SILENCE_LINE"
    done <<< "$SILENCE_DATA"
fi
# Step 3: Calcola i segmenti audio
echo "=== STEP 3: Calcolo segmenti audio ==="
VALID_SEGMENTS=()
SILENCE_START=0
SILENCE_END=0
PREV_SILENCE_END=0
# In questa fase è necessario lavorare con numeri in virgola mobile
while IFS= read -r SILENCE_LINE; do
    if [[ $SILENCE_LINE == start* ]]; then
        SILENCE_START=${SILENCE_LINE//start: /}
    elif [[ $SILENCE_LINE == end* ]]; then
        SILENCE_END=${SILENCE_LINE//end: /}
        if (( $(bc <<< "$SILENCE_START > $PREV_SILENCE_END") )); then
            VALID_SEGMENTS+=("$PREV_SILENCE_END $SILENCE_START")
            PREV_SILENCE_END=$SILENCE_END
        fi
    fi
done <<< "$SILENCE_DATA"
if (( $(bc <<< "$TOTAL_DURATION > $PREV_SILENCE_END") )); then
    VALID_SEGMENTS+=("$PREV_SILENCE_END $TOTAL_DURATION")
fi
if [ $DEBUG -eq 1 ]; then
    echo "Segmenti validi rilevati:"
    for ((i=0; i<${#VALID_SEGMENTS[@]}; i++)); do
        read -r FLOAT_SEGMENT_START FLOAT_SEGMENT_END <<< "${VALID_SEGMENTS[i]}"
        echo "Segmento $((i+1)): Da $(seconds_to_time "${FLOAT_SEGMENT_START%.*}") a $(seconds_to_time "${FLOAT_SEGMENT_END%.*}") - ${FLOAT_SEGMENT_START} - ${FLOAT_SEGMENT_END}"
    done
fi
MERGED_SEGMENTS=()
CURRENT_START=0
CURRENT_END=0
SEGMENT_SEARCH=0 # 0 = cerca inizio, 1 = cerca fine
for ((i=0; i<${#VALID_SEGMENTS[@]}; i++)); do
    read -r SEGMENT_START SEGMENT_END <<< "${VALID_SEGMENTS[i]}"
    if (( $(bc <<< "$SEGMENT_START == $SEGMENT_END") )); then
        continue
    fi
    if [ $SEGMENT_SEARCH -eq 0 ]; then
        CURRENT_START=$SEGMENT_START
        CURRENT_END=$SEGMENT_END
        SEGMENT_SEARCH=1
        continue
    fi
    CURRENT_DURATION=$(bc <<< "$CURRENT_END - $CURRENT_START")
    POTENTIAL_DURATION=$(bc <<< "$SEGMENT_END - $CURRENT_START")

    if (( $(bc <<< "$POTENTIAL_DURATION <= $MAX_DURATION") )); then
        CURRENT_END=$SEGMENT_END
        continue
    fi

    if (( $(bc <<< "$CURRENT_DURATION >= $MIN_DURATION") )); then
        MERGED_SEGMENTS+=("$CURRENT_START $CURRENT_END")
        CURRENT_START=$SEGMENT_START
        CURRENT_END=$SEGMENT_END
    else
        CURRENT_END=$SEGMENT_END
        MERGED_SEGMENTS+=("$CURRENT_START $CURRENT_END")
        SEGMENT_SEARCH=0
    fi
done
if [ $SEGMENT_SEARCH -eq 1 ]; then
    MERGED_SEGMENTS+=("$CURRENT_START $CURRENT_END")
fi
if [ $DEBUG -eq 1 ]; then
    echo "Spezzoni finali calcolati:"
    for ((i=0; i<${#MERGED_SEGMENTS[@]}; i++)); do
        read -r start_time end_time <<< "${MERGED_SEGMENTS[i]}"
        echo "Spezzone $((i+1)): Da $(seconds_to_time "${start_time%.*}") a $(seconds_to_time "${end_time%.*}") - ${start_time} - ${end_time}"
    done
fi

# Step 4: Estrazione degli spezzoni
if [[ ${#MERGED_SEGMENTS[@]} -eq 0 ]]; then
    echo "Nessun segmento valido trovato. Prova ad aggiustare i parametri:"
    echo "  - Ridurre la soglia di silenzio (-st)"
    echo "  - Modificare la durata minima del silenzio (-sd)"
    echo "  - Aggiustare i range di durata (-min/-max)"
    exit 1
fi

echo "=== STEP 4: Estrazione spezzoni audio ==="
if [ $USE_WHISPER -eq 1 ]; then
    declare -a TMP_FILES=()
    TMP_SEGMENTS_DIR=$(mktemp -d /dev/shm/audio_segments.XXXXXX)
fi
for ((i=0; i<${#MERGED_SEGMENTS[@]}; i++)); do
    read -r start_time end_time <<< "${MERGED_SEGMENTS[i]}"


    echo "Accodo spezzone $((i+1))/${#MERGED_SEGMENTS[@]}..."
    echo "  Da: $(seconds_to_time "${start_time%.*}")"
    echo "  A: $(seconds_to_time "${end_time%.*}")"

    if [ $USE_WHISPER -eq 0 ]; then
        # Crea directory di output
        mkdir -p "$OUTPUT_DIR"

        OUTPUT_FILE="$OUTPUT_DIR/spezzone_$(printf "%02d" $((i+1)))_$(seconds_to_time "${start_time%.*}" | tr ':' '-').${AUDIO_FORMAT}"
        echo "  File: $(basename "$OUTPUT_FILE")"

        (
            if [[ "$AUDIO_FORMAT" == "mp3" ]]; then
                ffmpeg -nostdin -y -ss "$start_time" -to "$end_time" -i "$INPUT_FILE" -vn -sn -dn -acodec libmp3lame -ac 1 -ar "$SAMPLERATE" -b:a "$AUDIO_QUALITY" -filter:a "$AUDIO_FILTERS" "$OUTPUT_FILE" -v quiet
            elif [[ "$AUDIO_FORMAT" == "wav" ]]; then
                ffmpeg -nostdin -y -ss "$start_time" -to "$end_time" -i "$INPUT_FILE" -vn -sn -dn -acodec pcm_s16le -filter:a "$AUDIO_FILTERS" "$OUTPUT_FILE" -v quiet
            elif [[ "$AUDIO_FORMAT" == "flac" ]]; then
                ffmpeg -nostdin -y -ss "$start_time" -to "$end_time" -i "$INPUT_FILE" -vn -sn -dn -acodec flac -filter:a "$AUDIO_FILTERS" "$OUTPUT_FILE" -v quiet
            else
                ffmpeg -nostdin -y -ss "$start_time" -to "$end_time" -i "$INPUT_FILE" -vn -sn -dn -filter:a "$AUDIO_FILTERS" "$OUTPUT_FILE" -v quiet
            fi
            status=$?
            echo "Spezzone $((i+1))/${#MERGED_SEGMENTS[@]}..."
            if [[ $status -eq 0 ]]; then
                echo "  ✓ Completato"
            else
                echo "  ✗ Errore durante l'estrazione"
            fi

        ) &

        JOBS=$((JOBS + 1))
        if [[ $JOBS -ge $MAX_JOBS ]]; then
            wait -n
            JOBS=$((JOBS - 1))
        fi
        wait
    else
        TMP_FILE="$TMP_SEGMENTS_DIR/segment_$(printf "%04d" $i).mp3"
        TMP_FILES+=("$TMP_FILE")
        (
            # Inspiegabilmente, quando ffmpeg scrive su pipe, Whisper riconosce meglio l'audio all'inizio del file.
            # ¯\_(ツ)_/¯
            ffmpeg -nostdin -loglevel panic -hide_banner -y -ss "$start_time" -to "$end_time" -i "$INPUT_FILE" -vn -sn -dn -acodec libmp3lame -ac 1 -ar "$SAMPLERATE" -q:a 9 -v quiet -f mp3 -filter:a "$AUDIO_FILTERS" pipe:1 >"$TMP_FILE"
            status=$?
            echo "Spezzone $((i+1))/${#MERGED_SEGMENTS[@]}..."
            if [[ $status -eq 0 ]]; then
                echo "  ✓ Completato"
            else
                echo "  ✗ Errore durante l'estrazione"
            fi
        ) &
        JOBS=$((JOBS + 1))
        if [[ $JOBS -ge $MAX_JOBS ]]; then
            wait -n
            JOBS=$((JOBS - 1))
        fi
    fi

    echo ""
done

wait
if [ $USE_WHISPER -eq 1 ]; then
    echo "=== STEP 5: Trascrizione audio ==="

    touch "${TRANSCRIPTION_FILE}.part"
    truncate -s 0 "${TRANSCRIPTION_FILE}.part"
    i=1
    for TMP_FILE in "${TMP_FILES[@]}"; do
        echo "Trascrivo segmento $i/${#TMP_FILES[@]} ($(basename "$TMP_FILE"))..."
        curl -s "$WHISPER_API" -H "Content-Type: multipart/form-data" -F file=@"${TMP_FILE}" "${WHISPER_API_OPTIONS[@]}" | jq -r '.segments[].text' >> "${TRANSCRIPTION_FILE}.part"
        i=$((i + 1))
    done
    cleanup "$TMP_SEGMENTS_DIR"
    mv "${TRANSCRIPTION_FILE}.part" "${TRANSCRIPTION_FILE}"
    echo "Trascrizione completata!"
fi

echo "=== COMPLETATO ==="
echo "Spezzoni estratti: ${#MERGED_SEGMENTS[@]}"
if [ $USE_WHISPER -eq 0 ]; then
    echo "Directory output: $OUTPUT_DIR"
fi

if [ $USE_WHISPER -eq 1 ]; then
    echo "Trascrizione salvata in: ${TRANSCRIPTION_FILE}"
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
