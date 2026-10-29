import AppKit
import SwiftUI

@MainActor
struct PracticeBattleView: View {
    private let l = L(.ko)
    let roster: PracticeRoster
    @Bindable var model: PracticeBattle
    var artwork = true
    var liveUpdates = true
    @State private var playerID: String
    @State private var opponentID: String
    private var player: PracticeCandidate? { roster.eligible.first { $0.id == playerID } }
    private var opponent: PracticeCandidate? { roster.eligible.first { $0.id == opponentID } }
    private var running: Bool { model.phase == .running }

    init(roster: PracticeRoster, model: PracticeBattle, artwork: Bool = true, liveUpdates: Bool = true) {
        self.roster = roster; self.model = model; self.artwork = artwork; self.liveUpdates = liveUpdates
        _playerID = State(initialValue: roster.eligible.first?.id ?? "")
        _opponentID = State(initialValue: roster.eligible.dropFirst().first?.id ?? "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            HStack(alignment: .top, spacing: 16) {
                contender(player, selection: $playerID, otherID: opponentID, title: l.practicePlayer, side: model.view?.p1, own: true)
                contender(opponent, selection: $opponentID, otherID: playerID, title: l.practiceOpponent, side: model.view?.p2, own: false)
            }
            controls
            if let notice = model.notice {
                Label(notice, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange)
            }
            if roster.eligible.count < 2 {
                Text(l.practiceNeedsPair)
                    .font(.callout).foregroundStyle(.secondary)
            }
            if !running, roster.candidates.contains(where: { $0.snapshot == nil }) {
                DisclosureGroup(l.practiceBlocked(roster.candidates.filter { $0.snapshot == nil }.count)) {
                    ForEach(roster.candidates.filter { $0.snapshot == nil }) { row in
                        Text("\(row.name) — \(row.blockedReason ?? l.practiceMissingInfo)").frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.font(.caption).foregroundStyle(.secondary)
            }
            battleLog
            HStack {
                Label(l.practiceReadOnly, systemImage: "lock.shield")
                Spacer()
                Text(l.practiceRules)
            }.font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(minWidth: 820, minHeight: 690)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: playerID) { _, _ in model.prepareSelection() }
        .onChange(of: opponentID) { _, _ in model.prepareSelection() }
        .task {
            guard liveUpdates else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                model.tick()
            }
        }
    }
    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text(l.practiceHeading).font(.system(size: 12, weight: .bold, design: .rounded)).tracking(2).foregroundStyle(.indigo)
                Text(l.practiceHero).font(.system(size: 23, weight: .bold))
                Text(l.practiceDescription)
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Label(l.practiceLocal, systemImage: "desktopcomputer").font(.caption.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 7).background(.indigo.opacity(0.08), in: Capsule())
        }
    }
    private func contender(_ candidate: PracticeCandidate?, selection: Binding<String>, otherID: String,
                           title: String, side: BattleView.Pokemon?, own: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.caption.weight(.bold)).foregroundStyle(own ? .indigo : .teal)
            Picker(title, selection: selection) {
                if candidate == nil { Text(l.practiceChoose).tag("") }
                ForEach(Array(roster.eligible.enumerated()), id: \.element.id) { index, row in
                    Text("\(row.name) · Lv.\(row.snapshot?.set.level ?? 0) · #\(index + 1)")
                        .tag(row.id).disabled(row.id == otherID)
                }
            }.labelsHidden().disabled(running).accessibilityLabel(title)
            if let candidate, let snapshot = candidate.snapshot {
                HStack(spacing: 16) {
                    if artwork {
                        SpriteView(speciesID: snapshot.set.speciesNum, size: 86, shiny: snapshot.set.shiny,
                                   form: snapshot.set.form.map { PokemonForm($0) })
                    } else {
                        Image(systemName: own ? "bolt.circle.fill" : "drop.circle.fill")
                            .font(.system(size: 66)).foregroundStyle(own ? .indigo : .teal).frame(width: 86, height: 86)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(candidate.name).font(.title2.bold()).lineLimit(1)
                        Text("Lv. \(side?.level ?? snapshot.set.level) · \(side?.species ?? snapshot.publicInfo.species)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        HStack(spacing: 5) {
                            ForEach(side?.types ?? snapshot.publicInfo.types, id: \.self) { type in
                                Text(type).font(.system(size: 10, weight: .semibold)).padding(.horizontal, 7).padding(.vertical, 3)
                                    .background((own ? Color.indigo : .teal).opacity(0.1), in: Capsule())
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                health(side, snapshot: snapshot, own: own)
                if side == nil {
                    let stats = snapshot.publicInfo.stats
                    Text(l.practiceStats(stats))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineSpacing(3)
                    Text(l.practiceSecrets).font(.caption).foregroundStyle(.tertiary)
                } else {
                    HStack(spacing: 5) {
                        Text(l.practiceAbility).foregroundStyle(.secondary)
                        if let ability = side?.ability { metadata(.ability, ability, snapshot: snapshot) }
                        else { Text(l.practiceUnrevealed).foregroundStyle(.tertiary) }
                    }.font(.caption)
                    if !own {
                        HStack(spacing: 5) {
                            Text(l.practiceMoves).foregroundStyle(.secondary)
                            if side?.moves.isEmpty == true { Text(l.practiceFirstUse).foregroundStyle(.tertiary) }
                            ForEach(side?.moves ?? [], id: \.self) { metadata(.move, $0, snapshot: snapshot) }
                        }.font(.caption).lineLimit(2)
                    }
                }
            } else {
                ContentUnavailableView(l.practiceWaiting, systemImage: "leaf", description: Text(l.practiceWaitingInfo))
                    .frame(height: 180)
            }
        }
        .padding(16).frame(maxWidth: .infinity, minHeight: 258, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke((own ? Color.indigo : .teal).opacity(0.18)))
    }
    private func health(_ side: BattleView.Pokemon?, snapshot: BattleSnapshot, own: Bool) -> some View {
        let hp = side?.hp ?? snapshot.publicInfo.stats["hp", default: 1]
        let maxHP = side?.maxhp ?? hp
        return VStack(spacing: 5) {
            HStack {
                Text("HP").fontWeight(.bold)
                Spacer()
                if let side, !side.status.isEmpty { Text(PracticeText.status(side.status)).foregroundStyle(.orange) }
                Text(side != nil && !own ? "\(hp)%" : "\(hp) / \(maxHP)").monospacedDigit()
            }.font(.caption)
            ProgressView(value: Double(hp), total: Double(max(1, maxHP))).tint(own ? .indigo : .teal)
        }
    }
    @ViewBuilder private func metadata(_ kind: PokemonNameResource.Kind, _ id: String, snapshot: BattleSnapshot) -> some View {
        let originals = kind == .move ? snapshot.set.moves : [snapshot.set.ability]
        let slug = originals.first { $0.filter(\.isLetter).lowercased() == id.lowercased() } ?? id.lowercased()
        if artwork { PokemonNameLabel(kind, slug, language: .ko) }
        else { Text(PokemonNameLocalization.identifier(slug)) }
    }
    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker(l.practiceMode, selection: $model.mode) {
                    Text(l.practiceManual).tag(PracticeBattle.Mode.manual)
                    Text(l.practiceAuto).tag(PracticeBattle.Mode.automatic)
                }.pickerStyle(.segmented).frame(width: 210)
                Spacer()
                if running {
                    Text(l.practiceTurn(model.view?.turn ?? 1)).font(.headline)
                    if model.mode == .manual {
                        Label(l.practiceSeconds(model.remainingSeconds), systemImage: "timer").monospacedDigit().foregroundStyle(.indigo)
                    } else { Text(l.practiceAutoRunning).foregroundStyle(.secondary) }
                    Button(l.practiceStop) { model.cancel() }.buttonStyle(.bordered)
                } else {
                    if let result = model.result {
                        Text(result.winner == nil ? l.practiceDraw : result.winner == "p1" ? l.practiceWon : l.practiceLost)
                            .font(.headline).foregroundStyle(.indigo)
                    } else if model.phase == .cancelled { Text(l.practiceCancelled).foregroundStyle(.secondary) }
                    Button(model.phase == .ready ? l.practiceStart : l.practiceAgain) {
                        if let player, let opponent { model.start(player: player, opponent: opponent, mode: model.mode) }
                    }.buttonStyle(.borderedProminent).tint(.indigo)
                        .disabled(player == nil || opponent == nil || playerID == opponentID)
                        .accessibilityIdentifier("practiceStart")
                }
            }
            if running {
                HStack(spacing: 9) {
                    ForEach(model.request.moves) { move in
                        Button { model.choose(slot: move.slot) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                if move.id == "recharge" { Text(l.practiceRecharge) }
                                else if move.id == "struggle" { Text(l.practiceStruggle) }
                                else if let snapshot = player?.snapshot { metadata(.move, move.id, snapshot: snapshot) }
                                HStack {
                                    Text(move.type).font(.caption)
                                    Spacer()
                                    Text("PP \(move.pp)/\(move.maxpp)").font(.caption.monospacedDigit())
                                }.foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(7)
                        }.buttonStyle(.bordered).disabled(move.disabled || move.pp == 0 || model.mode == .automatic)
                            .accessibilityLabel(l.practiceMoveLabel(move.slot, move.name))
                    }
                }
            } else {
                Text(l.practiceTimerHint).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var battleLog: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(l.practiceLog, systemImage: "text.alignleft").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if model.messages.isEmpty {
                            Text(l.practiceStartHint).foregroundStyle(.secondary)
                        }
                        ForEach(Array(model.messages.enumerated()), id: \.offset) { index, message in
                            Text(message).frame(maxWidth: .infinity, alignment: .leading).id(index)
                        }
                    }.font(.system(size: 12)).textSelection(.enabled).padding(12).reservesScrollerLane()
                }
                .onChange(of: model.messages.count) { _, count in proxy.scrollTo(count - 1, anchor: .bottom) }
            }
            .frame(maxWidth: .infinity, minHeight: 110, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

@MainActor
final class PracticeWindowController: NSObject, NSWindowDelegate {
    static let shared = PracticeWindowController()
    private let l = L(.ko)
    private var window: NSWindow?
    private var model: PracticeBattle?
    func open(state: CompanionState, activeName: String?) {
        if let window { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return }
        do {
            let engine = try BattleEngine()
            let roster = PracticeRoster(state: state, activeName: activeName, engine: engine)
            let model = PracticeBattle(engine: engine)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 760),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = l.practiceWindowTitle
            window.isReleasedWhenClosed = false; window.delegate = self
            window.contentView = NSHostingView(rootView: PracticeBattleView(roster: roster, model: model))
            window.minSize = NSSize(width: 850, height: 730)
            self.window = window; self.model = model
            window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        } catch {
            let alert = NSAlert(); alert.messageText = l.practiceCannotOpen
            alert.informativeText = PracticeText.failure(error); alert.runModal()
        }
    }
    func windowWillClose(_ notification: Notification) {
        model?.cancel(); window?.contentView = nil; model = nil; window = nil
    }
}
