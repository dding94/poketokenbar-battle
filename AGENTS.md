# PokeTokenBattle — AI 작업 지침

이 저장소는 공개 저장소다. 현재 상태, 승인된 제품 결정, 작업 계획, 릴리스와 서버 운영 절차는 비공개 저장소 `dding94/poketokenbar-battle-private`에 둔다.

## 작업 시작

1. 비공개 저장소의 clone을 연다: `~/IdeaProjects/poketokenbar-battle-private`. 없으면 `gh repo clone dding94/poketokenbar-battle-private ~/IdeaProjects/poketokenbar-battle-private`로 받는다.
2. 그 저장소의 `AGENTS.md`를 읽고 따른다. 구현을 시작하기 전에 `docs/AI_HANDOFF.md`의 현재 상태를 확인한다.
3. 앱의 개발·테스트 규칙은 [CLAUDE.md](CLAUDE.md)를 따른다.

비공개 저장소를 읽을 수 없으면 추측으로 진행하지 말고 사용자에게 알린다.

## 공개 저장소에서 항상 지킬 것

- 커밋, PR 제목과 본문, 이슈, 릴리스 노트, 문서는 모두 공개된다. 작업 일지, 운영 수치, 배포 절차, 사람이나 소속을 드러내는 내용은 여기에 쓰지 않고 비공개 저장소에 기록한다.
- 커밋 전에 `git config user.name`과 `git config user.email`이 이 저장소 이력의 계정인지 확인한다. 새 clone에는 로컬 설정이 없어 그 맥의 전역 계정이 쓰일 수 있다.
- 비밀값, 실제 서버 주소, 초대코드, 경기 기록, 실제 세이브, 토큰 사용 로그를 커밋하지 않는다.
- 원본 라이선스와 저작자 표시, 비공식 팬 프로젝트 고지를 유지한다. 닌텐도 자산(스프라이트, 음악, ROM 유래 데이터)을 저장소에 넣지 않는다.
- PR 작성 요청에는 `.agents/skills/prepare-pr/SKILL.md`와 `.github/PULL_REQUEST_TEMPLATE.md`를 사용한다.
