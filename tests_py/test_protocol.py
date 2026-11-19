"""enactd's wire protocol, poked directly with a raw WebSocket (no Swift client in the loop)."""
from __future__ import annotations

import time

from ws import WS

CHUNK = 17 / 24


def test_chunks_are_mp4_with_continuous_media_time(server):
    ws = WS(server)
    ws.send_json({"type": "start", "chunks": 3})
    heads = []
    for _ in range(3):
        h, mp4 = ws.recv_chunk()
        assert mp4[4:8] == b"ftyp", "chunk payload is not an MP4"
        heads.append(h)
    assert [h["chunk"] for h in heads] == [0, 1, 2]
    assert [h["startTicks"] for h in heads] == [0, 17000, 34000]
    ws.close()


def test_chunks_arrive_at_real_time_cadence(server):
    ws = WS(server)
    t0 = time.monotonic()
    ws.send_json({"type": "start", "chunks": 4})
    arrivals = []
    for _ in range(4):
        ws.recv_chunk()
        arrivals.append(time.monotonic() - t0)
    gaps = [b - a for a, b in zip(arrivals, arrivals[1:])]
    assert all(abs(g - CHUNK) < 0.2 for g in gaps), gaps
    ws.close()


def test_inputs_before_start_and_garbage_are_ignored(server):
    ws = WS(server)
    ws.send_text("not json")
    ws.send_json({"type": "input", "seq": 999, "button": 1, "x": 0.1, "y": 0.1, "dx": 0, "dy": 0})
    ws.send_json({"type": "warp-drive"})
    ws.send_json({"type": "start", "chunks": 2})
    h0, _ = ws.recv_chunk()
    h1, _ = ws.recv_chunk()
    assert 999 not in h0["inputs"] + h1["inputs"]
    ws.close()


def test_input_conditions_the_next_chunk_not_the_current_one(server):
    ws = WS(server)
    ws.send_json({"type": "start", "chunks": 3})
    time.sleep(0.2)                       # chunk 0 started at t=0; this sample arrives during it
    ws.send_json({"type": "input", "seq": 1, "button": 1, "x": 0.3, "y": 0.3, "dx": 0, "dy": 0})
    heads = [ws.recv_chunk()[0] for _ in range(3)]
    # The rule: an input never changes the chunk already being made, and is used exactly once.
    # Normally that is chunk 1. On a loaded CI VM the message can reach the server after chunk 1
    # has started, and then chunk 2 is the right answer (EP-7), so the sleep alone can't pin it.
    assert heads[0]["inputs"] == [], "input changed the chunk already being made"
    where = [i for i, h in enumerate(heads) if 1 in h["inputs"]]
    assert len(where) == 1 and where[0] in (1, 2), [h["inputs"] for h in heads]
    ws.close()


def test_note_replaces_beats_not_yet_started(server):
    ws = WS(server)
    ws.send_json({"type": "start", "chunks": 6})
    time.sleep(CHUNK + 0.1)               # during chunk 1, in beat 1 (chunks 0-2)
    ws.send_json({"type": "note", "text": "Alice, louder"})
    beats = [ws.recv_chunk()[0]["beat"] for _ in range(6)]
    assert beats[:2] == [1, 1] and all(b >= 100 for b in beats[2:]), beats
    ws.close()


def test_two_viewers_are_independent(server):
    a, b = WS(server), WS(server)
    a.send_json({"type": "start", "chunks": 3})
    b.send_json({"type": "start", "chunks": 3})
    time.sleep(0.1)
    a.send_json({"type": "input", "seq": 1, "button": 1, "x": 0.5, "y": 0.5, "dx": 0, "dy": 0})
    ha = [a.recv_chunk()[0] for _ in range(3)]
    hb = [b.recv_chunk()[0] for _ in range(3)]
    assert sum(len(h["inputs"]) for h in ha) == 1 and sum(len(h["inputs"]) for h in hb) == 0
    a.close(); b.close()


def test_server_survives_a_viewer_leaving_mid_stream(server):
    ws = WS(server)
    ws.send_json({"type": "start", "chunks": 10})
    ws.recv_chunk()
    ws.close()
    time.sleep(CHUNK * 2)
    again = WS(server)
    again.send_json({"type": "start", "chunks": 1})
    assert again.recv_chunk()[0]["chunk"] == 0
    again.close()
