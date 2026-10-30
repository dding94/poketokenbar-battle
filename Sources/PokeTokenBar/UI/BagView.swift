import SwiftUI

/// 가방(인벤토리) — 소유 아이템 카드 + 사용. 빈 상태는 움직이는 잠만보(컬렉션의 피카츄 패턴).
@MainActor
struct BagView: View {
    let store: CompanionStore
    let nav: PopoverNavigation
    /// false 면 아이템 아이콘을 이모지로만 그린다(네트워크 없음) — 연습 화면의 `artwork: false` 와 같은 뜻, 테스트용.
    var artwork = true
    /// 마지막으로 쓴 배틀 아이템의 결과(회복 후 체력·재추첨한 개체값, PR 03C) — 닫거나 가방을 떠날 때까지 맨 위에.
    /// 그 종류의 마지막 하나를 쓰면 카드가 목록에서 사라지므로 결과는 카드 밖에 둔다.
    @State private var feedback: BattleItemFeedback?

    var body: some View {
        if store.ownedItems.isEmpty && feedback == nil {
            emptyState
        } else {
            // 고정 높이 — 컬렉션과 동일(팝오버 재오픈 시 fitting size 축소 방지).
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if let feedback {
                            BattleItemFeedbackCard(feedback: feedback, l: store.l) { self.feedback = nil }
                                .id(Self.feedbackID)
                        }
                        ForEach(store.ownedItems, id: \.kind) { item in
                            ItemCard(store: store, nav: nav, kind: item.kind, count: item.count) { feedback = $0 }
                        }
                    }
                    .reservesScrollerLane()
                }
                .frame(height: 520)
                // 결과가 화면 밖(목록 아래쪽 카드에서 사용)이어도 보이게 맨 위로. 애니메이션 없이 바로 옮긴다.
                .onChange(of: feedback) { _, new in
                    if new != nil { proxy.scrollTo(Self.feedbackID, anchor: .top) }
                }
            }
        }
    }

    private static let feedbackID = "battle-item-feedback"

    /// 빈 가방 — 움직이는 잠만보(143) + 안내(특정 아이템명 미언급, 확장 대비).
    private var emptyState: some View {
        VStack(spacing: 10) {
            SpriteView(speciesID: 143, size: 96, animated: true)   // 잠만보(움직임)
            Text(store.l.bagEmptyTitle)
                .font(.callout.weight(.semibold))
            Button(store.l.shop) { nav.tab = .shop }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }
}

/// 아이템 1장 — 아이콘·이름·개수·설명 + 인라인 확인 사용.
/// 확인은 인라인(버튼 morph) — .sheet/.alert 금지: transient 팝오버가 닫힐 때 고아 시트가
/// 이후 클릭을 먹통내는 기존 결함(PopoverView 주석) 회피.
@MainActor
private struct ItemCard: View {
    let store: CompanionStore
    let nav: PopoverNavigation
    let kind: ItemKind
    let count: Int
    /// 배틀 아이템을 쓴 결과를 가방 맨 위로 넘긴다(PR 03C).
    let onBattleItemUsed: (BattleItemFeedback) -> Void
    @State private var confirming = false
    @State private var candyCount = 1
    /// 개체값 재추첨 확인 단계 — 지금 개체값을 보여 주는 동안의 값.
    @State private var rerollFrom: PokemonIVs?

    /// 배틀 아이템 4종인지 — 현재 포켓몬의 체력·개체값에 따라 쓸 수 있는지가 갈린다.
    private var isBattleItem: Bool { [.potion, .hyperPotion, .revive, .ivReroll].contains(kind) }
    private var isHealing: Bool { [.potion, .hyperPotion, .revive].contains(kind) }
    private var battleUse: BattleItemUse { BattleItemUse(kind, count: count, healthShare: store.currentHealthShare) }

    private var selectedCandyCount: Int { min(candyCount, max(1, store.maxRareCandyUseCount)) }

