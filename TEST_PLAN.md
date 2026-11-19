# Test plan: enact-probe

Follows the shared [test strategy](https://github.com/su0xpj-bastion/proof-sheet/blob/main/docs/TEST_STRATEGY.md). Real bugs from building it are in [BUGS.md](BUGS.md).

**In scope:** the viewer side of a live, chunked AI-video stream: input sampling, chunk delivery, decode, and what the viewer sees and hears.

**Out of scope:** the generative model itself (a stand-in renders test frames); real networks with loss; real devices.

## What must be true, and how it's checked

| Requirement | Priority | How it is checked |
|---|---|---|
| Input reaches the screen fast enough | P0 | touch-to-photon latency from decoded frames: p50 ≤ 1.5 chunks + 0.3 s, p95 ≤ 2 chunks + 0.38 s |
| No freezes, no repeated or skipped frames | P0 | arrival gaps, frame sequence, media time to the 1/24000 s tick |
| Every input is used exactly once, at the cadence the model expects | P0 | 14–20 samples per chunk window; consumed-once |
| A new instruction takes effect quickly | P1 | barge-in ≤ 2 chunks + 0.3 s |
| Sound on picture; the scene holds its look | P1 | click vs frame ±5 ms; tint vs the first frame ±6/255 |

## How it runs

- **Every push (CI):** all checks, then the fault matrix (each planted bug switched on alone must fail exactly its pinned checks).
- **Locally:** the same checks through the command-line tool (`scripts/build-local.sh`), on a Mac with only the Command Line Tools.

## Exit criteria

11/11 checks pass on a clean server; each of 8 server faults fails exactly its checks; or the session is marked invalid if the machine can't run real time. CI is green on the default branch.

## Risks

- Test media is generated, so every answer is exact. Real-world media needs licensed sets run through the same checks.
- Simulators and CI machines are not real devices. Timing and hardware behaviour need a real-device pass before release.
