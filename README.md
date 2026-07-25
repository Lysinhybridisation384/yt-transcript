# yt-transcript

Plain-text transcripts for video URLs, for feeding to an LLM to summarize or search.

Captions first, local transcription only when necessary:

1. **YouTube captions** if they exist. Free, instant, and usually better than local ASR.
2. **Parakeet TDT** locally otherwise, via `parakeet-cli` from `whisper-cpp`.

## Why Parakeet instead of Whisper

Measured on a 2019 MacBook Pro (Core i9-9880H, 8 cores, CPU-only, no usable GPU
backend), transcribing the same 2-minute slice with 8 threads:

| Model | Wall clock | Real-time factor |
|---|---|---|
| **Parakeet TDT 0.6B q8_0** | **20.8s** | **0.17x** |
| whisper base.en | 25.2s | 0.21x |
| whisper small.en | 61.4s | 0.51x |
| whisper large-v3-turbo | 148.2s | 1.24x |

Parakeet is **7.1x faster than whisper large-v3-turbo** while being at least as
accurate. On the test clip both Whisper models transcribed "Lyric's TikToks" as
"Eric's TikToks", inventing a person; Parakeet got it right. large-v3-turbo also
emitted no capitalization or punctuation at all, which matters when the transcript
feeds a summarizer.

Parakeet TDT 0.6B v3 posts 6.32% WER on English versus Whisper large-v3's 7.44%,
and covers 25 European languages. Whisper still wins for languages outside that set
and reportedly for heavy accents or specialized vocabulary.

### Things that do not work on Intel Macs

- **MLX**: Apple Silicon only. Requires Metal and unified memory.
- **OpenVINO**: its GPU plugin is not supported on macOS, so it is CPU-only there,
  and it accelerates only Whisper's encoder.
- **Core ML**: whisper.cpp's 3x Core ML speedup uses the Apple Neural Engine, which
  Intel Macs do not have.
- **faster-whisper**: its advantage is CUDA. No meaningful CPU win over whisper.cpp.

Homebrew's `whisper-cpp` build reports `no GPU found` and falls back to BLAS on CPU.

## The 400-second wall

`parakeet-cli` reports `n_audio_ctx = 5000` at `subsampling_factor = 8`, about 400
seconds of context. Past that it degrades badly and **fails silently**:

- 300s clip: works, 774 words.
- 600s clip: did not finish in 8 minutes, despite needing ~104s at measured speed.
- 77-minute file: exited 0 and wrote an **empty** transcript.

So the script always splits into 300s chunks. If you use `parakeet-cli` directly,
chunk it yourself and check that every chunk produced text. An exit code of 0 does
not mean it worked.

## Overlapping chunks

Chunks overlap by 15s, so consecutive chunks run 0-300s, 285-585s, 570-870s, and so
on. A hard cut lands mid-word and both halves transcribe to garbage, quietly losing
a word at every seam. With overlap, every word appears intact, with context on both
sides, in at least one chunk.

The repeated span is **left in the output**, marked with a line like:

```
[overlap: the following ~15s of speech repeats the end of the previous section]
```

It is not stitched out. `-otxt` gives plain text with no timestamps to align on, so
de-duplication would be a fuzzy suffix/prefix match, and when that misfires it drops
a whole sentence instead of one word. Leaving a labelled repeat is the safer failure
mode when the consumer is an LLM. Two consequences worth knowing:

- Word counts run ~5% above the true spoken count, which matters if you check a
  transcript against the usual 130-160 words per minute.
- If you need a clean transcript for a human, strip the marked spans yourself.

Set `OVERLAP_SECS=0` to get the old back-to-back behaviour.

## Setup

```bash
brew install yt-dlp ffmpeg whisper-cpp

mkdir -p ~/whisper-models
curl -L -o ~/whisper-models/ggml-parakeet-tdt-0.6b-v3-q8_0.bin \
  https://huggingface.co/ggml-org/parakeet-GGUF/resolve/main/ggml-parakeet-tdt-0.6b-v3-q8_0.bin
```

Verify the download (638 MB):

```
sha256  4d64e9e96c2792186d072fde0034df0ad670cf680a2f53069052ead827fd600e
```

The model comes from `ggml-org`, the org behind whisper.cpp and llama.cpp. Weights
are NVIDIA's `parakeet-tdt-0.6b-v3` under CC-BY-4.0, so attribution is required if
you redistribute. The ggml conversion is MIT.

Note that `ggml-org/parakeet-GGUF` is a low-traffic repo. The underlying NVIDIA
weights are widely used; this particular repackaging is not. Check the hash.

## Usage

```bash
transcript.sh "https://www.youtube.com/watch?v=..."            # to stdout
transcript.sh "https://youtu.be/..." -o transcript.txt         # to a file
```

Environment overrides: `PARAKEET_MODEL`, `THREADS` (default 8),
`CHUNK_SECS` (default 300; raising it is not recommended, see above),
`OVERLAP_SECS` (default 15; must be less than `CHUNK_SECS`).

Expect roughly 1 minute of compute per 5 minutes of audio when captions are absent.
Overlap adds about 5% to that.

## As a Claude Code plugin

```
/plugin marketplace add delfinadap/yt-transcript
/plugin install yt-transcript
```

## License

MIT for this repo. Model weights are CC-BY-4.0 from NVIDIA.
