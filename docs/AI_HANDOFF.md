# 다음 AI를 위한 작업 인계

최종 갱신: 2026-10-29. **저장소 준비 단계이며 배틀 기능은 아직 구현하지 않았다.**

## 지금 있는 것

- 개인 프로젝트: `dding94/poketokenbar-battle` (private).
- 원본 Swift 앱과 테스트, Git 이력: `chattymin/PokeTokenBar`의 `v2.5.6`.
- 기준 commit: `77f789d7ccf6e692c805f599abf7dcf0c834c56b`.
- 승인된 제품 결정·검증 기준·16개 작업 단위: [BATTLE_PLAN.md](BATTLE_PLAN.md).
- 에이전트 진입점: [../AGENTS.md](../AGENTS.md), Claude 진입점: [../CLAUDE.md](../CLAUDE.md).
- 기준 앱의 문서: [../README.upstream.md](../README.upstream.md), 상세 규칙: `docs/reference/`.

제품 요구사항을 인터뷰하고 설계를 승인받았다. 추가된 것은 프로젝트 문서와 포크용 작업 안내·CI 실행 설정이다. `Sources/`, `Tests/`, `Package.swift`, 기존 스크립트와 `LICENSE`는 기준 소스를 유지한다.

## 아직 없는 것 / 검증하지 않은 것

- `server/`, Cloudflare 리소스·자격 증명·배포 URL, battle schema와 API.
- 배틀 엔진·소유권 이전·새 스타터 지급·그룹 화면.
- 배포 환경에서의 Showdown 호환성·무료 한도 성능 검증.
- 이 포크의 Swift 빌드·테스트·앱 실행·설치 확인.
- 포크용 앱 이름·번들 ID·저장 디렉터리·실행 잠금·업데이트 채널의 실제 변경.
- 실제 GitHub 기능 PR. 계획서의 PR 01~16은 앞으로 수행할 작업 단위다.

REA 설치본 버전 확인은 수행했지만, 바이너리와 소스의 재현 빌드 일치나 전투 실행을 증명하지 않는다. REA Evidence ID는 이전 조사 세션의 참조이며 새 AI 세션에서 조회 가능하다고 가정하지 않는다. 구조 근거는 기준 소스에서 직접 확인할 수 있다.

## 다음 작업: PR 01

사용자가 구현을 지시한 경우 다음 순서로 진행한다.

1. 실제 체크아웃·작업 상태·remote·기준 commit을 확인한다. 사용자의 다른 변경을 보존한다.
2. `BATTLE_PLAN.md` §1, §2, §7, PR 01을 읽는다.
3. 별도 `server/`에서 고정 전투 입력·seed·기대 결과 계약 테스트부터 만든다.
4. Showdown의 **시뮬레이터 라이브러리만** 도입하고 패키지 버전·commit·데이터 해시를 고정한다. 공개 Showdown 서버에 경기 데이터를 보내지 않는다.
5. Cloudflare Free의 Workers + SQLite DO에서 실행 가능한 번들을 만든다. 호환성 실패를 무시하거나 항상 성공하는 대역으로 실측을 대체하지 않는다.
6. 원격 검증이 요청 범위에 포함되어 있으면 계정의 실제 Free 플랜·기존 합산 사용량·대상 리소스를 확인한 뒤 검증 배포한다. 필요한 인증은 해당 도구의 정상 절차로 처리한다.
7. 실제 CPU·메모리·시작 시간·사용량과 고정 결과 일치를 검증하고 기록한다. 무료 조건을 만족하지 못하면 후속 기능 확대 전에 결과와 대안을 사용자에게 알린다.
8. 통과하면 사용자가 요청한 구현 범위 안에서 PR 02 이후 의존 순서를 따른다.

**30명·하루 100경기와 로그 용량 예시는 부하 가정이며 실측값이 아니다.** 무료 운영 판정 항목과 수치 목표는 계획서 §7에 있다. 새 서버용 `npm run ...` 명령도 현재 존재하지 않으며 초기 작업에서 정의할 인터페이스다.

## 사용자 결정을 다시 묻지 않을 것

