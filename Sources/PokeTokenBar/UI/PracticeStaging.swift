import SwiftUI

// Words and small views for staged practice turns (`PracticePlayback`). Beats are data; this file turns
// them into localized lines: the action on screen, its callout chips, the ticker and the result log.
// Move and ability names stay localized through PokéAPI (`artwork: true`) or read as the identifier
// offline, like `PracticeMetadataName`. Nothing here shows a raw engine string.

/// A name inside a line: a PokéAPI move or ability, or text that is already localized.
enum PracticeNameRef: Hashable {
    case resource(PokemonNameResource)
    case literal(String)
}

/// A line made of localized text and names that may still be loading.
struct PracticePhrase: Hashable {
    enum Piece: Hashable { case text(String), name(PracticeNameRef) }
    var pieces: [Piece] = []

    init(_ pieces: [Piece] = []) { self.pieces = pieces }
    init(_ text: String) { pieces = [.text(text)] }

    /// Splices a name into a localized template ("특성 공개: \(name)") wherever the template puts it.
    init(_ template: (String) -> String, _ name: PracticeNameRef) {
        let marker = "\u{1F}"
        let parts = template(marker).components(separatedBy: marker)
        for (index, part) in parts.enumerated() {
            if !part.isEmpty { pieces.append(.text(part)) }
            if index < parts.count - 1 { pieces.append(.name(name)) }
        }
    }

    static func + (lhs: PracticePhrase, rhs: PracticePhrase) -> PracticePhrase { PracticePhrase(lhs.pieces + rhs.pieces) }

    var resources: [PokemonNameResource] {
        pieces.compactMap { if case .name(.resource(let resource)) = $0 { resource } else { nil } }
    }
}

/// How a callout chip is tinted.
enum PracticeCalloutTone {
    case strong, critical, muted, status, up, down, field, reveal, hurt

    init(_ callout: PracticeCallout) {
        switch callout {
        case .superEffective: self = .strong
        case .critical, .fainted: self = .critical
        case .resisted, .immune, .miss, .failed, .timedOut: self = .muted
        case .status, .cureStatus, .cant: self = .status
        // 0 stages: already at ±6, so the stat did not move.
        case .boost(_, _, let stages): self = stages > 0 ? .up : stages < 0 ? .down : .muted
        case .weather: self = .field
        case .abilityRevealed: self = .reveal
        case .recoil: self = .hurt
        }
    }

    var color: Color {
        switch self {
        case .strong: .orange
        case .critical: .red
        case .muted: .secondary
        case .status: .purple
        case .up: .blue
        case .down: .indigo
        case .field: .teal
        case .reveal: .mint
        case .hurt: .pink
        }
    }
}

/// Words for one battle: names and snapshots of both sides, so move ids map back to PokéAPI slugs.
@MainActor
struct PracticeWording {
    let l: L
    let playerName: String
    let opponentName: String
    let playerSnapshot: BattleSnapshot?
    let opponentSnapshot: BattleSnapshot?

    /// From the pair the battle was started with: the selection may already name someone else (a wild search
    /// replacing its batch mid-battle).
    init(battle: PracticeBattle, l: L) {
        self.l = l
        playerName = battle.player?.name ?? battle.view?.p1.species ?? ""
        opponentName = battle.opponent?.name ?? battle.view?.p2.species ?? ""
        playerSnapshot = battle.player?.snapshot
        opponentSnapshot = battle.opponent?.snapshot
    }

    func name(_ side: PracticeSide) -> String { side == .player ? playerName : opponentName }
    private func snapshot(_ side: PracticeSide) -> BattleSnapshot? { side == .player ? playerSnapshot : opponentSnapshot }

    /// Showdown move id ("volttackle") → the snapshot's PokéAPI slug ("volt-tackle").
    func move(_ side: PracticeSide?, _ moveID: String) -> PracticeNameRef {
        switch moveID {
        case "struggle": return .literal(l.practiceStruggle)
        case "recharge": return .literal(l.practiceRecharge)
        default:
            let owner: BattleSnapshot? = side.flatMap { self.snapshot($0) }
            let slug = PracticeMetadataName.slug(.move, moveID, in: owner)
            return .resource(PokemonNameResource(kind: .move, name: slug))
        }
    }

