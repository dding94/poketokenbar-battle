#!/usr/bin/env bash
# Fork release preparation and separately authorized publication. See RELEASE.md.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="dding94/poketokenbar-battle"
TAP_REPO="dding94/homebrew-tap"
CASK_NAME="poke-token-bar-battle"
CASK_PATH="Casks/$CASK_NAME.rb"
APP_NAME="PokeTokenBattle"
EXEC_NAME="PokeTokenBarBattle"
MODE="${1:-}"
case "$MODE" in
  --check-only) [[ $# == 1 ]] || { echo 'Use --check-only without a version' >&2; exit 1; } ;;
  --prepare|--prepare-build) [[ $# == 2 ]] || { echo 'Use --prepare or --prepare-build VERSION' >&2; exit 1; }; VERSION="$2" ;;
  *)
    [[ "${PTB_FORK_RELEASE_READY:-0}" == 1 ]] || { echo 'Publication is disabled. Confirm version, signing identity, targets, and remaining acceptance checks before PTB_FORK_RELEASE_READY=1.' >&2; exit 1; }
    [[ $# == 1 ]] || { echo 'Use release.sh VERSION' >&2; exit 1; }
    MODE=publish; VERSION="$1" ;;
esac
# A public build without the address silently falls back to manual entry, and every later check would pass.
if [[ "$MODE" == --prepare-build || "$MODE" == publish ]]; then
  [[ -n "${PTB_BATTLE_SERVER_URL:-}" ]] || { echo 'PTB_BATTLE_SERVER_URL is required: a release embeds the server address.' >&2; exit 1; }
fi

doc_check() {
  local warn=0
  echo "▶ 문서 일관성 검토"
  # 정적 버전 하드코딩(릴리스마다 수동 갱신 필요 → 동적 배지 권장)
  if grep -rnE "img.shields.io/badge/release-v[0-9]" README*.md 2>/dev/null; then
    echo "  ⚠ README 에 정적 버전 배지가 있습니다(동적 github/v/release 배지 권장)."; warn=1
  fi
  # 제거된 의존성/도구 흔적 (필요 시 PATTERN 에 추가)
  for pat in ccusage; do
    if grep -rniq "$pat" README*.md 2>/dev/null; then
      echo "  ⚠ README 에 '$pat' 잔존 — 제거된 항목인지 확인."; warn=1
    fi
  done
  # UI 변경 → 스크린샷 staleness (실제 diff 상태 검증 — 수동 체크리스트가 통과의례로 묻히지 않게).
  # 직전 릴리스 태그 이후 UI 소스가 바뀌었는데 assets 스크린샷이 안 바뀌었으면 README 이미지 stale 가능.
  local last_tag ui_changed shot_changed
  last_tag=$(git describe --tags --match "v*" --abbrev=0 2>/dev/null || echo "")
  if [[ -n "$last_tag" ]]; then
    ui_changed=$(git diff --name-only "$last_tag"..HEAD -- 'Sources/PokeTokenBar/UI/' 2>/dev/null)
    shot_changed=$(git diff --name-only "$last_tag"..HEAD -- 'assets/settings*' 'assets/screenshot*' 'assets/menubar*' 'assets/shiny*' 2>/dev/null)
    if [[ -n "$ui_changed" && -z "$shot_changed" ]]; then
      echo "  ⚠ UI 소스가 $last_tag 이후 변경됐으나 스크린샷(assets/) 갱신 없음 — README 이미지 stale 가능:"
      echo "$ui_changed" | sed 's/^/       /'
      echo "     → 변경된 화면이면 assets 스크린샷 재생성 (README.md/ja 각 언어)."
      warn=1
    fi

    # 새 UI 기능 → **신규** 에셋 커버리지 (하드 게이트).
    # 위 staleness 는 "에셋이 하나라도 바뀌었나"만 본다 → 기존 스크린샷만 다시 그려도 통과한다.
    # 2.5.0 이 정확히 그 경로로 새 나갔다: 플로팅 펫(신규 기능)이 README·랜딩에 이미지 하나 없이 배포됐고,
    # settings.png 를 갱신해 둔 탓에 위 검사는 조용히 통과했다. 신규 기능은 신규 에셋을 요구한다.
    local ui_feats new_assets
    ui_feats=$(git log "$last_tag"..HEAD --format='%s' -- 'Sources/PokeTokenBar/UI/' 2>/dev/null \
                 | grep -iE '^(feat|feature)[(:]' || true)
    new_assets=$(git diff --name-only --diff-filter=A "$last_tag"..HEAD -- 'assets/' 2>/dev/null)
    if [[ -n "$ui_feats" && -z "$new_assets" ]]; then
      echo "  ✗ UI 를 바꾼 신규 기능이 있는데 assets/ 에 **새로 추가된** 파일이 없습니다:"
      echo "$ui_feats" | sed 's/^/       /'
      echo "     → 새 화면·새 표면이면 전용 스크린샷을 만들어 README(ja 포함)와 랜딩에 넣으세요."
      echo "     → 신규 화면의 실제 캡처나 명시적으로 표시한 합성 렌더 이미지를 추가하세요."
      # 예외 없음. 경고(return 1, y/N 프롬프트)와 달리 return 2 는 호출부에서 즉시 중단시킨다 —
      # 환경변수 우회구를 두면 결국 그 변수가 습관이 된다. 통과시키려면 에셋을 만들거나
      # 커밋 타입을 바꿔야 한다(= 판단을 기록으로 남겨야 한다).
      return 2
    fi
  fi
  cat <<'CHECK'
  ─ 수동 체크리스트 (내용 변경 시 갱신) ─────────────────────────────
   [ ] README.md / .ja : 기능 목록·요구사항·데이터소스·스크린샷
   [ ] 확정된 포크 랜딩(있는 경우): hero·features·install·works-with·요구사항·푸터
       · 버전 배지는 동적(github/v/release) → 자동. 기능/문구만 수동.
       · 3개 언어 i18n 사전(en/ko/ja) 동시 갱신 + 키 정합 유지.
   [ ] homebrew-tap cask: caveats(설치 요구사항) 최신 상태인지
  ─────────────────────────────────────────────────────────────────
CHECK
  return $warn
}

# Local preflight never contacts GitHub, reads a private key, installs, or creates an identity.
ORIGIN=$(git remote get-url origin)
case "$ORIGIN" in
  "https://github.com/$REPO.git"|"https://github.com/$REPO"|"git@github.com:$REPO.git") : ;;
  *) echo "Fork origin mismatch: $ORIGIN" >&2; exit 1 ;;
esac
python3 scripts/release-validate.py source .

if [[ "$MODE" == --check-only ]]; then
  doc_check
  echo 'Local source/document checks passed. Signing, tap existence, acceptance, and publication readiness are NOT verified.'
  exit 0
fi
python3 scripts/release-validate.py version "$VERSION"
NOTES_FILE="${PTB_NOTES_FILE:-}"
python3 scripts/release-metadata.py check-notes "$NOTES_FILE" "${PTB_CONTRIBUTORS_FILE:-}"
doc_check

if [[ "$MODE" == --prepare ]]; then
  echo "Prepared local review for v$VERSION: $REPO, $EXEC_NAME.zip, /Applications/$APP_NAME.app."
  echo "Planned tap: $TAP_REPO/$CASK_PATH (not queried or created)."
  echo 'Build/signature, actual signing identity, tap existence, two-Mac acceptance, Free-plan operations/recovery, and publication readiness are NOT verified.'
  echo 'No build, installation, key creation, tracked version change, commit, push, tag, Release, tap, or Pages change was performed.'
  exit 0
fi

# Publication requires explicit readiness plus an existing, clean main branch and fork tap.
# Both preparation modes return above/below before any publication command.
TMP_RELEASE=$(mktemp -d "${TMPDIR:-/tmp}/ptb-release.XXXXXX")
trap 'rm -rf "$TMP_RELEASE"' EXIT
if [[ "$MODE" == publish ]]; then
  BRANCH=$(git rev-parse --abbrev-ref HEAD)
  [[ "$BRANCH" == main ]] || { echo "Publication requires main (current: $BRANCH)" >&2; exit 1; }
  [[ -z "$(git status --porcelain --untracked-files=no)" ]] || { echo 'Publication requires a clean working tree' >&2; exit 1; }
  # Read only: a missing/unconfigured tap is a blocker, never a reason to create one.
  gh api "repos/$TAP_REPO/contents/$CASK_PATH" > "$TMP_RELEASE/tap.json"
  python3 - "$TMP_RELEASE/tap.json" "$TMP_RELEASE/cask.rb" <<'TAP'
import base64, json, pathlib, sys
value=json.loads(pathlib.Path(sys.argv[1]).read_text())
if not value.get('sha') or not value.get('content'): sys.exit('Fork tap cask is missing')
pathlib.Path(sys.argv[2]).write_bytes(base64.b64decode(value['content'], validate=False))
TAP
  # The tap still holds the pre-rename template (app "PokeTokenBar Battle.app") until this publication rewrites it.
  python3 scripts/release-validate.py check-published-cask "$TMP_RELEASE/cask.rb"
fi

# CI is the full-suite criterion. Do not run local OCR or an unisolated/opt-out native test gate.
# This selector is verified against GitHub's run/jobs/logs API; it is never a manual assertion.
CI_HEAD=$(git rev-parse HEAD)
python3 scripts/release-ci.py "${PTB_CI_RUN_ID:-}"

# Public identity metadata only; no certificate creation or secret lookup.
SIGN_IDENTITY="${CODESIGN_IDENTITY:-PokeTokenBar Battle Local}"
EXPECTED_LEAF="${PTB_EXPECTED_LEAF:-}"
[[ "$EXPECTED_LEAF" =~ ^[A-Fa-f0-9]{40}$ ]] || { echo 'PTB_EXPECTED_LEAF must identify the approved certificate (40 hex digits)' >&2; exit 1; }
EXPECTED_LEAF=$(printf '%s' "$EXPECTED_LEAF" | tr '[:lower:]' '[:upper:]')
LEAF=$(security find-identity -v -p codesigning | awk -v id="\"$SIGN_IDENTITY\"" 'index($0,id) {print toupper($2); exit}')
[[ "$LEAF" == "$EXPECTED_LEAF" ]] || { echo 'Signing identity missing or leaf mismatch; confirm the existing identity. No certificate was created.' >&2; exit 1; }

mkdir -p build/release
# A failed rebuild must not leave a prior cask preview looking current.
rm -f "build/release/$EXEC_NAME.zip" "build/release/$CASK_NAME.rb"
# Never install or terminate either app while building a release artifact.
PTB_SKIP_INSTALL=1 PTB_NATIVE_ARCH_ONLY=0 PTB_REQUIRE_STABLE_SIGN=1 \
  PTB_RELEASE_VERSION="$VERSION" CODESIGN_IDENTITY="$SIGN_IDENTITY" ./scripts/build-app.sh
APP="build/$APP_NAME.app"
python3 scripts/release-validate.py bundle . "$APP" "$VERSION" "$EXPECTED_LEAF"
# Reuse the preflight boundary: newly added source is just as unverified as a tracked edit.
python3 scripts/release-ci.py --check-source "$CI_HEAD"
ZIP="build/release/$EXEC_NAME.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
ZIP_SHA=$(shasum -a 256 "$ZIP" | awk '{print $1}')
python3 scripts/release-validate.py cask "$VERSION" "$ZIP_SHA" > "build/release/$CASK_NAME.rb"
python3 scripts/release-validate.py check-cask "build/release/$CASK_NAME.rb"
echo "Validated local artifact: $ZIP (SHA256 $ZIP_SHA)"
echo "Cask preview: build/release/$CASK_NAME.rb"
echo 'Stable certificate identity does not establish Developer ID trust, notarization, Gatekeeper acceptance, or uninterrupted Keychain permission.'
if [[ "$MODE" == --prepare-build ]]; then
  echo 'Local build prepared. No installation, commit, push, tag, GitHub Release, tap, or Pages mutation performed. External acceptance/readiness is NOT verified.'
  exit 0
fi

# Only the separately authorized publication path below edits tracked version or external services.
COMMIT_MESSAGE=$(python3 scripts/release-metadata.py commit-message "$VERSION" "${PTB_COAUTHORS_FILE:-}")
python3 - "$VERSION" <<'BUMP'
import pathlib,re,sys
path=pathlib.Path('scripts/build-app.sh')
value,count=re.subn(r'^VERSION="[0-9.]+"$', 'VERSION="'+sys.argv[1]+'"',path.read_text(),count=1,flags=re.M)
if count!=1: sys.exit('Missing tracked VERSION assignment')
path.write_text(value)
BUMP
git add scripts/build-app.sh
git commit -q -m "$COMMIT_MESSAGE"
git push -q origin main
gh release create "v$VERSION" "$ZIP" --repo "$REPO" \
  --title "$APP_NAME v$VERSION" --target main --notes-file "$NOTES_FILE"
# Update both version and checksum from the validated artifact, with optimistic tap SHA.
python3 - "$TMP_RELEASE/tap.json" "build/release/$CASK_NAME.rb" "$TMP_RELEASE/update.json" <<'UPDATE'
import base64,json,pathlib,sys
old=json.loads(pathlib.Path(sys.argv[1]).read_text())
cask=pathlib.Path(sys.argv[2]).read_bytes()
pathlib.Path(sys.argv[3]).write_text(json.dumps({'message':'cask: update poke-token-bar-battle','content':base64.b64encode(cask).decode(),'sha':old['sha']}))
UPDATE
gh api -X PUT "repos/$TAP_REPO/contents/$CASK_PATH" --input "$TMP_RELEASE/update.json"
echo "Published v$VERSION and fork cask. Verify the published asset checksum and approved installation/upgrade separately."
