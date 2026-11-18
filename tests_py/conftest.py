from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
BIN = Path(os.environ.get("ENACT_BIN", ROOT / ".build" / "local"))
sys.path.insert(0, str(Path(__file__).parent))


@pytest.fixture()
def server():
    p = subprocess.Popen([str(BIN / "enactd"), "--port", "0"], stdout=subprocess.PIPE, text=True,
                         env=dict(os.environ, ENACT_FAULTS=""))
    port = int(p.stdout.readline().split()[1])
    yield port
    p.terminate()
    p.wait(timeout=5)
