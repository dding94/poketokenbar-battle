# 전투 엔진

`@pkmn/sim` **0.10.12**, esbuild **0.28.2**를 고정한다. 제품 계약은
[부록 A](../docs/BATTLE_PLAN.md#부록-a-전투-엔진-api-계약-pr-01-초안), 실제 검증 상태는
[AI_HANDOFF](../docs/AI_HANDOFF.md)에 기록한다. `probe/`는 5세대 연구 자료이며 제품 코드가 아니다.

```sh
cd engine
npm ci --ignore-scripts
npm test                 # 번들 생성 + 계약
npm run corpus           # 2,000 무작위 + 200 장기전, Node ↔ Swift JSContext
npm run compatibility    # 고정 PokéAPI 참조 다운로드 → 541개 기술·649종·106개 폼 대조
```

`dist/battle-engine.js`, SHA-256 파일, Swift `BattleEngineManifest.swift`를 함께 생성·커밋한다.
앱은 해시가 맞는 번들만 실행한다. 최소화의 **keepNames: true는 필수**다.
Showdown 상태 직렬화가 생성자 이름을 참조한다. 학습·합법성 데이터만 번들에서 제거하며,
명시적으로 전달받은 기술로 전투한다. 제거 전후 2,200판 결과가 같은지 검사했다.
`PTB_FULL_ENGINE=1 npm run corpus:generate`로 전체 데이터 비교용 번들을 만들 수 있다.

입출력은 동기 JSON 문자열이다. `createBattle(JSON.stringify(config))`가 반환한 id 역시
`request(JSON.stringify(id), JSON.stringify('p1'))`처럼 JSON 인자로 전달한다.
`inputLog`는 `{version:2,policyVersion:"auto-v2",config,choices:[{side,choice}]}` 객체다. `replay`는 이 구조와
모든 선택을 다시 검증한다. 시뮬레이터 명령 스트림을 받지 않는다. 로그의 플레이어 이름은
결과의 일관성을 위해 p1/p2로 고정하고, 앱이 화면용 이름을 표시한다.

9세대, 테라스탈 금지, 도구 없음, EV 0, 실제 레벨/IV/성격, 200턴 무승부다.
도구 의존 폼(기라티나·아르세우스·게노세크트), 날씨/전투 중 변하는 폼은 기본 폼에서 시작한다.
외형 폼은 기본 데이터로, 데오키스·로토무 등 독립 전투 폼은 해당 9세대 데이터로 매핑한다.
출전 화면은 실제 적용되는 종·타입·능력치를 보여 줘야 한다.

자동 선택 v1은 위력·자속·상성·명중률을 곱하고 변화기는 낮은 우선순위로 평가한다.
동점은 전투 RNG와 분리한 policySeed/턴/진영으로 결정한다. v2(`auto-v2`)는 진영마다 `policy`로
`standard`(v1과 같음)·`aggressive`·`tactical`·`erratic` 성향을 고른다(부록 A).
`tests/reference/policy-auto-v1.js`는 v1 원본 정책이다. `standard`가 같은 선택을 하는지 비교하는 기준이라
고치지 않는다(테스트가 SHA-256을 고정한다). 최초 기술·특성 공개는 drainEvents로 받는다.
봉인 등 숨은 정보로 선택이 거절되면 갱신된 요청으로 재선택한다. 코퍼스는 이 경계와
첫 선택 직후 상태 복원을 포함한다. 단순 기술 호출 검사는 모든 조건별 효과를 증명하지 않는다.

공개 참조 데이터는 `.cache/`, 실행 결과는 `out/`에만 저장하며 Git에서 제외한다.
개인 세이브·사용량 로그를 읽지 않는다. `LICENSE.pokemon-showdown`은 번들과 함께 앱에 포함한다.
