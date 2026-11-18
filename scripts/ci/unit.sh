#!/bin/bash
# XCTest (live in-process session + units + decode metrics), then the fault matrix via pytest.
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build/reports
swift build -c release --product enactd
swift build -c release --product probe
# Release build: the live session is timing-sensitive, and debug Swift is too slow for real time on a CI VM.
swift test -c release -Xswiftc -enable-testing --no-parallel 2>&1 | tee build/reports/swift-test.log
[ -d .venv ] || python3 -m venv .venv
.venv/bin/pip -q install -r requirements-dev.txt
ENACT_BIN=.build/release .venv/bin/python -m pytest --junitxml=build/reports/pytest.xml
