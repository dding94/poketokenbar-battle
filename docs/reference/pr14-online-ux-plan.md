---
summary: "PR 14 실사용 피드백 개선의 사용자 결정, 실행 순서, 작업 지시서."
read_when:
  - PR 14(온라인 흐름, 알림, 대전감, 앱 이름)를 시작하거나 이어갈 때
---

# PR 14 — 실사용 피드백 개선 계획 (온라인 흐름·알림·대전감·이름)

- 작성일: 2026-11-05
- 상태(2026-11-05 갱신): **구현 완료, 공개 전.** T24(수동 시험표)와 T25(보류)는 공개 뒤 실전 확인으로 넘겼다. 공개 버전 제안은 2.7.0이며 아직 공개하지 않았다. 남은 일은 AI_HANDOFF 최상단을 따른다.
- 근거: 사용자의 첫 실사용 피드백, 전문가 6명과 라우터의 읽기 전용 검토(실행 없는 정적 추적), Opus 에스컬레이션 2건, 운영자의 코드 대조.
- 줄 번호는 2026-11-05 작업 트리 기준이다. 코드가 바뀌었으면 함수 이름으로 다시 찾는다.

## 1. 사용자 결정 (2026-11-05)

| ID | 결정 | 영향 |
|---|---|---|
| D1 | 서버 주소를 앱에 내장한다. 저장소에는 커밋하지 않고 빌드할 때 넣는다. 값이 없는 빌드는 수동 입력을 유지한다 | T08, T09 |
| D8 | 고정 서버는 새 운영 Worker `ptb-battle-league`다. 주소를 바꾸면 접속키가 끊기므로 가입자가 거의 없는 지금 옮긴다 | T26, T08 |
| D2 | 가입은 초대코드 + 앱 안 방장 패널이다. 신청·승인 방식은 이번 범위가 아니다 | T10 |
| D3 | 메뉴바 표식 + macOS 알림 + 입력·대기·배틀 구간의 팝오버 자동 고정 | T03, T04, T05 |
| D5 | 앱 표시 이름은 PokeTokenBattle이다(사용자 최종 선택, 상표·원본 혼동 위험을 알고 선택). 내부 식별자는 유지한다. 비공식 고지를 두고 공식 캐릭터 없는 아이콘을 쓴다. TokenArena는 같은 분야의 제품(GitHub, npm)이 이미 써서 뺐다 | T22, T23 |
| D4 | 수락·최종 확인·전투 준비 3단계를 유지하고 안내부터 강화한다. 자동 진행은 보류한다 | T06, T20 |
| D6 | 기술 연출은 3초 안팎으로 짧게, 건너뛸 수 있게, 연출 중에도 선택을 허용한다. 서버 시계는 바꾸지 않는다 | T13, T14, T18 |
| D7 | 상대가 선택을 마쳤다는 사실만 표시한다. 내용은 공개하지 않는다 | T16 |
| - | 효과음은 넣지 않는다 | - |

운영자가 대조해 확인한 사실:

- 주소에 들어 있는 계정 이름은 공개 저장소의 커밋 작성자 이메일에 이미 있다. 앱에 주소를 넣어도 새로 드러나는 개인 정보는 없다.
- `server/wrangler.jsonc`에 account_id가 없고, 운영 이름 `ptb-battle-league`는 이미 설정돼 있다.
- 공개 저장소 규칙은 그대로다. 실제 주소, 계정 ID, 하위 도메인, 같은 계정의 다른 서비스 이름, 비밀값을 문서와 코드에 넣지 않는다.

### 이름·이미지 변경에 대한 답 (법률 자문이 아님)

이름을 바꾸고 이미지를 교체해서 쓰는 것은 MIT 라이선스상 허용됩니다. 다만 법률 자문이 아니라 저장소 파일을 읽은 실무 판단입니다.

반드시 유지할 것: LICENSE의 chattymin 저작권 고지와 허가 문구 원문은 모든 사본에 그대로 두어야 하고, 아래에 포크 기여자 줄을 추가하는 것은 괜찮습니다. 앱 안의 '원본 기반' 링크와 README의 출처 고지도 지우지 마세요.

MIT가 주지 않는 것: 이름은 라이선스와 별개의 상표 문제입니다. 'Poke'가 들어간 이름은 The Pokémon Company 상표와 원본 PokeTokenBar 양쪽에 혼동될 수 있습니다. PokeTokenBattle도 원본과 구분하는 효과가 거의 없습니다. 팬 프로젝트 이름에 대한 공식 정책 원문은 확인하지 못했고 서면 허가 없이는 안전하다고 확정할 수 없습니다. 사내·지인 한정 배포, README 비공식 고지, 몬스터볼·공식 캐릭터를 쓰지 않는 아이콘, 식별자와 이름의 분리를 지키면 실무 위험은 낮다고 판단합니다. 공개 확산을 계획한다면 Poke가 없는 이름을 권합니다.

이미지: 현재 아이콘은 몬스터볼이 아니라 원본 작성자가 만든 추상 '네온 알'이라 사용자의 느낌대로 원본과 닮아 있습니다. 저작권 문제는 아니지만 교체를 권하며(T23), 새 아이콘은 직접 만들거나 권리가 분명한 소재만 쓰세요. 더 큰 문제는 README와 assets에 실제 포켓몬 스프라이트가 담긴 스크린샷이 있다는 점입니다. 2장만 직접 확인했고(screenshot-home.png는 스프라이트 있음, screenshot-online-rematch.png는 합성), MIT는 그 이미지들의 권리를 주지 않습니다. 런타임 스프라이트는 PokeAPI에서 가져와 번들에는 없습니다.

식별자는 바꾸지 마세요: 번들 ID, 상태 폴더, Keychain, 로그인 에이전트, Worker 이름(ptb-battle-league 계열)은 바꾸면 2.6.0 테스터의 세이브, 접속키, 로그인 항목이 끊기고 서버 데이터도 새로 시작합니다. 표시 이름만 바꾸는 것이 안전합니다(T22). UI 카피에 공식 게임 화면의 구성(HP바 배치, 메뉴 박스, 폰트, 효과음)을 일부러 닮게 만들지 않는 것도 권합니다.

## 2. 피드백과 작업의 대응

| 피드백 | 작업 |
|---|---|
| 1. 복붙 중 팝오버가 닫힘 | T00(입력 유지), T05(고정) |
| 2. 서버 고정, 관리자 운영 | T26, T08, T09, T10 |
| 3. 가입부터 대전까지 흐름이 직관적이지 않음 | T01, T06, T07, T09, T11 |
| 3-1. 신청·수락이 됐는지 모름 | T06, T07, T01 |
| 3-2. 받는 쪽이 팝오버를 안 보면 모름 | T02, T03, T04, T12 |
| 3-3. 최종 확인 대기 중 팝오버가 닫히면 확인 불가 | T02, T03, T04, T05 |
| 4. 대전이 밋밋함 | T13~T19 |
| 5. 이름·이미지 | T22, T23 |
| 발견: 서버 오류가 한 문장으로 뭉개짐 | T01 |
| 발견: 복구코드를 복사할 수 없고 앱을 끄면 사라짐 | T11 |
| 발견: 슬립 복귀 뒤 최대 10분 먹통, 모르는 메시지에 연결이 영구 종료 | T12 |
| 발견: 재실행하면 진행 중 대전으로 돌아가지 못함 | T05 |
| 발견: 방장 화면이 없고 앱이 방장이 될 경로도 없음 | T26, T10 |
| 발견: 동료 맥의 Gatekeeper 차단 안내 부족 | T24 |
| 발견: 공개 문서에 실제 포켓몬 스프라이트 스크린샷 | T23 |

## 3. 실행 순서

| 순서 | 작업 | 메모 |
|---|---|---|
| 라운드 0 | T00 | 기준선. 끝나기 전에는 다른 작업을 시작하지 않는다. |
| 라운드 1 | T01, T02, T08, T13, T26 | T01(handle)과 T13(process·publish)은 Session.swift의 다른 구간을 고친다. T01을 먼저 통합하고 T13을 그 위로 rebase한다. T26은 사용자 참여가 필요하니 다른 작업을 기다리게 하지 않는다. |
| 라운드 2 | T03, T06, T14, T22 | T22는 build-app.sh를 고치므로 T08 다음이다. |
| 라운드 3 | T04, T07, T15, T23 | T04가 끝나면 **리뷰 A**(인지·흐름 코어, opus high). |
| 라운드 4 | T05, T09, T16 | T05(방 선택)와 T09(가입)는 Session.swift의 다른 구간을 고친다. T16은 서버를 앱보다 먼저 배포한다. 끝나면 **시험 빌드 1**: 사용자가 가입부터 대전까지 흐름을 직접 확인한다. |
| 라운드 5 | T10, T12, T17 | T10과 T17은 Session.swift의 다른 구간을 고친다. T12는 PokeTokenBarApp.swift에 복귀 신호를 연결한다. 끝나면 **리뷰 B**(운영·연결, opus high). |
| 라운드 6 | T11, T18 |  |
| 라운드 7 | T19, T21 | 끝나면 **리뷰 C**(배틀 전체, opus high). |
| 라운드 8 | T24 | 두 맥 시험과 설치 안내. 결과에 따라 T25를 켠다. 릴리스는 사용자 요청이 있을 때만 한다. |
| 보류 | T20, T25 | T20은 D4 결정으로 보류. T25는 T24 (f) 실패 때만 진행. |

한 라운드의 작업은 별도 worktree에서 병렬로 진행하고, 표에 적은 순서대로 통합한다. `OnlineBattleSession.swift`와 `OnlineBattleLocalization.swift`는 여러 작업이 고치므로 통합할 때마다 rebase한다.

## 4. 작업 에이전트 공통 규칙

