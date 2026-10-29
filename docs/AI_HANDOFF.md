# 다음 AI를 위한 작업 인계

최종 갱신: 2026-10-29. **PR 00·01·02·03 검증을 완료했다. PR 03A의 읽기 전용 연습전 테스트를 실행 중이다. 배틀 화면은 아직 없다.**

## 진행 중인 작업 (2026-10-29 기준, PR 03 검증 완료 → PR 03A 착수)

- 브랜치: `feat/local-practice-battle` (`main` 5e9af78에서 분기). 인수 시 모든 변경은 미커밋이었다. 사용자 승인으로 문서(`372eba0`)·PR 00(`c04769a`)·프로브(`0ddc584`)를 나누어 커밋·푸시했고 CI 수정은 `f1dad46`, `cc0b9fe`다. 이후 사용자 승인으로 별도 포크 앱을 설치·실행했으나 아래 격리 누락을 발견해 종료했다. 배포·공개 전환은 하지 않았다.
- 문서 개정: `docs/BATTLE_PLAN.md`(새 구조, PR 00~13 + PR 03A, 부록 A), `docs/AI_HANDOFF.md`, `AGENTS.md`, `README.md`(고지), `CLAUDE.md`(첫 단락 경고 한 줄).
- PR 00 코드(작성 완료, macOS 15 CI 및 로컬 arm64 설치 검증 완료):
  - `Sources/PokeTokenBar/Core/AppIdentity.swift`(신규): 포크 식별값의 단일 출처와 원본 값 목록.
  - `Core/AppStatePaths.swift`: 기본 저장 폴더를 `PokeTokenBarBattle`로 분리, `UpstreamSaveImport`(원본 `companion-state.json`을 포크 세이브가 없을 때만 복사).
  - `PokeTokenBarApp.swift`: 원본 폴더를 옮기던 TokenMac → PokeTokenBar 이관을 제거하고, `PTB_STATE_DIR`가 없을 때만 첫 실행 복사를 호출.
  - `Core/LoginItem.swift`, `Core/UpdateChecker.swift`: LaunchAgent label·업데이트 저장소·cask를 포크 값으로.
  - `Core/SupportMail.swift`, `UI/SettingsView.swift`: 리포트 메일이 원본 개발자에게 가지 않게(`AppIdentity.supportEmail`이 nil이면 리포트 행 숨김), 푸터의 원본 웹사이트·후원 링크를 출처 링크로 교체, 정보 섹션에 팬 프로젝트 고지·제3자 라이선스 표시.
  - `Core/Localization.swift`: `basedOnUpstream`, `forkDisclaimer`, `thirdPartyNotice` 8개 언어.
  - `scripts/build-app.sh`: 포크 번들 ID·앱 이름(`PokeTokenBar Battle`)·실행 파일(`PokeTokenBarBattle`)·LaunchAgent, 원본 값이면 중단, `PTB_SKIP_INSTALL=1`, JIT entitlement 서명, `engine/dist/battle-engine.js`가 있으면 리소스로 복사.
  - `scripts/battle.entitlements`(신규), `scripts/release.sh`(포크 값, `PTB_FORK_RELEASE_READY=1` 없으면 중단, `PTB_EXPECTED_LEAF` 필수), `scripts/create-signing-cert.sh`(인증서 이름).
  - 테스트: `Tests/PokeTokenBarTests/AppIdentityTests.swift`(신규), `PokeTokenBarTests.swift`의 SupportMail 테스트가 수신 주소를 명시하도록 수정.
  - `default.profraw` 삭제, `.gitignore`에 `*.profraw`.
- `engine/`: `@pkmn/sim` 0.10.12·esbuild 0.28.2 고정 `package.json`·`package-lock.json`, 사전 실측 프로토타입 `engine/probe/`, `engine/README.md`. 정식 어댑터·번들·계약 및 결정성 테스트는 아래 PR 01 기록대로 구현했다. (중단한 작업이 남긴 것은 설치뿐이었다.)

검증 상태:

