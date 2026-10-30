# PokeTokenBar Battle

회사 동료끼리 기존에 키운 포켓몬으로 1:1 배틀을 하고, 진 쪽 포켓몬은 기절하며 이긴 쪽은 성장 경험치를 받는 macOS 앱 확장 프로젝트입니다. 배틀로 포켓몬을 빼앗지 않습니다.

**현재 상태: 포크 격리와 전투 엔진, 자동 정책, 서버 없는 로컬 연습전(야생·오늘의 상대, 기절과 회복약, 승리 경험치, 개체값 재추첨)을 구현했습니다. 검증 상태는 AI_HANDOFF를 확인하세요. 온라인 대전은 설계만 마쳤고 Cloudflare 서버는 아직 없습니다.**

## 다른 AI가 작업을 시작할 때

1. [AGENTS.md](AGENTS.md): 작업 규칙과 반드시 유지할 결정
2. [docs/AI_HANDOFF.md](docs/AI_HANDOFF.md): 현재 구현 상태, 기준 소스, 다음 작업
3. [docs/BATTLE_PLAN.md](docs/BATTLE_PLAN.md): 승인된 설계, PR 00~13(PR 08~10 폐기), TDD·인수·무료 운영 검증 기준
4. [CLAUDE.md](CLAUDE.md): 기존 Swift 앱의 상세 기여·테스트 규칙

PR 00~03C(포크 격리·엔진·연습전)는 끝났습니다. 구현 요청을 받으면 AI_HANDOFF의 '다음 작업'부터 이어갑니다(다음은 **PR 04 — 서버 골격·초대·접속키**). 문서를 읽은 것만으로 배포나 구현 권한이 생기는 것은 아닙니다.

## 확정한 방향