- 기존 개체를 사용하고 로컬 육성을 유지한다. 온라인 소유권은 서버가 관리한다.
- 로그인 화면을 원하지 않는다. 회사 이메일은 닉네임처럼 받는 표시값이다. 이메일 인증·Google/Microsoft 로그인으로 확대하지 않는다.
- 원작에 가까운 자동 배틀과 실제 레벨을 사용한다. 무료 실행 검증이 먼저다.
- 승자는 패자의 정확한 출전 개체를 가져간다. 과거 도감 기록은 남긴다.
- 마지막 개체도 걸 수 있고, 전멸하면 Lv5 스타터 한 마리를 선택한다.
- 서버 운영비 0원이 중요하다. 회사 IP나 개인 맥북을 서버로 쓰는 안은 채택하지 않았다.

제품 규칙을 바꿔야 하는 구체적인 구현 문제가 발견되면 그 영향과 대안을 설명한다. 복구코드나 접속키는 이메일과 다른 역할이며, 개인정보·키 원문은 로그나 Git에 남기지 않는다.

## 핵심 코드 진입점

| 경로 | 확인할 내용 |
|---|---|
| `Sources/PokeTokenBar/Core/PokemonProfile.swift` | instanceID·IV·레벨·특성·기술, `black-2-white-2`, 능력치 계산 |
| `Sources/PokeTokenBar/Core/CompanionModel.swift` | active·dex·놓아준 이력·완전한 육성 상태 |
| `Sources/PokeTokenBar/Core/CompanionStore.swift` | 저장·졸업·개체 선택·합성 UI ID |
| `Sources/PokeTokenBar/Core/SaveTransfer.swift` | 세이브 가져오기·복원 |
| `Sources/PokeTokenBar/Core/PokeAPIClient.swift` | 현재 폼·종족값·특성·기술 메타데이터 |
| `Sources/PokeTokenBar/UI/PopoverView.swift` | 배틀 진입점 |
| `Sources/PokeTokenBar/UI/CompanionView.swift` | 개체별 선택·상세 |
| `scripts/test-gate.sh` | 기존 Swift 전체 테스트와 코어 커버리지 |

`DexEntry`에는 놓아준 과거 기록도 있다. 이를 현재 소유 목록으로 삼지 않는다. 가져온 미성숙 개체를 다시 키우려면 `MonState`의 전체 진화·성장 상태를 이전해야 한다. UI용 합성 ID는 진화에 따라 바뀔 수 있다.

## 실행·배포 시 미확정 사항

- 원본 세이브와 별개의 앱 식별·저장·실행 잠금·업데이트 경로.
- Cloudflare 계정·Free 사용량·개발 및 운영 리소스 이름.
- 포크 배포와 설치 방법, 실제 두 대의 검증 맥.

`scripts/release.sh`의 `REPO`·`TAP_REPO`, `UpdateChecker.swift`의 원본 저장소·Homebrew·login label을 먼저 확인한다. 원본 앱의 배포 스크립트를 이 저장소용으로 검증했다고 가정하지 않는다. 이번 GitHub 저장소 준비는 앱 릴리스가 아니다.

## 이후 기록 방식

- 계획의 체크박스는 실제 작업·테스트 증거가 있을 때 갱신한다.
- 이 문서에 마지막 완료 작업, 다음 작업, 실제 검증 명령과 결과, 알려진 제약을 짧게 유지한다.
- 미래 AI가 사용할 설명은 저장소 상대 경로로 작성한다. 이전 대화나 개인 컴퓨터의 다른 프로젝트에 의존하지 않는다.
- 커밋 작성자 설정은 저장소 로컬 설정을 따른다. Git 작성자 이메일과 제품의 이메일 표시명 정책은 별개다.

## 다른 AI에게 전달할 요청 예시

```text
이 저장소의 AGENTS.md와 docs/AI_HANDOFF.md, docs/BATTLE_PLAN.md를 읽어줘.
승인한 계획의 PR 01 무료 전투 엔진 검증을 TDD로 진행해줘.
Cloudflare 원격 검증에 필요한 계정·배포 대상은 준비한 변경과 함께 알려줘.
월 0원 조건과 로그인 화면 없는 초대코드 + 이메일 표시명 방식을 유지해줘.
```

이 예시는 다음 구현 요청을 작성하기 위한 것으로, 저장소 준비 단계에서 구현이나 배포를 실행하라는 지시가 아니다.
