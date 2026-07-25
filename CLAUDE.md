# yt-transcript

Plugin providing a `yt-transcript` skill: plain-text transcripts for video URLs.

## Layout

- `scripts/transcript.sh` — the whole implementation. Captions first, Parakeet fallback.
- `skills/yt-transcript/SKILL.md` — how Claude invokes it.
- `.claude-plugin/` — plugin and marketplace manifests. Bump `version` in **both**.

## Constraints that are easy to break

- **Never raise `CHUNK_SECS` above ~400.** The model's context is `n_audio_ctx=5000`
  at `subsampling_factor=8`, roughly 400 seconds. Beyond it `parakeet-cli` exits 0
  and writes an empty file. This failure is silent, so the script checks for empty
  output rather than trusting the exit code. Keep that check.
- **Do not swap in a Whisper model as a "safer" default.** It was measured 7x slower
  than Parakeet on the target hardware at worse accuracy. See README for numbers.
- Captions must stay the first path. Local ASR is minutes; captions are seconds.

## Testing

There is no test suite. Verify by hand against two URLs:

1. One with captions, which should return in seconds and never invoke `parakeet-cli`.
2. One without, which should chunk and report progress per chunk.

A useful regression check is that the transcript is non-empty and its word count is
plausible for the video length, roughly 130-160 words per minute for speech.
