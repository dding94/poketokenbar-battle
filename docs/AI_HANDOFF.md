# 다음 AI를 위한 작업 인계

최종 갱신: 2026-10-29. **PR 00 코드는 작성했지만 테스트를 실행하지 못했고, 배틀 기능은 아직 구현하지 않았다.**

## 진행 중인 작업 (2026-10-29 기준, PR 00 원격 검증 준비)

- 브랜치: `feat/local-practice-battle` (`main` 5e9af78에서 분기). 인수 시 모든 변경은 미커밋이었다. 사용자가 GitHub Actions 검증과 필요한 커밋·푸시를 승인했으며, 문서·PR 00·프로브를 나누어 올리는 중이다. 설치·배포·공개 전환은 하지 않았다.
- 문서 개정: `docs/BATTLE_PLAN.md`(새 구조, PR 00~13 + PR 03A, 부록 A), `docs/AI_HANDOFF.md`, `AGENTS.md`, `README.md`(고지), `CLAUDE.md`(첫 단락 경고 한 줄).
- PR 00 코드(작성 완료, 테스트 미실행):
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
- `engine/`: `@pkmn/sim` 0.10.12·esbuild 0.28.2 고정 `package.json`·`package-lock.json`, 사전 실측 프로토타입 `engine/probe/`, `engine/README.md`. **PR 01의 정식 어댑터·번들·테스트는 아직 없다.** (중단한 작업이 남긴 것은 설치뿐이었다.)

검증 상태:

- `swift build`(debug): 성공 (Command Line Tools, Swift 6.3.2).
- `swift test`: **실행 불가.** 이 맥에는 Xcode가 없고 Command Line Tools만 있어 `no such module 'XCTest'`로 컴파일이 멈춘다. 새 가드 테스트와 기존 전체 테스트 모두 미실행이며, 결함 주입 확인도 하지 않았다.
- `scripts/*.sh`: `bash -n` 문법 확인만 했다. `build-app.sh`는 실행하지 않았다.
- 엔진 프로브: `cd engine && npm run probe` — 5세대 2,500판 Node·JavaScriptCore 불일치 0, 재생·상태 왕복 실패 0(`--keep-names` 빌드). 9세대 규칙은 미검증.

### PR 00 검증 재시도 (2026-10-29)

- `git status --short --branch`·`git remote -v` (각 종료 코드 0): `feat/local-practice-battle`의 기존 미커밋 변경과 `origin=https://github.com/dding94/poketokenbar-battle.git`를 확인했다. 기존 코드·프로브 변경은 보존했다.
- `xcode-select -p` (0): `/Library/Developer/CommandLineTools`. `swift --version` (0): Apple Swift 6.3.2, arm64. `xcodebuild -version` (1): 활성 개발 경로가 Command Line Tools라 Xcode 명령을 사용할 수 없다.
- 실제 대상 테스트 명령: `PTB_STATE_DIR="$(mktemp -d /private/tmp/ptb-pr00-test.XXXXXX)" swift test --filter "AppIdentityTests|SupportMailTests|UpdateCheckerTests"`.
  - 첫 시도는 실행 환경의 기본 Swift 모듈 캐시 쓰기 제한으로 종료 코드 1이었다. 캐시 접근을 허용해 같은 명령을 다시 실행했다.
  - 재시도도 종료 코드 **1**: 테스트 모듈 컴파일에서 **`no such module 'XCTest'`**. 테스트 실행 **0건**, 테스트 성공·실패·skip 집계는 생성되지 않았다. 테스트 통과나 기능 RED 증거로 보지 않는다.
- XCTest 불가 시 멈추라는 사용자 지시에 따라 `./scripts/test-gate.sh`, 식별값 결함 주입, 앱 번들 생성·설치·실행 검증은 미실행이다. PR 01·02·03·03A에는 착수하지 않았고 계획 체크박스도 바꾸지 않았다. 원본 앱·실제 세이브에는 접근하지 않았다.
- **선택 완료:** 사용자가 무료 분량이 충분하면 Actions로 검증하도록 승인했다(필요한 커밋·푸시 포함). 필요 시 공개 전환도 허용했으나, 2026-10-29 로그인한 GitHub Billing 화면에서 이번 검증에 충분한 무료 잔여량을 확인해 private를 유지한다. 계정별 과금 세부 정보는 대화에서만 보고한다.
- CI 준비: 기존 `ci.yml`의 수동 실행만 유지하고 macOS 15 작업은 10분, Linux 비밀값 검사는 3분으로 제한했다. `PTB_STATE_DIR`는 러너 임시 폴더다. 대상 테스트 → 전체 커버리지 게이트 → 원본 bundle ID 결함 주입(실제 XCTest assertion 실패 확인) → 원복 후 재검증 순서다. 결과 이미지는 1일만 보관한다. 원격 실행 결과는 아직 없다.

이어서 할 일:

1. XCTest를 쓸 수 있게 한다: Xcode 설치 후 `xcode-select`로 선택하거나, GitHub Actions `ci.yml`을 수동 실행한다(private 저장소라 무료 분량을 소모한다).
2. `swift test --filter "AppIdentityTests|SupportMailTests|UpdateCheckerTests"` → `./scripts/test-gate.sh`. 값 하나를 원본으로 되돌려 가드가 실패하는지 확인한 뒤 원복한다.
3. `PTB_SKIP_INSTALL=1 PTB_NATIVE_ARCH_ONLY=1 ./scripts/build-app.sh`로 `build/PokeTokenBar Battle.app`을 만든다. Info.plist 번들 ID·실행 파일·LaunchAgent·`codesign -d --entitlements -`를 확인한 뒤 설치하고, 원본 앱이 계속 실행되고 원본 폴더가 바뀌지 않는지와 첫 실행 복사를 확인한다.
4. PR 00을 마무리하고 PR 01 → 02 → 03 → 03A(로컬 연습전) 순서로 진행한다. 사용자가 연습전을 직접 시험한 뒤 public 전환을 정한다.
5. 커밋은 사용자 요청이 있을 때 PR 단위로 나눈다(문서 개정 / PR 00 / engine 프로브).

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

- PR 01의 엔진 어댑터·번들·테스트, `server/`, Cloudflare 리소스·자격 증명·배포 URL.
- 배틀 화면(로컬 연습전 포함)·락스텝 프로토콜·소유권 이전·스타터 지급·그룹 화면.
- 이 포크의 Swift 테스트 실행, 앱 번들 빌드·설치·실행 확인.
- PR 00의 테스트 검증(코드는 위 "진행 중인 작업" 참고).
- 저장소 public 전환과 앱 안 고지(README 고지와 포크 고유 커밋의 비밀값 패턴 점검은 2026-10-29에 완료).
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
