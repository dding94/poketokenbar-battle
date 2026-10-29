#!/bin/bash
# Fails when an alternative of a `swift test --filter` regex ran no test. XCTest reports a filter that
# matches nothing as success, so a renamed or misspelled class would drop out of CI silently
# (step 4 wired "PracticeWildTests" while the classes were PracticeWildRulesTests, ...).
# Usage: check-test-filter.sh "<A|B|C>" <swift test log>
set -euo pipefail
[ $# -eq 2 ] && [ -f "$2" ] || { echo "usage: $0 \"<A|B|C>\" <swift test log>" >&2; exit 2; }
filter="$1"; log="$2"

# "Test Case '-[PokeTokenBarTests.SomeTests testSomething]' passed (0.010 seconds)." -> "PokeTokenBarTests.SomeTests testSomething"
ran="$(grep -oE "Test Case '-\[[^]]+\]' (passed|failed|skipped)" "$log" | sed -E "s/^Test Case '-\[([^]]+)\]'.*/\1/" | sort -u || true)"

missing=0
IFS='|' read -ra alternatives <<< "$filter"
for alternative in "${alternatives[@]}"; do
    if ! grep -qE -- "$alternative" <<< "$ran"; then
        echo "::error::test filter alternative '$alternative' ran no test" >&2
        missing=1
    fi
done
[ $missing -eq 0 ] && echo "every alternative of the filter ran ($(grep -c . <<< "$ran") tests)"
exit $missing
