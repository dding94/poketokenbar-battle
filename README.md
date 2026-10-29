# PokeTokenBar Battle

회사 동료끼리 기존에 키운 포켓몬으로 1:1 배틀을 하고, 쟁탈전에서는 승자가 패자의 출전 개체를 획득하는 macOS 앱 확장 프로젝트입니다.

**현재 상태: 포크 격리와 전투 엔진, 자동 정책, 서버 없는 로컬 연습전을 구현했습니다. 연습전 최종 검증 상태는 AI_HANDOFF를 확인하세요. 온라인 대전·Cloudflare 서버는 아직 없습니다.**

## 다른 AI가 작업을 시작할 때

1. [AGENTS.md](AGENTS.md): 작업 규칙과 반드시 유지할 결정
2. [docs/AI_HANDOFF.md](docs/AI_HANDOFF.md): 현재 구현 상태, 기준 소스, 다음 작업
3. [docs/BATTLE_PLAN.md](docs/BATTLE_PLAN.md): 승인된 설계, PR 00~13, TDD·인수·무료 운영 검증 기준
4. [CLAUDE.md](CLAUDE.md): 기존 Swift 앱의 상세 기여·테스트 규칙

구현 요청을 받으면 **PR 00 — 포크 식별·격리**와 **PR 01 — 전투 엔진 결정성 게이트**부터 시작합니다. 문서를 읽은 것만으로 배포나 구현 권한이 생기는 것은 아닙니다.

## 확정한 방향

- macOS 전용. 기존 육성 데이터와 개체를 가져와 사용합니다.
- 초대코드 + 회사 이메일 표시명으로 가입합니다. 로그인 화면과 이메일 인증은 추가하지 않습니다.
- 앱이 개인 접속키를 Keychain에 보관합니다. 이메일을 계정 소유 증명으로 사용하지 않습니다.
- 두 맥이 같은 시뮬레이터([Pokémon Showdown](https://github.com/smogon/pokemon-showdown) 기반 `@pkmn/sim`)로 같은 입력을 동시에 계산합니다. 서버는 전투를 계산하지 않습니다.
- 배틀 방식은 신청할 때 고릅니다: 직접 조작(턴마다 기술 선택, 시간 초과 시 자동) 또는 자동 배틀. 쟁탈전과 친선전이 있습니다.
- 9세대 규칙(테라스탈 없음)에 앱이 배운 기술과 현재 레벨·개체값·성격·특성을 반영합니다.
- 쟁탈전 패자의 정확한 한 개체를 승자에게 이전하고, 과거 도감 이력은 유지합니다.
- 마지막 개체를 잃으면 Lv5 이상해씨·파이리·꼬부기 중 한 마리를 선택합니다(재지급은 3일 쿨다운).
- 서버는 Cloudflare **무료 플랜**의 Worker와 SQLite 기반 Durable Object 하나입니다. 실제 계정의 사용량 검증은 아직 남아 있습니다.

## 기준 소스

| 항목 | 값 |
|---|---|
| 저장소 | [dding94/poketokenbar-battle](https://github.com/dding94/poketokenbar-battle) — private. 로컬 테스트 후 public 전환 예정 |
| Upstream | [chattymin/PokeTokenBar](https://github.com/chattymin/PokeTokenBar) |
| 기준 태그 | `v2.5.6` |
| 기준 커밋 | `77f789d7ccf6e692c805f599abf7dcf0c834c56b` |
| 기존 기술 | Swift 6 · SwiftUI · macOS 14+ · Swift Package Manager |

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

`npm test --prefix engine`과 `cd engine && npm run corpus && npm run compatibility`로 엔진을 검증합니다. Node와 JavaScriptCore의 같은 2,200판을 로컬 macOS 26.5 및 CI macOS 14·15에서 실행했습니다. 정책 v1은 불일치·재생·상태 복원 실패 0건입니다. BW2 541개 기술 호출 검사는 모든 조건별 효과 조합을 증명하지 않습니다.

앱 검증은 `swift build`, `swift test`, `./scripts/test-gate.sh`입니다. 로컬 Command Line Tools에는 XCTest가 없어 테스트는 Xcode가 있는 수동 GitHub Actions로 실행합니다. 실제 명령·개수·skip·미검증 범위는 [AI_HANDOFF](docs/AI_HANDOFF.md)에 기록합니다.

GitHub Actions는 private 동안 **수동 실행**만 사용합니다. 앱 이름·번들 ID·실행 파일·저장 폴더·로그인 항목·업데이트는 포크 전용으로 분리했습니다. 기본 세이브 위치는 `~/Library/Application Support/PokeTokenBarBattle`이며 최초 실행 시 원본 세이브가 있으면 읽어서 한 번 복사합니다. 개발 실행은 `PTB_STATE_DIR`로 별도 상태 폴더를 지정할 수 있습니다.

## 로컬 연습전 시험

1. `PTB_SKIP_INSTALL=1 PTB_NATIVE_ARCH_ONLY=1 ./scripts/build-app.sh`로 현재 맥용 번들을 만듭니다. `build/PokeTokenBar Battle.app`에 엔진과 라이선스가 들어갑니다.
2. 검증한 번들을 `/Applications/PokeTokenBar Battle.app`으로 복사해 실행합니다. 자동 설치는 별도 사용자 승인 후에만 수행합니다.
3. 메뉴바 팝오버 아래 **연습전**을 누르고 내 개체와 다른 보유 개체를 선택합니다. 출전 가능한 개체가 두 마리 필요합니다. 누락된 정보는 출전 보류 이유로 표시합니다.
4. **직접 조작**은 기술을 클릭합니다. 30초가 지나면 해당 턴을 자동 선택합니다. **자동 진행**은 양쪽을 정책 v1로 조종합니다. 전투 피해·결과는 육성 세이브에 기록하지 않습니다.
5. 실행 시 바로 창을 열려면 `open -a 'PokeTokenBar Battle' --args --practice`를 사용할 수 있습니다(앱이 이미 실행 중이면 메뉴바에서 여세요).

스프라이트와 이름 번역은 실행 중 내려받습니다. 오프라인이면 대체 그림/식별자를 표시합니다. 원본 앱 설치본·세이브를 덮어쓰지 않으며, 릴리스·공개 전환·서버 배포는 별도 작업입니다.

## 라이선스와 고지

**MIT** — [LICENSE](LICENSE). MIT 라이선스는 이 프로젝트의 원본 소스 코드에만 적용되며, 앱이 접근하는 제3자 상표·이미지·데이터에 대한 권리를 부여하지 않습니다.

PokeTokenBar Battle은 [PokeTokenBar](https://github.com/chattymin/PokeTokenBar)를 기반으로 한 **비공식·비상업 팬 프로젝트**입니다. Nintendo, Game Freak, Creatures Inc., The Pokémon Company와 관련이 없으며 이들의 승인·후원을 받지 않았습니다. "Pokémon"과 관련 이름·캐릭터·이미지는 각 권리자의 상표이자 저작물이며, 이 프로젝트는 Pokémon 지식재산에 대한 어떤 권리도 주장하지 않습니다.

PokeTokenBar Battle is an **unofficial, non-commercial fan project** based on PokeTokenBar. It is **not affiliated with, endorsed, sponsored, or approved by Nintendo, Game Freak, Creatures Inc., or The Pokémon Company.** "Pokémon" and all related names, characters, and imagery are trademarks and copyrights of their respective owners. This project claims no ownership of, and asserts no rights over, any Pokémon intellectual property.
