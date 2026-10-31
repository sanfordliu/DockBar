#!/bin/bash
# Runs the unit tests and fails when line coverage of DockBar is under 70%.
set -euo pipefail
cd "$(dirname "$0")/.."

frameworks="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
if [[ ! -d "$frameworks/Testing.framework" ]]; then
  echo "Swift Testing framework was not found at ${frameworks}." >&2
  exit 1
fi

swift test --enable-code-coverage \
  -Xswiftc -F -Xswiftc "$frameworks"

profdata="$(find .build -path '*arm64-apple-macosx/debug/codecov/default.profdata' -print | head -1)"
binary="$(find .build -type f -path '*arm64-apple-macosx/debug/DockBarPackageTests.xctest/Contents/MacOS/DockBarPackageTests' -print | head -1)"
if [[ -z "$profdata" || -z "$binary" ]]; then
  echo "Could not find coverage data or the test binary." >&2
  exit 1
fi

report="$(xcrun llvm-cov report "$binary" \
  -instr-profile "$profdata" \
  -ignore-filename-regex 'Tests/|\.build/' \
  -name-regex 'Sources/DockBar')"
echo "$report"

percent="$(echo "$report" | awk '/^TOTAL/ { gsub("%","",$10); print $10 }')"
echo "Line coverage: ${percent}%"
awk -v p="$percent" 'BEGIN { if (p+0 < 70) exit 1 }' || {
  echo "Coverage ${percent}% is below 70%." >&2
  exit 1
}
