#!/usr/bin/env bash
# transcript.sh <url> [-o outfile]
#
# Plain-text transcript for a video URL.
#   1. YouTube captions if they exist (free, instant).
#   2. Otherwise local ASR with Parakeet TDT.

set -euo pipefail

MODEL="${PARAKEET_MODEL:-$HOME/whisper-models/ggml-parakeet-tdt-0.6b-v3-q8_0.bin}"
THREADS="${THREADS:-8}"

# The model reports n_audio_ctx=5000 at subsampling_factor=8, i.e. ~400s of
# context. Past that, attention cost explodes: a 600s clip that should take
# ~104s did not finish in 8 minutes, and a full 77-minute file silently
# produced an empty transcript. 300s stays safely inside the window.
CHUNK_SECS="${CHUNK_SECS:-300}"

# Chunks overlap. A hard cut lands mid-word, and the two halves each transcribe
# to garbage, so a word is quietly lost at every seam. With overlap, every word
# appears intact -- with context on both sides -- in at least one chunk. The
# duplicated span is left in the output and labelled rather than stitched out:
# there are no timestamps to align on, so de-duplication would be a fuzzy text
# match, and when that misfires it drops a whole sentence instead of one word.
# The consumer here is a model, which handles a marked repeat trivially.
OVERLAP_SECS="${OVERLAP_SECS:-15}"

URL=""; OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) OUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)  URL="$1"; shift ;;
  esac
done
[ -n "$URL" ] || { echo "usage: transcript.sh <url|audiofile> [-o outfile]" >&2; exit 1; }

command -v ffmpeg >/dev/null || { echo "missing dependency: ffmpeg" >&2; exit 1; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
emit() { if [ -n "$OUT" ]; then cp "$1" "$OUT"; echo "wrote $OUT" >&2; else cat "$1"; fi; }

# YouTube throttles aggressively. A 429 or bot-check looks exactly like "this
# video has no captions" unless we inspect stderr, which would silently send us
# down the 15-minute ASR path for a video that actually has captions.
throttled() {
  grep -qiE "HTTP Error 429|Too Many Requests|confirm you.re not a bot|Sign in to confirm" "$1"
}
bail_throttled() {
  echo "==> YouTube is rate-limiting this machine." >&2
  echo "    Wait a while, or pass cookies:" >&2
  echo "      yt-dlp --cookies-from-browser chrome ..." >&2
  exit 2
}

# A local file skips all networking. Also the only way to re-run on already
# downloaded audio when YouTube is throttling.
if [ -f "$URL" ]; then
  echo "==> local file, skipping download" >&2
  cp "$URL" "$WORK/src"
  SKIP_DOWNLOAD=1
else
  SKIP_DOWNLOAD=0
  command -v yt-dlp >/dev/null || { echo "missing dependency: yt-dlp" >&2; exit 1; }
fi

# ---- 1. captions ----------------------------------------------------------
VTT=""
if [ "$SKIP_DOWNLOAD" -eq 0 ]; then
  echo "==> checking for captions..." >&2
  yt-dlp --write-auto-sub --write-sub --sub-lang "en.*" --skip-download \
         -o "$WORK/cap" "$URL" >/dev/null 2>"$WORK/cap.err" || true
  # An `if` here, not `cmd && bail`: under `set -e` a failing left side of a
  # && list makes the list's status non-zero and kills the script.
  if throttled "$WORK/cap.err"; then bail_throttled; fi
  VTT="$(find "$WORK" -name '*.vtt' -print -quit 2>/dev/null || true)"
fi
if [ -n "$VTT" ]; then
  echo "==> captions found, skipping transcription" >&2
  python3 - "$VTT" > "$WORK/out.txt" <<'PY'
import re, sys
seen, out = None, []
for line in open(sys.argv[1], encoding="utf-8", errors="replace"):
    line = line.strip()
    if (not line or "-->" in line or line == "WEBVTT"
            or line.startswith(("Kind:", "Language:", "NOTE"))
            or re.fullmatch(r"\d+", line)):
        continue
    line = re.sub(r"<[^>]+>", "", line).strip()   # drop <c>/karaoke tags
    if line and line != seen:                     # auto-subs repeat each cue
        out.append(line); seen = line
print(" ".join(out))
PY
  emit "$WORK/out.txt"; exit 0
fi

# ---- 2. local ASR ---------------------------------------------------------
if [ "$SKIP_DOWNLOAD" -eq 0 ]; then
  echo "==> no captions; transcribing with Parakeet" >&2
else
  echo "==> transcribing with Parakeet" >&2
fi
command -v parakeet-cli >/dev/null || { echo "missing parakeet-cli (brew install whisper-cpp)" >&2; exit 1; }
[ -f "$MODEL" ] || { echo "model not found: $MODEL -- see README" >&2; exit 1; }

if [ "$SKIP_DOWNLOAD" -eq 0 ]; then
  echo "==> downloading audio..." >&2
  if ! yt-dlp -x --audio-format mp3 -o "$WORK/a.%(ext)s" "$URL" \
       >/dev/null 2>"$WORK/dl.err"; then
    throttled "$WORK/dl.err" && bail_throttled
    echo "==> audio download failed:" >&2
    grep -iE "^ERROR" "$WORK/dl.err" | head -3 >&2 || tail -3 "$WORK/dl.err" >&2
    exit 1
  fi
  SRC="$WORK/a.mp3"
else
  SRC="$WORK/src"
fi

ffmpeg -i "$SRC" -ar 16000 -ac 1 -c:a pcm_s16le "$WORK/a.wav" -y >/dev/null 2>&1

DUR="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$WORK/a.wav" | cut -d. -f1)"
echo "==> ${DUR}s of audio (~$((DUR * 20 / 100))s expected)" >&2

