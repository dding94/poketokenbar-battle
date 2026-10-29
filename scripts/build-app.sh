#!/bin/bash
# PokeTokenBar Battle.app 번들 조립 + /Applications 설치
#
# 포크 식별값(번들 ID·앱 이름·실행 파일·LaunchAgent label)은 Sources/PokeTokenBar/Core/AppIdentity.swift 와
# 같아야 한다 — AppIdentityTests 가 이 파일을 읽어 대조한다. 원본 PokeTokenBar.app 은 절대 지우거나 종료하지 않는다.
# 설치 없이 build/ 에만 만들려면 PTB_SKIP_INSTALL=1.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="2.5.6"
APP_NAME="PokeTokenBar Battle"
EXEC_NAME="PokeTokenBarBattle"
BUNDLE_ID="io.github.dding94.poketokenbar-battle"
LOGIN_LABEL="io.github.dding94.poketokenbar-battle.login"
PRODUCT="PokeTokenBar"   # SwiftPM 실행 파일 이름(번들 안에서는 EXEC_NAME 으로 바꿔 넣는다)
ENGINE_BUNDLE="engine/dist/battle-engine.js"
ENTITLEMENTS="scripts/battle.entitlements"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

# 원본 설치본(/Applications/PokeTokenBar.app)·원본 프로세스를 건드리는 값으로 되돌아가면 즉시 중단한다.
if [[ "$APP_NAME" == "PokeTokenBar" || "$EXEC_NAME" == "PokeTokenBar" \
      || "$BUNDLE_ID" == "io.github.chattymin.poketokenbar" ]]; then
    echo "✗ 원본 앱 식별값으로 빌드하려 합니다. 원본 설치본을 덮어쓸 수 있어 중단합니다." >&2
    exit 1
fi

# README 가 Apple Silicon + Intel 지원을 약속하므로 배포 바이너리는 universal(arm64 + x86_64)이어야 한다.
# `swift build --arch arm64 --arch x86_64` 는 Xcode(xcbuild)가 필요해 Command Line Tools 만으로는 실패하므로
# 아키텍처별로 따로 빌드한 뒤 lipo 로 합친다. 로컬 개발에서 빌드 시간을 줄이려면 PTB_NATIVE_ARCH_ONLY=1.
ARCHS=(arm64 x86_64)
if [[ "${PTB_NATIVE_ARCH_ONLY:-0}" == "1" ]]; then
    [[ "${PTB_REQUIRE_STABLE_SIGN:-0}" == "1" ]] && { echo "   ✗ 릴리스 빌드는 PTB_NATIVE_ARCH_ONLY 를 쓸 수 없다 (universal 필수)." >&2; exit 1; }
    ARCHS=("$(uname -m)")
fi
SLICES=()
for arch in "${ARCHS[@]}"; do
    echo "==> swift build -c release --arch $arch"
    swift build -c release --arch "$arch"
    SLICES+=("$(swift build -c release --arch "$arch" --show-bin-path)/$PRODUCT")
done

echo "==> $APP 조립"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${SLICES[@]}" -output "$APP/Contents/MacOS/$EXEC_NAME"
lipo "$APP/Contents/MacOS/$EXEC_NAME" -verify_arch "${ARCHS[@]}"
echo "   archs: $(lipo -archs "$APP/Contents/MacOS/$EXEC_NAME")"
# 심볼 strip — 릴리스 바이너리 1.84MB → 0.80MB(-57%). codesign 전에 수행(서명 무효화 방지).
strip -rSTx "$APP/Contents/MacOS/$EXEC_NAME" 2>/dev/null || strip -rSx "$APP/Contents/MacOS/$EXEC_NAME"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# 전투 엔진 번들(engine/ 에서 빌드해 커밋한 단일 JS). 없으면 배틀 화면이 엔진 없음 오류를 보여 준다.
if [[ -f "$ENGINE_BUNDLE" ]]; then
    cp "$ENGINE_BUNDLE" "$APP/Contents/Resources/battle-engine.js"
    cp engine/LICENSE.pokemon-showdown "$APP/Contents/Resources/LICENSE.pokemon-showdown"
else
    echo "   ⚠ $ENGINE_BUNDLE 없음 — 배틀 기능 없이 조립합니다 (cd engine && npm ci && npm run build)."
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>$EXEC_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# 크래시/OOM(exit≠0) 시 자동 재실행 LaunchAgent(KeepAlive) — SMAppService.agent 가 등록해 launchd 가
# 워치독으로 동작. 정상 종료(exit 0: 사용자 종료·업데이트)엔 재실행 안 함(SuccessfulExit=false).
# ProgramArguments 는 설치 경로(/Applications) 고정. codesign 전에 생성해 서명 seal 에 포함.
mkdir -p "$APP/Contents/Library/LaunchAgents"
cat > "$APP/Contents/Library/LaunchAgents/$LOGIN_LABEL.plist" <<AGENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LOGIN_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Applications/$APP_NAME.app/Contents/MacOS/$EXEC_NAME</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key><false/>
    </dict>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
    <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
AGENT

echo "==> codesign"
# JavaScriptCore(JSContext)의 JIT 는 allow-jit entitlement 로 서명해야 켜진다(없으면 인터프리터로 느리게 동작).
SIGN_IDENTITY="${CODESIGN_IDENTITY:-PokeTokenBar Battle Local}"
# 안정적 Keychain ACL 을 위해서는 인증서 존재가 아니라 유효한 codesigning identity 가 필요하다.
if security find-identity -v -p codesigning | grep -F "\"$SIGN_IDENTITY\"" >/dev/null; then
    # 안정적 자체 서명 신원 → 재빌드해도 Keychain "항상 허용" 유지
    codesign --force --entitlements "$ENTITLEMENTS" -s "$SIGN_IDENTITY" "$APP"
else
    # 인증서 없음 → ad-hoc (빌드마다 cdhash 변경 = Keychain 재프롬프트 가능)
    if [[ "${PTB_REQUIRE_STABLE_SIGN:-0}" == "1" ]]; then
        # 릴리스 경로(release.sh 가 세팅). ad-hoc 릴리스는 사용자 Keychain 승인을 깨므로 절대 금지.
        echo "   ✗ PTB_REQUIRE_STABLE_SIGN=1 인데 '$SIGN_IDENTITY' 유효 identity 없음 → ad-hoc 금지, 중단." >&2
        echo "     ./scripts/create-signing-cert.sh 실행 후 다시 시도하세요." >&2
        exit 1
    fi
    echo "   ('$SIGN_IDENTITY' 유효 codesigning identity 없음 → ad-hoc 서명 — 로컬 개발용)"
    echo "   반복 Keychain 허용 프롬프트를 줄이려면 ./scripts/create-signing-cert.sh 실행 후 다시 빌드하세요."
    codesign --force --entitlements "$ENTITLEMENTS" -s - "$APP"
fi

if [[ "${PTB_SKIP_INSTALL:-0}" == "1" ]]; then
    echo "완료(설치 생략): open \"$APP\""
    exit 0
fi

echo "==> 기존 포크 인스턴스 종료 + /Applications 설치 (원본 PokeTokenBar.app 은 그대로 둔다)"
pkill -x "$EXEC_NAME" 2>/dev/null || true
rm -rf "/Applications/$APP_NAME.app"
cp -R "$APP" /Applications/

echo "완료: open \"/Applications/$APP_NAME.app\""
