# enact-probe

<!-- plain-english:begin -->
[![ci](https://github.com/su0xpj-bastion/enact-probe/actions/workflows/ci.yml/badge.svg)](https://github.com/su0xpj-bastion/enact-probe/actions/workflows/ci.yml)

A test kit for **live AI video**: apps where the video is generated while you
watch, and it reacts to your finger and your instructions in short chunks (about 0.7 s each).
It answers the questions a viewer feels:
- When I drag, how long until I see it?
- Does it ever freeze?
- If I give a new instruction, does it listen quickly?
- Is the sound on the picture?

A live AI app can "work" and still feel laggy, and users leave without
saying why. This turns "feels laggy" into a number, and blocks a release when the number gets
worse.

- A stand-in AI video server in Swift. It streams real H.264 video chunks over a WebSocket, using each viewer input only for the next chunk, the way a real causal generator works.
- An iPhone app and a command-line viewer that measure everything from what actually reached the screen and speakers. Every frame carries two barcodes: its number, and the last input it obeyed.
- 11 checks (latency, freezes, frame order, timing, input cadence, barge-in, A/V sync, scene drift) and 8 planted server bugs, each proven caught.

Touch-to-screen is about 1.1 s typical and 1.5 s at the 95th percentile,
which is what the design predicts (one to two chunks).

Swift, Network.framework, URLSession WebSockets, AVFoundation encode and
decode, SwiftUI, XCTest, XCUITest, Python protocol tests, Jenkins and GitHub Actions. CI taught
me to measure input the way the model consumes it (samples per chunk), and to flag when the
test machine itself can't keep up instead of blaming the app.

[Test plan](TEST_PLAN.md) · [Bugs found](BUGS.md) · [Test strategy](https://github.com/su0xpj-bastion/proof-sheet/blob/main/docs/TEST_STRATEGY.md)

---

## Technical detail
<!-- plain-english:end -->

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
| 1 | Touch-to-photon latency | `input.latency` | for samples the model used: send time of sample *s* → first decoded frame whose barcode B ≥ *s*; p50 ≤ 1.5 chunks + 0.3 s (1.36 s), p95 ≤ 2 chunks + 0.38 s (1.80 s) |
| 2 | Input/latent alignment | `input.cadence`, `input.consumed-once` | 24 ± 2 samples/s, and 14-20 samples in every chunk-length window (17 expected); every sample conditions exactly one chunk |
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
- If the stand-in generator itself misses real time (a CI VM without hardware video encode), the report says so, and the fault matrix retries that session and then skips it as invalid instead of blaming the client.
- Latency budgets are wall-clock times on shared CI machines. A clean local run has about 330 ms of headroom on p95; the input sampler runs on its own high-priority thread against absolute deadlines, because a GCD timer dropped to 17 samples/s on a CI VM.
- The app shows each chunk's last frame as it lands; it does not play back at 24 fps. The checks use every decoded frame.
