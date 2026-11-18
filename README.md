# enact-probe

An iPhone test harness for **live AI video**: a stream that answers your touch and your voice
chunk by chunk, as in Pika's
[Enact architecture](https://pika.art/blog/pika-enact) (live staging, live actor direction).

`enactd` is a stand-in for the generator. It speaks the stream's shape:
- WebSocket in: `(button, x, y, dx, dy)` samples at 24 Hz and director's notes.
- WebSocket out: one H.264 + AAC chunk every 17/24 s, conditioned on the inputs that arrived
  before that chunk started generating.

`probe` (CLI, XCTest) and the iPhone app watch the stream like a viewer does, and measure it.

Every frame carries two barcodes:
- **A:** the frame number.
- **B:** the last input sample the "model" applied, plus the beat id.

Every second of audio carries a click on a frame's first sample. So "did my drag show up, and
when?", "did the note interrupt?", "is the sound on the picture?" are read **from the pixels and
samples the phone actually decoded**. Nothing is taken from server logs.

```
Sources/EnactProbe   wire format, frame codes, chunk decoder, client, analyzer (iOS + macOS)
Sources/EnactServer  chunk renderer (AVAssetWriter H.264/AAC) + Network.framework WebSocket server + faults
Sources/enactd       the server         Sources/probe   synthetic viewer CLI
Tests/               XCTest: one test per check on a live in-process session, units, decode metrics
tests_py/            pytest: raw-WebSocket protocol tests, fault matrix
App/                 SwiftUI iPhone app (touch → 24 Hz samples, note button, live readout) + XCUITest
```

## Use cases → checks

| # | Use case | Check | How it is measured |
|---|---|---|---|
| 1 | Touch-to-photon latency | `input.latency` | send time of sample *s* → first decoded frame whose barcode B ≥ *s*; p50 ≤ 1.5 chunks + 0.3 s (1.36 s), p95 ≤ 2 chunks + 0.38 s (1.80 s) |
| 2 | Input/latent alignment | `input.cadence`, `input.consumed-once` | 24 samples/s, no gap of 3 frame intervals (125 ms), 99% of gaps under 2 (83 ms); every sample conditions exactly one chunk |
| 3 | Chunk-boundary seams | `stream.frame-sequence`, `stream.pts-continuous`, `stream.frames-readable` | frame numbers run 0…N−1 with no repeats; media time is exact in 1/24000 s ticks |
| 4 | Streaming playback | `stream.complete`, `stream.no-stalls` | every chunk arrives and decodes; no gap between arrivals exceeds a chunk + 0.3 s |
| 5 | Device health | XCTest `XCTClockMetric`/`XCTCPUMetric`/`XCTMemoryMetric`; XCUITest app CPU/memory; thermal state | |
| 7 | A/V sync | `av.sync` | each once-a-second click lands on its frame's first sample, ±5 ms |
| 8 | Barge-in | `direction.barge-in` | note sent → first frame of the new beat ready, ≤ 2 chunks + 0.3 s |
| 9 | Identity / scene hold | `scene.anchor-hold` | scene tint vs the first frame (the anchor), ±6/255 |

## Fault matrix

`ENACT_FAULTS=<name> enactd` breaks the server on purpose. `tools/fault_matrix.py` (and the
pytest wrapper) require that each fault fails **exactly** these checks, and that a clean run passes
all of them:

| Fault | What breaks | Caught by |
|---|---|---|
| chunkClockDrift | chunks stamped at k × 0.708 s, not k × 17/24 s (8 ticks short per chunk) | stream.pts-continuous |
| seamDuplicate | each chunk repeats the previous chunk's last frame | stream.frame-sequence |
| lateChunk | every 8th chunk ships 0.9 s late | stream.no-stalls, input.latency |
| inputDropAtBoundary | samples arriving in the 100 ms before a chunk starts are lost | input.consumed-once |
| inputLagExtraChunk | samples applied one chunk later than possible | input.consumed-once, input.latency |
| beatNotReplaced | a note waits behind queued beats instead of replacing them | direction.barge-in |
| audioDrift | audio slips 1 ms per chunk | av.sync |
| anchorDrift | the scene's look creeps away from the first frame | scene.anchor-hold |

Measured locally (macOS 26, Apple silicon), clean server, 20 chunks:
- Input-to-photon latency: p50 1.14 s, p95 1.47 s. This fits the model: an input waits for the next chunk to start, so 1 to 2 chunk lengths plus encode, transport and decode.
- Barge-in: 1.31 s.
- A/V offset: 0.0 ms.
- Chunk decode: p95 83 ms.

## Run it

```bash
scripts/build-local.sh                         # enactd + probe with plain swiftc
.build/local/enactd --port 8770 &
.build/local/probe run --url ws://127.0.0.1:8770
python3 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt
.venv/bin/python -m pytest                     # protocol tests + fault matrix (about 3 minutes, real time)
scripts/ci/ui.sh                               # XCUITest on an iPhone simulator (needs Xcode + brew xcodegen)
```

## What it does not cover (from the original list)

- **6 Mic interruptions** and **10 Line fidelity**: the app's note button sends text. Real hold-to-talk needs AVAudioSession plus Speech, and a TTS fixture to score the actors' word error rate.
- **11 iPhone media as reference**: the import side (HEIC, orientation, P3, HDR, VFR) is tested in [proof-sheet](https://github.com/su0xpj-bastion/proof-sheet).
- **12 Gyro as camera control**: needs device motion. The simulator has none, so this belongs on a real-device run.

## Honest limits

- `enactd` is a stand-in. It renders test frames, not a diffusion model. What it reproduces is the timing, conditioning and transport contract of a causal chunked generator, which is what the client tests exercise.
- Latency budgets are wall-clock times on shared CI machines. A clean local run has about 330 ms of headroom on p95; the input sampler runs on its own high-priority thread against absolute deadlines, because a GCD timer dropped to 17 samples/s on a CI VM.
- The app shows each chunk's last frame as it lands; it does not play back at 24 fps. The checks use every decoded frame.
