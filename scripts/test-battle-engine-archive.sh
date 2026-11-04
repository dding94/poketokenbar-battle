#!/bin/bash
# Synthetic future upgrade verifies preservation, deduplication and failure gates without an app install.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/ptb-archive-test.XXXXXX")"
trap 'rm -rf "$FIXTURE"' EXIT
mkdir -p "$FIXTURE/scripts" "$FIXTURE/engine/archive" "$FIXTURE/engine/dist" "$FIXTURE/Sources/PokeTokenBar/Core"
cp "$ROOT/scripts/package-battle-engines.sh" "$FIXTURE/scripts/"
printf 'old verified engine\n' > "$FIXTURE/engine/old.js"
printf 'new verified engine\n' > "$FIXTURE/engine/dist/battle-engine.js"
OLD="$(shasum -a 256 "$FIXTURE/engine/old.js" | awk '{print $1}')"
NEW="$(shasum -a 256 "$FIXTURE/engine/dist/battle-engine.js" | awk '{print $1}')"
cp "$FIXTURE/engine/old.js" "$FIXTURE/engine/archive/$OLD.js"
cp "$FIXTURE/engine/dist/battle-engine.js" "$FIXTURE/engine/archive/$NEW.js"
printf 'license\n' > "$FIXTURE/engine/LICENSE.pokemon-showdown"
printf 'static let sha256 = "%s"\n' "$NEW" > "$FIXTURE/Sources/PokeTokenBar/Core/BattleEngineManifest.swift"
printf 'Entry(hash: "%s",\nEntry(hash: "%s",\n' "$OLD" "$NEW" > "$FIXTURE/Sources/PokeTokenBar/Core/BattleEngineArchive.swift"
package() { bash "$FIXTURE/scripts/package-battle-engines.sh" "$FIXTURE/resources"; }
package
cmp "$FIXTURE/engine/old.js" "$FIXTURE/resources/battle-engines/$OLD.js"
cmp "$FIXTURE/engine/dist/battle-engine.js" "$FIXTURE/resources/battle-engine.js"
[[ ! -f "$FIXTURE/resources/battle-engines/$NEW.js" ]]
echo 'PASS: future upgrade preserves historical engine and deduplicates current engine'
printf 'corruption' >> "$FIXTURE/engine/archive/$OLD.js"
if package > "$FIXTURE/rejected.log" 2>&1; then echo 'FAIL: corrupt historical engine accepted' >&2; exit 1; fi
grep -q 'Missing or corrupt engine' "$FIXTURE/rejected.log"
echo 'PASS: corrupt historical bytes fail packaging'
cp "$FIXTURE/engine/old.js" "$FIXTURE/engine/archive/$OLD.js"
rm "$FIXTURE/engine/archive/$NEW.js"
if package > "$FIXTURE/rejected.log" 2>&1; then echo 'FAIL: missing current archive accepted' >&2; exit 1; fi
echo 'PASS: missing current archive fails packaging'
printf 'Entry(hash: "%s",\n' "$OLD" > "$FIXTURE/Sources/PokeTokenBar/Core/BattleEngineArchive.swift"
if package > "$FIXTURE/rejected.log" 2>&1; then echo 'FAIL: unpinned current engine accepted' >&2; exit 1; fi
grep -q 'Current engine is not archived and pinned' "$FIXTURE/rejected.log"
echo 'PASS: unpinned current engine fails packaging'
