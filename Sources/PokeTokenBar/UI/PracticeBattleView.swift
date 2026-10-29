import AppKit
import SwiftUI

@MainActor
struct PracticeBattleView: View {
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
                contender(player, selection: $playerID, otherID: opponentID, title: "내 출전 개체", side: model.view?.p1, own: true)
                contender(opponent, selection: $opponentID, otherID: playerID, title: "연습 상대 · 자동 정책", side: model.view?.p2, own: false)
            }
            controls
            if let notice = model.notice {
                Label(notice, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange)
            }
            if roster.eligible.count < 2 {
                Text("출전 가능한 개체 두 마리가 필요합니다. 보유 개체 정보가 준비되면 이 창을 다시 열어 주세요.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if !running, roster.candidates.contains(where: { $0.snapshot == nil }) {
                DisclosureGroup("출전 보류 · \(roster.candidates.filter { $0.snapshot == nil }.count)마리") {
                    ForEach(roster.candidates.filter { $0.snapshot == nil }) { row in
                        Text("\(row.name) — \(row.blockedReason ?? "정보 없음")").frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.font(.caption).foregroundStyle(.secondary)
            }
            battleLog
            HStack {
                Label("세이브 읽기 전용 · 경험치·소유권 변화 없음", systemImage: "lock.shield")
                Spacer()
                Text("9세대 · 테라스탈·도구 없음 · EV 0 · 200턴 무승부")
            }.font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(minWidth: 820, minHeight: 690)
        .background(Color(nsColor: .windowBackgroundColor))
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
                Text("PRACTICE / 연습전").font(.system(size: 12, weight: .bold, design: .rounded)).tracking(2).foregroundStyle(.indigo)
                Text("함께 자란 개체, 첫 번째 대결").font(.system(size: 23, weight: .bold))
                Text("내 다른 개체를 상대로 가볍게 연습하세요. 상대는 같은 자동 정책으로 움직입니다.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Label("로컬", systemImage: "desktopcomputer").font(.caption.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 7).background(.indigo.opacity(0.08), in: Capsule())
        }
    }
    private func contender(_ candidate: PracticeCandidate?, selection: Binding<String>, otherID: String,
                           title: String, side: BattleView.Pokemon?, own: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.caption.weight(.bold)).foregroundStyle(own ? .indigo : .teal)
            Picker(title, selection: selection) {
                if candidate == nil { Text("개체를 골라 주세요").tag("") }
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
                    Text("공격 \(stats["atk", default: 0]) · 방어 \(stats["def", default: 0]) · 특공 \(stats["spa", default: 0])\n특방 \(stats["spd", default: 0]) · 스피드 \(stats["spe", default: 0])")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineSpacing(3)
                    Text("기술·특성은 전투 중 공개됩니다.").font(.caption).foregroundStyle(.tertiary)
                } else {
                    HStack(spacing: 5) {
                        Text("특성").foregroundStyle(.secondary)
                        if let ability = side?.ability { metadata(.ability, ability, snapshot: snapshot) }
                        else { Text("아직 공개되지 않음").foregroundStyle(.tertiary) }
                    }.font(.caption)
                    if !own {
                        HStack(spacing: 5) {
                            Text("기술").foregroundStyle(.secondary)
                            if side?.moves.isEmpty == true { Text("첫 사용 후 공개").foregroundStyle(.tertiary) }
                            ForEach(side?.moves ?? [], id: \.self) { metadata(.move, $0, snapshot: snapshot) }
                        }.font(.caption).lineLimit(2)
                    }
                }
            } else {
                ContentUnavailableView("출전 대기", systemImage: "leaf", description: Text("개체 정보가 준비되면 선택할 수 있습니다."))
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
                Picker("진행 방식", selection: $model.mode) {
                    Text("직접 조작").tag(PracticeBattle.Mode.manual)
                    Text("자동 진행").tag(PracticeBattle.Mode.automatic)
                }.pickerStyle(.segmented).frame(width: 210)
                Spacer()
                if running {
                    Text("\(model.view?.turn ?? 1)턴").font(.headline)
                    if model.mode == .manual {
                        Label("\(model.remainingSeconds)초", systemImage: "timer").monospacedDigit().foregroundStyle(.indigo)
                    } else { Text("자동으로 진행 중").foregroundStyle(.secondary) }
                    Button("연습 중단") { model.cancel() }.buttonStyle(.bordered)
                } else {
                    if let result = model.result {
                        Text(result.winner == nil ? "무승부" : result.winner == "p1" ? "내 개체 승리!" : "상대 승리")
                            .font(.headline).foregroundStyle(.indigo)
                    } else if model.phase == .cancelled { Text("연습을 중단했습니다.").foregroundStyle(.secondary) }
                    Button(model.phase == .ready ? "연습 시작" : "다시 연습") {
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
                                if move.id == "recharge" { Text("재충전") }
                                else if move.id == "struggle" { Text("발버둥") }
                                else if let snapshot = player?.snapshot { metadata(.move, move.id, snapshot: snapshot) }
                                HStack {
                                    Text(move.type).font(.caption)
                                    Spacer()
                                    Text("PP \(move.pp)/\(move.maxpp)").font(.caption.monospacedDigit())
                                }.foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(7)
                        }.buttonStyle(.bordered).disabled(move.disabled || move.pp == 0 || model.mode == .automatic)
                            .accessibilityLabel("기술 \(move.slot): \(move.name)")
                    }
                }
            } else {
                Text("직접 조작은 매 턴 30초. 시간이 지나면 자동으로 선택합니다.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var battleLog: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("전투 기록", systemImage: "text.alignleft").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if model.messages.isEmpty {
                            Text("출전 개체와 진행 방식을 고른 뒤 시작하세요.").foregroundStyle(.secondary)
                        }
                        ForEach(Array(model.messages.enumerated()), id: \.offset) { index, message in
                            Text(message).frame(maxWidth: .infinity, alignment: .leading).id(index)
                        }
                    }.font(.system(size: 12)).textSelection(.enabled).padding(12)
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
            window.title = "PokeTokenBar Battle · 연습전"
            window.isReleasedWhenClosed = false; window.delegate = self
            window.contentView = NSHostingView(rootView: PracticeBattleView(roster: roster, model: model))
            window.minSize = NSSize(width: 850, height: 730)
            self.window = window; self.model = model
            window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        } catch {
            let alert = NSAlert(); alert.messageText = "연습전을 열 수 없습니다."
            alert.informativeText = PracticeText.failure(error); alert.runModal()
        }
    }
    func windowWillClose(_ notification: Notification) {
        model?.cancel(); window?.contentView = nil; model = nil; window = nil
    }
}
