# Call transcription: research notes

Goal: a running, saved transcript of a voice call, labelled by speaker, covering every participant,
made on this machine. No call audio or text goes to any company's servers.

Status: research only (2026-11-13). Nothing built.

## What fastcord already gives us

- **Speaker labels come free.** Discord's voice server forwards one Opus stream per speaker, keyed by
  SSRC (the stream's number), and fastcord maps each SSRC to a user ID (`src/voice/conn.jai`
  `map_user`, via op 5 and op 12). So we don't need speaker diarization (guessing who spoke from a
  mixed recording): every stream already names its speaker.
- **Tap point for others:** `rx_tick` in `src/voice/conn.jai` decodes each user's frame separately
  (48 kHz stereo float, 20 ms) before it is mixed. Take the copy right after `codec.decode`, before
  the volume, local mute and self-deafen checks, so the transcript doesn't depend on what you chose
  to hear.
- **Tap point for you:** `tx_tick`, after `mic_process` and before the soundboard mix, and only for
  frames actually sent (not muted, VAD open). The transcript then holds what others heard from you.
- **DAVE (Discord's end-to-end encryption) is no obstacle:** fastcord decrypts frames before decoding.
  Doing the work locally keeps E2EE meaningful; a cloud service would not.
- **Utterance boundaries:** each user's speaking flag (op 5) plus fastcord's own VAD
  (`src/voice/vad.jai`) cut speech into utterances, so the model only runs on speech. This also stops
  Whisper-style models from inventing text in silence.
- **Hosted servers:** their voice uses the same client stack (`call_client`), so the same tap works.

## Engine candidates (all local, all MIT/Apache)

| Engine | Why | Cost |
|---|---|---|
| whisper.cpp (ggml-org) | Plain C/C++, vendorable like our other libs, no extra runtime. CPU, Vulkan, Metal, CUDA. Silero VAD built in. Many languages. | Chunked, not true streaming (seconds of delay). Models: tiny 75 MB, base 142 MB, small 466 MB, medium 1.5 GB. |
| Moonshine v2 (moonshine-ai) | Built for live streaming (~50 ms claimed on an M3). MIT for streaming models. C API. Has its own speaker-ID API we wouldn't need. | Fewer languages (en, es, de, zh, ja, ko, vi, tl, uk, ar). Runtime is probably ONNX Runtime (a large native dependency); unconfirmed. Non-English legacy models are non-commercial. |
| sherpa-onnx (k2-fsa) | One C API over many models: Parakeet TDT 0.6B, streaming Zipformer, Whisper, Moonshine. | Needs ONNX Runtime. Parakeet isn't streaming and needs ~2 GB RAM. |

Leaning: **whisper.cpp first**, because it vendors cleanly with no runtime and already handles many
languages; utterance-chunked delay of a few seconds is fine for a transcript. Revisit Moonshine if
live captions need to feel instant. Decide by measuring on this laptop (step 1 below), not by blog
benchmarks, which disagree.

Sources: [whisper.cpp](https://github.com/ggml-org/whisper.cpp),
[Moonshine](https://github.com/moonshine-ai/moonshine),
[Moonshine v2 paper](https://arxiv.org/abs/2602.12241),
[sherpa-onnx](https://k2-fsa.github.io/sherpa/onnx/),
[a 2026 comparison (vendor blog)](https://openwhispr.com/blog/parakeet-vs-whisper-vs-nemotron).

## Constraints from AGENTS.md

- **Download size (under 25 MB):** no model ships in the binary. The model downloads on first enable
  from a pinned URL checked against a pinned sha256, or the user points at a file they have. That is
  data, not a self-update; the binary never changes. The download only tells the host that someone
  fetched a model, never anything about a call.
- **Threads:** the voice thread only copies samples into a per-speaker ring buffer (no lock, no
  allocation). One worker resamples 48 kHz to 16 kHz mono and runs the model. If it falls behind, it
  drops or delays utterances; it never stalls audio. The UI only reads finished lines.
- **Storage:** transcripts go in `fastcord.db` (an added table), not a new file. Export as text or
  markdown.
- **Vendoring:** the library goes in `vendor/<lib>/` unmodified, with `fc_<lib>.c` and a README, as
  for codecs.

## Consent (the real risk)

- Transcribing others is recording them. About a dozen US states (California among them) and many
  countries require every party's consent. Keeping it local doesn't change that.
- Discord already has a per-user consent signal: "Allow my voice to be recorded in Clips". The client
  sends its own flags on the voice gateway's op 18, and the server relays each peer's. My
  unconfirmed memory of the bits: 1 = clips enabled, 2 = allow voice recording, 4 = allow any viewer
  clips. fastcord ignores op 18 today (`conn.jai` lists `OP_FLAGS` as informational) and never sends
  its own. Confirm against the 0.0.420 bundle (the test profiles' cache, not on this laptop) and
  record the rule in `traffic/CLIENT_RULES.md`.
- Proposed default: transcribe only peers whose flags allow voice recording, and show the others as
  "not transcribed". Whether to also tell the call (a chat line, a status) is the user's call: it is
  outward-facing and the official client sends nothing like it.

## Steps

1. Benchmark: run whisper.cpp (base, small, large-v3-turbo quantized) and Moonshine streaming on a
   recorded multi-speaker call on this laptop. Measure real-time factor (seconds of compute per
   second of audio) with 1 and 4 people talking, and the word error rate.
2. Confirm op 18's flags from the bundle; parse peers' flags and send our own as the client does.
3. Tap plus ring buffers plus worker, behind a setting (off by default), with a headless test that
   plays known speech through the fake voice server and checks the text.
4. Call view: a live transcript pane; the saved transcript per call in `fastcord.db`; export.