    func ability(_ side: PracticeSide, _ abilityID: String) -> PracticeNameRef {
        .resource(.init(kind: .ability, name: PracticeMetadataName.slug(.ability, abilityID, in: snapshot(side))))
    }

    // MARK: Beat lines

    /// "Pikachu · Volt Tackle", "Pikachu · Paralyzed", or an end-of-turn / system line.
    func action(_ beat: PracticeBeat) -> PracticePhrase {
        guard let actor = beat.actor else {
            if beat.callouts.contains(.timedOut) { return PracticePhrase(l.practiceCalloutTimedOut) }
            return PracticePhrase(l.practiceEndOfTurn)
        }
        let head = PracticePhrase(name(actor) + l.practiceSeparator)
        if let moveID = beat.moveID { return head + PracticePhrase([.name(move(actor, moveID))]) }
        for case .cant(_, let reason) in beat.callouts { return head + PracticePhrase(l.practiceCantReason(reason)) }
        return PracticePhrase(name(actor))
    }

    /// Callouts shown as chips: the ones the action line already says are left out.
    func chips(_ beat: PracticeBeat) -> [PracticeCallout] {
        beat.callouts.filter { callout in
            switch callout {
            case .cant: beat.moveID != nil
            case .timedOut: beat.actor != nil
            default: true
            }
        }
    }

    /// One callout as chip text. Callouts about the side that did not act carry its name.
    func callout(_ callout: PracticeCallout, in beat: PracticeBeat) -> PracticePhrase {
        func tagged(_ side: PracticeSide, _ text: String) -> PracticePhrase {
            PracticePhrase(side == beat.actor ? text : l.practiceTagged(name(side), text))
        }
        switch callout {
        case .superEffective: return PracticePhrase(l.practiceCalloutSuperEffective)
        case .resisted: return PracticePhrase(l.practiceCalloutResisted)
        case .immune: return PracticePhrase(l.practiceCalloutImmune)
        case .critical: return PracticePhrase(l.practiceCalloutCritical)
        case .miss: return PracticePhrase(l.practiceCalloutMiss)
        case .failed: return PracticePhrase(l.practiceCalloutFailed)
        case .status(let side, let code): return tagged(side, l.practiceStatusName(code))
        case .cureStatus(let side, let code): return tagged(side, l.practiceCured(code))
        case .boost(let side, let stat, let stages): return tagged(side, l.practiceBoost(stat: stat, stages: stages))
        case .cant(let side, let reason): return tagged(side, l.practiceCantReason(reason))
        case .fainted(let side): return tagged(side, l.practiceCalloutFainted)
        case .weather(let id): return PracticePhrase(l.practiceWeather(id))
        case .abilityRevealed(let side, let abilityID):
            let phrase = PracticePhrase({ l.practiceAbilityRevealed($0) }, ability(side, abilityID))
            return side == beat.actor ? phrase : PracticePhrase(l.practiceTagged(name(side), "")) + phrase
        case .recoil(let side): return tagged(side, l.practiceCalloutRecoil)
        case .timedOut: return PracticePhrase(l.practiceCalloutTimedOut)
        }
    }

    func tone(_ callout: PracticeCallout) -> PracticeCalloutTone { PracticeCalloutTone(callout) }

    /// A finished beat as one sentence: "피카츄 · 10만볼트 → 잉어킹 −48% · 약점!".
    func sentence(_ beat: PracticeBeat, notes: Int = 2) -> PracticePhrase {
        var line = action(beat)
        let order: [PracticeSide] = beat.actor == .opponent ? [.player, .opponent] : [.opponent, .player]
        var first = beat.actor != nil
        for side in order {
            guard let delta = beat.hpDelta[side], delta != 0 else { continue }
            line = line + PracticePhrase((first ? l.practiceArrow : l.practiceSeparator) + l.practiceHit(name(side), delta))
            first = false
        }
        for callout in chips(beat).prefix(notes) {
            line = line + PracticePhrase(l.practiceSeparator) + self.callout(callout, in: beat)
        }
        return line
    }
}

