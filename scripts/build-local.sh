#!/bin/sh
# Build enactd + probe with plain swiftc (Command Line Tools only). With Xcode: swift build.
set -e
cd "$(dirname "$0")/.."
B=${BUILD_DIR:-.build/local}
mkdir -p "$B"
for m in EnactProbe EnactServer; do
  swiftc -O -parse-as-library -emit-library -static -module-name $m -I "$B" -emit-module-path "$B/$m.swiftmodule" -o "$B/lib$m.a" Sources/$m/*.swift
done
swiftc -O -I "$B" -L "$B" -lEnactProbe -lEnactServer -o "$B/enactd" Sources/enactd/main.swift
swiftc -O -I "$B" -L "$B" -lEnactProbe -o "$B/probe" Sources/probe/main.swift
