#!/bin/bash
# Fails unless the build-test shards between them ran every test of the suite exactly once. The rest
# shard skips the regex the rendering shard filters on, but a mismatch, a crash that ends a run early
# or tests from another library would otherwise leave tests out of CI without a failure.
# Usage: check-test-union.sh <`swift test list` output> <swift test log>...
set -euo pipefail
export LC_ALL=C
[ $# -ge 2 ] || { echo "usage: $0 <test list> <swift test log>..." >&2; exit 2; }
for file in "$@"; do [ -s "$file" ] || { echo "::error::missing or empty: $file" >&2; exit 2; }; done
list="$1"; shift

# Both sides as "PokeTokenBarTests.SomeTests/testSomething", the form `swift test list` prints.
listed="$(grep -E '^[^ ]+\.[^ /]+/[^ ]+$' "$list" | sort || true)"
ran() {  # "Test Case '-[PokeTokenBarTests.SomeTests testSomething]' passed (0.010 seconds)."
    { grep -ohE "Test Case '-\[[^]]+\]' (passed|failed|skipped)" "$@" || true; } |
        sed -E "s/^Test Case '-\[([^ ]+) ([^]]+)\]'.*/\1\/\2/"
}

status=0
report() {
    [ -n "$2" ] || return 0
    echo "::error::$(grep -c . <<< "$2") test(s) $1:" >&2
    sed 's/^/  /' <<< "$2" >&2
    status=1
}
[ -n "$listed" ] || report "listed" "(none: the list has no test names)"
for log in "$@"; do echo "$(ran "$log" | grep -c . || true) tests ran in $(basename "$log")"; done
report "ran more than once" "$(ran "$@" | sort | uniq -d)"
report "listed but never ran" "$(comm -23 <(echo "$listed") <(ran "$@" | sort -u))"
report "ran but not listed" "$(comm -13 <(echo "$listed") <(ran "$@" | sort -u) | grep . || true)"
[ $status -eq 0 ] && echo "every one of the $(grep -c . <<< "$listed") listed tests ran exactly once"
exit $status