/// Renders a phrase as one `Text`, so it truncates as a single line. Names load once through the shared
/// display store (the same cache as `PokemonNameLabel`); offline or until loaded they read as identifiers.
@MainActor
struct PracticePhraseText: View {
    let phrase: PracticePhrase
    let l: L
    let artwork: Bool
    var provider: any PokemonNameProviding = PokemonNameClient.shared
    var displayStore = PokemonNameDisplayStore.shared

    var body: some View {
        Text(text)
            .task(id: artwork ? phrase.resources : []) {
                for resource in Set(phrase.resources) where displayStore.names[resource] == nil {
                    guard !Task.isCancelled else { return }
                    _ = await displayStore.load(resource, provider: provider)
                }
            }
    }

    private var text: String {
        phrase.pieces.map { piece in
            switch piece {
            case .text(let text): return text
            case .name(.literal(let text)): return text
            case .name(.resource(let resource)):
                if artwork, let names = displayStore.names[resource], let name = l.lang.resolveName(names) { return name }
                return PokemonNameLocalization.identifier(resource.name)
            }
        }.joined()
    }
}

/// A callout chip: bold tinted text on a faint capsule of the same tint.
@MainActor
struct PracticeCalloutChip: View {
    let phrase: PracticePhrase
    let tone: PracticeCalloutTone
    let l: L
    let artwork: Bool

    var body: some View {
        PracticePhraseText(phrase: phrase, l: l, artwork: artwork)
            .font(.caption.weight(.bold))
            .lineLimit(1)
            .foregroundStyle(tone.color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(tone.color.opacity(0.14), in: Capsule())
            .fixedSize()
    }
}

/// "−48%" / "+12%" over a side's HP. It rises in when its beat starts and fades upward when the beat
/// ends; the parent keys it by the beat id, so every beat plays it once and nothing repeats.
@MainActor
struct PracticeFloatingDelta: View {
    let delta: Int
    let l: L

    var body: some View {
        Text(l.practiceDelta(delta))
            .font(.system(size: 13, weight: .heavy).monospacedDigit())
            .foregroundStyle(delta < 0 ? Color.red : Color.green)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(.background, in: Capsule())
            .overlay(Capsule().strokeBorder((delta < 0 ? Color.red : Color.green).opacity(0.35)))
            .fixedSize()
    }

    static var transition: AnyTransition {
        .asymmetric(insertion: .offset(y: 8).combined(with: .opacity).combined(with: .scale(scale: 0.8)),
                    removal: .offset(y: -10).combined(with: .opacity))
    }
}

/// Values of the one-shot hit reaction on a sprite tile.
struct PracticeHitFrame {
    var offset: CGFloat = 0
    var flash: Double = 0
}

/// Shakes and flashes the content once whenever `trigger` changes to a new hit (no repeat).
@MainActor
struct PracticeHitReaction: ViewModifier {
    let trigger: Int?

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: PracticeHitFrame(), trigger: trigger) { content, frame in
            content
                .overlay(Color.red.opacity(frame.flash).clipShape(RoundedRectangle(cornerRadius: 10)))
                .offset(x: frame.offset)
        } keyframes: { _ in
            KeyframeTrack(\.offset) {
                CubicKeyframe(-6, duration: 0.06)
                CubicKeyframe(6, duration: 0.08)
                CubicKeyframe(-4, duration: 0.08)
                CubicKeyframe(3, duration: 0.07)
                CubicKeyframe(0, duration: 0.07)
            }
            KeyframeTrack(\.flash) {
                LinearKeyframe(0.35, duration: 0.05)
                LinearKeyframe(0, duration: 0.3)
            }
        }
    }
}

extension View {
    func practiceHitReaction(trigger: Int?) -> some View { modifier(PracticeHitReaction(trigger: trigger)) }

    /// Dims and desaturates a fainted side; eases once when the state flips.
    func practiceFainted(_ fainted: Bool) -> some View {
        self.grayscale(fainted ? 1 : 0)
            .opacity(fainted ? 0.4 : 1)
            .animation(.easeOut(duration: 0.4), value: fainted)
    }
}
