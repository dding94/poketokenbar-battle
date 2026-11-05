import XCTest
@testable import PokeTokenBar

/// The source both surfaces read: prepared ids reach the calculator, and the clock boundaries are found.
@MainActor
final class OnlineAttentionSourceTests: XCTestCase {
    private static let now = Date(timeIntervalSince1970: 1_793_683_600)
    private func room(_ id: String, _ state: OnlineBattleState, confirmed: Bool = false, deadlineIn seconds: Double? = nil) -> OnlineBattleView {
        let me = OnlineBattlePlayer(trainerId: "synthetic-me", snapshot: nil, publicInfo: nil, hpPercent: nil)
        let foe = OnlineBattlePlayer(trainerId: "synthetic-foe", snapshot: nil, publicInfo: nil, hpPercent: nil)
        return .init(battleId: id, state: state, revision: 1, mode: .manual, p1: foe, p2: me, createdAt: 1,
                     expiresAt: Self.now.timeIntervalSince1970 * 1000 + 3_600_000, startedAt: nil, reportedAt: nil, confirmed: confirmed,
                     config: nil, roundSeq: 1, deadline: seconds.map { (Self.now.timeIntervalSince1970 + $0) * 1000 }, ownChoice: nil,
                     journal: [], result: nil, reason: nil, rematchOf: nil)
    }
    private func source(_ battles: [OnlineBattleView], prepared: Set<String> = [], status: String = "접속 중") -> OnlineAttentionSource {
        let model = OnlineBattlePresentation()
        model.account = .init(trainer: .init(trainerId: "synthetic-me", displayEmail: "나래", role: .member, status: .active),
                              group: .init(groupId: "synthetic-group", name: "동료들", hostTrainerId: "synthetic-foe"))
        model.battles = battles; model.connectionStatus = status
        return OnlineAttentionSource(presentation: model, preparedBattleIDs: { prepared })
    }

    func testPreparedIdsReachTheMarkAndTheSubtitle() {
        let l = L(.ko)
        let confirmed = room("bt-conf", .accepted, confirmed: true)
        XCTAssertEqual(source([confirmed]).menuMark(l: l, now: Self.now)?.text, "●")
        XCTAssertEqual(source([confirmed]).homeSubtitle(l: l, now: Self.now), "\(l.onlineAnonymous)님과 대결 확정 · 전투 준비 필요")
        let readied = source([confirmed], prepared: ["bt-conf"])
        XCTAssertNil(readied.menuMark(l: l, now: Self.now), "Readied, nothing is asked of me")
        // Readied and waiting on the other side: the home row says so rather than reading as an idle group.
        XCTAssertEqual(readied.homeSubtitle(l: l, now: Self.now), "\(l.onlineAnonymous)님의 응답 대기 중")
    }

    func testTheSubtitleReadsTheConnectionStatusOfThePresentation() {
        XCTAssertEqual(source([], status: "연결 중").homeSubtitle(l: L(.ko), now: Self.now), "다시 연결하는 중")
    }

    func testNextMarkChangeIsTheUrgentBoundaryThenTheDeadline() {
        XCTAssertNil(source([]).nextMarkChange(now: Self.now))
        XCTAssertNil(source([room("bt-in", .pending)]).nextMarkChange(now: Self.now), "A challenge has no countdown")
        XCTAssertEqual(source([room("bt-t", .running, confirmed: true, deadlineIn: 25)]).nextMarkChange(now: Self.now), Self.now.addingTimeInterval(15))
        XCTAssertEqual(source([room("bt-t", .running, confirmed: true, deadlineIn: 10)]).nextMarkChange(now: Self.now), Self.now.addingTimeInterval(10),
                       "Already urgent, only the deadline is left")
        XCTAssertEqual(source([room("bt-t", .running, confirmed: true, deadlineIn: 4)]).nextMarkChange(now: Self.now), Self.now.addingTimeInterval(4))
        XCTAssertEqual(source([room("bt-a", .running, confirmed: true, deadlineIn: 25), room("bt-b", .running, confirmed: true, deadlineIn: 12)])
            .nextMarkChange(now: Self.now), Self.now.addingTimeInterval(2), "The earliest boundary across rooms")
    }
}
