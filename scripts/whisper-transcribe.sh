#!/usr/bin/env bash
# whisper-transcribe.sh — audio file → transcript.txt via OpenAI Whisper API.
# Invoked by the /transcribe slash command. Does NOT produce the analysis report;
# that's the command's job.
#
# Usage:
#   whisper-transcribe.sh --preflight                 # check .env + ffmpeg, exit 0/2/3
#   whisper-transcribe.sh --resolve <name>            # print matching audio paths, one per line
#   whisper-transcribe.sh <audio-file> <output-dir>   # transcribe → <output-dir>/transcript.txt
#
# Exit codes: 2=no .env/key, 3=no ffmpeg, 4=API error, 5=no match in --resolve mode.

set -euo pipefail

WHISPER_MAX_BYTES=25000000
DOTFILES_DIR="${HOME}/.claude-dotfiles"
ENV_FILE="${DOTFILES_DIR}/.env"

# --- Preflight: .env ---
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE missing." >&2
  echo "Setup:" >&2
  echo "  cp $DOTFILES_DIR/.env.example $ENV_FILE" >&2
  echo "  chmod 600 $ENV_FILE" >&2
  echo "  # then edit $ENV_FILE and add your OPENAI_API_KEY" >&2
  exit 2
fi
set -a; . "$ENV_FILE"; set +a
: "${OPENAI_API_KEY:?OPENAI_API_KEY missing or empty in $ENV_FILE}"
if [[ "$OPENAI_API_KEY" == "sk-REPLACE_ME" ]]; then
  echo "ERROR: OPENAI_API_KEY in $ENV_FILE is still the placeholder. Replace it." >&2
  exit 2
fi

# --- Preflight: ffmpeg ---
command -v ffmpeg >/dev/null || {
  echo "ERROR: ffmpeg not installed. Run: brew install ffmpeg" >&2
  exit 3
}

# --- Preflight-only mode ---
if [[ "${1:-}" == "--preflight" ]]; then
  echo "ok" >&2
  exit 0
fi

# --- Resolve mode: find audio files matching a name ---
if [[ "${1:-}" == "--resolve" ]]; then
  needle="${2:-}"
  [[ -z "$needle" ]] && { echo "ERROR: --resolve needs a search term" >&2; exit 5; }
  # Direct hit
  if [[ -f "$needle" ]]; then echo "$needle"; exit 0; fi

  declare -A seen=()
  search_dirs=()
  for d in "$PWD" "$HOME/Desktop" "$HOME/Documents" "$HOME/Downloads" "$HOME" \
           "$HOME/Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings"; do
    [[ -d "$d" ]] || continue
    canon=$(cd "$d" && pwd -P)
    [[ -n "${seen[$canon]:-}" ]] && continue
    seen[$canon]=1
    search_dirs+=("$d")
  done

  matches=()
  for d in "${search_dirs[@]}"; do
    while IFS= read -r -d '' f; do matches+=("$f"); done \
      < <(find "$d" -maxdepth 2 -type f -iname "*${needle}*" \
            \( -iname "*.m4a" -o -iname "*.mp3" -o -iname "*.wav" \
               -o -iname "*.aac" -o -iname "*.caf" -o -iname "*.flac" \
               -o -iname "*.ogg" -o -iname "*.opus" -o -iname "*.wma" \
               -o -iname "*.mp4" -o -iname "*.webm" -o -iname "*.mpga" \) -print0 2>/dev/null)
  done

  if (( ${#matches[@]} > 0 )); then
    printf '%s\n' "${matches[@]}"
    exit 0
  fi
  exit 5
fi

# --- Normal transcription mode ---
if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <audio-file> <output-dir>" >&2
  exit 1
fi

AUDIO="$1"
OUT_DIR="$2"
[[ -f "$AUDIO" ]] || { echo "ERROR: audio file not found: $AUDIO" >&2; exit 1; }
mkdir -p "$OUT_DIR"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# --- Transcode if non-native format OR >25MB ---
ext="${AUDIO##*.}"
ext_lower=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
native_re='^(m4a|mp3|mp4|mpeg|mpga|wav|webm)$'
size=$(stat -f '%z' "$AUDIO")
upload="$AUDIO"
if [[ ! "$ext_lower" =~ $native_re ]] || (( size > WHISPER_MAX_BYTES )); then
  echo "Transcoding to mono 64kbps m4a..." >&2
  upload="$TMP/compressed.m4a"
  ffmpeg -nostdin -loglevel error -y -i "$AUDIO" -ac 1 -b:a 64k -c:a aac "$upload"
  size=$(stat -f '%z' "$upload")
fi

# --- Chunk if still too big ---
chunks=()
if (( size > WHISPER_MAX_BYTES )); then
  echo "File still >25MB after compression; chunking..." >&2
  duration=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$upload")
  # Target ~20MB/chunk for safety margin
  seg_seconds=$(awk -v d="$duration" -v s="$size" 'BEGIN { printf "%d", d * (20000000 / s) }')
  (( seg_seconds < 60 )) && seg_seconds=60
  ffmpeg -nostdin -loglevel error -y -i "$upload" -f segment \
    -segment_time "$seg_seconds" -segment_format mp4 \
    -reset_timestamps 1 -c copy "$TMP/chunk_%03d.m4a"
  while IFS= read -r -d '' c; do chunks+=("$c"); done \
    < <(find "$TMP" -name 'chunk_*.m4a' -print0 | sort -z)
else
  chunks=("$upload")
fi

# --- Transcribe each chunk ---
: > "$OUT_DIR/transcript.txt"
total=${#chunks[@]}
i=0
for c in "${chunks[@]}"; do
  i=$((i+1))
  echo "Transcribing chunk $i/$total..." >&2
  if ! resp=$(curl -sS --fail-with-body \
      -H "Authorization: Bearer $OPENAI_API_KEY" \
      -F "model=whisper-1" \
      -F "response_format=text" \
      -F "file=@$c" \
      https://api.openai.com/v1/audio/transcriptions); then
    echo "ERROR: Whisper API call failed for chunk $i/$total." >&2
    echo "Response body: $resp" >&2
    exit 4
  fi
  if (( total > 1 )); then
    printf '\n\n--- chunk %d/%d ---\n\n' "$i" "$total" >> "$OUT_DIR/transcript.txt"
  fi
  printf '%s\n' "$resp" >> "$OUT_DIR/transcript.txt"
done

# --- Provenance (not the audio itself, just the path) ---
printf '%s\n' "$AUDIO" > "$OUT_DIR/source.txt"
echo "Transcript: $OUT_DIR/transcript.txt" >&2
