# CohereTranscribe

Local speech-to-text with [Cohere Transcribe 03-2026](https://huggingface.co/cstr/cohere-transcribe-03-2026-GGUF)
through the [CrispASR](https://github.com/CrispStrobe/CrispASR) server on Metal. This is the
engine behind Pavarotti's dictation (fork step 2).

## What it does

- **Install** (`CohereInstaller`): fetches the GGUF model, Silero VAD, Silero language ID and
  the CrispASR runtime into `~/Library/Application Support/Pavarotti/Models/cohere-transcribe-03-2026`.
  Every file is pinned by size and SHA-256 (the same files the TypeWhisper fork uses). If
  TypeWhisper already downloaded a file, it is copied (an APFS clone) instead of downloaded.
- **Serve** (`CrispASRServer`): runs `crispasr --server` on a random loopback port with a
  per-launch API key. The model stays loaded, so only the first request pays for loading.
  A small shell guard stops the server when the app exits, even after a crash.
- **Transcribe** (`CohereTranscriber`): uploads WAV or an audio file to the
  OpenAI-compatible endpoint. In automatic mode the server's language ID decides between
  German and English; any other detection is redone in German.

## Models

| ID | Size | Note |
|---|---|---|
| `cohere-transcribe-03-2026-q4_k` | 1.51 GB | Compact |
| `cohere-transcribe-03-2026-q5_0` | 1.74 GB | Recommended |
| `cohere-transcribe-03-2026-q6_k` | 1.98 GB | Higher precision |
| `cohere-transcribe-03-2026-q8_0` | 2.42 GB | Experimental |

## Try it on a Mac

```sh
swift run --package-path Packages/CohereTranscribe cohere-cli status
swift run --package-path Packages/CohereTranscribe cohere-cli install
swift run --package-path Packages/CohereTranscribe cohere-cli transcribe ~/Desktop/test.m4a
swift run --package-path Packages/CohereTranscribe cohere-cli transcribe --language en --segments ~/Desktop/test.wav
```

`transcribe` prints how long the server took to start and how long the transcription took,
which is the number to compare with TypeWhisper.

## Tests

`make test` covers the language rule, the multipart upload, response decoding, the WAV
encoder, the installer (fake downloader, seeds, checksums, tar extraction) and the catalog.
Starting the real server needs the 1.7 GB model and is left to `cohere-cli` on hardware.
