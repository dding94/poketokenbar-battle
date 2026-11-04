---
summary: "포크 릴리스 준비·검증·별도 승인 게시 절차. 원본 설치/tap/Pages를 사용하지 않는다."
read_when:
  - 릴리스를 준비하거나 게시할 때
  - release.sh의 문서·에셋·식별·서명 게이트에 막혔을 때
---

# PokeTokenBar Battle 릴리스 절차

명령과 승인 경계의 기준은 [RELEASE.md](../../RELEASE.md)다. 이 포크의 공개 버전·실제 서명 신원·게시 대상은 아직 별도 확인이 필요하다. PR 12 ad-hoc 개발 ZIP은 공개 릴리스가 아니다.

1. `./scripts/release.sh --check-only`로 로컬 포크 식별값과 커밋된 문서/이미지 변경을 확인한다. 종료 1/2를 무시하거나 통과로 보고하지 않는다. 0도 실제 두 맥·Free 운영·서명 신뢰·tap 존재를 확인했다는 뜻은 아니다.
2. 영어 노트 템플릿의 New / Fixed / Other / Contributors와 Install / Upgrade를 채우고 포함 PR/직접 커밋의 실제 외부 기여자를 대조한다. `PTB_NOTES_FILE`, `PTB_CONTRIBUTORS_FILE`을 전달해 `--prepare <version>`을 실행한다. 이 경로는 feature 브랜치에서 사용할 수 있으며 빌드·서명·GitHub 조회·설치·키 생성·tracked 버전 변경·commit/push/tag·Release/tap/Pages 변경을 하지 않는다.
3. 사용자가 로컬 릴리스 빌드를 요청한 경우에만 기존 승인 인증서 이름과 공개 leaf SHA-1을 `CODESIGN_IDENTITY`, `PTB_EXPECTED_LEAF`로 지정해 `--prepare-build <version>`을 쓴다. `PTB_CI_RUN_ID`로 선택한 GitHub CI의 읽기 전용 실검증, 설치 없는 universal 빌드, 포크 bundle/LaunchAgent/설치 경로·버전·각 arch의 minOS 15.0·strict signature·실제 공개 인증서 leaf·JIT·엔진 해시를 검사한다. 결과는 `build/release/PokeTokenBarBattle.zip`과 실제 ZIP SHA-256이 든 cask preview다. tracked VERSION은 바꾸지 않는다. 이 경로는 GitHub 조회가 필요하며 로컬 test-gate/OCR/네이티브 Worker를 실행하지 않는다. 선택한 실행의 fork 저장소·CI workflow·정확한 HEAD·동일 실행 attempt와 필수 8개 job/step 성공, 해당 rest job 로그의 지정된 네이티브 3건 실제 통과·skip 0을 확인한다. 이전 SHA·일부 scope 실행·job/step skip·로그 만료·API 실패는 서명/빌드 전 차단한다. 전체 실행은 통합 소스를 커밋한 뒤 `gh workflow run ci.yml --ref <branch> -f scope=all`로 요청하고 완료를 기다려 실제 성공 ID를 사용한다. release 스크립트 자체는 CI를 실행 요청하지 않는다. all scope는 양쪽 macOS를 모두 검사한다. 기존 opt-in skip은 여전히 미검증이다. tracked 수정/미추적 소스 입력은 거절하며 무관한 생성 build/log는 허용한다. 실패한 재빌드는 이전 ZIP/preview를 지워 낡은 결과를 현재 결과로 오인하지 않게 한다.
4. README.md/ko/ja의 요구사항·현재 상태·이미지 참조와 새 화면의 실제/명시된 합성 이미지를 검토한다. 원본 릴리스 링크는 출처·형식 참조에만 사용하며 설치 명령으로 사용하지 않는다. 포크 랜딩이 확정되지 않은 상태에서 upstream gh-pages를 수정/푸시하거나 새 리소스를 만들지 않는다.
5. 버전, 노트 요약, 정확한 ZIP/hash, 서명 종류, 게시 대상, 기존 fork tap/cask와 남은 인수 결과를 보여준 뒤 외부 게시를 별도로 승인받는다. 자체 서명은 Developer ID/공증이나 Gatekeeper/회사 정책 통과를 증명하지 않는다. 인증서 재생성으로 승인 문제를 해결하지 않는다.

게시 형식 `release.sh <version>`은 `PTB_FORK_RELEASE_READY=1`, 깨끗한 main, 사전 검증된 노트/서명 및 기존 포크 cask와 동일한 exact-HEAD CI 증거를 요구한다. tap이 없거나 fork URL/checksum/macOS15/app 템플릿과 다르면 빌드 전에 차단한다. 빌드도 항상 `PTB_SKIP_INSTALL=1`이며 성공 후에만 tracked 버전 변경→commit/push→GitHub Release→동일 ZIP 기반 cask 버전/SHA 갱신을 수행한다. tap 생성·Pages 변경은 하지 않는다. 이 경로를 준비 작업 중 실행하지 않는다.

설치/업그레이드와 실제 복구 시험은 별도 승인 범위다. fork 앱과 `PokeTokenBarBattle` 상태를 비공개로 백업하고 원본 `/Applications/PokeTokenBar.app`을 교체하지 않는다. 구체적인 백업/rollback 대상과 두 맥·무료 한도·복구 미검증 범위는 RELEASE.md와 기존 AI_HANDOFF/BATTLE_PLAN에서 추적한다. 공개/설치가 안 된 상태에 미래 Homebrew 명령을 지금 사용할 수 있는 것처럼 안내하지 않는다.
