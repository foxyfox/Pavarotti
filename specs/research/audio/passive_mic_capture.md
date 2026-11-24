# Passive mic capture (Pavarotti fork, 2026-11-12)

**Decision:** Pavarotti no longer records the microphone through Apple's voice
processing (VPIO, `LiveMicCaptureEngine`). It reads the chosen microphone straight from
the HAL with an IO proc on that one device (`PassiveMicCaptureEngine`; since 2026-11-24,
see "AVAudioEngine was not passive") and does the echo and level work
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
| 11-11 14:30 | Output on the MacBook speakers (PR #40 companion), call on the Bluetooth speaker | Canceller had a silent reference: far side at 0.34 s delay on the mic track |
| 11-11 14:30:38 | Rebuilt on Bluetooth headphones as output | Headphones at 24 kHz (headset mode) for the whole call although the mic was the Studio Display |
| 11-12 10:10 | Same companion route as 11-11 | Short Slack huddle recording with everything doubled (far side at 0.33 s, about -15 dB, on the mic track) |

PR #40 removed the reclock but could not fix the design: with the output on a companion
device the canceller is blind, and with it on the real output the unit takes part in the
call's audio path. MacWhisper, which only listens, never showed any of this on the same
Mac.

## What replaced it

- **Capture** (`PassiveMicCaptureEngine`): `AudioDeviceCreateIOProcIDWithBlock` +
  `AudioDeviceStart` on the chosen microphone's device, channel 0 of its first input
  stream, handed to the unchanged `MicCaptureSession`. No output device, sample rate or
  default device is opened or changed. Listeners on the device's rate, stream format and
  liveness rebuild the capture; a failed rebuild never ends the recording, it is retried
  (0.3 s to 5 s apart) until it works or the recording stops, and the gap is filled with
  silence. Hardware check with AirPods Max as default input (24 kHz) and the Studio
  Display as chosen microphone, including a reconnect
  (`PAVAROTTI_HARDWARE_MIC=1 PAVAROTTI_HARDWARE_MIC_UID=<uid> swift test --filter PassiveMicHardware`):
  8.59 s wall clock gave 8.70 s of audio, the AirPods stayed at 48 kHz.
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

## AVAudioEngine was not passive (2026-11-24)

The first version (PR #42) used an input-only `AVAudioEngine` with the chosen device set
on the input node. That held only while the chosen microphone was also the default input.
With AirPods Max as default input:

- Recordings of 11-23 11:27 and 11-24 10:38 lost the microphone: after a configuration
  change the rebuilt engine refused to start (`-10868`, "Input HW format 48000, tap format
  24000": the node kept the default input's format). The old code then shut the capture
  down for good, silently.
- Reproduced on hardware with a `reconnect()` mid-capture. Passing the hardware format to
  the tap made it worse: the engine opened the default input, the AirPods dropped to
  24 kHz (headset mode) and the engine looped through configuration changes without
  delivering audio.

The input node of `AVAudioEngine` belongs to the default input; it cannot be trusted to
leave it alone. Do not go back to it for capture.

Also learned: system tap creation still fails with `'nope'` (OSStatus 1852797029) now and
then without VPIO (11-24 10:38:41, twice), so that failure is not caused by voice
processing. It is retried by `AudioRecorder`; cause still open.

## Numbers

- Real call 2026-11-23 (14.5 min, Bluetooth speaker, passive capture): bleed found in all
  86 blocks at 0.49 s delay; microphone level in the 547 seconds with far-side audio
  -35.3 dBFS raw, -52.5 dBFS cleaned (median reduction 19.7 dB); the 170 near-side-only
  seconds changed by -0.5 dB; lag between raw and cleaned track 0 samples, equal length.
  Five more calls (11-17 to 11-20): 130 to 243 blocks each, 80 to 100 % of them cleaned,
  same 0.49 s delay.

- Recording 2026-11-12 (Bluetooth speaker, still VPIO, canceller blind): far side on the mic track
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