- `swift build`(debug): 성공 (Command Line Tools, Swift 6.3.2).
- 로컬 `swift test`: **실행 불가.** Command Line Tools만 있어 `no such module 'XCTest'`로 컴파일이 멈춘다. 원격 macOS 15 CI에서 아래 검증을 수행했다.
- [성공한 CI 40801084586](https://github.com/dding94/poketokenbar-battle/actions/runs/40801084586) (`cc0b9fe`, macOS 15, Apple Swift 6.1.2):
  - `swift test --filter "AppIdentityTests|SupportMailTests|UpdateCheckerTests"`: 종료 0, **31건 통과·실패 0·skip 0**.
  - `./scripts/test-gate.sh`: 종료 0. `swift test --enable-code-coverage` 보고 1,562건 중 **1,546건 통과·16건 skip·실패 0**, 코어 라인 커버리지 **93.80%**(기준 75%).
  - skip 16건은 대용량 성능 1·선택적 이미지 생성 3·실제 자격 증명 경계 2·실제 사용량 로그 및 PokéAPI 대조 10건이다. 이 시나리오는 미검증이며 통과로 계산하지 않는다. 실제 사용자 로그·자격 증명을 CI에 제공하지 않았다.
  - `bash scripts/test-fork-identity-guard.sh`: 종료 0. 원본 bundle ID 주입 후 해당 가드 **1건 실행·1건 assertion 실패, 내부 명령 종료 1** → 원복 후 **1건 통과, 내부 명령 종료 0**. 원복 파일 일치 확인.
  - Gitleaks: 전체 이력 386개 커밋 검사, 확인된 요금제 라벨 오탐 한 건만 fingerprint 예외, 발견 0. macOS 작업 5분 6초, Linux 작업 14초. 실제 청구 반영액은 별도이며 실행 시간만으로 0원이라고 단정하지 않는다.
- `PTB_SKIP_INSTALL=1 PTB_NATIVE_ARCH_ONLY=1 ./scripts/build-app.sh`: 종료 0, `build/PokeTokenBar Battle.app` 생성(arm64, ad-hoc 서명, 설치 생략). 기존 `PopoverView.swift:1189`의 `GeometryProxy` Sendable 경고 1건은 남아 있다. 엔진 번들은 아직 없으며 배틀 기능은 미포함이다.
- 번들 검사: Python `plistlib`로 Info.plist·LaunchAgent를 파싱하고 `lipo -verify_arch arm64`, `codesign -d --entitlements - --xml`, `codesign --verify --deep --strict`를 실행해 종료 0. 번들 ID `io.github.dding94.poketokenbar-battle`, 실행 파일 `PokeTokenBarBattle`, LaunchAgent `io.github.dding94.poketokenbar-battle.login`과 포크 설치 경로, `com.apple.security.cs.allow-jit=true`를 확인했다. 첫 검사 스크립트는 codesign의 기본 텍스트 출력을 XML로 파싱해 종료 1이었고, `--xml`을 명시한 재검사는 통과했다. Intel 슬라이스·안정 서명 인증서·설치 후 동작은 미검증이다.
- 엔진 프로브: `cd engine && npm run probe` — 5세대 2,500판 Node·JavaScriptCore 불일치 0, 재생·상태 왕복 실패 0(`--keep-names` 빌드). 9세대 규칙은 미검증.

### PR 00 검증 재시도 (2026-10-29)

- `git status --short --branch`·`git remote -v` (각 종료 코드 0): `feat/local-practice-battle`의 기존 미커밋 변경과 `origin=https://github.com/dding94/poketokenbar-battle.git`를 확인했다. 기존 코드·프로브 변경은 보존했다.
- `xcode-select -p` (0): `/Library/Developer/CommandLineTools`. `swift --version` (0): Apple Swift 6.3.2, arm64. `xcodebuild -version` (1): 활성 개발 경로가 Command Line Tools라 Xcode 명령을 사용할 수 없다.
- 실제 대상 테스트 명령: `PTB_STATE_DIR="$(mktemp -d /private/tmp/ptb-pr00-test.XXXXXX)" swift test --filter "AppIdentityTests|SupportMailTests|UpdateCheckerTests"`.
  - 첫 시도는 실행 환경의 기본 Swift 모듈 캐시 쓰기 제한으로 종료 코드 1이었다. 캐시 접근을 허용해 같은 명령을 다시 실행했다.
  - 재시도도 종료 코드 **1**: 테스트 모듈 컴파일에서 **`no such module 'XCTest'`**. 테스트 실행 **0건**, 테스트 성공·실패·skip 집계는 생성되지 않았다. 테스트 통과나 기능 RED 증거로 보지 않는다.
- XCTest 불가 시 멈추라는 사용자 지시에 따라 `./scripts/test-gate.sh`, 식별값 결함 주입, 앱 번들 생성·설치·실행 검증은 미실행이다. PR 01·02·03·03A에는 착수하지 않았고 계획 체크박스도 바꾸지 않았다. 원본 앱·실제 세이브에는 접근하지 않았다.
- **선택 완료:** 사용자가 무료 분량이 충분하면 Actions로 검증하도록 승인했다(필요한 커밋·푸시 포함). 필요 시 공개 전환도 허용했으나, 2026-10-29 로그인한 GitHub Billing 화면에서 이번 검증에 충분한 무료 잔여량을 확인해 private를 유지한다. 계정별 과금 세부 정보는 대화에서만 보고한다.
- CI 설정: 기존 `ci.yml`의 수동 실행만 유지하고 macOS 15 작업은 10분, Linux 비밀값 검사는 3분으로 제한했다. `PTB_STATE_DIR`는 러너 임시 폴더다. 대상 테스트 → 전체 커버리지 게이트 → 원본 bundle ID 결함 주입 → 원복 후 재검증 순서다. 결과 이미지는 1일만 보관한다.
- 첫 원격 실행: [40800833879](https://github.com/dding94/poketokenbar-battle/actions/runs/40800833879), commit `f1dad46`. 대상 테스트 명령 종료 1, 실행 0건: `AppIdentityTests.testLoginItemUsesForkAgent`의 `@MainActor` 누락으로 CI 도구체인에서 컴파일 실패. 전체 게이트·결함 주입은 skip(미검증)이다. 앱만 빌드했던 이전 검증은 테스트 소스의 컴파일을 확인하지 못했다. 해당 메서드에 격리를 명시하고 다른 `LoginItem` 테스트 접근도 검색했다.
- 같은 실행의 Gitleaks는 전체 이력 385개 커밋에서 원본 테스트의 공개 요금제 라벨 `default_claude_max_20x`를 비밀값으로 오인했다. 원본 커밋·파일·행을 확인하고 `.gitleaksignore`에는 그 한 건의 fingerprint만 예외로 기록한다. 전체 파일·규칙을 제외하지 않는다.
- 스크립트 가드 점검: `build-app.sh`의 안전 설명 주석에 원본 설치 경로가 있어 기존 문자열 검사가 오인할 수 있었다. 테스트 helper가 주석 행을 제외한 실행 내용을 검사하도록 보완했으며, 원본 식별값 주입 검증은 유지한다. 위 수정은 성공한 CI에서 재검증했다.

이어서 할 일:

1. PR 03 자동 선택 정책 v1과 최초 공개 이벤트를 구현하고 변경된 정책으로 결정성 코퍼스를 다시 실행한다.
2. PR 02 → PR 03 → PR 03A(로컬 연습전) 순서로 진행한다. 설치·실행 및 계속 진행은 사용자가 승인했다.
3. 사용자에게 연습전 시험 방법을 안내하고 멈춘다. 공개 전환은 필요하지 않아 private를 유지한다.

### PR 03A-1 진행

- RED [CI 40811448759](https://github.com/dding94/poketokenbar-battle/actions/runs/40811448759), `bb7a080`: `swift test --enable-code-coverage --filter "BattleEngineTests|BattleSnapshotTests|PracticeBattleTests"` 종료 1, 20건 실행·22 assertion 실패·skip 0. 연습전 8건 중 7건 실패, 기존 12건 및 잘못된 출전 거절 1건은 통과했다. 컴파일 오류 없이 실제 stub 동작을 확인했다.
- 후보 목록은 값 복사한 CompanionState에서 활성/미방출 졸업 개체만 가져온다. 누락 정보는 한국어 이유와 함께 보류한다. 세션은 BattleSnapshot과 엔진만 소유하며 세이브/CompanionStore/네트워크 참조를 받지 않는다.
- 30초 단조 시계 기한, 0.6초 자동 진행, 숨은 제한 거절 후 재선택, 정상 결과/기술 오류 분리, 닫기/재시작 시 엔진 해제를 구현했다. 로컬 `swift build` 종료 0. 원격 GREEN은 다음 검증이다.

### PR 03 완료 증거

- [CI 40811051440](https://github.com/dding94/poketokenbar-battle/actions/runs/40811051440), `7fa203c`, macOS 14·15: 각각 `swift test --enable-code-coverage --filter "BattleEngineTests|BattleSnapshotTests"` 종료 0, 12건 통과·실패/skip 0. `npm test` 종료 0, 31건 통과·실패/skip 0. `npm run corpus` 종료 0, 2,200판 Node/JSC 불일치 0·inputLog 재생/상태 왕복 실패 0·200턴 무승부 200건. `npm run compatibility` 종료 0, 649종/106폼/541기술 차이 0(조건 불충족 54개는 효과 성공으로 세지 않음).
- 로컬 같은 코퍼스 종료 0. `PTB_FULL_ENGINE=1 npm run corpus:generate && npm run corpus:node` 뒤 최소화 결과와 비교 종료 0, 2,200판 동일. 제품 SHA-256 `5c949cd65373b2dde2b31660643e561a781fac06f9b237d28567a15acccb28da`.
- 첫 수동 실행 요청은 gh의 기본 저장소가 upstream으로 해석되어 403·러너 미실행이었다. 이후 모든 gh 명령에 `-R dding94/poketokenbar-battle`를 명시한다. 엔진 전용 scope라 앱 전체/비밀값 job은 미실행이며 PR 03A 마지막 게이트에서 검증한다.

### PR 03 진행

- Node RED `npm test --prefix engine`: 종료 1, 30건 중 23 통과·7 실패·skip 0. 변화기 반복·동점·공개 이벤트·정책 기록 등 실제 동작 실패를 확인했다.
- 자동 v1은 피해 점수와 조건부 변화기 점수, 전투 RNG와 독립된 policySeed/턴/진영 동점 선택을 쓴다. inputLog v2에 정책 버전을 고정하고 최초 공개 이벤트를 viewer별로 추출한다. Trace/Skill Swap의 현재 특성 소유자도 검사한다.
- GREEN 과정에서 재충전은 Dex의 일반 기술이 아니어서 NaN 점수가 되던 결함을 발견했다. 강제 행동 요청은 평가 없이 지정 슬롯을 반환한다. PP 소진·재충전 테스트가 이 분기를 검증한다. 속도 동률/동일 선택 재생 테스트도 추가했다.
- PR 03A는 변경량을 나눠 **03A-1 읽기 전용 후보/세션/시간 제한** → **03A-2 별도 창/한국어 표시/이미지/설치 검증** 순서로 구현한다. 현재 보유 개체가 여러 마리 있으므로 첫 버전 상대는 내 다른 개체를 사용한다. 야생 개체 생성은 이번 범위에 추가하지 않는다.

### PR 02 진행

- 공개 능력치 API `describeSet`을 부록 A에 추가했다. 같은 `makeSet` 검증을 사용하고 EV 0·9세대 폼·껍질몬 HP 1을 계산하며 기술/특성을 반환하지 않는다.
- Node RED: `npm test --prefix engine` 종료 1, 20건 중 기존 17 통과·신규 3 실패·skip 0. GREEN 종료 0, 20 통과·실패/skip 0. 별칭으로 같은 기술을 중복 입력하는 경우도 거절한다.
- Swift RED: [CI 40808265569](https://github.com/dding94/poketokenbar-battle/actions/runs/40808265569), `ba79906`. `swift test --filter "BattleEngineTests|BattleSnapshotTests"` 종료 1, 10건 실행(기존 4 통과·스냅샷 6 실패), 11개 실패 assertion/오류·skip 0. 테스트 컴파일이 아닌 실제 stub 동작 실패다.
- 스냅샷 schema 1, instanceID·엔진 해시·규칙/정책 버전·전투 입력·공개 능력치만 저장한다. 성장량/단계 진행도는 포함하지 않는다. 개인 데이터 없이 합성 `CompanionState`의 실제 Codable 형태를 인코딩/복원해 검사한다.
- `BattleSnapshot`은 저장소 참조나 파일 쓰기 기능이 없는 값 타입이다. 누락된 성격/성별/특성/기술은 오류로 남기고 기본값으로 채우지 않는다. 원격 GREEN·전체 앱 게이트는 다음 검증이다.

### PR 02 완료 증거

- [CI 40808781003](https://github.com/dding94/poketokenbar-battle/actions/runs/40808781003), `32dfcbd`, macOS 15: 대상 `swift test --filter "AppIdentityTests|SupportMailTests|UpdateCheckerTests|BattleEngineTests|BattleSnapshotTests"` 종료 0, 45건 통과·실패/skip 0. `./scripts/test-gate.sh` 종료 0, 1,576건 중 1,560 통과·16 skip·실패 0, 기존 로직 코어 커버리지 93.82%. 기존 16개 선택적 시나리오는 미검증이다. 결함 주입/원복 가드 종료 0, Gitleaks 398커밋 발견 0.
- 보충 [CI 40809341124](https://github.com/dding94/poketokenbar-battle/actions/runs/40809341124), `e29e6ec`: `swift test --enable-code-coverage --filter "BattleEngineTests|BattleSnapshotTests"` 종료 0, 스냅샷 8 + 래퍼 4 = 12건 통과·실패/skip 0. `./scripts/battle-coverage.sh` 종료 0으로 `llvm-cov show --show-regions`를 확인했다. 스냅샷 거절 분기에 `^0`은 없고, 래퍼의 정상 계약상 항상 있는 error 문자열이 누락됐을 때의 대체 코드 `engine_failure`는 미실행이다. 런타임 할당 실패/손상 JS 예외 조합 전체를 검증한 것은 아니다.
- Node 계약 20/20 통과·skip 0, 로컬 `swift build` 종료 0. 최신 PokéAPI 649종/폼/기술 대조는 PR 01의 같은 고정 데이터 검사로 재사용했다. 서버는 아직 없으며 공통 검증 경계는 `engine/src/input.js`다.

### PR 01 완료 증거

- `npm test` 종료 0: 계약 17건 통과·실패 0·skip 0. 고정 승자/정규화 해시, 입력 거절, 정보 숨김, replay를 검사한다.
- `npm run corpus` 종료 0: 무작위 2,000 + 장기전 200 = 2,200판. 로컬 macOS 26.5, [macOS 15 CI 40806393060](https://github.com/dding94/poketokenbar-battle/actions/runs/40806393060)(`958ea50`의 해당 job 성공), [macOS 14 CI 40807196393](https://github.com/dding94/poketokenbar-battle/actions/runs/40807196393)(`272df9e`) 각각 Node/JSC 불일치 0·재생 실패 0·상태 복원 실패 0, 200턴 무승부 200건. 두 CI의 엔진 번들은 같은 해시다.
- `swift test --filter BattleEngineTests` 각 CI 종료 0: macOS 14·15 각각 4건 통과·실패 0·skip 0. 이전 RED 및 도구체인 실패 이력은 아래 보존했다. 로컬 `swift build` 종료 0(3.50초); 로컬 XCTest는 여전히 사용할 수 없다.
- `npm run compatibility` 종료 0(로컬 및 두 CI): PokéAPI 고정 참조와 649종 메타데이터 차이 0, 앱 폼 106개 일치, BW2 레벨업 541개를 전체/제품 번들 모두 실제 호출. 54개 조건 불충족 기술은 효과 발동 성공으로 보고하지 않는다. 모든 조건별 효과 조합·두 맥 네트워크 경기는 미검증이다.
- 학습 데이터 제거 전/후 2,200판 결과 동일. `keepNames: true`를 고정한다. 제품 번들 2,811,602바이트, SHA-256 `ecd252b0b41f4fb5c3734656777f6f67f001adec2549467d356af19beb49ff36`. Swift 상수와 번들 해시를 함께 생성하며 변조 번들은 실행 전에 거절한다.
- 엔진 전용 CI에서는 일반 앱 전체 게이트/비밀값 job을 scope에 따라 실행하지 않았다. 해당 skip은 앱 전체 회귀 통과를 의미하지 않는다. PR 00 전체 게이트 근거는 별도이며 다음 앱 변경 후 다시 실행한다.

### PR 01A 진행 (2026-10-29)

- 계약 테스트 먼저 작성: `npm test --prefix engine` 종료 1, 17건 중 17건 assertion 실패·skip 0 (`not_implemented` 응답). 입력·호출·오류 경계를 구현한 뒤 같은 명령 종료 0, 17건 통과·실패 0·skip 0.
- 고정 입력은 독립적인 `Battle` 직접 호출로 승자 p1·1턴·정규화 SHA-256 `cffaf9acfe3a04e3a23205cd46c4adbbbdfb540efc86ac5eef03e47e5d216e41`를 산출해 계약에 고정한다.
- 9세대·Terastal Clause, 도구 없음, EV 0, 엄격한 SET/선택 토큰 검증, 200턴 종료 경계, JSON 오류 응답, 시점별 공개 뷰와 inputLog 토큰 재생을 구현했다. `BattleStream`은 사용하지 않는다. 자동 선택은 아직 첫 합법 기술이며 PR 03에서 정책 v1로 교체한다.
- 최소화는 `keepNames: true` 고정. Node 계약만 검증했으며 결정성 코퍼스·상태 왕복·전체 폼/기술 대조·Swift 래퍼·다른 macOS CI는 다음 01B에서 검증한다. PR 01 완료로 보지 않는다.

### PR 01B 진행 (2026-10-29)

- 전체 번들 코퍼스: 무작위 2,000 + 200턴 장기전 200 = **2,200판**, Node 24.14.0와 로컬 macOS 26.5 JavaScriptCore에서 결과·inputLog 해시 불일치 0, 재생/상태 왕복 실패 0. `npm run corpus:compare` 종료 0. 모든 경기에서 첫 선택 직후 상태를 직렬화/복원해 대기 중 선택도 검증했다.
- 첫 코퍼스는 봉인에 의한 숨은 기술 거절을 실패로 취급해 중단됐다. 거절 시 갱신된 요청으로 최대 5회 재선택하고 최종 실패는 계속 오류로 처리한다. 최초 장기전 fixture는 PP 소진으로 200턴 전에 끝나 draw 검증이 실패했다. 총 PP 256인 비공격 4기술로 fixture를 수정한 뒤 200건 모두 200턴 무승부를 확인했다.
- 로컬 첫 JSC 컴파일은 캐시 쓰기 제한으로 종료 1(실행 0건). 캐시 접근을 허용한 같은 명령은 실행됐다. XCTest 우회 검증이 아니라 PR 01이 요구한 실제 Swift JSContext 코퍼스다.
- Swift 래퍼 RED: [CI 40805519751](https://github.com/dding94/poketokenbar-battle/actions/runs/40805519751), `7a47674`. macOS 15에서 `swift test --filter BattleEngineTests` 종료 1, 4건 실행·4실패·skip 0(2건 예상하지 않은 stub 오류 포함). macOS 14는 기본 Swift 5.10이라 컴파일 종료 1·실행 0건이며 RED 증거가 아니다. macOS 14에 설치된 Xcode 16.2를 선택하도록 수정했다.
- 새로운 `engine.yml`은 기본 브랜치에 없어 수동 실행이 404로 거절됐다(러너 미실행). 기존 `ci.yml`의 `scope=app|engine|engine-contract`로 통합했다. 기본 브랜치·공개 상태를 바꾸지 않았다.
- 공식 PokéAPI commit `2bf639e5572812a67d2b94903fdcb9d095f5aeb2`를 캐시에만 받아 대조: 649종 타입·종족값·특성 차이 0, 앱 폼 106개 매핑. 기본 종만 세던 539개 기술에서 폼별 BW2 데이터까지 포함한 **541개**로 수정했다. 9세대에서 모든 기술을 실제 1턴 호출하며 조건 불충족 실패 54건은 효과 발동 성공으로 세지 않는다. 전체 조건별 효과 조합을 증명한 것은 아니다.
- `keepNames: true`로 학습/합법성 데이터를 제거한 번들 2,811,602바이트를 만들었다. 학습 데이터만 제거한 첫 시도는 legality 병합 초기화가 실패해, 둘을 함께 제거했다. 제거 후 Node/JSC 2,200판 불일치 0, 재생/상태 실패 0, 200턴 무승부 200건, 제거 전/후 2,200판 결과 동일을 확인했다(각 비교 종료 0). 원격 GREEN은 진행 중이다. CI `40806393060`의 macOS 14에서는 Xcode 16.2 선택 후 기존 `store.onRefresh` 클로저의 Sendable 추론 차이로 앱 컴파일이 실패(테스트 0건)했다. 클로저에 기존 요구 타입인 `@MainActor @Sendable`을 명시해 보완했다. 재시도 `40806895199`는 기존 렌더 테스트 5곳의 `flatMap(descendants)`를 Swift 6.0이 throwing 함수 참조로 추론해 컴파일 실패(실행 0건)했다. 동일한 호출을 명시적 클로저 `flatMap { descendants($0) }`로 바꾸며 테스트를 제외하지 않는다.

### PR 00 최종 재검증 (2026-10-29)

- [CI 40802858618](https://github.com/dding94/poketokenbar-battle/actions/runs/40802858618), `dc0aa8c`, macOS 15: 대상 테스트 종료 0, **34건 통과·실패 0·skip 0**. 전체 `./scripts/test-gate.sh` 종료 0, **1,565건 중 1,549건 통과·16건 skip·실패 0**, 코어 라인 커버리지 **93.82%**. skip 범위는 위 기록과 같다.
- `bash scripts/test-fork-identity-guard.sh` 종료 0: 원본 bundle ID 주입 시 1건 assertion 실패(내부 종료 1), 원복 후 1건 통과(내부 종료 0). Gitleaks는 388개 커밋 검사·발견 0.
- `PTB_SKIP_INSTALL=1 PTB_NATIVE_ARCH_ONLY=1 ./scripts/build-app.sh` 종료 0. 수정 번들의 Info.plist·LaunchAgent·JIT entitlement·arm64·서명 검사 종료 0. 엔진은 아직 없으며 ad-hoc 로컬 서명이다.
- 사용자 승인 범위에서 `ditto`로 포크 설치본만 교체하고 `open`으로 실행(각 종료 0). 한 명령 안에서 원본 저장 폴더를 해시·mtime 비교한 실행 직후 3초 관측: **220개 파일 변경 0·추가 0**, 원본 PID 유지, 포크 실행, 포크 `Logs/PokeTokenBar.log` 갱신 확인. 이후 포크 폴더에 `last-snapshot.json`과 `usage-cache.json` 생성도 확인했다. 원본 앱 자체의 주기적 저장까지 장시간 불변이라고 주장하지 않는다.
- 최초 복사는 이전 설치의 `upstream save import: imported` 로그와 포크 세이브 생성으로 확인했다. 실제 세이브는 fixture로 쓰지 않았고 원본 파일을 복구/덮어쓰기하지 않았다.
- 보조 `e2e.sh`·`parity-check.sh`도 포크 앱/상태 경로로 수정했다. `bash -n` 종료 0, 실제 UI/사용량 시나리오는 미실행이다.
- UI 도구의 설치 앱 접근은 타임아웃으로 화면 검증 미완료. 프로세스 확인은 권한 있는 읽기 검사에서 원본·포크 모두 실행 중이다(제한 환경의 pgrep 결과는 상태 근거로 쓰지 않음). Intel·다른 macOS·Gatekeeper 배포 인증·실제 자격 증명/사용량 검사·서버 접속은 미검증이다.

### 설치 검증에서 발견한 격리 누락

- `ditto 'build/PokeTokenBar Battle.app' '/Applications/PokeTokenBar Battle.app'`와 `open '/Applications/PokeTokenBar Battle.app'`: 각 종료 0. 원본 앱 PID가 유지된 채 포크도 실행됐고 최초 복사 성공 로그(`upstream save import: imported`) 및 포크 세이브 생성을 확인했다. 실제 세이브는 fixture로 사용하거나 저장소·CI에 올리지 않았다.
- 원본 저장 폴더 220개 파일의 설치 전후 해시·mtime 검사에서 `companion-state.json`, `last-snapshot.json`, `usage-cache.json`의 변화를 발견해 검사 종료 1. 원본 앱도 실행 중이므로 세이브 변화의 주체는 이 비교만으로 단정할 수 없다. 코드 점검으로 포크의 사용량 캐시·진단 스냅샷이 원본 폴더를 쓰는 것은 확인했다.
- 즉시 `pkill -TERM -x PokeTokenBarBattle`(종료 0)로 포크만 종료했고 원본 앱이 계속 실행 중임을 확인했다. 실제 원본 파일을 과거 값으로 되돌리지 않았다.
- 근본원인: `AppStatePaths`를 사용하는 companion 세이브만 분리하고, 직접 경로를 만드는 다른 저장소를 놓쳤다. 기존 테스트도 식별 상수·companion 복사만 검증해 실제 캐시·로그 쓰기 경로를 검사하지 못했다.
- 부류 스윕: `LocalUsageCache`·`UsageStore.writeParitySnapshot`·`PokeAPIClient.baseIndexFile`·`SpriteStore`·`SpriteLoader`에 원본 Application Support 경로, `AppLog`·`CrashReporter`에 원본 로그/실행 마커 경로가 남아 있다. `PTB_STATE_DIR`도 이 경로들에는 적용되지 않았다. 진단 메일의 로그 위치 안내도 함께 수정해야 한다.
- RED: [CI 40802465261](https://github.com/dding94/poketokenbar-battle/actions/runs/40802465261), `2fb688e`. 대상 34건 실행·14 assertion 실패·skip 0, 명령 종료 1. 로그 위치·두 스프라이트 경로 및 분산된 경로 생성이 실제로 검출됐다. 소스 가드가 `AppStatePaths.applicationSupportDirectory()` 호출도 오인한 한 건은 직접 FileManager 조회 패턴만 검사하도록 좁혔다.
- 수정: 위 모든 저장소를 `AppStatePaths.directory()` 및 그 아래 `Logs/`로 모으고 SpriteLoader와 SpriteStore의 경로를 공유했다. 진단 메일도 실제 `AppLog.logFileURL`을 표시한다. 기존 로그 파일 이름은 포크 전용 폴더 안에서 유지한다. 수정 후 원격 재검증과 설치본 교체 결과는 위 최종 재검증을 참고한다.

## 지금 있는 것

- 개인 프로젝트: `dding94/poketokenbar-battle` (private. 사용자의 로컬 테스트 후 public 전환 예정).
- 원본 Swift 앱과 테스트, Git 이력: `chattymin/PokeTokenBar`의 `v2.5.6`.
- 기준 commit: `77f789d7ccf6e692c805f599abf7dcf0c834c56b`.
- 승인된 제품 결정·검증 기준·PR 00~13: [BATTLE_PLAN.md](BATTLE_PLAN.md).
- 에이전트 진입점: [../AGENTS.md](../AGENTS.md), Claude 진입점: [../CLAUDE.md](../CLAUDE.md).
- 기준 앱의 문서: [../README.upstream.md](../README.upstream.md), 상세 규칙: `docs/reference/`.

2026-10-29 개정에서 전투 계산을 서버에서 양쪽 앱으로 옮겼다. 두 맥이 같은 엔진으로 같은 입력을 동시에 계산하고, Cloudflare Worker와 SQLite 기반 Durable Object 하나가 선택 중계·원장·결과 대조·확정을 맡는다. D1은 쓰지 않는다.

## 사전 실측 결과 (2026-10-29, PR 완료 아님)

- `@pkmn/sim` 0.10.12를 단일 번들로 만들어 macOS 26.5 Swift `JSContext`에서 보조 코드 없이 실행했다.
- `gen5customgame` 2,700판(무작위 2,500 + 장기전 200)에서 Node 24.14.0과 JavaScriptCore의 정규화 로그·승자·inputLog 불일치가 0건이었다. inputLog 재생과 상태 직렬화 왕복도 모두 일치했다.
- JavaScriptCore(JIT) 경기당 약 1.2ms, JIT 없이 약 7.8ms. JIT는 `com.apple.security.cs.allow-jit` entitlement 서명이 있어야 켜졌다.
- 번들은 최소화 6.6MB(gzip 1.0MB)이며 대부분 전 세대 학습 기술 데이터다.
- 9세대와 5세대 데이터 차이(1~649번): 일반 특성 24종, 숨겨진 특성 23종, 타입 22종, 종족값 55종.
- Cloudflare 문서상 무료 DO의 호출당 CPU 한도는 확정할 수 없어 10ms로 가정한다. 중계 구조는 메시지당 1ms 수준이라 영향이 없다.
- 실측 스크립트는 `engine/probe/`에 연구용 프로토타입으로 옮겼다(`engine/README.md`). PR 01에서 정식 테스트와 CI로 대체한다.

미검증: 9세대 규칙의 결정성·기술 동작, 다른 macOS 버전의 JavaScriptCore, 실제 두 맥 대전, 학습 기술 데이터 제거, 실제 Free 계정의 WebSocket·요청 사용량.

## 아직 없는 것 / 검증하지 않은 것

- `server/`, Cloudflare 리소스·자격 증명·배포 URL.
- 배틀 화면(로컬 연습전 포함)·락스텝 프로토콜·소유권 이전·스타터 지급·그룹 화면.
- CI의 skip 16건 및 macOS 15 이외 환경에서의 XCTest 검증.
- 저장소 public 전환 및 앱 안 고지의 실제 화면 확인(고지 코드·문자열 테스트는 완료).
- 실제 GitHub 기능 PR. 계획서의 PR 00~13은 앞으로 수행할 작업 단위다.

REA 설치본 버전 확인은 수행했지만, 바이너리와 소스의 재현 빌드 일치를 증명하지 않는다. REA Evidence ID는 이전 조사 세션의 참조이며 새 AI 세션에서 조회 가능하다고 가정하지 않는다.

## 다음 작업: PR 00 검증 → PR 01 → PR 02 → PR 03 → PR 03A

사용자가 구현을 지시한 경우 다음 순서로 진행한다. 현재 위치는 위 "진행 중인 작업"의 이어서 할 일이다.

1. 실제 체크아웃·작업 상태·remote·브랜치를 확인한다. 미커밋 변경을 보존한다.
2. `BATTLE_PLAN.md` §1, §2, §6.3~6.5, §7, PR 00·01·03A, 부록 A를 읽는다.
3. PR 00: 작성된 가드 테스트를 실행해 통과와 결함 주입 실패를 모두 확인한다. 검증 전에는 `scripts/build-app.sh`로 설치하지 않는다.
4. PR 01: `engine/`에 부록 A 계약 테스트를 먼저 만들고, `@pkmn/sim` 버전·잠금 파일·번들 해시를 고정한다. 9세대 규칙(테라스탈 금지)으로 Node와 JavaScriptCore 결정성 코퍼스를 통과시킨다. `engine/probe/`는 참고용이다.
5. PR 02·03 다음 PR 03A(로컬 연습전)를 만들어 사용자가 맥 한 대에서 직접 시험하게 한다. 서버는 필요 없다.
6. 원격 검증이 요청 범위에 포함되면 Cloudflare 계정의 실제 Free 플랜·기존 합산 사용량·대상 리소스를 확인한 뒤 진행한다. PR 07(두 맥 친선전)이 첫 번째 서버 통합 마일스톤이다.

**30명·하루 100경기와 경기당 메시지 수는 부하 가정이며 실측값이 아니다.** 새 `npm run ...` 명령도 현재 존재하지 않으며 PR 01·04~06에서 정의할 인터페이스다.

## 사용자 결정을 다시 묻지 않을 것

- 전투는 두 맥이 계산하고 서버는 중계·원장만 맡는다. 서버 운영비 0원이 중요하다. 회사 IP나 개인 맥북을 서버로 쓰지 않는다.
- 배틀 방식은 신청 때 고른다: 직접 조작 + 자동 보조, 또는 자동. 쟁탈전과 친선전이 있다.
- 9세대 규칙(테라스탈 금지)에 앱이 배운 기술을 그대로 쓴다. 실제 레벨을 쓴다.
- 출전 전에는 종·레벨·타입·능력치만 공개하고 기술·특성은 처음 쓰일 때 공개한다.
- 기존 개체를 사용하고 로컬 육성을 유지한다. 온라인 소유권은 서버가 관리한다.
- 로그인 화면을 원하지 않는다. 회사 이메일은 닉네임처럼 받는 표시값이다. 이메일 인증·Google/Microsoft 로그인으로 확대하지 않는다.
- 쟁탈전 승자는 패자의 정확한 출전 개체를 가져간다. 과거 도감 기록은 남긴다.
- 마지막 개체도 걸 수 있고, 전멸하면 Lv5 스타터 한 마리를 선택한다. 스타터 지급은 3일 쿨다운(첫 지급 즉시).
- 키 분실은 복구코드 또는 방장의 일회용 재연결 코드로 처리한다.
- 탈퇴·퇴사 시 개체는 동결, 표시명은 익명화, 기록은 ID로 유지한다.
- 1차 범위에 친선전·관전·연승·챔피언 칭호·리벤지 매치를 넣는다.
- 저장소는 사용자가 로컬에서 먼저 테스트한 뒤 public으로 전환한다. 원본처럼 비공식·비상업 팬 프로젝트로 운영하고 README와 앱 안에 고지를 둔다.

제품 규칙을 바꿔야 하는 구체적인 구현 문제가 발견되면 그 영향과 대안을 설명한다. 복구코드나 접속키는 이메일과 다른 역할이며, 개인정보·키 원문은 로그나 Git에 남기지 않는다.

## 아직 정하지 않은 세부값 (제안 기본값)

- 직접 조작 턴 제한시간 30초, 미확정 도전 만료 24시간, 결과 보고 기한 72시간.
- 리벤지 매치에서 승자가 거는 개체를 방금 얻은 개체로 고정할지(제안: 고정).
- 챔피언 규칙(제안: 그룹에서 현재 연승이 가장 긴 사람), 친선전 전적 표시 방식.
- `disableKeychainAccess` 설정을 배틀 키에도 적용할지(PR 07).
- 엔진이 바뀐 뒤 과거 경기 재생 방식(구버전 엔진 보관 또는 상세 로그 저장, PR 11).
- 다시 합류한 동료의 동결 해제 절차(제안: 방장 처리).
- 포크의 문제 리포트 수신처(`AppIdentity.supportEmail`, 현재 nil이라 리포트 행 숨김).
- 원본 앱이 함께 실행 중일 때 경고할지(두 앱이 같은 토큰 로그로 각자 개체를 키운다).
- 연습전 상대를 내 다른 개체로만 할지, 앱의 부화 규칙으로 만든 야생 개체도 넣을지(PR 03A).

## 핵심 코드 진입점

| 경로 | 확인할 내용 |
|---|---|
| `Sources/PokeTokenBar/Core/PokemonProfile.swift` | instanceID·IV·레벨·특성·기술, `black-2-white-2`, 능력치 계산 |
| `Sources/PokeTokenBar/Core/PokeAPIClient.swift` | 기술만 B2W2로 거르고 타입·종족값·특성은 최신값 |
| `Sources/PokeTokenBar/Core/CompanionModel.swift` | `active` 단일 슬롯·dex·놓아준 이력·`MonState` |
| `Sources/PokeTokenBar/Core/CompanionStore.swift` | 성장 반영(`update`)·저장·졸업·개체 선택·합성 UI ID |
| `Sources/PokeTokenBar/Core/SaveTransfer.swift` | 세이브 가져오기·복원, `SaveEnvelope.schemaVersion` |
| `Sources/PokeTokenBar/Core/AppStatePaths.swift` | 고정 저장 경로와 `PTB_STATE_DIR` |
| `Sources/PokeTokenBar/Core/UpdateChecker.swift`, `LoginItem.swift` | 원본 저장소·cask·LaunchAgent label |
| `Sources/PokeTokenBar/Core/KeychainAccess.swift`, `SessionKeyLimitsProvider.swift` | Keychain 조회 게이트, 기존 비밀값 파일 저장 방식 |
| `Sources/PokeTokenBar/UI/PopoverView.swift`, `CompanionView.swift` | 배틀 진입점, 개체별 선택·상세 |
| `scripts/build-app.sh`, `scripts/release.sh` | 원본 설치본 덮어쓰기, 원본 서명 인증서 고정 |
| `scripts/test-gate.sh` | 기존 Swift 전체 테스트와 코어 커버리지 |

`DexEntry`에는 놓아준 과거 기록도 있다. 이를 현재 소유 목록으로 삼지 않는다. 가져온 미성숙 개체를 다시 키우려면 `MonState`의 전체 진화·성장 상태를 이전해야 하며, 현재 모델에는 보관함이 없다. UI용 합성 ID는 진화에 따라 바뀔 수 있다.

## 이후 기록 방식

- 계획의 체크박스는 실제 작업·테스트 증거가 있을 때 갱신한다.
- 이 문서에 마지막 완료 작업, 다음 작업, 실제 검증 명령과 결과, 알려진 제약을 짧게 유지한다.
- 미래 AI가 사용할 설명은 저장소 상대 경로로 작성한다. 이전 대화나 개인 컴퓨터의 다른 프로젝트에 의존하지 않는다.
- 커밋 작성자 설정은 저장소 로컬 설정을 따른다. Git 작성자 이메일과 제품의 이메일 표시명 정책은 별개다.

## 다른 AI에게 전달할 요청 예시

```text
이 저장소의 AGENTS.md와 docs/AI_HANDOFF.md, docs/BATTLE_PLAN.md를 읽어줘.
feat/local-practice-battle 브랜치의 미커밋 PR 00을 테스트로 검증하고,
PR 01 → 02 → 03 → 03A(로컬 연습전)를 TDD로 진행해줘.
월 0원 조건과 로그인 화면 없는 초대코드 + 이메일 표시명 방식을 유지해줘.
```

이 예시는 다음 구현 요청을 작성하기 위한 것으로, 구현이나 배포를 실행하라는 지시가 아니다.