- macOS 전용. 기존 육성 데이터와 개체를 가져와 사용합니다.
- 초대코드 + 회사 이메일 표시명으로 가입합니다. 로그인 화면과 이메일 인증은 추가하지 않습니다.
- 앱이 개인 접속키를 Keychain에 보관합니다. 이메일을 계정 소유 증명으로 사용하지 않습니다.
- 두 맥이 같은 시뮬레이터([Pokémon Showdown](https://github.com/smogon/pokemon-showdown) 기반 `@pkmn/sim`)로 같은 입력을 동시에 계산합니다. 서버는 전투를 계산하지 않습니다.
- 배틀 방식은 신청할 때 고릅니다: 직접 조작(턴마다 기술 선택, 시간 초과 시 자동) 또는 자동 배틀. 온라인 경기는 정식전만 있습니다. 진 쪽 포켓몬은 기절하고, 이긴 쪽의 현재 포켓몬은 1천만 경험치를 받습니다(온라인 승리 하루 10회까지). 직접 조작 턴은 30초입니다.
- 9세대 규칙(테라스탈 없음)에 앱이 배운 기술과 현재 레벨·개체값·성격·특성을 반영합니다.
- 배틀은 포켓몬을 가져가지 않고 도감도 바꾸지 않습니다. 진 포켓몬은 기절하고(체력 0), 토큰으로 산 회복약으로 되살립니다: 상처약(체력 50% 회복, 1억), 고급상처약(전부 회복, 3억), 기력의조각(기절 상태에서 50%로 부활, 4억). 자연 회복은 없습니다.
- 서버는 Cloudflare **무료 플랜**의 Worker와 SQLite 기반 Durable Object 하나입니다. 실제 계정의 사용량 검증은 아직 남아 있습니다.

## 기준 소스

| 항목 | 값 |
|---|---|
| 저장소 | [dding94/poketokenbar-battle](https://github.com/dding94/poketokenbar-battle) — public (2026-10-29 전환) |
| Upstream | [chattymin/PokeTokenBar](https://github.com/chattymin/PokeTokenBar) |
| 기준 태그 | `v2.5.6` |
| 기준 커밋 | `77f789d7ccf6e692c805f599abf7dcf0c834c56b` |
| 기존 기술 | Swift 6 · SwiftUI · macOS 15+ · Swift Package Manager |

기준 버전 소스와 Git 이력을 포함합니다. 원본 저작권과 [MIT LICENSE](LICENSE)를 보존하며, 기존 앱 설명은 [README.upstream.md](README.upstream.md)에 있습니다. upstream의 설치·릴리스 안내는 이 확장판의 배포 안내가 아닙니다.

## 현재 디렉터리

- `Sources/PokeTokenBar/`: 기존 macOS 앱
- `Tests/PokeTokenBarTests/`: 기존 테스트
- `scripts/`: 기존 빌드·테스트·릴리스 도구
- `docs/BATTLE_PLAN.md`: 제품·설계·작업 순서의 기준
- `docs/AI_HANDOFF.md`: 진행 상황과 다음 AI를 위한 인계
- `engine/`: 고정 버전 시뮬레이터, JSON 계약·결정성 테스트, 제품 번들
- `server/`: 아직 없음. PR 04 이후 범위

## 검증과 배포 상태

`npm test --prefix engine`과 `cd engine && npm run corpus && npm run compatibility`로 엔진을 검증합니다. Node와 JavaScriptCore의 같은 2,200판을 로컬 macOS 26.5 및 CI macOS 15·26에서 실행했습니다. 정책 auto-v2(standard는 v1과 같음)는 불일치·재생·상태 복원 실패 0건입니다. BW2 541개 기술 호출 검사는 모든 조건별 효과 조합을 증명하지 않습니다.

앱 검증은 `swift build`, `swift test`, `./scripts/test-gate.sh`입니다. Command Line Tools에는 XCTest가 없으므로 로컬에서는 Xcode를 설치하고 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`로 `swift test`를 실행합니다. 통과 기준은 GitHub Actions(macOS 15)입니다. 실제 명령·개수·skip·미검증 범위는 [AI_HANDOFF](docs/AI_HANDOFF.md)에 기록합니다.

GitHub Actions는 `feat/**` 브랜치 푸시와 PR에서 자동으로 돌고(문서만 바뀌면 건너뜁니다), 수동 실행도 됩니다. 앱 이름·번들 ID·실행 파일·저장 폴더·로그인 항목·업데이트는 포크 전용으로 분리했습니다. 기본 세이브 위치는 `~/Library/Application Support/PokeTokenBarBattle`이며 최초 실행 시 원본 세이브가 있으면 읽어서 한 번 복사합니다. 개발 실행은 `PTB_STATE_DIR`로 별도 상태 폴더를 지정할 수 있습니다.

## 로컬 연습전 시험

1. `PTB_SKIP_INSTALL=1 PTB_NATIVE_ARCH_ONLY=1 ./scripts/build-app.sh`로 현재 맥용 번들을 만듭니다. `build/PokeTokenBar Battle.app`에 엔진과 라이선스가 들어갑니다.
2. 검증한 번들을 `/Applications/PokeTokenBar Battle.app`으로 복사해 실행합니다. 자동 설치는 별도 사용자 승인 후에만 수행합니다.
3. 메뉴바 아이콘을 눌러 팝오버를 열고 홈의 **연습전** 행(또는 하단 방패 버튼)을 누릅니다. 별도 창 없이 팝오버 안에서 내 개체와 상대를 고르고 시작합니다. 출전 가능한 개체는 한 마리면 충분합니다(야생 상대와 오늘의 상대가 있습니다). 누락된 정보는 출전 보류 이유로 표시합니다.
4. **직접 조작**은 기술 카드나 1~4 키로 고릅니다. 15초가 지나면 그 턴을 자동 선택합니다. 팝오버를 닫거나 다른 화면으로 가면 타이머가 멈추고, 다시 열면 같은 화면에서 이어집니다. **자동 진행**은 내 쪽은 standard 정책, 상대는 성향별 정책으로 조종하며 팝오버를 닫아도 계속됩니다. 메뉴바에는 진행 중 `⚔︎`, 결과 확인 전 `⚑`가 붙고, 현재 포켓몬이 기절하면 `✚`가 붙으며 아이콘이 흐려집니다. 야생 상대와 오늘의 상대와의 배틀만 체력(기절)과 승리 경험치(500만, 하루 10승까지)를 육성 세이브에 반영하고, 내 개체끼리의 스파링은 아무것도 바꾸지 않습니다. 연습 전적은 별도 `practice-records.json`에 기록합니다. 회복약과 개체값 재추첨권(4억)은 상점에서 소모한 토큰으로 삽니다. 회복약은 연습전 선택 화면의 **회복**이나 가방에서, 재추첨권은 가방에서 현재 포켓몬에게 씁니다.
5. `open -a 'PokeTokenBar Battle' --args --practice`로 실행하거나, 이미 실행 중일 때 Finder에서 앱을 다시 열면 팝오버가 연습전 화면으로 열립니다.

스프라이트와 이름 번역은 실행 중 내려받습니다. 오프라인이면 대체 그림/식별자를 표시합니다. 원본 앱 설치본·세이브를 덮어쓰지 않으며, 릴리스·공개 전환·서버 배포는 별도 작업입니다.

## 라이선스와 고지

**MIT** — [LICENSE](LICENSE). MIT 라이선스는 이 프로젝트의 원본 소스 코드에만 적용되며, 앱이 접근하는 제3자 상표·이미지·데이터에 대한 권리를 부여하지 않습니다.

PokeTokenBar Battle은 [PokeTokenBar](https://github.com/chattymin/PokeTokenBar)를 기반으로 한 **비공식·비상업 팬 프로젝트**입니다. Nintendo, Game Freak, Creatures Inc., The Pokémon Company와 관련이 없으며 이들의 승인·후원을 받지 않았습니다. "Pokémon"과 관련 이름·캐릭터·이미지는 각 권리자의 상표이자 저작물이며, 이 프로젝트는 Pokémon 지식재산에 대한 어떤 권리도 주장하지 않습니다.

PokeTokenBar Battle is an **unofficial, non-commercial fan project** based on PokeTokenBar. It is **not affiliated with, endorsed, sponsored, or approved by Nintendo, Game Freak, Creatures Inc., or The Pokémon Company.** "Pokémon" and all related names, characters, and imagery are trademarks and copyrights of their respective owners. This project claims no ownership of, and asserts no rights over, any Pokémon intellectual property.
