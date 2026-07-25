---
name: yt-transcript
description: Get a plain-text transcript for a YouTube or other video URL, for summarizing or searching its contents. Tries YouTube captions first, falls back to local Parakeet TDT transcription. Use whenever asked to summarize, quote, or answer questions about a video.
---

Produces a plain-text transcript for a video URL.

Steps:
1. Find the script: `find ~/.claude -name "transcript.sh" -path "*/yt-transcript/*" 2>/dev/null | sort -V | tail -1`
2. Run it:
   ```
   <scripts-dir>/transcript.sh "<url>" -o /tmp/transcript.txt
   ```
   - Without `-o` it prints to stdout.
   - Progress goes to stderr, so it is safe to redirect stdout.
3. Read the output file and work from it.

How it decides:
- If YouTube has captions (manual or auto), it uses those and finishes in seconds. This is the common case.
- If not, it downloads the audio and transcribes locally with Parakeet TDT.

Important notes:
- **Local transcription is slow.** Budget roughly 1 minute of compute per 5 minutes of
  audio on an Intel Mac. A 77-minute video takes about 15 minutes. Run it in the
  background and do other work while waiting. Do not run it in the foreground with a
  short timeout.
- **Livestreams that just ended have no captions yet.** YouTube usually generates them
  within a few hours. If the user is not in a hurry, waiting is far cheaper than
  transcribing.
- The transcript has no speaker labels and no timestamps. For a multi-speaker video,
  attribute quotes only when context makes the speaker unambiguous.
- ASR makes proper-noun errors. Treat unfamiliar names as suspect, and prefer names
  that appear consistently across the transcript over one-off spellings.

Setup (first run only): see the repository README for installing `yt-dlp`,
`ffmpeg`, `whisper-cpp`, and downloading the Parakeet model.
