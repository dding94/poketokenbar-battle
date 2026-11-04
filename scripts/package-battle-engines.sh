#!/bin/bash
# Verify immutable archive pins and package resources. No network, build, signing, or installation.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESOURCES="${1:?Usage: package-battle-engines.sh RESOURCES_DIRECTORY}"
REGISTRY="$ROOT/Sources/PokeTokenBar/Core/BattleEngineArchive.swift"
MANIFEST="$ROOT/Sources/PokeTokenBar/Core/BattleEngineManifest.swift"
CURRENT="$(sed -n 's/.*static let sha256 = "\([0-9a-f]*\)".*/\1/p' "$MANIFEST")"
PINS="$(sed -n 's/.*Entry(hash: "\([0-9a-f]*\)".*/\1/p' "$REGISTRY")"
[[ ${#CURRENT} == 64 && -n "$PINS" ]] || { echo 'Missing engine trust pins' >&2; exit 1; }
printf '%s\n' "$PINS" | grep -qx "$CURRENT" || { echo 'Current engine is not archived and pinned' >&2; exit 1; }
[[ "$(printf '%s\n' "$PINS" | sort | uniq -d)" == '' ]] || { echo 'Duplicate engine pins' >&2; exit 1; }
verify() {
    [[ -f "$1" && "$(shasum -a 256 "$1" | awk '{print $1}')" == "$2" ]] || {
        echo "Missing or corrupt engine: $1" >&2; exit 1;
    }
}
# Validate everything before copying. A corrupt pin is an assembly failure, never a silent omission.
verify "$ROOT/engine/dist/battle-engine.js" "$CURRENT"
while IFS= read -r pin; do
    [[ ${#pin} == 64 ]] || { echo 'Invalid engine hash pin' >&2; exit 1; }
    verify "$ROOT/engine/archive/$pin.js" "$pin"
done <<< "$PINS"
mkdir -p "$RESOURCES"
cp "$ROOT/engine/dist/battle-engine.js" "$RESOURCES/battle-engine.js"
cp "$ROOT/engine/LICENSE.pokemon-showdown" "$RESOURCES/LICENSE.pokemon-showdown"
while IFS= read -r pin; do
    if [[ "$pin" != "$CURRENT" ]]; then
        mkdir -p "$RESOURCES/battle-engines"
        cp "$ROOT/engine/archive/$pin.js" "$RESOURCES/battle-engines/$pin.js"
    fi
done <<< "$PINS"