- 시작 전에 `AGENTS.md`, 이 문서의 §1과 §4, 자기 작업 항목을 읽는다. 다른 작업 항목은 읽지 않아도 된다.
- 브랜치는 `feat/online-ux-feedback`에서 worktree로 나눈다. main에 직접 커밋하지 않고 푸시하지 않는다. 통합과 푸시는 운영자가 한다.
- 기능 변경은 RED(단언 실패) → GREEN → REFACTOR로 커밋을 나눈다. 새 가드는 결함을 일부러 넣어 실패하는지 한 번 확인하고, 가드에 실제로 도달하는 전제 조건을 갖춘다.
- 커밋은 영어 Conventional Commits이며 co-author trailer를 넣지 않는다.
- 로컬 Swift 테스트: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer PTB_STATE_DIR=<임시 폴더> swift test --filter …`. `xcode-select`는 바꾸지 않는다. 통과 기준은 CI(macOS 15, Swift 6.1)다. 로컬 Swift 6.4가 통과시켜도 CI의 6.1은 막을 수 있고, 관련 테스트만 고르면 소스 검사 테스트를 놓치므로 필터에 항상 `LocalizedUILiteralTests`를 넣는다(2026-11-05 CI 실패).
- 테스트 판정: XCTest의 `N failures (0 unexpected)`는 예외가 없다는 뜻일 뿐 **단언 실패가 N건 있다는 뜻**이다. `Test Suite ... failed`가 보이면 실패다. 파이프로 넘긴 명령의 종료 코드는 `swift test`의 것이 아닐 수 있으니 `set -o pipefail`이나 파일 저장으로 확인한다. 실패를 추정으로 넘기지 않는다.
- 결함 주입은 작업당 다시 빌드 약 10회까지만 한다. 함께 넣을 수 있는 결함은 묶는다.
- CI는 작업이 모두 끝난 뒤 한 번만 돌린다(2026-11-05 사용자 결정, 한 번에 약 15분). 통합할 때는 로컬 테스트로 판단하고 푸시하지 않는다. Swift 6.1과 macOS 15에서 나오는 문제는 마지막 CI에서 한꺼번에 고친다. 머지와 릴리스 전 CI 통과는 그대로 필수다.
- 합성 클릭: `window.sendEvent`로 기본 스타일 버튼을 누르면 CI의 macOS 15에서 테스트가 끝없이 멈출 수 있다. NSButton이면 `performClick`을 쓴다(defect-log). 필터에 `SwiftUIIsolationTests`도 항상 넣는다.
- 서버 테스트: `npm ci --prefix server`, `npm run typecheck --prefix server`, `npm test --prefix server`.
- 실제 세이브와 `/Applications/PokeTokenBar.app`을 건드리지 않는다. 설치, 배포, 릴리스, Homebrew tap 변경, 비밀값 입력은 사용자 승인 뒤에만 한다.
- 화면은 메뉴바 팝오버 안에서만 진행한다. 공식 게임 화면을 닮게 만들지 않고 닌텐도 자산을 저장소에 넣지 않는다.
- 화면이 바뀌면 렌더링 이미지를 남긴다. PR에는 이미지가 필수다(`.agents/skills/prepare-pr/SKILL.md`).
- 결함을 찾으면 `CLAUDE.md`의 결함 대응 프로토콜을 따르고 `docs/reference/defect-log.md`에 남긴다.
- 실제 명령, 종료 코드, 테스트 수, 실패와 skip, 미검증 범위를 보고한다. 0건이나 미실행을 통과로 보고하지 않는다.

모델 배치: 작업 항목의 값을 쓴다. 같은 작업이 RED→GREEN에서 두 번 막히거나 리뷰에서 Major가 나오면 Opus high로 올린다. 리뷰는 작업마다 하지 않고 §3의 리뷰 A, B, C만 Opus high로 한다. 긴 작업은 기록이 길어지면 API 시간 초과로 멈출 수 있으니, 후속 수정은 새 에이전트에게 맡긴다.

작업 에이전트에게 주는 지시문:

```text
너는 PokeTokenBattle(저장소 poketokenbar-battle) PR 14의 작업 에이전트다. 작업: {작업 ID}.
이 worktree에서 `git reset --hard {통합 브랜치 끝 커밋}`으로 시작한다.
docs/reference/pr14-online-ux-plan.md의 §1, §4와 {작업 ID} 항목, AGENTS.md를 읽고 수용 기준을 모두 충족해.
RED 테스트를 먼저 커밋하고, 결함 주입으로 테스트가 잡는지 확인해. 푸시하지 마.
보고: 커밋, 실행한 명령과 종료 코드, 테스트 수, 결함 주입 결과, 미검증 범위.
```

## 5. 작업 상세

### T00 — 기준선 정리: 미커밋 수정 보존·검증·결정 기록

- 우선순위 P0 · 크기 S · 모델 sonnet medium
- 피드백: 1
- 선행: 없음
- 목표: main 작업 트리에 커밋되지 않은 입력 초안 유지·붙여넣기 수정과 인계 문서 변경을 잃지 않고 작업 브랜치의 기준선으로 만든다. 이번 결정을 문서에 남겨 모든 작업 에이전트가 같은 전제에서 시작하게 한다.
- 파일: `Sources/PokeTokenBar/Core/OnlineBattle*.swift`, `Sources/PokeTokenBar/UI/OnlineBattleScreen.swift`, `Tests/PokeTokenBarTests/OnlineBattle*Tests.swift`, `AGENTS.md`, `docs/AI_HANDOFF.md`, `docs/BATTLE_PLAN.md`

수용 기준:

- main에서 브랜치 feat/online-ux-feedback을 만들고 미커밋 변경을 그대로 옮긴다. main에 직접 커밋하지 않는다
- 변경분을 읽고 관련 테스트(OnlineBattleSetupTests, OnlineBattleSessionTests, OnlineBattleScreenRenderingTests)를 실행해 결과를 기록한 뒤 코드와 문서를 나누어 커밋한다
- AGENTS.md의 바꾸지 않을 제품 결정에 이 문서 §1의 결정을 추가한다
- 이 문서를 함께 커밋한다

먼저 쓸 테스트: 신규 동작이 없는 정리 작업이라 RED는 없다. 기존 테스트 통과를 기록한다.

### T26 — 운영 Worker 배포와 첫 방장 계정 연결

- 우선순위 P0 · 크기 S · 모델 sonnet medium
- 피드백: 2, new
- 선행: T00
- 목표: 앱에 내장할 운영 서버를 만들고 사용자의 앱을 그 그룹의 방장으로 연결한다. 지금은 앱에 그룹을 만드는 경로가 없고, 로컬 스크립트는 그룹을 만든 뒤 방장 키를 앱에 넘기지 않아 사용자의 앱은 일반 멤버다. 이 단계가 없으면 T10의 패널이 보이지 않는다.
- 파일: `server/scripts/bootstrap-group.mjs`, `server/README.md`, `server/test/measure.test.ts`

수용 기준:

- server/scripts/bootstrap-group.mjs가 주소를 인자로, 운영자 비밀값을 환경변수로만 받아 그룹을 만들고 방장 복구코드를 사용자 터미널에만 한 번 출력한다. 접속키는 출력하지 않고 파일에 쓰지 않는다
- 배포 전에 wrangler 로그인 상태, 계정의 현재 무료 사용량, dry-run 결과를 사용자에게 보여 주고 승인받는다. 대상은 wrangler.jsonc 최상위의 ptb-battle-league다
- 비밀값은 사용자가 직접 넣는다: 개발 환경과 같은 방식으로 CODE_PEPPER는 표준 입력으로 만들고, OPERATOR_SECRET은 키체인 항목 ptb-battle-prod-operator에 저장한다. 작업 에이전트는 값을 읽거나 출력하지 않는다
- 사용자가 앱의 복구코드 입력으로 방장 계정을 연결하고, /v1/me의 role이 host임을 앱 화면 또는 응답으로 확인한다
- 운영 주소는 커밋하지 않는 로컬 빌드 입력(T08)에만 둔다
- server/README.md에 절차를 남기되 실제 주소와 계정 값은 쓰지 않는다

먼저 쓸 테스트: 스크립트의 인자 처리와 출력 필터를 단위 테스트로 고정한다: 출력에 접속키와 운영자 비밀값이 없고, 주소가 없으면 실패한다. 실제 배포는 수동 확인이다.

### T01 — 서버 오류 코드별 한국어 문구 매핑 (가입 실패 포함)

- 우선순위 P0 · 크기 M · 모델 sonnet high
- 피드백: 3, 3-1, 3-4
- 선행: 없음
- 목표: 가입·신청 실패 시 원인과 다음 행동이 서로 다른 문구로 보인다. 지금은 모든 서버 오류가 '온라인 정보를 확인하지 못했어요' 한 문장으로 뭉개진다.
- 파일: `Sources/PokeTokenBar/Core/OnlineBattleSession.swift`, `Sources/PokeTokenBar/Core/OnlineBattleLocalization.swift`, `Sources/PokeTokenBar/Core/OnlineBattleAPI.swift`, `Tests/PokeTokenBarTests/OnlineBattleSessionTests.swift`

수용 기준:

- handle(_:)가 OnlineBattleServerError를 분기하고 invite_revoked, invite_expired, invite_used_up, too_many_attempts(retryAfter 초 포함), display_email_taken 5종이 각각 다른 문구(원인+다음 행동)로 표시된다
- 서버가 내려주는지 확인되지 않은 코드(group_full, 버전 불일치)는 기존 일반 문구로 남기고, 코드가 확인되면 한 줄 추가로 확장할 수 있는 구조다
- 상대가 이미 취소·만료한 신청에 수락을 눌러도 '출전 정보가 바뀌었어요'로 오안내하지 않고 '상대가 신청을 취소했어요/시간이 지났어요'로 나온다
- 하드코딩된 한국어 오류 문자열이 L.online(ko,en) 경로로 옮겨진다
- 성공한 사용자 액션 시작 시 이전 오류 notice가 비워진다

먼저 쓸 테스트: OnlineBattleSessionTests에서 mock API가 invite_used_up, invite_expired, display_email_taken, too_many_attempts(retryAfter=30)를 던질 때 presentation.notice가 서로 다르고 일반 문구와도 다르다고 단언한다. 지금은 모두 같은 문구라 실패한다.

### T02 — OnlineAttention 단일 이벤트 정의 (배지·알림·배너·홈 부제가 공유)

- 우선순위 P0 · 크기 M · 모델 opus high
- 피드백: 3-1, 3-2, 3-3
- 선행: 없음
- 목표: 사용자 행동이 필요한 상태 7종(incomingChallenge, challengeAccepted, finalConfirmed, myTurn, matchEnded, rematchRequested, resultReady)을 한 곳에서 계산해, 배지·알림·앱 내 배너·홈 부제가 같은 값에서 문구를 만든다.
- 파일: `Sources/PokeTokenBar/Core/OnlineBattleAttention.swift`, `Sources/PokeTokenBar/Core/OnlineBattleAttentionText.swift`, `Tests/PokeTokenBarTests/OnlineBattleAttentionTests.swift`

수용 기준:

- OnlineBattlePresentation을 입력으로 받아 현재 가장 높은 우선순위 이벤트 하나를 돌려주는 순수 함수가 있다(우선순위 myTurn > challengeAccepted > incomingChallenge > 나머지)
- 이벤트 식별 키가 battleId+단계라 같은 (상대, 이벤트)는 한 번만 발생으로 취급되고, 상태가 풀리면 해제된다
- 각 이벤트의 알림 문구·배지 툴팁·홈 부제 문구가 상대 닉네임을 포함해 정의된다(예: '○○님이 대결을 신청했어요', 'myTurn은 30초 안에 기술을 고르세요')
- 알림 대상은 앞의 4종, matchEnded와 resultReady는 앱 내 표시 전용임이 타입으로 드러난다
- Attention 계산은 presentation과 이전 표시 기록(seen)을 입력으로 받는 순수 함수이고, 저장과 발송은 T03·T04가 맡는다

검토로 확정한 변경(위 내용보다 우선):

- OnlineAttention을 푸시 이벤트가 아니라 publish 시점의 views 상태 비교로 정의한다. hello 뒤 refresh, 재실행, 복귀 대조가 모두 같은 경로로 감지되게 하기 위해서다. 재실행 시 중복 알림을 막도록 마지막 알린 battleId와 revision을 저장한다.
- 결과 이벤트의 기준을 원시 room.state가 아니라 publish의 표시 게이트 이후 값으로 정한다. 팝오버를 보고 있는 사용자에게 마지막 연출 전에 승패가 먼저 노출되지 않게 한다.

먼저 쓸 테스트: OnlineBattleAttentionTests에서 수신 신청 1건 presentation은 incomingChallenge, 내 차례가 겹치면 myTurn, 아무 일 없으면 nil, 같은 battleId·단계를 두 번 평가하면 새 이벤트로 취급하지 않는다고 단언한다. 타입이 없어 실패한다.

### T03 — 메뉴바 온라인 표식 + 홈 온라인 행 상태 부제

- 우선순위 P0 · 크기 M · 모델 sonnet high
- 피드백: 3-2, 3-3
- 선행: T02
- 목표: 팝오버를 열지 않아도 메뉴바에서 온라인 행동 필요 상태를 알 수 있고, 홈의 온라인 행이 현재 상태를 한 줄로 알려준다.
- 파일: `Sources/PokeTokenBar/PokeTokenBarApp.swift`, `Sources/PokeTokenBar/UI/PopoverView.swift`, `Sources/PokeTokenBar/Core/OnlineBattleAttentionText.swift`, `Tests/PokeTokenBarTests/OnlineBattleAttentionTests.swift`

수용 기준:

- 행동 필요 이벤트가 있으면 메뉴바 제목 끝에 온라인 전용 표식(점 또는 숫자)과 툴팁 한 줄이 붙고, 이벤트가 사라지면 제거된다
- 연습전 배지(practice.statusBadge)와 동시에 있어도 서로 가리지 않는다
- 홈 온라인 행에 부제가 표시된다(가입 전 '동료와 겨루기 · 아직 가입 안 함', 접속 중 '받은 신청 1건', 재연결 중 '다시 연결하는 중')
- myTurn은 남은 시간이 10초 이하일 때 알림 없이 표식 색만 바꾼다

검토로 확정한 변경(위 내용보다 우선):

- 메뉴바 표식의 대상에 RUNNING과 REPORTED 방을 포함한다. 재실행 뒤 팝오버가 닫혀 있어도 진행 중 경기를 알 수 있게 한다.

먼저 쓸 테스트: 배지 문자열 생성 함수에 대한 단위 테스트(행동 필요 이벤트별 표식 문자열)를 먼저 작성한다. 화면 표시는 두 맥에서 팝오버를 닫은 채 상대가 신청을 보내 메뉴바 표식이 뜨는지 수동 확인한다.

### T04 — macOS 알림 발송 + 알림 클릭 라우팅 + 권한 요청 시점

- 우선순위 P0 · 크기 M · 모델 sonnet high
- 피드백: 3-2, 3-3, new
- 선행: T02, T03
- 목표: 팝오버가 닫혀 있을 때 신청 수신, 수락됨, 최종 확인 필요, 내 차례 4종을 한 번씩 알림으로 알리고, 알림을 누르면 해당 배틀 화면이 바로 열린다.
- 파일: `Sources/PokeTokenBar/Core/OnlineAttentionNotifier.swift`, `Sources/PokeTokenBar/PokeTokenBarApp.swift`, `Sources/PokeTokenBar/Core/UsageStore.swift`, `Tests/PokeTokenBarTests/OnlineAttentionNotifierTests.swift`

수용 기준:

- 재대결 신청도 알림 대상이다(운영자 결정, 2026-11-05: 상대의 응답이 필요한 상태를 놓치면 안 된다). T02의 4종 제한과 그 테스트를 함께 고친다
- incomingChallenge, challengeAccepted, finalConfirmed, myTurn에서만 알림이 가고 identifier는 battleId+단계로 고정되어 중복이 없다
- 팝오버가 열려 있으면 알림을 보내지 않고, 이벤트가 해소되면 대기 중 알림을 철회한다
- AppDelegate에 UNUserNotificationCenterDelegate가 있고 didReceive에서 openPopover 후 해당 배틀 화면으로 라우팅한다
- myTurn 알림은 연출 완료를 기다리지 않고 라운드 해결 즉시 보내며 문구에 남은 시간이 들어간다
- 권한 요청은 닉네임 입력 완료 직후 한 번 하되 먼저 이유 한 줄을 보여준다. 거부 상태를 확인(getNotificationSettings)해 설정 화면에 안내를 띄운다. 알림만이 유일한 수단이 아니고 T03의 앱 내 표시가 기본이다
- 번들 앱이 아니면 건너뛴다(기존 가드 유지)

검토로 확정한 변경(위 내용보다 우선):

- 알림 권한이 거부된 상태면 팝오버 온라인 행에 안내를 표시한다. 메뉴바 표식은 전체 화면에서 가려질 수 있어 완전한 대체로 간주하지 않는다.
- 화면을 보고 있는 동안 표시 hold 중에는 결과 알림을 내지 않는다. 안 보이는 상태면 hold가 없으므로 기존대로 즉시 발송한다.

먼저 쓸 테스트: notifier를 UNUserNotificationCenter 프로토콜 목으로 주입해 같은 이벤트를 두 번 넣으면 add가 한 번만 호출되고, 팝오버 열림 상태에서는 0번 호출된다고 단언한다. 실제 알림 배너와 클릭 라우팅은 설치본으로 두 맥 수동 확인한다(swift run에서는 불가).

### T05 — 팝오버 단계별 고정(.applicationDefined)과 재오픈 시 온라인 화면 복귀

- 우선순위 P0 · 크기 M · 모델 sonnet high
- 피드백: 1, 3-3
- 선행: T03, T04
- 목표: 서버·초대코드를 붙여넣거나 응답을 기다리는 동안 다른 앱을 눌러도 팝오버가 닫히지 않고, 닫힌 뒤 다시 열면 처리할 온라인 화면으로 바로 들어간다.
- 파일: `Sources/PokeTokenBar/PokeTokenBarApp.swift`, `Sources/PokeTokenBar/UI/PopoverView.swift`, `Sources/PokeTokenBar/Core/OnlineBattleAttention.swift`, `Tests/PokeTokenBarTests/OnlineBattleAttentionTests.swift`, `Sources/PokeTokenBar/Core/OnlineBattleSession.swift`

수용 기준:

- 고정 구간은 가입/설정 입력, 응답 대기, 최종 확인 대기, prepare·arena·verifying이고 로비 목록·결과·홈은 .transient 그대로다. 구간 판정은 Attention 파일의 순수 함수 하나로 둔다
- 고정 중에는 전역 클릭 모니터(앱 밖 클릭 닫기)를 끄고, 팝오버 헤더에 '고정됨' 표시와 닫기 버튼을 두며 Esc로도 닫힌다
- 대기가 끝나거나 결과가 오면 자동으로 .transient로 돌아간다
- showPopover가 처리할 온라인 이벤트가 있으면 navigation.reset() 후 홈이 아니라 해당 온라인 화면으로 진입한다
- applicationShouldHandleReopen도 같은 규칙으로 팝오버를 연다
- 사용자가 이미 진행한 툴바 내림 수정이 있으면 먼저 git diff로 확인해 그 변경과 중복·충돌하지 않게 반영한다
- 고정은 팝오버가 열려 있는 동안에만 적용한다. 메뉴바 아이콘을 다시 눌러도 닫히고, 사용자가 직접 닫으면 자동으로 다시 열지 않는다
- 응답 대기는 최대 24시간까지 길어질 수 있으므로, 고정이 작업을 방해하는지 T24에서 반드시 확인하고 결과를 기록한다

검토로 확정한 변경(위 내용보다 우선):

- 재실행 복귀 범위를 추가한다. 팝오버를 열 때 presentation.phase가 arena나 verifying이면 nav.showingOnlineBattle=true로 라우팅한다(PopoverView.swift:46, :200). OnlineBattleSession.swift:618의 방 선택에서 RUNNING과 REPORTED를 최신 PENDING보다 우선한다. 닫힌 상태에서 팝오버를 자동으로 열지는 않는다.
- PopoverView.swift:126의 OnlineBattleScreen에 onAppear/onDisappear로 온라인 화면 표시 액션(onlineScreenVisible)을 추가한다. T13이 이 값을 쓰므로 이 부분만 T13과 함께 먼저 넣거나 T13에 포함한다.

먼저 쓸 테스트: 고정 구간 판정 함수에 대해 단계별 입력(가입 중, 응답 대기, 최종 확인, arena는 true / 로비, 결과, 홈은 false)을 단언하는 단위 테스트를 먼저 쓴다. 팝오버 동작은 수동 확인: 초대코드를 다른 앱에서 복사하는 동안 팝오버가 유지되는지, 닫기 버튼으로 닫히는지.

### T06 — 방 진행 단계 표시 + 이름 포함 안내 + 내 준비 상태 + 비활성 사유

- 우선순위 P0 · 크기 M · 모델 sonnet high
- 피드백: 3, 3-1, 3-3, 3-4
- 선행: T01, T02
- 목표: 신청 후 방 화면이 지금 몇 단계인지, 누구 차례인지, 내가 누른 것이 접수됐는지, 버튼이 왜 눌리지 않는지를 항상 말해준다.
- 파일: `Sources/PokeTokenBar/UI/OnlineBattleScreenLobby.swift`, `Sources/PokeTokenBar/Core/OnlineBattlePresentation.swift`, `Sources/PokeTokenBar/Core/OnlineBattleSession.swift`, `Sources/PokeTokenBar/Core/OnlineBattleLocalization.swift`, `Tests/PokeTokenBarTests/OnlineBattlePresentationTests.swift`

수용 기준:

- 방 화면 상단에 4단계(신청, 수락, 최종 확인, 전투 준비) 진행 표시와 현재 단계 주체가 이름과 함께 나온다('○○님의 수락을 기다려요', '내 차례: 최종 확인을 눌러 주세요')
- 신청자 대기 화면에 상대 이름, '신청을 보냈어요', 신청 후 경과 시간이 보인다
- presentation에 localReady(내 준비 완료)가 노출되고 준비를 누르면 '내 준비 완료 · 상대 대기 중'으로 바뀌며 버튼이 비활성화된다
- '정식전 신청' 버튼 아래에 비활성 사유 한 줄이 나온다('상대를 선택하세요', '출전 포켓몬을 고르세요', '기절한 포켓몬은 회복이 필요해요')
- 전투 준비 버튼은 소켓 미연결 시 '서버에 연결하는 중…'을 보여준다
- 오프라인 상대를 선택하면 '상대가 앱을 열 때 알려져요' 경고가 붙는다

먼저 쓸 테스트: OnlineBattlePresentationTests에서 prepared 상태의 세션이 localReady=true를 노출하고, 상대 미선택·출전 포켓몬 없음·기절 각각에 서로 다른 disabledReason을 낸다고 단언한다. 지금은 필드가 없어 컴파일부터 실패한다.

### T07 — 거절·취소·만료 안내 + 확인 대기 화면 + notice 수명

- 우선순위 P0 · 크기 M · 모델 sonnet high
- 피드백: 3-1, 3-3, new
- 선행: T01, T06
- 목표: 신청이 거절·취소·만료되어 로비로 돌아갈 때 이유를 한 번 보여주고, 확인 대기 화면이 멈춘 것처럼 보이지 않게 한다.
- 파일: `Sources/PokeTokenBar/Core/OnlineBattleSession.swift`, `Sources/PokeTokenBar/UI/OnlineBattleScreenLobby.swift`, `Sources/PokeTokenBar/UI/OnlineBattleScreen.swift`, `Sources/PokeTokenBar/Core/OnlineBattleLocalization.swift`, `Tests/PokeTokenBarTests/OnlineBattleSessionTests.swift`

수용 기준:

- declined, cancelled, expired로 phase가 .lobby로 바뀌는 순간 닫을 수 있는 안내가 1회 나온다('○○님이 신청을 거절했어요/취소했어요/시간이 지났어요')
- 대기 방에 남은 시간(24시간 만료 기준)과 '신청 취소' 버튼 위치가 보인다
- 결과 확인 중 화면에 '자동으로 갱신돼요(보통 수 초)' 문구가 있고 새로고침은 보조 수단이 된다
- 오류 notice는 눈에 띄는 배너 형태이고 닫기 또는 다시 시도 동작이 하나 있다
- 앱 내 표시가 기본이며 시스템 알림 권한 거부와 무관하게 동작한다

검토로 확정한 변경(위 내용보다 우선):

- 신청 화면에 만료 시각을 표시한다. 상대가 온라인으로 보여도 슬립일 수 있으므로 '응답을 기다리는 중'으로 안내하고 도달을 약속하지 않는다.

먼저 쓸 테스트: OnlineBattleSessionTests에서 서버 상태가 declined/cancelled/expired로 바뀌면 presentation.notice가 각각 다른 상대 이름 포함 문구로 설정되고 로비 phase로 돌아간다고 단언한다.

### T08 — 서버 주소 빌드 내장 (값이 없으면 수동 입력 유지)

- 우선순위 P0 · 크기 M · 모델 sonnet high
- 피드백: 2
- 선행: 없음
- 목표: 사용자가 서버 주소를 입력·적용하는 단계를 없앤다. 주소는 저장소에 커밋하지 않고 빌드할 때만 넣는다.
- 파일: `scripts/build-app.sh`, `scripts/release-validate.py`, `Sources/PokeTokenBar/Core/OnlineBattleCredentials.swift`, `docs/BATTLE_PLAN.md`, `Tests/PokeTokenBarTests/OnlineBattleCredentialsTests.swift`

수용 기준:

- build-app.sh가 커밋되지 않는 환경변수(예: PTB_BATTLE_SERVER_URL)를 Info.plist 키로 넣고, 앱은 값이 있으면 저장된 serverURL보다 그 값을 우선한다. 값이 없는 빌드(CI 등)는 지금의 수동 입력을 유지한다
- 주입 값은 https origin으로 검증하고, 잘못된 값이면 빌드가 실패한다
- 저장소의 어떤 파일에도 실제 workers.dev 주소가 없다는 점을 release-validate.py가 검사한다
- BATTLE_PLAN.md 1239행의 "저장소·앱 번들에는 실제 주소를 넣지 않는다" 규칙을 새 정책으로 고친다: 저장소에는 넣지 않고, 앱 번들에는 넣는다. 주소는 비밀이 아니며 보호는 초대코드와 시도 제한이 맡는다
- 서명 전에 Info.plist 키가 들어가 codesign --deep --strict 검증이 통과한다
- 접속키의 Keychain 범위가 주소 해시에 묶여 있으므로, 주소가 바뀌면 재가입이 필요하다는 점을 코드 주석이 아니라 문서에 남긴다

먼저 쓸 테스트: OnlineBattleCredentialsTests에서 Bundle 주입 값이 있을 때 설정의 serverURL이 그 값이고 저장된 값을 덮어쓰며, 값이 없을 때는 기존 저장값을 쓴다고 단언한다.

### T09 — 가입 폼 단순화: 닉네임+초대코드, 서버는 '고급'으로

- 우선순위 P0 · 크기 M · 모델 sonnet high
- 피드백: 1, 2, 3
- 선행: T01, T07, T08
- 목표: 첫 화면 입력을 닉네임과 초대코드 두 칸으로 줄이고, 서버 '적용' 별도 단계를 없애며, 붙여넣기가 실패하지 않게 한다.
- 파일: `Sources/PokeTokenBar/UI/OnlineBattleScreen.swift`, `Sources/PokeTokenBar/Core/OnlineBattleSession.swift`, `Sources/PokeTokenBar/Core/OnlineBattleLocalization.swift`, `Tests/PokeTokenBarTests/OnlineBattleSetupTests.swift`

수용 기준:

- 서버가 내장된 빌드에서는 서버 입력란과 적용 버튼이 보이지 않고, 서버 변경이 필요한 경우만 화면 맨 아래 접힌 고급에 있다(기본 접힘)
- 그룹 참여가 서버 적용을 자동으로 먼저 수행해 .serverChanged 때문에 가입이 막히는 상태가 없다
- 초대 정보 붙여넣기가 코드 한 줄과 서버+코드 두 줄(수동 입력 빌드용)을 모두 받고, 줄 수 때문에 실패하지 않는다
- 붙여넣기 실패 시 이유가 구체 문구로 나온다
- 닉네임 최대 길이와 형식이 가입 화면에 안내된다
- 앞서 작업 트리에 있던 입력 초안 유지·붙여넣기 수정(T00에서 커밋)을 먼저 읽고 그 위에 작업한다

먼저 쓸 테스트: OnlineBattleSetupTests에서 서버가 주입된 상태로 초대코드 한 줄만 붙여 넣어도 가입이 활성화되고, 공백·개행이 섞인 입력도 파싱된다고 단언한다. 현재는 두 줄이어야만 성공하고 서버 적용이 선행되어야 해 실패한다.

### T10 — 방장 관리 패널: 초대 발급·회수, 멤버 제거, 재연결 코드

- 우선순위 P0 · 크기 L · 모델 sonnet high
- 피드백: 2, new
- 선행: T09, T26
- 목표: 방장이 앱 안에서 직접 초대를 만들어 보내고 채널을 운영하게 한다. 지금은 관련 API를 호출하는 앱 화면이 없고 스크립트로만 가능하다.
- 파일: `Sources/PokeTokenBar/UI/OnlineBattleHostPanel.swift`, `Sources/PokeTokenBar/UI/OnlineBattleScreen.swift`, `Sources/PokeTokenBar/Core/OnlineBattleSession.swift`, `Sources/PokeTokenBar/Core/OnlineBattleLocalization.swift`, `Tests/PokeTokenBarTests/OnlineBattleSessionTests.swift`

수용 기준:

- OnlineBattleModels는 이미 role을 디코딩하지만 쓰는 곳이 없다. 이 값이 host인 기기에서만 헤더 메뉴에 멤버 관리가 보이고 일반 멤버에게는 보이지 않는다
- 초대 발급은 기본 7일·30명(2026-10-30 사용자 결정)이고 1회용(1명)도 고를 수 있다. 복사 버튼으로 클립보드에 넣는다
- 활성 초대 목록과 회수, 멤버 제거, 재연결 코드 발급이 기존 API(createInvite, invites, revokeInvite, removeMember, issueReconnectCode)로 연결된다. 서버 변경은 없다
- 제거하면 서버가 열린 초대를 함께 회수한다(revokedInvites)는 사실을 결과 문구로 알려 준다
- 초대코드는 화면에서 복사 후 가려지고 로그에 남지 않는다
- 위험 동작(멤버 제거)은 한 번 더 확인을 받는다

먼저 쓸 테스트: OnlineBattleSessionTests에서 host 역할 세션만 createInvite 액션을 노출하고, 호출 시 기본값(30명)과 1회용(maxUses=1)이 각각 API로 전달되며, 비방장은 액션이 비활성이라고 단언한다.

### T11 — 가입 직후·로비 보완: 복구코드 복사, 빈 상태, 받은/보낸 신청 배지, 긴 닉네임

- 우선순위 P1 · 크기 M · 모델 sonnet high
- 피드백: 3, 3-4, new
- 선행: T06, T09, T10
- 목표: 가입 직후와 첫 로비에서 막히지 않고, 받은 신청을 놓치지 않으며, 복구코드를 잃지 않는다.
- 파일: `Sources/PokeTokenBar/UI/OnlineBattleScreen.swift`, `Sources/PokeTokenBar/UI/OnlineBattleScreenLobby.swift`, `Sources/PokeTokenBar/Core/OnlineBattleLocalization.swift`, `Tests/PokeTokenBarTests/OnlineBattleScreenRenderingTests.swift`

수용 기준:

- 복구코드 화면에 복사 버튼(NSPasteboard)이 있고 '복사했거나 적어 뒀어요' 체크 후에야 보관 버튼이 활성화된다
- 동료가 0명일 때 '아직 다른 동료가 없어요. 방장에게 초대코드를 받아 함께 들어오세요' 빈 상태가 나온다
- 진행 중인 경기 행에 '받은 신청/보낸 신청/내 차례' 배지와 강조색이 붙는다
- 복구코드 확인 직후 로비 상단에 3줄 '이제 이렇게 해요' 안내가 1회 표시된다
- 신청 직전 확인 문구에 상대 전체 이름이 줄바꿈 허용으로 나온다

먼저 쓸 테스트: OnlineBattleScreenRenderingTests에서 동료 0명 로비가 빈 상태 문구를 렌더링하고, 복구코드 단계에서 체크 전에는 보관 버튼이 비활성이라고 단언한다.

### T12 — 닫힌 상태 수신 보강: 슬립·네트워크 복귀 즉시 재연결

- 우선순위 P1 · 크기 M · 모델 opus high
- 피드백: 3-2, new
- 선행: T05
- 목표: 덮개를 연 직후와 연결 실패 뒤에도 신청·수락을 늦지 않게 받는다. 지금은 복귀 직후 연결이 세 번 실패하면 팝오버가 닫힌 동안 최대 10분간 수신도 조회도 없다. 닫힌 상태의 주기 폴링은 넣지 않는다.
- 파일: `Sources/PokeTokenBar/Core/OnlineBattleConnection.swift`, `Sources/PokeTokenBar/PokeTokenBarApp.swift`, `Tests/PokeTokenBarTests/OnlineBattleConnectionTests.swift`

수용 기준:

- OnlineBattleConnecting에 재연결 힌트 메서드를 추가하고 NSWorkspace.didWakeNotification과 NetworkReachabilityMonitor.onReconnected에 연결한다. polling과 retryWaiting에서는 attempts와 openFailures를 0으로 하고 즉시 connect, connected에서는 nextPing을 now로 당긴다
- OnlineBattleConnection.swift:218의 nextAction을 now+600에서 now+120으로 바꾼다
- :92의 팝오버 열림 분기에서 polling이면 refresh에 더해 connect한다
- 닫힌 상태의 presence는 refresh를 생략하고 dirty 표시 후 열릴 때 1회 갱신한다(한 명의 온오프가 동료 전체의 3요청으로 번지는 것을 막는다)
- :199의 모르는 메시지 type은 종료 대신 무시한다. 배포된 2.6.0은 모르는 type을 받으면 복구 불가로 멈춘다
- 연결 상태 전이를 AppLog에 기록해 T24 실측에 쓴다(키와 주소는 제외)
- :195 문구를 "다시 연결하는 중"으로 바꾼다. T03의 `onlineHomeSubtitle`과 메뉴 표식은 연결 상태를 화면 문구(`L.onlineReconnectingStatuses`, `L.onlineConnectedStatus`) 비교로 구분하므로, presentation에 타입이 있는 연결 상태를 두고 그 비교를 없앤다
- 주기 폴링과 60초 수치는 넣지 않는다. WebSocket이 막힌 환경은 T24 결과에 따라 T25로 다룬다

판단 근거(Opus 검토):

T12를 '주기 폴링'에서 '재연결 우선'으로 바꾼다. 슬립 복귀와 네트워크 복구 때 즉시 재연결하고, polling 상태의 재연결 주기를 600초에서 120초로 줄이며, 팝오버를 열면 바로 재연결한다.

닫힌 상태의 주기 폴링은 지금 넣지 않는다. 실측에서 회사망이 WebSocket을 막는다고 나오면 그때 조건부 T25로 가벼운 활성 방 조회를 60초 간격으로 넣는다. 현재 refresh()를 그대로 주기 폴링하려면 10명 기준 안전 하한은 180초이고, T12의 60초는 철회한다.

T02는 푸시 이벤트가 아니라 views 상태 비교로 정의한다. 재실행 복귀는 세션에는 이미 있으므로 화면 라우팅과 방 선택 우선순위만 T05에서 고친다.

남은 위험:

- 실기 미확인: 디스플레이 슬립 중 App Nap이 ping과 수신 처리를 얼마나 늦추는지, 복귀 후 Wi-Fi가 붙는 시간은 코드로 확정할 수 없다. T24 측정 전까지 beginActivity는 넣지 않는다.
- 회사 프록시가 WebSocket을 막으면 T12만으로는 닫힌 상태 알림이 오지 않고, 팝오버를 열 때만 갱신된다. 이 경우에만 T25가 필요하며 프록시 통과 여부는 BATTLE_PLAN.md:300에도 미검증으로 남아 있다.
- 슬립한 상대의 소켓은 서버가 끊김을 알 때까지 isOnline이 true로 남을 수 있다. T06·T07 문구에서 온라인 표시를 '받을 수 있음'으로 약속하면 안 되고, 신청 만료 안내가 필요하다.
- 시스템 슬립 중에는 어떤 방법으로도 수신할 수 없다. 복귀 후 대조로만 인지하므로 그 사이 PENDING 만료와 턴 타임아웃은 막지 못한다.
- 120초와 180초는 한도 계산값이지 Free 계정 실측값이 아니다. 조회 응답의 DO CPU도 미측정이라 대시보드 확인이 필요하다.
- 복귀 재연결은 presence 팬아웃을 늘린다. T12의 닫힌 상태 presence 생략이 빠지면 요청이 늘어난다.

먼저 쓸 테스트: OnlineBattleConnectionTests에서 가짜 시계로 복귀 재연결, 3회 실패 뒤 120초 재시도, 열림 시 재연결, 모르는 type 무시를 각각 단언한다.

### T13 — 온라인 연출 코어: 진행층과 표시층 분리, BattleSeatFrame으로 시점 고정

- 우선순위 P1 · 크기 L · 모델 opus high
- 피드백: 4
- 선행: 없음
- 목표: 진행(process, advance, report, settle)은 네트워크 속도 그대로 두고 표시만 뒤따라가는 OnlineBattleStaging을 만든다. 연습전 재생기(PracticePlayback)를 재사용해, 연출이 선택 입력과 서버 시계를 건드리지 않게 한다.
- 파일: `Sources/PokeTokenBar/Core/OnlineBattleStaging.swift`, `Sources/PokeTokenBar/Core/OnlineBattleSession.swift`, `Sources/PokeTokenBar/Core/OnlineBattleResolver.swift`, `Sources/PokeTokenBar/Core/PracticePlayback.swift`, `Sources/PokeTokenBar/Core/PracticeBattle.swift`, `Sources/PokeTokenBar/UI/PopoverView.swift`, `Tests/PokeTokenBarTests/OnlineBattleStagingTests.swift`

수용 기준:

- OnlineBattleStagePlan.decide 표 전체가 단위 테스트로 고정된다
- p2 시점 파서 골든 라인(win, reveal 포함)이 통과한다
- 실제 엔진으로 같은 시드를 p1·p2 resolver에 돌리는 거울 테스트에서 양쪽 beat의 actor와 hpDelta 소유가 정확히 반전되고, 최종 display[.player]가 각자 own.hp/maxhp와 일치한다
- 숨긴 동안 N라운드가 지나고 다시 열면 beat가 재생되지 않는다
- 터미널 라운드 연출 중 completed가 도착하면 phase가 .arena를 유지한 뒤 .result로 간다
- 기술 선택 가능 여부는 연출 상태와 독립이다(D6). 연습전의 .playback hold는 옮기지 않는다
- PopoverView.swift:126의 OnlineBattleScreen에 onAppear/onDisappear로 온라인 화면 표시 액션(onlineScreenVisible)을 추가한다
- 내부 순서는 BattleSeatFrame → 수집과 plan → 게이트와 드라이버이고 단계별로 커밋한다

확정 설계(Opus 검토):

결론: 코드 읽기만으로 설계를 확정할 수 있고, 실측 없이 구현을 시작해도 된다. 진행(process, advance, report, settle)은 네트워크 속도 그대로 두고, 표시만 뒤따라가는 `OnlineBattleStaging`을 새로 둔다.

**1. 수명: 세션이 전투별로 소유한다**
- 새 파일 `Core/OnlineBattleStaging.swift`를 만들고 `OnlineBattleSession`에 `stagings: [String: OnlineBattleStaging]`을 둔다. 세션은 앱 수명 동안 살아 있다(OnlineBattleSession.swift:5).
- 팝오버를 닫으면 뷰 트리가 해제되므로(PokeTokenBarApp.swift:799) `@State`에는 둘 수 없다.
- staging이 쥐는 것: `playback`, `parser`, `frame`, `stagedRounds` 커서, `lastView`, `lastRequest`. `introShown`은 `PracticePlayback`의 프로퍼티(PracticePlayback.swift:194)라 함께 옮겨지므로 별도 이전이 필요 없다.
- `presentation.stage`로 현재 방의 staging만 노출한다.
- 해제 지점: 세대 리셋 3곳(:101, :141, :360)과 `.dismissResult`(:686). void·cancelled·declined·expired는 :478에서 즉시 skip하고 제거한다.
- completed는 :485에서 resolver가 닫혀도 staging을 남기고, `lastView`로 마지막 연출을 끝까지 그린다.

**2. 수집 지점: 한 곳으로 모은다**
- `process()`의 consume 직후, :512 `publish()` 바로 앞에서 `ingest`한다. WS 라운드(:272), `readBattle`(:304), fallback이 모두 여기를 지나므로 입구가 하나다.
- resolver에는 `private(set) var roundLogEnds: [Int]`만 추가한다. `refresh()` 끝(:196)에서 `logs.count`를 append하면 `roundLogEnds.count == journal.count + 1`이 항상 성립한다. 0번 구간은 등장 라인이다.
- 라운드 i 시작 시 `journal[i][localSide] == .timeout`이면 `.timedOut`을 앞에 붙인다. 연습전은 PracticeBattle.swift:186에서 같은 일을 한다.
- 특성 공개는 라이브 resolver에서만 `drainEvents`를 불러 라운드별로 병합한다. PracticeBattle.swift:261-269의 병합을 공용 함수로 뺀다. 이 호출은 `logHash`에 영향이 없다(engine/src/index.js:58은 `b.log` 기준, 커서는 :96에서 별도).
- completed 응답이 이미 도착했는데 resolver가 뒤처져 있으면(:484) 일부러 consume하지 않고 결과로 바로 넘어간다. 검증 경로를 건드리지 않기 위해서다.

**3. 연출 범위: 순수 함수 `OnlineBattleStagePlan.decide(newRounds:mode:visible:secondsLeft:playing:)`**

0번 구간은 항상 즉시 처리한다(switch로 표시값 시드, 특성은 preamble로 다음 beat에 실림). 실행은 기존 API만으로 된다: `enqueue(이전 라운드) -> skipToEnd() -> enqueue(마지막 라운드)`.

| 조건 | 즉시 처리 | 연출 |
|---|---|---|
| 안 보임 | 전부(진행 중 beat 포함) | 없음 |
| 수동, 남은 시간 6초 미만 | 전부 | 없음 |
| 수동, 그 외 | 마지막 이전 전부와 진행 중 beat | 마지막 1라운드 |
| 자동, 새 라운드 1개(라이브) | 없음 | 큐 뒤에 추가 |
| 자동, 새 라운드 2개 이상(복귀) | 진행 중 beat와 마지막 이전 전부 | 마지막 1라운드 |

- `secondsLeft`가 nil이면 충분한 것으로 본다. WS 라운드 직후에는 deadline이 잠시 nil이다(:269-271).
- 자동전 라이브에는 배속 설정을 그대로 적용하고 '결과 보기' 버튼(`skipToEnd`)을 둔다. 연습전 `skipToResult`(PracticeSession.swift:312)에 대응한다.

**4. 선택 시간을 침범하지 않는 장치**
- 서버 deadline은 `open()` 시점부터 흐르고(server/src/battle-relay.ts:16), p1은 consume 직후 advance한다(OnlineBattleSession.swift:548).
- `advance`를 연출 뒤로 미루지 않는다. p2 fallback이 2초 뒤 어차피 advance하므로(:321) 미뤄도 효과가 없고, 숨김 상태와 충돌한다.
- 연습전의 `.playback` hold(PracticeSession.swift:538-543)는 옮기지 않는다. 수동전 기술 버튼은 `isPlaying`으로 잠그지 않는다. 한 라운드 연출은 통상 약 3초다.
- 연출이 잡는 것은 표시뿐이다. 기술 카드 입력과 deadline은 그대로 간다.

**5. 표시 게이트: `publish()` 한 곳**
- `publish()` 맨 앞에서 `syncStages()`를 호출한다. staging별 visible은 `popoverOpen && onlineScreenVisible && 이 방이 표시 대상 && !showsHistory && !showsStandings && rematchSourceID == nil`이다.
- 표시 대상 판정은 :618의 방 선택 로직을 함수로 뽑아 쓴다. phase로 판정하면 순환 참조가 되므로 쓰지 않는다.
- visible이 false면 그 자리에서 `skipToEnd`한다. 팝오버 숨김 중의 큐는 이 경로와 `ingest(visible: false)`로 항상 비어 있게 되어, 재오픈 시 이전 beat를 뒤늦게 재생하지 않는다.
- :660은 `publish()` 없이 return하므로 호출을 추가해야 한다. 그래야 닫을 때 skip되고 표시 hold도 풀린다.
- `onlineScreenVisible`은 PopoverView.swift:126의 `OnlineBattleScreen`에 `.onAppear`/`.onDisappear`로 새 액션을 보내 얻는다. 연습전의 `.screenHidden`(PopoverView.swift:132,135)과 같은 방식이다.
- phase 전환(:632-638): `.reported`와 `.completed`는 해당 staging이 `isPlaying`인 동안 `.arena`를 유지한다. `.void`는 잡지 않는다. HP·XP 정산(`settle`)은 표시와 무관하게 즉시 실행된다.
- arena와 request는 `resolvers[id]?.view ?? staging.lastView`로 읽는다.
- 드라이버는 PracticeSession.swift:549-569와 같은 100ms 루프를 세션에 둔다. visible이고 재생 중일 때만 돌고, 비면 멈추며 `publish()`한다. 기존 1초 ticker(:174)는 쓰지 않는다. `automaticTicks`가 false면 돌지 않고 테스트는 `tickStage()`를 직접 부른다.

**6. 재구성 경로**
- :502 needsRefetch에서 `staging.markResync()`를 호출한다. ObjectIdentifier 비교는 주소 재사용 위험이 있어 쓰지 않는다.
- 다음 ingest에서는 `skipToEnd()` 후 커서를 `journal.count`로 맞추고 `enqueue([.switchIn(.player,...), .switchIn(.opponent,...)])`로 표시값만 다시 시드한다. beat가 생기지 않아 history 중복도 없다.
- 앱 재시작 후에는 staging이 새로 생기므로 표의 복귀 규칙을 그대로 따른다.

**7. p1/p2 매핑을 구조적으로 막기**
- 엔진은 뷰어가 p2여도 식별자를 뒤집지 않는다. HP만 뷰어 기준이다(engine/tests/contract.test.cjs:90-94). 그런데 파서는 p1을 항상 player로 고정한다(PracticePlayback.swift:103-104). 수정 없이 붙이면 p2 사용자의 카드가 뒤바뀌므로 이것이 실제 결함 지점이다.
- `struct BattleSeatFrame { let local: OnlineBattleSide; static let practice; func side(ident:); func seat(_:); func pokemon(_:in:) }`를 추가한다.
- `PracticeEventParser(frame: .practice)`를 기본값으로 두어 연습전 동작은 그대로 유지한다.
- `PracticeSide`의 `String` raw type을 제거한다. 그러면 나머지 두 곳(PracticePlayback.swift:96의 `win`, PracticeBattle.swift:265의 reveal)이 컴파일 오류로 드러나 frame을 거치게 된다. Tests에는 `PracticeSide(rawValue:)` 사용처가 없다(grep 0건). `.rawValue` 사용처는 Practice 코어·UI 일부만 확인했으므로 컴파일로 최종 확인한다.
- frame은 `resolver.localSide`에서만 만든다. `presentation.localSide`는 `?? .p1` 폴백이 있어(:626) 쓰지 않는다.
- 아레나 뷰는 `view.p1`/`view.p2`를 직접 읽지 않고 `frame.pokemon(.player/.opponent, in:)`만 쓴다(OnlineBattleScreenArena.swift:24-25 교체).
- 비재생 상태의 카드는 `playback.display`가 아니라 view에서 만든 `PracticeDisplaySide`를 쓴다. 따라서 파싱 오류가 있어도 beat가 끝나면 권위값으로 돌아온다. 불일치는 `assertionFailure`로 잡는다. `shown`은 `beat?.after[side] ?? atRest(side)` 형태가 된다(PracticeBattleBoard.swift:50 대응). `display`를 그냥 nil로 넘기면 fainted가 false가 되므로(:367) 안 된다.

**8. 필수 테스트**
- `decide` 표 전체.
- p2 시점 파서 골든 라인(`win`, reveal 포함).
- 실제 엔진으로 같은 시드를 p1·p2 resolver에 돌리는 거울 테스트: 양쪽 beat의 actor와 hpDelta 소유가 정확히 반전되고, 최종 `display[.player]`가 각자 `own.hp/maxhp`와 일치해야 한다.
- 숨김 중 N라운드 → 재오픈 시 beat 없음. 터미널 라운드 연출 중 completed 도착 → phase `.arena` 유지 후 `.result`.

**핵심 파일**
- Sources/PokeTokenBar/Core/OnlineBattleSession.swift
- Sources/PokeTokenBar/Core/OnlineBattleResolver.swift
- Sources/PokeTokenBar/Core/PracticePlayback.swift
- Sources/PokeTokenBar/Core/PracticeBattle.swift
- Sources/PokeTokenBar/UI/OnlineBattleScreenArena.swift
- Sources/PokeTokenBar/UI/PopoverView.swift

남은 위험:

- 기술 버튼을 잠그지 않으므로 연출이 끝나기 전에 고르면 직전 턴의 결과를 다 보지 못한 채 선택하게 된다. 체감은 두 맥 수동 시험에서 확인하고, 필요하면 버튼 색 강조만 지연한다(입력은 계속 허용).
- view에서 바로 읽는 값은 연출보다 앞설 수 있다. view.turn, 공개된 상대 기술, request 변화(터미널 라운드에서 kind가 none으로 바뀌어 onlineForced 문구가 뜨는 경우), liveLogs가 해당하며, T14에서 모두 staged 값이나 hold 조건으로 처리해야 한다.
- completed가 먼저 도착해 resolver가 consume하지 않은 라운드는 history에 없다. 따라서 PracticePlayback.summary는 부분값일 수 있고, T19는 이 경우 요약을 숨겨야 한다.
- 자동전 라이브는 라운드를 전부 큐에 쌓아, 드물게 턴이 길면 진행이 끝난 뒤에도 표시가 오래 걸린다. 빠른 배속, 결과 보기 버튼, 팝오버 닫기 skip으로 완화할 뿐 상한을 두지는 않았다.
- PracticeSide의 raw type 제거는 Practice 코어·UI 일부만 grep했으므로 다른 파일에 .rawValue 사용처가 나올 수 있다. 나오면 컴파일 오류로 드러나 frame으로 옮기면 되므로 위험은 작다.
- PracticeSideCard는 BattleSnapshot을 받지만 온라인은 OnlineBattleSnapshot이다(OnlineBattleModels.swift:44). BattleSnapshot 필드와의 대응은 확인하지 않았으며 T14에서 어댑터를 확인해야 한다.
- beat 타이밍, 스플래시, 카드 전환의 체감 품질은 코드로 판단할 수 없어 T24 두 맥 시험에 의존한다. 설계 자체의 전제는 아니다.

먼저 쓸 테스트: OnlineBattleStagingTests에서 위 수용 기준 1~5를 먼저 쓴다. 타입이 없어 실패하고, 이후 단언 실패로 넘어가야 한다.

### T14 — 아레나 보드 교체: PracticeSideCard 재사용, 한 화면 고정 높이, 최근 로그

- 우선순위 P1 · 크기 L · 모델 sonnet high
- 피드백: 4, new
- 선행: T13
- 목표: HP가 순간이동하지 않고 누가 무슨 기술로 얼마나 때렸는지 보이는 연습전 수준의 아레나 화면을 만든다.
- 파일: `Sources/PokeTokenBar/UI/OnlineBattleScreenArena.swift`, `Sources/PokeTokenBar/UI/OnlineBattleCombatantCard.swift`, `Sources/PokeTokenBar/UI/PracticeStaging.swift`, `Sources/PokeTokenBar/Core/OnlineBattleHistoryText.swift`, `Tests/PokeTokenBarTests/OnlineBattleScreenRenderingTests.swift`

수용 기준:

- 상대·내 카드가 PracticeSideCard(HP 바 감소, 떠오르는 변화량, 히트 흔들림, 콜아웃 칩)로 그려지고 내 기술 칩 중복 표시가 없다
- 보드는 고정 높이라 기술 선택 버튼이 스크롤 아래로 밀리지 않는다(ScrollView 변경이 필요하면 OnlineBattleScreen.swift 대신 아레나 뷰 내부에서 처리)
- 로그는 최근 3~5줄 또는 접이식이고 새 줄이 위에 보인다. 기술명 해석은 PracticeWording/moveSlugs 기반이라 '미번역 기술 (X)'이 나오지 않는다
- 내 스프라이트에 shiny/form이 반영된다
- 시각 언어는 연습전 보드를 재사용하고 공식 게임 화면의 HP바 배치·메뉴 박스·효과음·폰트를 의도적으로 닮게 하지 않는다

검토로 확정한 변경(위 내용보다 우선):

- T13 완료 후 시작한다. 카드는 frame.pokemon과 staging의 shown(beat.after 우선, 비재생 시 view 유도값)으로 그리고 view.p1/p2 직접 참조를 제거한다. 기술 그리드는 isPlaying으로 잠그지 않는다. OnlineBattleLogCard(liveLogs)는 아레나에서 playback.recent로 바꾸고 전체 로그는 결과 후로 미룬다. reveal은 stagedReveal 방식으로 계산한다. hold 중(request none)에는 onlineForced 문구를 숨긴다. 자동전에 결과 보기 버튼을 둔다. BattleSnapshot 어댑터를 확인한다.

먼저 쓸 테스트: OnlineBattleHistoryTextTests에 17개 사전 밖 기술 slug를 넣어도 '미번역 기술' 문구가 나오지 않는다는 케이스를 추가하고, 렌더링 테스트에서 아레나 상태의 기술 이름이 한 번만 나타난다고 단언한다. 연출 체감은 두 맥에서 수동 확인한다.

### T15 — 기다리는 중 존재감: 선택 강조, 상대 상태, 자동 선택 안내

- 우선순위 P1 · 크기 M · 모델 sonnet high
- 피드백: 4
- 선행: T13, T14
- 목표: 내가 고른 기술을 강조하고 상대가 고르는 중인지, 연결이 끊겼는지를 보여 대기 시간이 멈춘 느낌을 없앤다.
- 파일: `Sources/PokeTokenBar/UI/OnlineBattleScreenArena.swift`, `Sources/PokeTokenBar/Core/OnlineBattlePresentation.swift`, `Tests/PokeTokenBarTests/OnlineBattlePresentationTests.swift`

수용 기준:

- 선택 후에도 기술 그리드가 유지되고 고른 카드만 체크+강조, 나머지는 흐려지며 레이아웃이 흔들리지 않는다
- 그리드 아래에 '상대가 고르는 중…'이 나오고, 상대 members.online이 false이면 '상대 연결 끊김, 시간 초과 시 자동 선택' 문구가 나온다
- 폴링 폴백 중에는 presence가 갱신되지 않으므로 online 값이 오래되었을 수 있음을 단정적으로 표시하지 않는다
- 시간 초과로 자동 선택된 경우 로그/결과에 그 사실이 명시된다

검토로 확정한 변경(위 내용보다 우선):

- 시간 초과 표시는 T13이 주입하는 .timedOut 콜아웃(beat.callouts)을 재사용한다. 별도 판정을 만들지 않는다. T13 이후로 순서를 둔다.

먼저 쓸 테스트: OnlineBattlePresentationTests에서 ownChoice가 있고 상대 online=false일 때 대기 문구 종류가 '연결 끊김'이고, online=true이면 '고르는 중'이라고 단언한다.

### T16 — 서버 view에 opponentSubmitted 불리언 추가와 앱 표시

- 우선순위 P1 · 크기 S · 모델 sonnet high
- 피드백: 4
- 선행: T15
- 목표: 선택 내용은 숨긴 채 '상대가 이번 라운드 선택을 마쳤다'는 사실만 보여 긴장감을 만든다.
- 파일: `server/src/battle-view.ts`, `Sources/PokeTokenBar/Core/OnlineBattleModels.swift`, `Sources/PokeTokenBar/Core/OnlineBattlePresentation.swift`, `Sources/PokeTokenBar/UI/OnlineBattleScreenArena.swift`, `Tests/PokeTokenBarTests/OnlineBattleModelsTests.swift`

수용 기준:

- view에 opponentSubmitted가 추가되고 상대 선택의 내용·슬롯은 어떤 형태로도 노출되지 않는다(로크스텝 유지)
- 앱은 이 필드를 옵셔널로 디코딩해 옛 서버에서도 동작하고, 서버를 앱보다 먼저 배포한다(운영·개발 Worker 배포는 사용자 승인 후)
- 필드가 있으면 '상대 선택 완료'를, 없으면 '고르는 중…'을 보여준다
- 서버 단위 테스트와 Swift 디코딩 테스트가 통과한다

검토로 확정한 변경(위 내용보다 우선):

- 제약을 추가한다. 새 WS 메시지 type을 만들지 말고 battle_changed와 HTTP view의 필드 추가로만 전달한다. 배포된 2.6.0은 모르는 type을 받으면 소켓이 복구 불가로 종료되기 때문이다.

먼저 쓸 테스트: 서버 테스트에서 상대가 제출한 뒤 내 view에 opponentSubmitted=true이고 choice 값은 직렬화에 없다고 단언한다. Swift 쪽은 필드가 없는 JSON도 디코딩된다고 단언한다.

### T17 — 기술 카드에 상성·STAB·위력 힌트 표시

- 우선순위 P1 · 크기 M · 모델 sonnet high
- 피드백: 4, new
- 선행: T14, T16
- 목표: 연습전에서 익힌 '이 기술이 굉장한가' 판단 근거를 온라인 기술 선택에도 제공한다.
- 파일: `Sources/PokeTokenBar/UI/OnlineBattleScreenArena.swift`, `Sources/PokeTokenBar/Core/OnlineBattleResolver.swift`, `Sources/PokeTokenBar/Core/OnlineBattleSession.swift`, `Tests/PokeTokenBarTests/OnlineBattleResolverTests.swift`

수용 기준:

- 내 request.moves에 대해서만 ×배수, STAB, 위력/명중 힌트를 계산해 PracticeMoveCard에 전달한다
- 상대 비공개 기술이나 선택 정보는 사용하지 않고 view에 공개된 상대 타입만 쓴다
- 엔진 typeChart/moveInfo 로드는 연습전 방식(PracticeSession)을 따르고 로드 실패 시 힌트만 생략된다

먼저 쓸 테스트: OnlineBattleResolverTests에서 불 기술 vs 풀 타입 상대는 ×2, 같은 타입 사용은 STAB 표시가 되고, 상대 기술 정보 없이 계산된다고 단언한다.

### T18 — 30초 소진 바 + 대전 시작 VS 스플래시 + 상대 닉네임·전적 표시

- 우선순위 P1 · 크기 S · 모델 sonnet high
- 피드백: 4
- 선행: T17
- 목표: 남은 시간을 감각으로 느끼게 하고, 동료와 싸우는 실감(닉네임, 연승, 상대 전적)을 아레나에 준다.
- 파일: `Sources/PokeTokenBar/UI/OnlineBattleScreenArena.swift`, `Sources/PokeTokenBar/UI/OnlineBattleCombatantCard.swift`, `Sources/PokeTokenBar/Core/OnlineBattlePresentation.swift`, `Tests/PokeTokenBarTests/OnlineBattlePresentationTests.swift`

수용 기준:

- 카드 위에 얇은 소진 바가 있고 마지막 5초는 주황색+맥박이며 '시간 초과 시 자동 선택'이 병기된다. 연출이 시계를 침범하지 않는다
- 첫 라운드 전에 상대 닉네임이 들어간 VS 스플래시가 한 번 나온다(introShown 재사용, 스킵 가능)
- 상대 카드 라벨이 '상대 · {닉네임}'이고 '연승 N / 상대 전적 a승 b패'가 한 줄로 표시된다. 전적은 presentation.battles의 completed 결과에서 클라이언트 계산한다
- UI 카피는 중립 어휘(대전, 도전, 수락)를 유지한다

검토로 확정한 변경(위 내용보다 우선):

- VS 스플래시는 presentation.stage.playback.introShown을 그대로 쓰고 splashDue에는 phase .running을 넘긴다. 타이머 바는 deadline nil을 0초로 그리지 않는다. 현재 remainingSeconds가 nil에 0을 돌려줘(OnlineBattleScreenArena.swift:61-64) 라운드 직후 주황색 0초가 잠깐 보일 수 있다. nil은 '다음 턴 준비 중' 상태로 처리한다.

먼저 쓸 테스트: OnlineBattlePresentationTests에서 같은 상대와의 completed 경기 3건(2승 1패)이 '2승 1패'로 집계되고 진행 중인 경기는 제외된다고 단언한다.

### T19 — 결과 화면 강화와 '한 번 더 겨루기' 재대결

- 우선순위 P1 · 크기 M · 모델 sonnet high
- 피드백: 4
- 선행: T07, T11, T13, T14
- 목표: 이기고 지는 순간에 감정 보상을 주고, 재대결을 기존 신청 경로 위의 주 버튼으로 올린다.
- 파일: `Sources/PokeTokenBar/UI/OnlineBattleScreen.swift`, `Sources/PokeTokenBar/UI/PracticeResultView.swift`, `Sources/PokeTokenBar/UI/OnlineBattleRematchPreparation.swift`, `Sources/PokeTokenBar/Core/OnlineBattleSession.swift`, `Tests/PokeTokenBarTests/OnlineBattleScreenRenderingTests.swift`

수용 기준:

- 막타 연출이 끝난 뒤에 확인 중을 거쳐 결과가 나온다(playback 완료 신호는 T13 객체에서 읽는다)
- PracticeResultView 형태(히어로, 턴/가한/받은 피해 타일, 상대 닉네임, 연승)를 재사용하고 승리/패배/무승부 제목은 L.online 로컬라이즈를 거친다
- 주 버튼 '한 번 더 겨루기'를 누르면 기존 로비 신청 경로로 신청이 가고 버튼이 '○○님의 응답을 기다려요 · 취소'로 바뀐다. 보조 버튼은 '로비로 돌아가기'
- 상대가 먼저 재대결을 보낸 경우 결과 화면에 배너와 '수락' '나중에' 버튼이 나온다
- 재대결 비활성 사유(내 포켓몬 기절, 상대 오프라인)가 버튼 아래에 한 줄로 보인다

검토로 확정한 변경(위 내용보다 우선):

- 결과 강화의 요약은 staging.playback.summary를 쓰며 frame 적용 후이므로 player가 곧 나다. 소비되지 않은 라운드가 있으면(history 마지막 턴이 terminalSeq 미만) 요약 수치를 숨긴다. staging은 dismissResult까지 유지되므로 수명 문제는 없다.

먼저 쓸 테스트: OnlineBattleScreenRenderingTests에서 패배 결과 상태가 로컬라이즈된 제목과 '한 번 더 겨루기' 버튼을 렌더링하고, 재대결 신청 후에는 같은 버튼이 대기+취소 상태로 바뀐다고 단언한다.

### T20 — 전투 준비 자동 진행 (보류)

- 우선순위 P2 · 크기 S · 모델 sonnet high
- 피드백: 3
- 선행: T06
- 목표: 사용자 결정(D4): 안내 강화(T06)를 먼저 하고, 써 보고도 길면 그때 추가한다. 지금은 실행하지 않는다. 동의 의미는 유지한 채 최종 확인 뒤 전투 준비 클릭을 하나 줄인다.
- 파일: `Sources/PokeTokenBar/Core/OnlineBattleSession.swift`, `Sources/PokeTokenBar/UI/OnlineBattleScreenLobby.swift`, `Tests/PokeTokenBarTests/OnlineBattleSessionTests.swift`

수용 기준:

- D4가 자동 진행일 때만 구현한다. 최종 확인 직후 팝오버가 열려 있고 소켓이 연결된 경우에 한해 전투 준비를 자동 호출한다
- 자동 진행 시 화면에 '자동으로 준비했어요'가 보이고 T06의 '내 준비 완료' 상태로 이어진다
- 팝오버가 닫혀 있으면 자동 진행하지 않고 finalConfirmed 알림 흐름을 따른다

먼저 쓸 테스트: OnlineBattleSessionTests에서 최종 확인 후 visible=true, 소켓 연결이면 prepare가 자동으로 1회 호출되고, visible=false이면 호출되지 않는다고 단언한다.

### T21 — 전투 화면 접근성: VoiceOver 라벨과 턴 시작 안내

- 우선순위 P2 · 크기 M · 모델 sonnet medium
- 피드백: new
- 선행: T18
- 목표: VoiceOver 사용자도 기술, HP, 남은 시간, 선택 완료 상태를 알고 턴제 대전을 할 수 있게 한다.
- 파일: `Sources/PokeTokenBar/UI/OnlineBattleScreenArena.swift`, `Sources/PokeTokenBar/UI/OnlineBattleCombatantCard.swift`, `Tests/PokeTokenBarTests/OnlineBattleScreenRenderingTests.swift`

수용 기준:

- 기술 버튼에 한국어 accessibilityLabel/Value(이름, PP, 타입)가 있다
- 전투 카드에 양쪽 HP%와 남은 시간이 접근성 값으로 제공된다
- 턴 시작과 결과 시 accessibility announcement가 나간다
- 기술 1-4 키 단축키는 선택 사항이다

먼저 쓸 테스트: 렌더링 테스트에서 기술 버튼 접근성 라벨이 비어 있지 않고 기술 이름을 포함한다고 단언한다. 현재는 accessibilityIdentifier만 있어 실패한다.

### T22 — 앱 이름을 PokeTokenBattle로 변경 (내부 식별자 유지, .app 폴더 포함)

- 우선순위 P1 · 크기 M · 모델 sonnet medium
- 피드백: 5
- 선행: T08
- 목표: 사용자에게 보이는 이름을 PokeTokenBattle로 바꾼다. 번들 ID, 실행 파일 이름, 상태 폴더, Keychain, 로그인 에이전트 라벨, Worker 이름, 저장소 이름은 그대로 둔다.
- 파일: `scripts/build-app.sh`, `Sources/PokeTokenBar/Core/AppIdentity.swift`, `Sources/PokeTokenBar/Core/LoginItem.swift`, `Sources/PokeTokenBar/Core/UpdateChecker.swift`, `Sources/PokeTokenBar/UI/SettingsView.swift`, `scripts/e2e.sh`, `scripts/release-metadata.py`, `scripts/release-validate.py`, `scripts/test-build-app-slices.sh`, `scripts/test-fork-identity-guard.sh`, `scripts/tests/test_release_workflow.py`, `README.md`, `README.ko.md`, `README.ja.md`, `LICENSE`, `Tests/PokeTokenBarTests/AppIdentityTests.swift`

수용 기준:

- 2026-11-05에 GitHub 저장소 검색, npm, Homebrew, App Store 검색에서 PokeTokenBattle과 같은 이름을 찾지 못한 것을 기록한다. 상표 데이터베이스(USPTO, KIPRIS)는 확인하지 못했다
- build-app.sh의 APP_NAME이 .app 폴더, CFBundleName, CFBundleDisplayName, LaunchAgent 경로(99행), 설치 경로를 함께 정한다. /Applications/PokeTokenBattle.app으로 설치되고 Spotlight와 Dock에 새 이름이 보인다
- bundleID, executableName, stateDirectoryName, loginAgentLabel, releaseRepo, caskName, Keychain service, Worker 이름은 바뀌지 않는다는 점을 AppIdentityTests가 단언한다
- 옛 폴더(/Applications/PokeTokenBar Battle.app)에서 옮겨 온 설치본의 로그인 항목이 새 경로로 다시 등록된다. 등록 경로가 다르면 앱 시작 때 고친다
- UpdateChecker의 업그레이드 스크립트는 옛 bundlePath를 다시 연다(233행). 폴더 이름이 바뀌는 첫 업데이트에서 재실행이 어떻게 되는지 확인하고, 실패한다면 릴리스 노트와 설치 안내에 수동 실행 안내를 넣는다
- homebrew-tap의 cask app 항목을 새 폴더 이름으로 바꾸는 절차를 문서에 남긴다(tap 변경은 릴리스 때 사용자 승인 후). cask 토큰은 이번에 유지한다
- LICENSE의 chattymin 저작권 및 허가 문구 원문을 유지하고 포크 기여자 줄만 아래에 추가한다. 앱 안 원본 기반 링크도 유지한다
- README 상단에 비공식 팬 프로젝트이며 The Pokémon Company, Nintendo, 원본 PokeTokenBar와 무관하다는 고지가 있다
- UI 카피는 트레이너, 몬스터볼 같은 상표 인상을 키우는 어휘를 새로 늘리지 않는다

먼저 쓸 테스트: AppIdentityTests에서 표시 이름이 PokeTokenBattle이고 bundleID, stateDirectoryName, loginAgentLabel은 기존 값 그대로라고 단언한다. test-build-app-slices.sh로 새 폴더 이름의 번들이 만들어지는지 확인한다.

### T23 — 앱 아이콘 교체와 README 스크린샷의 포켓몬 스프라이트 정리

- 우선순위 P1 · 크기 M · 모델 sonnet medium
- 피드백: 5, new
- 선행: T22
- 목표: 원본과 같은 네온 알 아이콘을 독자 아이콘으로 바꾸고, 공개 문서에서 실제 포켓몬 스프라이트가 담긴 스크린샷을 합성 화면으로 교체하거나 제거한다.
- 파일: `assets/icon.svg`, `assets/AppIcon.icns`, `assets/icon_1024.png`, `README.md`, `README.ko.md`, `README.ja.md`

수용 기준:

- 새 아이콘은 몬스터볼과 닌텐도 캐릭터 없이 두 개의 토큰 모양(방패 또는 번개 갈래)이 충돌하는 자체 형상이다. iconutil로 icns를 재생성하고 build-app.sh 복사 경로는 그대로 동작한다
- assets의 png/gif 65개를 모두 직접 열어 실제 스프라이트 포함 여부를 확인하고 표로 남긴다(현재 확인은 2장뿐: screenshot-home.png는 스프라이트 있음, screenshot-online-rematch.png는 합성)
- 스프라이트가 든 이미지는 합성 화면으로 교체하거나 README 임베드와 저장소에서 제거 대상으로 올리고, 온라인용 합성 화면은 유지한다
- AGENTS.md의 'Nintendo 자산 없음' 원칙과 README가 일치한다. 런타임 스프라이트는 PokeAPI 로딩이라 번들에 없다는 점은 그대로 둔다

먼저 쓸 테스트: 수동 확인: README에 임베드된 모든 이미지를 열어 실제 포켓몬 스프라이트가 없음을 확인하는 체크 표를 작성한다. 자동화하려면 assets 목록과 README 임베드 목록이 일치하는지 검사하는 스크립트를 먼저 둔다.

T23 결과 (축소판 contact sheet로 72개 png/gif를 모두 확인, 의심되는 곳만 확대):

- 아이콘: 번개 모양이 가운데를 가르는 파랑·주황 두 토큰. `assets/icon.svg`가 원본이고 `scripts/generate-icon.swift`가 같은 도형을 크기별로 직접 그려 `generate-icns.sh`가 `AppIcon.icns`, `icon_1024.png`를 만든다. `icon.png`(512)는 1024에서 줄인 것이다. 기존 아이콘은 사실 몬스터볼이었다.
- 스프라이트 판정(게임 스프라이트나 게임 아이템 아이콘이 보이면 있음):

| 이미지 | 스프라이트 | 처리 |
|---|---|---|
| floating-pet.gif, menubar.gif, shiny-banner.gif | 있음 | README 제거, 파일 삭제 |
| screenshot-home.png/.gif | 있음 | 삭제 |
| screenshot-bag, shop(-ko,-ja 포함) | 있음(사탕·민트·알 아이콘) | 삭제 |
| screenshot-usage-recap, pokemon-forms, collection-pokedex, collection-catchlog(-ko,-ja 포함) | 있음 | 삭제 |
| assets/pr-377/*, docs/pr/pokedex-back/* (6장) | 있음 | 참조가 없어 삭제 |
| animation-quality, antigravity-limits, daily-trend, difficulty, model-breakdown, pace-marker, pokemon-profile, quota-alignment, scan-folders, session-key, settings (각 -ko,-ja 포함) | 없음 | 유지 |
| screenshot-online-standings/rematch | 없음(합성, 회색 대체 아이콘) | 유지 |
| assets/pr-snapshot-history/* (3장), docs/pr/individual-picker/* (3장) | 없음 | 유지 |
| assets/icon.png, icon_1024.png | 새 아이콘 | 유지 |

- README.ko.md, README.ja.md의 해당 임베드와 홈 대표 이미지·회고 이미지를 제거하고 안내문을 고쳤다. README.md는 원래 스프라이트 임베드가 없었고 PokéAPI 런타임 로딩 문장만 보강했다. README.upstream.md도 같은 임베드를 뺐다.
- 자동 검사: `scripts/tests/test_readme_images.py`가 네 README의 로컬 이미지 임베드가 실제 파일을 가리키는지 확인한다. 깨진 링크를 일부러 넣어 실패하는 것을 확인했다.
- 미확인: git 이력에는 삭제한 이미지가 남아 있다(이력은 다시 쓰지 않는다). pr-snapshot-history·settings 같은 세로로 긴 이미지는 일부 구간만 확대해 봤다.

### T24 — 두 맥 수동 시험표와 받는 맥 설치 안내(Gatekeeper) 문서화

- 우선순위 P1 · 크기 S · 모델 sonnet medium
- 피드백: 3, new
- 선행: T04, T08, T23
- 목표: 자동 테스트가 못 보는 환경·버전 조합을 릴리스 전 필수 시험으로 고정하고, 비개발자 동료가 첫 실행에서 막히지 않게 한다.
- 파일: `docs/AI_HANDOFF.md`, `README.md`, `README.ko.md`, `INSTALL-ko.txt`

수용 기준:

- 시험표에 알림 권한 거부, 번들 외 실행, 팝오버 고정 후 닫기, 슬립 복귀, 옛 2.6.0 앱+새 서버, 새 앱+옛 서버, 저장된 serverURL이 있는 상태에서 고정 주소 빌드 실행이 각각 기대 화면 문구와 함께 있다
- 수락 대기·최종 확인 대기·내 턴을 팝오버를 닫은 상태에서 알아차리는지 확인하는 항목이 있다
- 설치 안내에 '열기 → 완료 → 시스템 설정 → 개인정보 보호 및 보안 → 그래도 열기' 4단계와 회사 정책 차단 시 방장에게 알릴 문구가 있다. 스크린샷은 스프라이트가 없는 화면만 쓴다
- 공증은 결정 없이 이번 범위에서 안내 강화까지만 한다

검토로 확정한 변경(위 내용보다 우선):

- 두 맥 측정표를 추가하고 각 항목의 지연 시간을 기록한다. (a) 팝오버 닫힘에서 신청과 수락 수신. (b) 디스플레이 슬립 10분, 전원과 배터리 각각에서 ping 간격과 수신 지연(App Nap 판단 기준). (c) 덮개 닫기 5분 뒤 열어 connected까지 걸린 시간. (d) RUNNING 중 앱 종료 후 재실행. (e) 집중 모드, 알림 거부, 전체 화면에서 인지 여부. (f) 실제 회사망의 WebSocket 통과 여부. (f)가 실패하면 T25를 활성화하고, (b)에서 수신이 수십 초 이상 늦으면 대기와 전투 구간에 한해 beginActivity 추가를 검토한다.
- 시험표에 항목 추가: p2 쪽 사용자의 카드와 HP 일치, 수동전 연출 중 선택, 턴 중 팝오버 닫았다 열기, 자동전 연출 중 결과 보기, 네트워크 차단 후 복귀 시 마지막 1라운드만 연출, 마지막 타격이 끝난 뒤에야 결과 화면 전환.

먼저 쓸 테스트: 문서 작업이라 자동 테스트 없음. 완료 기준은 사용자가 두 번째 맥에서 시험표를 위에서부터 따라 수행해 막히는 항목이 없는 것이다.

### T25 — WebSocket 차단 환경용 저빈도 폴링 (조건부)

- 우선순위 P2 · 크기 M · 모델 opus high
- 피드백: 3-2, new
- 선행: T24
- 목표: T24 (f)에서 회사망이 WebSocket을 막는다고 확인될 때만 진행한다. 그 전에는 실행하지 않는다.
- 파일: `server/src/index.ts`, `server/src/battle-store.ts`, `Sources/PokeTokenBar/Core/OnlineBattleConnection.swift`, `Sources/PokeTokenBar/Core/OnlineBattleAPI.swift`

수용 기준:

- 서버에 활성 방만 돌려주는 조회를 추가한다(store.forTrainer 재사용, battle-store.ts:71)
- 소켓이 끊기고 팝오버가 닫힌 동안 60초 간격으로 그 조회만 호출한다. 1요청이므로 10명 최악 14.4k회/일이다
- 대기 방은 기존 api.battle(id:)를 재사용하고, 전체 refresh를 주기 호출하지 않는다

먼저 쓸 테스트: 서버 테스트에서 활성 방만 반환되고 다른 그룹 방이 없다고 단언한다. 앱에서는 가짜 시계로 소켓 끊김 + 닫힘일 때만 60초 간격으로 예약된다고 단언한다.

### T27 — 작업 완료 후 brew 공개와 기존 설치본 업데이트 경로

- 우선순위 P0 · 크기 M · 모델 sonnet high · 사용자 결정 2026-11-05: 작업이 모두 끝난 뒤 공개한다. 새 설치는 brew로, 기존 설치본은 업데이트할 수 있어야 한다.
- 선행: T18, T19, T21, 리뷰 C, 마지막 CI. 사용자 결정(2026-11-05): 공개 전 두 맥 시험 없이 작업을 끝내 배포하고 실전에서 시험한다. T24의 수동 시험표는 공개 뒤 실전 확인 목록으로 쓴다. 실제 두 맥, 실제 알림, 실제 NSPopover 고정은 공개 시점에 미검증이며 이 사실을 노트에 적는다.
- 사실(v2.6.0 소스 대조):
  - 2.6.0의 앱 안 업데이트 확인은 GitHub `/releases/latest`만 읽는다. 지금 공개된 릴리스는 prerelease뿐이라 이 주소가 404다. 새 릴리스도 prerelease이거나 `--latest=false`이면 기존 앱에 업데이트 안내가 뜨지 않는다.
  - brew cask 설치본은 앱 안 버튼이 `brew update`와 `brew upgrade`를 돌린 뒤 옛 경로를 다시 연다. 앱 폴더 이름이 바뀌므로 첫 업데이트 뒤 자동으로 다시 열리지 않는다. 사용자가 새 앱을 직접 연다.
  - brew가 아닌 설치본은 앱 안 버튼이 릴리스 페이지를 연다. 수동으로 옮겨야 한다.
- 수용 기준:
  - 공개 직전에 버전, 노트 요약, 정식(latest) 공개 여부를 사용자에게 보여 주고 확인받는다
  - 공개 뒤 문제가 나오면 패치 릴리스로 고친다. 직전 릴리스와 개발 Worker는 그때까지 유지한다
  - 임시 appdir과 로컬 cask로 v2.6.0 → 새 버전 `brew upgrade`를 실제로 돌려 옛 폴더 제거, 새 폴더 설치, 세이브 유지를 확인한다
  - tap의 `app` 항목을 `PokeTokenBattle.app`으로 바꾼다(cask 토큰 유지). tap 변경은 승인 후 한다
  - 릴리스 노트와 INSTALL-ko에 brew 설치, brew 업데이트, 첫 업데이트 뒤 직접 열기, 수동 설치본 절차, 서버가 바뀌어 새 초대코드로 다시 가입해야 한다는 점을 적는다
  - 운영 주소를 넣어 빌드한다(`PTB_BATTLE_SERVER_URL`). 저장소에는 커밋하지 않는다. `release-validate.py addresses`를 통과한다
  - 개발 Worker는 2.6.0 사용자가 옮겨 갈 때까지 내리지 않는다

## 6. 확인하지 못한 것 (2026-11-05 공개 전 기준)

공개 전 두 맥 시험은 하지 않기로 했다(사용자 결정). 아래는 공개 시점에 실제로 확인하지 못한 것이며 릴리스 노트에 같은 내용을 적는다. T24 표는 공개 뒤 실전 확인 목록이다.

- 실제 두 맥 사이의 대전, 실제 macOS 알림 배너 표시와 클릭 라우팅, 다른 앱을 눌렀을 때 팝오버가 고정되는지, 슬립·덮개 복귀 뒤 재연결, VoiceOver 청취는 실기 확인 전이다. 자동 테스트와 합성 렌더는 이를 대신하지 않는다.
- 옛 2.6.0 앱과 새 서버, 새 앱과 옛 서버, 저장된 서버 주소가 있는 상태에서 내장 주소 빌드를 실행하는 경우는 실기 확인 전이다. 2.6.0 사용자는 새 서버에서 새 초대코드로 다시 가입해야 한다.
- 2.6.0에서 올라오는 첫 업데이트에서 옛 앱의 스크립트가 새 앱을 다시 열지 못한다는 판단은 소스 읽기에 근거한다. 실제 brew 업그레이드는 별도 리허설 결과를 확인한다([RELEASE.md](../../RELEASE.md) 이름 변경 절).
- 2.6.0의 앱 안 업데이트 안내는 `/releases/latest`만 읽는다. 정식(latest) 릴리스가 아니면 기존 앱에 안내가 뜨지 않는다.
- 후속 확인: 연습전 `PracticeBattle.tick`이 강제 턴에 `.timedOut`을 넣는지, 보관한 기술이 끊긴 동안 여러 라운드를 건너뛴 뒤 쓰일 수 있다는 점, 스크롤바 때문에 본문이 밀리는 현상, `build-test (rest)` 예산 16분이 충분한지.
- 운영 Worker의 Free 한도 사용량과 복구, 방장 계정 연결 확인 결과는 이 문서에 기록하지 않았다.
- workers.dev 주소에 대한 익명 플러드 방어(WAF 속도 제한 사용 가능 여부 미검증, Rate Limiting 바인딩은 근사치, 회전 IP 공격은 막지 못함)는 확인하지 못했다.
- 서버가 group_full, 닉네임 형식 오류, 버전 불일치를 구분하는 오류 코드를 내려주는지는 찾지 못했다. T01은 확인된 5개 코드만 매핑한다.
- 신청+방장 승인제(서버 join_requests, 스키마 v5)는 초대코드 방식(D2) 선택으로 제외했다. 나중에 원하면 별도 계획이 필요하다.
- 앱·서버 버전 협상(health에 features 배열 추가, 서버 미지원 시 '서버 업데이트 필요' 안내)은 제외했다. 서버 변경은 서버 먼저 배포하고 앱 필드를 옵셔널로 두는 것으로 대체했다.
- The Pokémon Company의 팬 프로젝트 이름 정책 원문은 찾지 못했다. PokeTokenBattle은 GitHub, npm, Homebrew, App Store만 확인했고 상표 데이터베이스(USPTO, KIPRIS)는 확인하지 못했다. 이름 안전성은 서면 허가 없이 확정할 수 없다.
- Apple 공증(유료 Developer 가입)은 결정 항목이 아니다. 설치 안내 강화까지만 포함한다. 동료 배포가 막히면 그때 사용자에게 묻는다.
- 효과음과 햅틱은 도입하지 않았다. 필요하면 옵트인 기능으로 별도 요청이 필요하다.
- 한국어 외 영어 문구(L.online)와 README.ja.md의 번역 품질은 이번 범위 밖이다.
- assets 이미지의 스프라이트 판정은 T23에서 축소판 contact sheet로 전수 확인했다. 세로로 긴 이미지는 일부 구간만 확대해 봤고, 저장소 이력에는 삭제한 이미지가 남아 있다.
- Homebrew cask 토큰과 GitHub 저장소 이름 변경은 이번 범위가 아니다.
