# PokeTokenBar Battle

회사 동료끼리 기존에 키운 포켓몬으로 자동 1:1 배틀을 하고, 승자가 패자의 출전 개체를 획득하는 macOS 앱 확장 프로젝트입니다.

**현재 상태: 원본 앱 소스와 승인된 작업계획서 준비 완료. 배틀 기능과 Cloudflare 서버는 아직 구현하지 않았습니다.**

## 다른 AI가 작업을 시작할 때

1. [AGENTS.md](AGENTS.md): 작업 규칙과 반드시 유지할 결정
2. [docs/AI_HANDOFF.md](docs/AI_HANDOFF.md): 현재 구현 상태, 기준 소스, 다음 작업
3. [docs/BATTLE_PLAN.md](docs/BATTLE_PLAN.md): 승인된 설계, 16개 PR, TDD·인수·무료 운영 검증 기준
4. [CLAUDE.md](CLAUDE.md): 기존 Swift 앱의 상세 기여·테스트 규칙

구현 요청을 받으면 **PR 01 — 실제 Cloudflare Free 환경의 전투 엔진 실행 검증**부터 시작합니다. 문서를 읽은 것만으로 배포나 구현 권한이 생기는 것은 아닙니다.

## 확정한 방향

- macOS 전용. 기존 육성 데이터와 개체를 가져와 사용합니다.
- 초대코드 + 회사 이메일 표시명으로 가입합니다. 로그인 화면과 이메일 인증은 추가하지 않습니다.
- 앱이 개인 접속키를 Keychain에 보관합니다. 이메일을 계정 소유 증명으로 사용하지 않습니다.
- 현재 레벨·기술·타입·특성을 반영하는 원작에 가까운 자동 배틀을 목표로 합니다.
- 패자의 정확한 한 개체를 승자에게 이전하고, 과거 도감 이력은 유지합니다.
- 마지막 개체를 잃으면 Lv5 이상해씨·파이리·꼬부기 중 한 마리를 선택합니다.
- Workers + D1 + SQLite 기반 Durable Objects의 **무료 플랜**을 사용합니다. 실제 호환성·사용량 검증은 아직 남아 있습니다.

## 기준 소스

| 항목 | 값 |
|---|---|
| 개인 저장소 | [dding94/poketokenbar-battle](https://github.com/dding94/poketokenbar-battle) — private |
| Upstream | [chattymin/PokeTokenBar](https://github.com/chattymin/PokeTokenBar) |
| 기준 태그 | `v2.5.6` |
| 기준 커밋 | `77f789d7ccf6e692c805f599abf7dcf0c834c56b` |
| 기존 기술 | Swift 6 · SwiftUI · macOS 14+ · Swift Package Manager |

기준 버전 소스와 Git 이력을 포함합니다. GitHub의 공개 fork 기능 대신 개인 비공개 저장소로 가져왔습니다. 원본 저작권과 [MIT LICENSE](LICENSE)를 보존하며, 기존 앱 설명은 [README.upstream.md](README.upstream.md)에 있습니다. upstream의 설치·릴리스 안내는 이 확장판의 배포 안내가 아닙니다.

## 현재 디렉터리

- `Sources/PokeTokenBar/`: 기존 macOS 앱
- `Tests/PokeTokenBarTests/`: 기존 테스트
- `scripts/`: 기존 빌드·테스트·릴리스 도구
- `docs/BATTLE_PLAN.md`: 제품·설계·작업 순서의 기준
- `docs/AI_HANDOFF.md`: 진행 상황과 다음 AI를 위한 인계
- `server/`: **아직 없음**. 무료 실행 검증 단계에서 추가할 예정

## 검증과 배포 상태

이번 준비 단계에서는 문서 링크·변경 범위·Git 추적 상태를 확인했습니다. Swift 빌드·테스트, 전투 엔진 성능 검증, Cloudflare 배포, 앱 설치·릴리스는 수행하지 않았습니다.

기존 앱 검증 명령은 `swift build`, `swift test`, `./scripts/test-gate.sh`입니다. 세부 범위와 새 서버용 예정 명령은 계획서를 따릅니다.

가져온 GitHub Actions는 초기에는 **수동 실행**만 허용합니다. private 저장소의 실행 가능량·과금 설정을 확인한 뒤 필요한 자동화를 결정합니다. `scripts/release.sh`와 `UpdateChecker.swift`는 아직 upstream 주소를 사용하므로 포크 대상·앱 식별·저장 경로를 분리하기 전에는 릴리스하거나 설치하지 않습니다.
