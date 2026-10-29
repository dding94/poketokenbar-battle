#!/usr/bin/env bash
# Run only after the unmodified fork tests pass. Always restore the source.
set -euo pipefail
cd "$(dirname "$0")/.."

SOURCE="Sources/PokeTokenBar/Core/AppIdentity.swift"
BACKUP=$(mktemp)
LOG=$(mktemp)
cp "$SOURCE" "$BACKUP"
restore() {
    cp "$BACKUP" "$SOURCE"
    rm -f "$BACKUP" "$LOG"
}
trap restore EXIT

python3 - <<'PY'
from pathlib import Path
source = Path("Sources/PokeTokenBar/Core/AppIdentity.swift")
text = source.read_text()
old = 'static let bundleID = "io.github.dding94.poketokenbar-battle"'
assert text.count(old) == 1, "Expected exactly one fork bundle ID"
source.write_text(text.replace(old, 'static let bundleID = "io.github.chattymin.poketokenbar"', 1))
PY

set +e
swift test --filter 'AppIdentityTests.testForkIdentityNeverReusesUpstreamValues' >"$LOG" 2>&1
RESULT=$?
set -e
cat "$LOG"
python3 - "$RESULT" "$LOG" <<'PY'
import sys
from pathlib import Path
log = Path(sys.argv[2]).read_text()
assert sys.argv[1] == "1", "Injected identity must fail with exit code 1"
assert "XCTAssertNotEqual failed" in log, "Require an assertion failure, not a build/environment error"
assert "testForkIdentityNeverReusesUpstreamValues" in log
assert "Executed 1 test, with 1 failure" in log, "Require exactly one executed, failing guard test"
print("PASS: upstream bundle ID was rejected by the fork identity assertion")
PY

cp "$BACKUP" "$SOURCE"
swift test --filter 'AppIdentityTests.testForkIdentityNeverReusesUpstreamValues'
cmp "$BACKUP" "$SOURCE"
