#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Xcode otherwise selects this legacy CocoaPods project symlink instead of Package.swift.
if [[ -L _Pods.xcodeproj ]]; then
  legacy_link="$(readlink _Pods.xcodeproj)"
  rm _Pods.xcodeproj
  trap 'ln -s "$legacy_link" _Pods.xcodeproj' EXIT
fi
if [[ -z "${SHUFFLE_TEST_DESTINATION:-}" ]]; then
  simulator_id="$(xcrun simctl list devices available --json | python3 -c 'import json,sys; data=json.load(sys.stdin); print(next(d["udid"] for runtime,devices in data["devices"].items() if "iOS" in runtime for d in devices if d["name"].startswith("iPhone") and d.get("isAvailable",False)))')"
  SHUFFLE_TEST_DESTINATION="platform=iOS Simulator,id=$simulator_id"
fi
xcodebuild test -scheme Shuffle -destination "$SHUFFLE_TEST_DESTINATION" \
  -parallel-testing-enabled NO "$@"
