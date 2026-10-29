# engine/ — 전투 엔진 (PR 01 진행 전)

양쪽 맥이 같은 입력으로 같은 결과를 계산하는 전투 엔진(`@pkmn/sim`, Pokémon Showdown 시뮬레이터 추출본)을
Swift 앱의 JavaScriptCore(`JSContext`)에서 실행하기 위한 폴더다. 설계는 [../docs/BATTLE_PLAN.md](../docs/BATTLE_PLAN.md)
§4·§6.3, PR 01, 부록 A(API 계약)를 따른다.

## 지금 있는 것

- `package.json`, `package-lock.json`: `@pkmn/sim` 0.10.12, `esbuild` 0.28.2 고정. 설치는 `npm ci --ignore-scripts`.
- `probe/`: 2026-10-29 사전 실측에 쓴 **연구용 프로토타입**이다. 검토된 제품 코드가 아니며 PR 01의 정식 어댑터·테스트로
  대체한다. 5세대(`gen5customgame`) 규칙으로 작성됐다. 채택한 규칙은 9세대·테라스탈 금지라서 PR 01에서 다시 검증해야 한다.

## 아직 없는 것

- PR 01의 정식 어댑터(`PTBEngine` API 계약 구현), `dist/battle-engine.js` 번들과 해시, `npm test` 계약 테스트,
  9세대 결정성 코퍼스, 기술 커버리지 검사. `scripts/build-app.sh`는 `dist/battle-engine.js`가 있으면 앱 리소스로 복사한다.

## 프로브 재현

```sh
cd engine
npm ci --ignore-scripts
npm run probe        # 번들 → 2,500판 코퍼스 → Node 실행 → JavaScriptCore 실행 → 비교
```

`probe/out/`은 Git에 넣지 않는다(코퍼스·로그 수십 MB). JavaScriptCore 실행에는 `swiftc`(Command Line Tools로 충분)가 필요하다.

2026-10-29 저장소 위치에서 다시 실행한 결과(macOS 26.5, Node 24.14.0, Swift 6.3.2):

| 항목 | 결과 |
|---|---|
| 무작위 5세대 1:1 | 2,500판, Node와 JavaScriptCore의 로그·승자·inputLog 불일치 0 |
| inputLog 재생 | Node·JSC 모두 실패 0 |
| 3턴 시점 상태 직렬화 왕복 | Node·JSC 모두 실패 0 (`--keep-names` 빌드) |
| 번들 | 최소화 + `--keep-names` 약 6.6MB |

## 지켜야 할 발견

- **최소화할 때 `--keep-names`가 필수다.** Showdown `sim/state.js`는 객체 참조를 `obj.constructor.name`으로 기록한다.
  이름을 바꾸는 최소화 빌드에서는 상태 직렬화 왕복이 100판 중 65판에서 어긋났다(전투 결과 해시 자체는 같았다).
  재접속 복원은 inputLog 재생을 기본으로 하고, 상태 직렬화를 쓰면 이 조건을 테스트로 고정한다.
- **`|t:|` 줄은 실제 시각이다.** 결과 해시 전에 뺀다.
- **`probe/adapter.js`의 `replay()`는 inputLog를 `BattleStream`에 그대로 넣는다.** 이 스트림은 `>eval`도 받으므로
  자기 앱이 만든 기록에만 쓴다. 상대에게 받은 기록·중계 텍스트는 검증한 선택 토큰으로만 다시 구성한다.
- **JIT:** macOS 26.5에서 `JSContext`의 JIT는 `com.apple.security.cs.allow-jit` entitlement로 서명해야 켜졌다
  (`probe/jit.entitlements`, 앱은 `scripts/battle.entitlements`). 없으면 경기당 약 8ms로 느려질 뿐 결과는 같다.
