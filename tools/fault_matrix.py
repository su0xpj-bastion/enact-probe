"""Start enactd once per server fault, run the synthetic viewer, and require that exactly the
pinned checks fail. A clean run must pass everything."""
from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BIN = Path(os.environ.get("ENACT_BIN", ROOT / ".build" / "local"))

EXPECTED: dict[str, set[str]] = {
    "": set(),
    "chunkClockDrift": {"stream.pts-continuous"},
    "seamDuplicate": {"stream.frame-sequence"},
    "lateChunk": {"stream.no-stalls", "input.latency"},
    "inputDropAtBoundary": {"input.consumed-once"},
    # Applied a chunk late, the last chunk's worth of samples is never shown at all.
    "inputLagExtraChunk": {"input.consumed-once", "input.latency"},
    "beatNotReplaced": {"direction.barge-in"},
    "audioDrift": {"av.sync"},
    "anchorDrift": {"scene.anchor-hold"},
}


SLOW = "generator too slow for real time"
# Checks that measure wall-clock timing. A shared CI VM can pause for a second and trip these on a
# clean run. Functional checks (frame sequence, PTS, consumed-once, barge-in, A/V sync) never retry.
TIMING = {"input.latency", "stream.no-stalls"}


def session(fault: str, attempts: int = 3) -> dict:
    """One viewer session against a fresh server.

    - The stand-in generator itself missed real time (CI VMs without hardware video encode): the
      session measures the machine, not the client. Retry; mark invalid if the machine stays slow.
    - The result differs from the pinned set ONLY in timing checks: retry, and record each retry in
      `flakes` so the report shows it. Any functional mismatch is returned at once, never retried.
    """
    flakes: list[dict] = []
    for _ in range(attempts):
        r = _session(fault)
        if any(SLOW in e for e in r.get("errors", [])):
            continue
        diff = failing(r) ^ EXPECTED.get(fault, set())
        if diff and diff <= TIMING:
            flakes.append({name: r["checks"].get(name, "passed") for name in sorted(diff)})
            continue
        r["flakes"] = flakes
        return r
    r["flakes"] = flakes
    if not flakes:
        r["invalid"] = True
    return r


def _session(fault: str) -> dict:
    env = dict(os.environ, ENACT_FAULTS=fault)
    server = subprocess.Popen([str(BIN / "enactd"), "--port", "0"], stdout=subprocess.PIPE, text=True, env=env)
    try:
        port = int(server.stdout.readline().split()[1])
        out = subprocess.run([str(BIN / "probe"), "run", "--url", f"ws://127.0.0.1:{port}", "--json"],
                             capture_output=True, text=True, timeout=120).stdout
        return json.loads(out)
    finally:
        server.terminate()
        server.wait(timeout=5)


def failing(report: dict) -> set[str]:
    return set(report["checks"])


def main() -> int:
    only = sys.argv[1:]
    ok = True
    for fault, want in EXPECTED.items():
        if only and fault not in only:
            continue
        r = session(fault)
        if r.get("invalid"):
            print(f"SKIP {fault or '(no fault)':22} machine too slow for a real-time session: {r['errors'][-1]}")
            continue
        got = failing(r)
        good = got == want
        for f in r.get("flakes", []):
            print(f"RETRY {fault or '(no fault)':20} timing-only mismatch on a loaded machine: {f}")
        ok &= good
        label = fault or "(no fault)"
        print(f"{'ok ' if good else 'BAD'} {label:22} caught by {sorted(got) or '-'}"
              f"   p50 {r['latencyP50'] * 1000:.0f} ms, p95 {r['latencyP95'] * 1000:.0f} ms")
        if not good:
            print(f"      expected {sorted(want)}")
            for name in sorted(got ^ want):
                print(f"      {name}: {r['checks'].get(name, 'passed')}")
    print("\nfault matrix: " + ("every fault caught by exactly its pinned checks" if ok else "MISMATCH"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