# Always chunk: it costs nothing on short files and is required past ~400s.
# The segment muxer cannot overlap, so cut each chunk with its own seek. -ss
# before -i is sample-accurate on PCM and does not scan the file.
STEP=$((CHUNK_SECS - OVERLAP_SECS))
[ "$STEP" -gt 0 ] || { echo "OVERLAP_SECS must be less than CHUNK_SECS" >&2; exit 1; }

i=0; start=0
while :; do
  ffmpeg -ss "$start" -t "$CHUNK_SECS" -i "$WORK/a.wav" -c copy \
         "$(printf '%s/part_%03d.wav' "$WORK" "$i")" -y >/dev/null 2>&1
  i=$((i + 1)); start=$((start + STEP))
  # Stop once the chunk just written already reached the end. It covers up to
  # start + OVERLAP_SECS, so anything shorter than that is a redundant sliver.
  [ "$start" -lt "$DUR" ] && [ $((DUR - start)) -gt "$OVERLAP_SECS" ] || break
done

MARK="[overlap: the following ~${OVERLAP_SECS}s of speech repeats the end of the previous section]"

n=0; wrote=0; total=$i
: > "$WORK/out.txt"
for f in "$WORK"/part_*.wav; do
  n=$((n + 1)); echo "    chunk $n/$total" >&2
  # Never let one bad chunk abandon the good ones. Exit status is unreliable in
  # both directions here: 0 with an empty file is the documented failure mode.
  parakeet-cli -m "$MODEL" -f "$f" -t "$THREADS" \
               -otxt -of "${f%.wav}" --no-prints >/dev/null 2>&1 || true
  if [ ! -s "${f%.wav}.txt" ]; then
    echo "    warning: chunk $n produced no text" >&2
    continue
  fi
  [ "$wrote" -eq 0 ] || printf '\n%s\n' "$MARK" >> "$WORK/out.txt"
  cat "${f%.wav}.txt" >> "$WORK/out.txt"; wrote=1
done
[ -s "$WORK/out.txt" ] || { echo "transcription produced no output" >&2; exit 1; }
emit "$WORK/out.txt"
