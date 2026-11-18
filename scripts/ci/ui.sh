#!/bin/bash
# XCUITest on an iPhone simulator against two enactd servers on the host:
#   8770 clean, 8771 with ENACT_FAULTS=lateChunk (the app must report the stalls).
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build/reports
swift build -c release --product enactd
.build/release/enactd --port 8770 > build/reports/enactd-clean.log 2>&1 &
CLEAN=$!
ENACT_FAULTS=lateChunk .build/release/enactd --port 8771 > build/reports/enactd-late.log 2>&1 &
LATE=$!
trap 'kill $CLEAN $LATE 2>/dev/null || true' EXIT
which xcodegen >/dev/null || brew install xcodegen
(cd App && xcodegen --quiet)
udid=$(xcrun simctl list devices available -j | python3 -c '
import json,re,sys
best=None
for rt,ds in json.load(sys.stdin)["devices"].items():
    m=re.search(r"iOS-(\d+)-(\d+)",rt)
    for d in ds if m else []:
        if d["name"].startswith("iPhone") and " SE" not in d["name"]:
            k=((int(m.group(1)),int(m.group(2))),d["name"])
            best=max(best,(k,d["udid"])) if best else (k,d["udid"])
print(best[1])')
xcrun simctl boot "$udid" || true
rm -rf build/reports/ui.xcresult
xcodebuild test -project App/EnactProbe.xcodeproj -scheme EnactProbeApp -destination "id=$udid" \
  -resultBundlePath build/reports/ui.xcresult CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO \
  | tee build/reports/ui.log | grep -E "Test Case|error:|\*\* TEST|Executed"
