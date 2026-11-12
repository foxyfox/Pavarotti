# Passive mic capture (Pavarotti fork, 2026-11-12)

**Decision:** Pavarotti no longer records the microphone through Apple's voice
processing (VPIO, `LiveMicCaptureEngine`). It listens to the chosen microphone with an
input-only `AVAudioEngine` (`PassiveMicCaptureEngine`) and does the echo and level work
after the recording (`MicTrackCleaner`, `MicBleedRemover`). This supersedes the VPIO
recommendation in [`mic_capture_level_findings.md`](mic_capture_level_findings.md) for
the fork. `LiveMicCaptureEngine` and `VPIOOutputPlan` stay in the tree, unused, to keep
upstream merges easy.

## Why VPIO had to go

VPIO is a duplex unit. It needs an output device next to the microphone, builds a
system aggregate of both, and its echo canceller only knows the audio of the output it
is attached to. A recorder that is not the app playing the call cannot make that work
in every setup. Observed on Andreas' Mac (Studio Display mic 48 kHz, Bluetooth speaker
44.1 kHz, sometimes Bluetooth headphones), each with log evidence:

| Date | What VPIO did | What the user got |
|---|---|---|
| 11-05, 11-09 | Reclocked the busy Bluetooth speaker 44.1 → 48 kHz at record start | Call audio 8 % slow and low, other side heard echo, low copy of the far side on the mic track |
| 11-11 14:30 | Output on the MacBook speakers (PR #40 companion), call on the Bluetooth speaker | Canceller had a silent reference: far side at 0.34 s delay on the mic track; system tap creation failed with `'nope'` three times in a row |
| 11-11 14:30:38 | Rebuilt on Bluetooth headphones as output | Headphones at 24 kHz (headset mode) for the whole call although the mic was the Studio Display |
| 11-12 10:10 | Same companion route as 11-11 | Short Slack huddle recording with everything doubled (far side at 0.33 s, about -15 dB, on the mic track) |

PR #40 removed the reclock but could not fix the design: with the output on a companion
device the canceller is blind, and with it on the real output the unit takes part in the
call's audio path. MacWhisper, which only listens, never showed any of this on the same
Mac.

## What replaced it

- **Capture** (`PassiveMicCaptureEngine`): input node tap only, no output node in the
  graph. The chosen microphone is set on the input unit before the engine starts, so a
  different default input (Bluetooth headphones) is never opened. No output device, sample
  rate or default device is read for a decision or changed. Hardware check
  (`PAVAROTTI_HARDWARE_MIC=1 swift test --filter PassiveMicHardware`): 8.44 s wall clock
  gave 8.49 s of audio, output rate unchanged.
- **Echo** (`MicBleedRemover`, after stop): the system track is the reference. Per 20 s
  block (half overlap): delay from band envelopes (0 to 0.7 s), a 6-frame per-band
  least-squares filter predicts and subtracts the bleed, a spectral gain suppresses the
  rest (floor -30 dB). A block is only touched when the envelopes correlate (≥ 0.12 over
  the frames where the far side is audible) **and** the reference predicts at least 10 %
  of the microphone's power there. Headphone recordings stay bit-identical.
- **Level** (`MicTrackCleaner`): one static gain that raises the loud passages (95th
  percentile of 50 ms frames) to -20 dBFS, at most +24 dB, never clipping, never lowering.
- The mic file is rewritten only when something changed. The AAC encoder delay (2112
  samples) is dropped before re-encoding so the track does not move against the system
  track.

The earlier claim in `mic_capture_level_findings.md` that reference-based cancellation is
impossible for a passive recorder is wrong for this design: the tap delivers the audio
before the loudspeaker plays it, and after the recording causality does not matter anyway.

## Numbers

- Real recording 2026-11-12 (Bluetooth speaker, VPIO blind): far side on the mic track
  reduced from -26 dBFS to -45 dBFS (about 19 dB) in far-side-only seconds; the second in
  which Andreas talks keeps its level.
- Synthetic bleed on a real headphone recording (Python prototype, same algorithm):
  21.7 dB reduction far-side-only, near-side-only passages unchanged, double talk error
  -45 dB against speech at -23 dB.
- Speed (release build): 3.3 s for a 30 min recording, 6 s for 48 min.

## Diagnosis

- `defaults write de.foxagon.pavarotti PavarottiKeepRawMicTrack -bool YES` keeps the
  unprocessed track as `mic.raw.aac` next to `mic.aac`. Deleting a meeting's audio in the
  app does not remove that file; turn the default off again when done.
- Log lines (notice level): `Passive mic setup: …` (category `PassiveMicCapture`) and
  `Mic track pass: blocks=… cleaned=… delay=… gain=… replaced=…` (category
  `MicTrackCleaner`).
- `PAVAROTTI_BLEED_DIR=<folder> swift test -c release --filter MicTrackCleaner` runs the
  pass on copies of `<name>-mic.aac` / `<name>-system.aac` pairs and prints the per-block
  figures (correlation/explained share in percent).

## Open points

- Raw built-in MacBook microphone while a call app uses voice processing is very quiet
  (see `mic_capture_level_findings.md`); the static gain covers up to +24 dB but also
  raises the noise. Not yet measured in the fork.
- Outputs with more than 0.7 s latency (AirPlay) are outside the delay search and stay
  untouched.
- Noise suppression and Mic Modes (Voice Isolation) came with VPIO and are gone.
