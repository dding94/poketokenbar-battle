import SwiftUI

/// 가방(인벤토리) — 소유 아이템 카드 + 사용. 빈 상태는 움직이는 잠만보(컬렉션의 피카츄 패턴).
@MainActor
struct BagView: View {
    let store: CompanionStore
    let nav: PopoverNavigation
    /// false 면 아이템 아이콘을 이모지로만 그린다(네트워크 없음) — 연습 화면의 `artwork: false` 와 같은 뜻, 테스트용.
    var artwork = true
    /// 이 아이템 카드의 대상 목록을 연 채로 시작한다 — 렌더 테스트용.
    var openPickerFor: ItemKind?
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
                            BattleItemFeedbackCard(feedback: feedback, l: store.l, artwork: artwork) { self.feedback = nil }
                                .id(Self.feedbackID)
                        }
                        ForEach(store.ownedItems, id: \.kind) { item in
                            ItemCard(store: store, nav: nav, kind: item.kind, count: item.count, artwork: artwork,
                                     picking: openPickerFor == item.kind) {
                                feedback = $0
                            }
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

    /// 대상을 고르는 아이템을 지금 아무에게도 못 쓰는 이유. 누구 하나에게라도 쓸 수 있으면 nil.
    /// 판정은 스토어의 것(`itemVerdict`, 실제 사용과 같은 규칙) — 배틀 중이 먼저, 그다음 체력. 보유 포켓몬이 없을 때만
    /// 알·프로필 사유를 말한다(알을 키우는 중에도 졸업한 포켓몬은 아이템을 받을 수 있다).
    static func battleItemReason(_ kind: ItemKind, store: CompanionStore) -> String? {
        let l = store.l
        let individuals = store.ownedIndividuals
        guard !individuals.isEmpty else { return store.isEgg ? l.useAfterHatch : l.useNeedsPokemon }
        let verdicts = individuals.map { store.itemVerdict(kind, on: $0.id) }
        if verdicts.contains(.usable) { return nil }
        let first = [HealingItemVerdict.inBattle, .needsRevive, .hpFull, .notFainted].first(where: verdicts.contains)
        return first?.reason(l)
    }

    /// 대상 목록에서 고른 개체에게 아이템을 쓴다(재추첨은 확인 패널을 거쳐 `IVRerollPanel` 쪽에서).
    /// 결과는 **그 개체의** 값으로 만든다 — 현재 포켓몬의 체력을 읽으면 다른 개체를 고쳐 놓고 엉뚱한 값을 보여 준다.
    /// 현재 포켓몬에게 쓴 민트는 nil: 그 결과는 홈의 반짝임이 보여 준다.
    static func use(_ kind: ItemKind, on target: OwnedIndividual, store: CompanionStore) -> BattleItemFeedback? {
        switch kind {
        case .potion, .hyperPotion, .revive:
            guard store.useHealingItem(kind, on: target.id) else { return nil }
            return .healed(kind, name: target.name, share: store.healthShare(of: target.id))
        case .mint:
            guard let nature = store.useMint(on: target.id), !target.isCurrent else { return nil }
            return .natureChanged(name: target.name, nature: nature)
        case .rareCandy, .shinyCharm, .ivReroll:
            return nil
        }
    }

    /// 빈 가방 — 움직이는 잠만보(143) + 안내(특정 아이템명 미언급, 확장 대비).
    private var emptyState: some View {
        VStack(spacing: 10) {
            if artwork {
                SpriteView(speciesID: 143, size: 96, animated: true)   // 잠만보(움직임)
            } else {
                Image(systemName: "bag").font(.system(size: 40)).foregroundStyle(.tertiary).frame(width: 96, height: 96)
            }
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
    /// false 면 아이콘을 이모지로만(`BagView.artwork`).
    let artwork: Bool
    /// 대상 목록이 열려 있다.
    @State var picking: Bool
    /// 대상 목록의 아이템을 쓴 결과를 가방 맨 위로 넘긴다(PR 03C).
    let onBattleItemUsed: (BattleItemFeedback) -> Void
    @State private var confirming = false
    @State private var candyCount = 1
    /// 개체값 재추첨 확인 단계 — 지금 개체값을 보여 주는 동안의 대상.
    @State private var rerollTarget: OwnedIndividual?

    /// 보유 포켓몬 중에서 대상을 고르는 아이템. 이상한 사탕은 현재 포켓몬의 성장에만 쓰이므로 대상을 고르지 않고,
    /// 이로치 부적은 보유형이라 쓰는 동작이 없다(`CompanionStore.itemVerdict`).
    private var choosesTarget: Bool { [.potion, .hyperPotion, .revive, .mint, .ivReroll].contains(kind) }
    private var targets: [ItemTarget] { store.itemTargets(kind) }
    private var usableTargetCount: Int { targets.filter { $0.verdict == .usable }.count }

    private var selectedCandyCount: Int { min(candyCount, max(1, store.maxRareCandyUseCount)) }

    var body: some View {
        let l = store.l
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                ItemIconView(kind: kind, size: 30, artwork: artwork)
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

    /// 사용 컨트롤 효과 힌트 ("+XP" / "성격 랜덤 변경" / "체력 +50%").
    private func effectHint(_ l: L) -> String {
        switch kind {
        case .rareCandy: return "+\(TokenFormatter.compact(selectedCandyCount * RareCandy.xp)) XP"
        case .mint:      return l.mintEffectHint
        case .shinyCharm: return l.shinyCharmEffectHint
        case .potion, .hyperPotion, .revive, .ivReroll: return l.battleItemEffectHint(kind)
        }
    }
    /// 고른 대상에게 쓴다. 재추첨은 지금 개체값을 보여 주는 확인 패널을 먼저 거친다.
    /// 현재 포켓몬에게 쓴 민트는 지금까지처럼 홈으로 가서 반짝임을 본다. 나머지 결과는 가방 맨 위에 남는다.
    private func use(_ target: OwnedIndividual) {
        if kind == .ivReroll { rerollTarget = target; return }
        picking = false
        if let feedback = BagView.use(kind, on: target, store: store) {
            onBattleItemUsed(feedback)
        } else if kind == .mint, target.isCurrent {
            nav.tab = .home
        }
    }
    /// 재추첨 확정 — 새 개체값을 가방 맨 위에 보여 준다. 쓸 수 없었으면(nil) 아무것도 바뀌지 않는다.
    private func reroll(_ target: OwnedIndividual) {
        rerollTarget = nil
        picking = false
        guard let new = store.useIVReroll(on: target.id) else { return }
        onBattleItemUsed(.rerolled(name: target.name, old: target.ivs, new: new))
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
        } else if choosesTarget {
            targetControls(l)
        } else if store.canUseRareCandy {
            if confirming {
                HStack(spacing: 8) {
                    Text(l.useOnCurrent(store.displayName))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("\(l.use) ×\(selectedCandyCount)") { useCandy() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    Button(l.cancel) { confirming = false }
                        .buttonStyle(.borderless).controlSize(.small)
                }
            } else {
                HStack {
                    Text(effectHint(l))
                        .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                    Spacer()
                    Button(l.useItem) { confirming = true }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
        } else {
            // 알(부화 전)/활성 없음/(사탕만)라인 미로딩 — 비활성 + 사유
            Text(store.isEgg ? l.useAfterHatch : l.useNeedsPokemon)
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    /// 대상을 고르는 아이템: 닫힌 카드는 효과와 쓸 수 있는 포켓몬 수, 열면 목록, 재추첨은 그 뒤 확인 패널.
    /// 아무에게도 못 쓰면 사유를 말한다(배틀 중·체력 가득·기절·기절 아님·포켓몬 없음).
    /// 판정은 그릴 때마다 스토어에서 새로 읽는다 — 열어 둔 사이 대상이 배틀에 잡히면 버튼이 사유로 바뀐다.
    @ViewBuilder
    private func targetControls(_ l: L) -> some View {
        if let target = rerollTarget, store.itemVerdict(.ivReroll, on: target.id) == .usable {
            // 재추첨 확인 — 지금 개체값 6개와 "더 낮아질 수 있음"을 보여 준 뒤에만 쓴다.
            IVRerollPanel(stage: .confirm(current: target.ivs), l: l, targetName: target.name,
                          onReroll: { reroll(target) }, onCancel: { rerollTarget = nil }, onDone: {})
        } else if usableTargetCount > 0 {
            if picking {
                ItemTargetPicker(kind: kind, targets: targets, l: l, artwork: artwork,
                                 onUse: { use($0.individual) }, onCancel: { picking = false })
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(effectHint(l)).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                        Text(l.itemTargetCount(usableTargetCount)).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(l.useItem) { picking = true }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
        } else if let reason = BagView.battleItemReason(kind, store: store) {
            HStack {
                Text(effectHint(l)).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
                Spacer(minLength: 6)
                Text(reason).font(.caption2.weight(.medium)).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
        }
    }

    /// 사탕 사용 → Home 탭으로 전환(진화/졸업 연출·"+XP" 는 Home 의 CompanionHeader 에서 재생).
    private func useCandy() {
        confirming = false
        _ = store.useRareCandy(count: selectedCandyCount)
        nav.tab = .home
    }
}
