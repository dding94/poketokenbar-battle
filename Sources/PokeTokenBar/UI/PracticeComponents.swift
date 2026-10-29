import SwiftUI

// Small building blocks shared by the practice selection, battle and result screens and the Home
// entry row. They follow the popover look: system font, `secondary.opacity(0.06)` cards with
// radius 10, 8pt type capsules. `artwork: false` keeps every piece offline (no sprite downloads,
// no PokéAPI name lookups) with neutral placeholders and identifier names.

/// The card background every practice section uses, matching Bag/Shop cards.
extension View {
    func practiceCard(padding: CGFloat = 10) -> some View {
        self.padding(padding)
            .background(Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// A Pokémon sprite on a faint rounded tile; a neutral symbol when artwork is off.
@MainActor
struct PracticeSpriteTile: View {
    let set: BattleSet?
    var size: CGFloat = 44
    let artwork: Bool

    var body: some View {
        Group {
            if artwork, let set {
                SpriteView(speciesID: set.speciesNum, size: size * 0.92, shiny: set.shiny,
                           form: set.form.map { PokemonForm($0) })
            } else {
                Image(systemName: "pawprint.fill")
                    .font(.system(size: size * 0.4))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: size)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
    }
}

/// One capsule per type. Online it uses the shared `TypeBadges` (localized names); offline the
/// capitalized identifier on the same type color.
@MainActor
struct PracticeTypeBadges: View {
    let types: [String]
    let l: L
    let artwork: Bool

    var body: some View {
        if artwork {
            TypeBadges(types: types.map { $0.lowercased() }, language: l.lang)
        } else {
            HStack(spacing: 5) {
                ForEach(types, id: \.self) { type in
                    Badge(PokemonNameLocalization.identifier(type.lowercased()).uppercased(),
                          tint: .type(PokemonType(apiName: type)))
                }
            }
        }
    }
}

/// HP as a capsule: green above half, yellow above a fifth, red below. The fill eases once per HP
/// change (no repeating animation).
@MainActor
struct PracticeHPBar: View {
    let hp: Int
    let maxHP: Int
    var height: CGFloat = 6

    private var ratio: Double { maxHP > 0 ? min(1, max(0, Double(hp) / Double(maxHP))) : 0 }
    private var color: Color { ratio > 0.5 ? .green : ratio > 0.2 ? .yellow : .red }

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.secondary.opacity(0.15))
            Capsule().fill(color)
                .scaleEffect(x: ratio, y: 1, anchor: .leading)
        }
        .frame(height: height)
        .animation(.easeInOut(duration: 0.5), value: hp)
        .accessibilityElement()
        .accessibilityValue("\(hp)/\(maxHP)")
    }
}

/// A faint capsule chip for revealed moves, the ability, or a "?" placeholder.
@MainActor
struct PracticeChip<Label: View>: View {
    var dimmed = false
    @ViewBuilder var label: Label

    var body: some View {
        label
            .font(.system(size: 10, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(dimmed ? .tertiary : .secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color.secondary.opacity(dimmed ? 0.06 : 0.12), in: Capsule())
    }
}

/// A move or ability name. Engine ids ("irontail") are mapped back to the snapshot's PokéAPI slug
/// ("iron-tail") so the localized name can load; offline the slug reads as "Iron Tail".
@MainActor
struct PracticeMetadataName: View {
    let kind: PokemonNameResource.Kind
    let id: String
    let snapshot: BattleSnapshot?
    let l: L
    let artwork: Bool

    static func slug(_ kind: PokemonNameResource.Kind, _ id: String, in snapshot: BattleSnapshot?) -> String {
        let originals = kind == .move ? snapshot?.set.moves ?? [] : [snapshot?.set.ability].compactMap { $0 }
        let key = id.filter { $0.isLetter || $0.isNumber }.lowercased()
        return originals.first { $0.filter { $0.isLetter || $0.isNumber }.lowercased() == key } ?? id.lowercased()
    }

    var body: some View {
        let slug = Self.slug(kind, id, in: snapshot)
        if artwork {
            PokemonNameLabel(kind, slug, language: l.lang)
        } else {
            Text(PokemonNameLocalization.identifier(slug))
        }
    }
}

/// "Name Lv.50" with the name truncating first.
@MainActor
struct PracticeNameLevel: View {
    let name: String
    let level: Int
    var font: Font = .callout.weight(.semibold)

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(name).font(font).lineLimit(1)
            Text("Lv.\(level)").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .monospacedDigit().fixedSize()
        }
    }
}

/// Home entry row (Home tab, under the companion header): what the practice battle is doing and one
/// small button into the practice screen. It reads only the session's battle state — it never
/// builds the roster or the engine.
@MainActor
struct PracticeEntryRow: View {
    let session: PracticeSession
    let l: L
    let onOpen: () -> Void

    var body: some View {
        let battle = session.battle
        let running = battle?.phase == .running
        let unseenResult = battle?.phase == .finished && !session.resultSeen
        HStack(spacing: 10) {
            Image(systemName: "bolt.shield.fill")
                .font(.system(size: 17))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(l.practiceTitle).font(.callout.weight(.semibold))
                Group {
                    if running {
                        Text(l.practiceEntryRunning(battle?.view?.turn ?? 1)).foregroundStyle(Color.accentColor)
                    } else if unseenResult {
                        Text(l.practiceEntryResult).foregroundStyle(Color.accentColor)
                    } else {
                        Text(l.practiceEntryIdle).foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .lineLimit(1)
                .monospacedDigit()
            }
            Spacer(minLength: 6)
            Button(running ? l.practiceEntryResume : unseenResult ? l.practiceEntryShowResult : l.practiceEntryStart,
                   action: onOpen)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(l.practiceOpenHint)
        }
        .practiceCard()
    }
}