    var body: some View {
        let l = store.l
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                ItemIconView(kind: kind, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(l.itemName(kind)).font(.callout.weight(.semibold))
                        if !kind.isPassive {   // 보유형은 개수 개념이 없음(1회 구매·영구)
                            Text("×\(count)").font(.caption.weight(.bold))
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                        Spacer(minLength: 4)
                        if kind == .rareCandy, store.canUseRareCandy {
                            Stepper(value: $candyCount, in: 1...max(1, store.maxRareCandyUseCount)) {
                                Text("×\(selectedCandyCount)").font(.callout.weight(.semibold)).monospacedDigit()
                            }
                            .fixedSize()
                            .accessibilityLabel(l.itemName(.rareCandy))
                            .accessibilityValue("\(selectedCandyCount)")
                        }
                    }
                    Text(l.itemDescription(kind))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // 회복약은 지금 포켓몬의 체력을 같이 보여 준다 — 왜 못 쓰는지(가득 참·기절)가 막대로 읽힌다.
            if isHealing, let share = store.currentHealthShare {
                HStack(spacing: 6) {
                    Text(l.battleHP).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    BattleHealthLine(share: share, l: l)
                    Spacer(minLength: 0)
                }
            }
            if kind == .rareCandy, let preview = store.planRareCandyUse(count: selectedCandyCount) {
                if preview.graduates {
                    Text(l.candyGraduates).font(.caption2).foregroundStyle(.secondary)
                }
                if preview.discardedXP > 0 {
                    Text(l.candyDiscardedXP(TokenFormatter.compact(preview.discardedXP)))
                        .font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                } else if preview.evolves && !preview.graduates {
                    Text(l.candyCarryoverXP(TokenFormatter.compact(preview.carryoverXP)))
                        .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            useControls(l)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onChange(of: store.maxRareCandyUseCount) { _, _ in
            candyCount = selectedCandyCount
        }
    }

    /// 이 아이템을 지금 쓸 수 있나 (kind 별 — 사탕은 라인 로딩 필요, 민트는 활성 포켓몬만).
    private var canUse: Bool {
        switch kind {
        case .rareCandy: return store.canUseRareCandy
        case .mint:      return store.canUseMint
        case .shinyCharm: return false   // 보유형 — 사용 개념 없음(상시 효과)
        // 회복약은 체력에 맞을 때만, 재추첨은 부화한 포켓몬이면(`BattleItemUse`, Core 의 사용 규칙과 같은 판정).
        case .potion, .hyperPotion, .revive, .ivReroll: return battleUse == .usable
        }
    }
    /// 사용 컨트롤 효과 힌트 ("+XP" / "성격 랜덤 변경" / "체력 +50%").
    private func effectHint(_ l: L) -> String {
        switch kind {
        case .rareCandy: return "+\(TokenFormatter.compact(selectedCandyCount * RareCandy.xp)) XP"
        case .mint:      return l.mintEffectHint
        case .shinyCharm: return l.shinyCharmEffectHint
        case .potion, .hyperPotion, .revive, .ivReroll: return l.battleItemEffectHint(kind)
        }
    }
    private func performUse() {
        switch kind {
        case .rareCandy: _ = store.useRareCandy(count: selectedCandyCount)
        case .mint:      _ = store.useMint()
        case .shinyCharm: break   // 보유형 — 사용 동작 없음
        case .potion, .hyperPotion, .revive:
            // 현재 포켓몬에게 — 결과(남은 체력)는 가방 맨 위에 남긴다.
            guard let id = store.currentInstanceID, store.useHealingItem(kind, on: id) else { return }
            onBattleItemUsed(.healed(kind, share: store.currentHealthShare ?? 1))
        case .ivReroll: break     // 확인 패널(`IVRerollPanel`)이 지금 개체값을 보여 준 뒤 `reroll(from:)` 로 쓴다
        }
    }
    /// 재추첨 확정 — 새 개체값을 가방 맨 위에 보여 준다. 쓸 수 없었으면(nil) 아무것도 바뀌지 않는다.
    private func reroll(from current: PokemonIVs) {
        rerollFrom = nil
        guard let new = store.useIVReroll() else { return }
        onBattleItemUsed(.rerolled(old: current, new: new))
    }

    @ViewBuilder
    private func useControls(_ l: L) -> some View {
        if kind.isPassive {
            // 보유형(이로치 부적) — 사용 버튼 대신 상시 효과 표시.
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill").font(.caption2).foregroundStyle(.green)
                Text(l.shinyCharmEffectHint).font(.caption2.weight(.semibold)).foregroundStyle(.green)
                Spacer()
            }
        } else if kind == .ivReroll, canUse, let current = rerollFrom {
            // 재추첨 확인 — 지금 개체값 6개와 "더 낮아질 수 있음"을 보여 준 뒤에만 쓴다.
            IVRerollPanel(stage: .confirm(current: current), l: l,
                          onReroll: { reroll(from: current) }, onCancel: { rerollFrom = nil }, onDone: {})
        } else if canUse {
            if confirming {
                HStack(spacing: 8) {
                    Text(l.useOnCurrent(store.displayName))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button(kind == .rareCandy ? "\(l.use) ×\(selectedCandyCount)" : l.use) { useNow() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    Button(l.cancel) { confirming = false }
                        .buttonStyle(.borderless).controlSize(.small)
                }
            } else {
                HStack {
                    Text(effectHint(l))
                        .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                    Spacer()
                    Button(l.useItem) {
                        // 재추첨은 인라인 확인 대신 지금 개체값을 보여 주는 확인 패널로.
                        if kind == .ivReroll { rerollFrom = store.currentIVs } else { confirming = true }
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
            }
        } else if isBattleItem, let reason = battleUse.reason(l, isEgg: store.isEgg) {
            // 배틀 아이템 — 지금 포켓몬의 체력 때문에 못 쓰는 이유를 말한다(체력 가득·기절·기절 아님).
            HStack {
                Text(l.battleItemEffectHint(kind)).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                Spacer(minLength: 6)
                Text(reason).font(.caption2.weight(.medium)).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
        } else {
            // 알(부화 전)/활성 없음/(사탕만)라인 미로딩 — 비활성 + 사유
            Text(store.isEgg ? l.useAfterHatch : l.useNeedsPokemon)
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    /// 사용 → 사탕·민트는 Home 탭으로 전환(진화/졸업 연출·"+XP"·성격 변경 토스트는 Home 의 CompanionHeader 에서 재생).
    /// 배틀 아이템은 가방에 남는다 — 결과(남은 체력·새 개체값)를 가방 맨 위에서 보여 준다.
    private func useNow() {
        confirming = false
        performUse()
        if !isBattleItem { nav.tab = .home }
    }
}
