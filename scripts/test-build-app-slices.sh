#!/bin/bash
# Functional bundle-assembly regression: synthetic architecture markers, no real build/sign/install.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ptb-build-slices-test.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/bin"
cat > "$TEST_DIR/bin/fake-tool" <<'MOCK'
#!/bin/bash
set -euo pipefail
tool="${0##*/}"
printf '%s %s\n' "$tool" "$*" >> "$FAKE_LOG"
case "$tool" in
swift)
    arch=""; show=0
    while (($#)); do
        case "$1" in --arch) arch="$2"; shift ;; --show-bin-path) show=1 ;; esac
        shift
    done
    bin="$FIXTURE_REPO/.build/shared"
    [[ "$OUTPUT_LAYOUT" == distinct ]] && bin="$FIXTURE_REPO/.build/$arch"
    if [[ "$show" == 1 ]]; then printf '%s\n' "$bin"; else mkdir -p "$bin"; printf '%s\n' "$arch" > "$bin/PokeTokenBar"; fi
    ;;
lipo)
    if [[ "$1" == -create ]]; then
        shift; archs=""; seen=" "
        while [[ "$1" != -output ]]; do
            arch="$(cat "$1")"
            case "$seen" in *" $arch "*) echo "duplicate architecture: $arch" >&2; exit 1 ;; esac
            seen="$seen$arch "; archs="${archs:+$archs }$arch"; shift
        done
        printf '%s\n' "$archs" > "$2"
        printf 'combined:%s\n' "$archs" >> "$FAKE_LOG"
    elif [[ "$1" == -archs ]]; then cat "$2"
    else
        binary="$1"; shift
        [[ "$1" == -verify_arch ]]; shift
        # Xcode 27's lipo accepts only one requested architecture per verification call.
        (($# == 1)) || { echo 'verify_arch requires exactly one architecture' >&2; exit 1; }
        actual=" $(cat "$binary") "
        for arch in "$@"; do [[ "$actual" == *" $arch "* ]] || exit 1; done
    fi
    ;;
strip|codesign) : ;;
security) echo '0 valid identities found' ;;
pkill) echo 'Unexpected process termination' >&2; exit 1 ;;
cp|rm)
    for arg in "$@"; do
        [[ "$arg" != /Applications* ]] || { echo 'Unexpected installation access' >&2; exit 1; }
    done
    exec "/bin/$tool" "$@"
    ;;
esac
MOCK
chmod +x "$TEST_DIR/bin/fake-tool"
for tool in swift lipo strip codesign security pkill cp rm; do ln -s fake-tool "$TEST_DIR/bin/$tool"; done
for layout in shared distinct; do
    repo="$TEST_DIR/$layout"
    mkdir -p "$repo/scripts" "$repo/assets" "$repo/engine/dist" "$repo/tmp"
    cp "$ROOT/scripts/build-app.sh" "$repo/scripts/build-app.sh"
    touch "$repo/assets/AppIcon.icns" "$repo/engine/dist/battle-engine.js" "$repo/engine/LICENSE.pokemon-showdown" "$repo/scripts/battle.entitlements"
    if ! PATH="$TEST_DIR/bin:$PATH" FIXTURE_REPO="$repo" OUTPUT_LAYOUT="$layout" FAKE_LOG="$repo/calls.log" \
         TMPDIR="$repo/tmp" PTB_SKIP_INSTALL=1 PTB_NATIVE_ARCH_ONLY=0 PTB_REQUIRE_STABLE_SIGN=0 \
         bash "$repo/scripts/build-app.sh" > "$repo/build.log" 2>&1; then
        cat "$repo/build.log" >&2
        echo "FAIL: $layout output layout must assemble both original architectures" >&2
        exit 1
    fi
    grep -qx 'combined:arm64 x86_64' "$repo/calls.log"
    [[ "$(cat "$repo/build/PokeTokenBar Battle.app/Contents/MacOS/PokeTokenBarBattle")" == 'arm64 x86_64' ]]
    ! grep -Eq '^pkill |/Applications' "$repo/calls.log"
    [[ -z "$(ls -A "$repo/tmp")" ]] || { echo 'FAIL: temporary slices were not removed' >&2; exit 1; }
    echo "PASS: $layout outputs preserve both slices, skip installation, and clean temporary files"
done
