# PokeTokenBar Battle

회사 동료끼리 기존에 키운 포켓몬으로 1:1 배틀을 하고, 쟁탈전에서는 승자가 패자의 출전 개체를 획득하는 macOS 앱 확장 프로젝트입니다.

**현재 상태: 원본 앱 소스와 승인된 작업계획서, 엔진 사전 실측 결과가 있습니다. 배틀 기능과 Cloudflare 서버는 아직 구현하지 않았습니다.**

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
- `engine/`, `server/`: **아직 없음**. PR 01과 PR 04에서 추가할 예정

## 검증과 배포 상태

전투 엔진의 결정성은 사전 실측으로만 확인했습니다(2,700판, Node와 JavaScriptCore 불일치 0건). 저장소 테스트·CI로 재현하는 작업, Swift 빌드·테스트, Cloudflare 배포, 앱 설치·릴리스는 아직 수행하지 않았습니다.

기존 앱 검증 명령은 `swift build`, `swift test`, `./scripts/test-gate.sh`입니다. 세부 범위와 새 엔진·서버용 예정 명령은 계획서를 따릅니다.

GitHub Actions는 public 전환 전까지 **수동 실행**만 허용합니다. `scripts/build-app.sh`, `scripts/release.sh`, `UpdateChecker.swift`는 아직 원본 앱 식별값과 upstream 주소를 사용합니다. 포크 대상·앱 식별·저장 경로를 분리하기 전(PR 00)에는 빌드 설치나 릴리스를 하지 않습니다. 특히 `build-app.sh`는 설치된 원본 `/Applications/PokeTokenBar.app`을 지우고 덮어씁니다.

## 라이선스와 고지

**MIT** — [LICENSE](LICENSE). MIT 라이선스는 이 프로젝트의 원본 소스 코드에만 적용되며, 앱이 접근하는 제3자 상표·이미지·데이터에 대한 권리를 부여하지 않습니다.

PokeTokenBar Battle은 [PokeTokenBar](https://github.com/chattymin/PokeTokenBar)를 기반으로 한 **비공식·비상업 팬 프로젝트**입니다. Nintendo, Game Freak, Creatures Inc., The Pokémon Company와 관련이 없으며 이들의 승인·후원을 받지 않았습니다. "Pokémon"과 관련 이름·캐릭터·이미지는 각 권리자의 상표이자 저작물이며, 이 프로젝트는 Pokémon 지식재산에 대한 어떤 권리도 주장하지 않습니다.

PokeTokenBar Battle is an **unofficial, non-commercial fan project** based on PokeTokenBar. It is **not affiliated with, endorsed, sponsored, or approved by Nintendo, Game Freak, Creatures Inc., or The Pokémon Company.** "Pokémon" and all related names, characters, and imagery are trademarks and copyrights of their respective owners. This project claims no ownership of, and asserts no rights over, any Pokémon intellectual property.
