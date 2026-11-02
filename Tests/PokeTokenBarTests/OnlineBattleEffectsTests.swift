import XCTest
@testable import PokeTokenBar

private struct OnlineEffectsProvider: PokeProviding {
    func line(baseSpeciesID: Int) async throws -> EvoLine {
        EvoLine(baseID: 1, tree: EvoNode(speciesID: 1, children: [EvoNode(speciesID: 2, children: [EvoNode(speciesID: 3, children: [])])]), rarity: .common, names: [:])
    }
    func baseSpeciesIndex() async throws -> [BaseSpecies] { [] }
    func baseSpecies(id: Int) async throws -> BaseSpecies? { nil }
}
@MainActor
final class OnlineBattleEffectsTests: XCTestCase {
    private var folder: URL!
    private var defaults: UserDefaults!
    private var suite: String!
    private let now = Date(timeIntervalSince1970: 1_793_400_000)
    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        suite = "OnlineBattleEffectsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(1.0, forKey: "growthDifficulty")
    }
    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: folder)
    }
    private func state(active: Bool = true, credit: Int = 1_000_000) -> CompanionState {
        var s = CompanionState(); s.usedSinceInstall = 1_000_000_000; s.spentTokens = 123
        s.inventory = [ItemKind.potion.rawValue: 2]
        if active { s.active = MonState(baseID: 1, pathIDs: [1], plannedPathIDs: [1, 2, 3], stageIndex: 0, usedAtStage: credit, rarity: .common,
            totalForms: 3, profile: PokemonProfile.generate(seed: 1, instanceID: "current")) }
        return s
    }
    private func key(_ id: String = "battle") -> OnlineBattleReceiptKey {
        .init(scope: .init(originHash: "origin", groupID: "group", trainerID: "trainer"), battleID: id)
    }
    private func effect(_ id: String = "battle", outcome: OnlineBattleOutcome = .win, hp: Double = 0.4, hash: String = "hash") throws -> VerifiedOnlineBattleEffect {
        try .init(key: key(id), resultHash: hash, localInstanceID: "entrant", remainingHPShare: hp, outcome: outcome)
    }
    private func open(_ name: String = "save", date: Date? = nil,
                      writer: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) -> CompanionStore {
        CompanionStore(provider: OnlineEffectsProvider(), clock: { date ?? self.now }, fileURL: folder.appendingPathComponent(name),
                       dittoDisguiseRollingEnabled: false, defaults: defaults, onlineStateWriter: writer)
    }
    private func make(_ s: CompanionState? = nil, name: String = "save",
                      writer: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) throws -> CompanionStore {
        try JSONEncoder().encode(s ?? state()).write(to: folder.appendingPathComponent(name))
        return open(name, writer: writer)
    }
    func testWinCommitsHPCurrentRecipientCreditAndReceiptWithoutUsageOrWallet() throws {
        let store = try make(); let before = store.state
        try store.holdOnlineBattle(key: key(), instanceID: "entrant")
        let receipt = try store.applyVerifiedOnlineBattleEffect(effect())
        XCTAssertEqual(receipt.grantedXP, 10_000_000)
        XCTAssertEqual(receipt.recipientInstanceID, "current")
        XCTAssertEqual(store.healthShare(of: "entrant"), 0.4)
        XCTAssertEqual(store.state.active?.usedAtStage, 11_000_000)
        XCTAssertEqual(store.state.usedSinceInstall, before.usedSinceInstall)
        XCTAssertEqual(store.state.spentTokens, before.spentTokens)
        XCTAssertEqual(store.state.eggUsage, before.eggUsage)
        XCTAssertEqual(store.state.onlineBattleReceipts, [receipt])
        XCTAssertFalse(store.isHeldForBattle(instanceID: "entrant"))
    }
    func testDuplicateAcrossRestartAndHashConflict() throws {
        let store = try make(); let first = try store.applyVerifiedOnlineBattleEffect(effect())
        let reopened = open()
        XCTAssertEqual(try reopened.applyVerifiedOnlineBattleEffect(effect()), first)
        XCTAssertEqual(reopened.state.active?.usedAtStage, 11_000_000)
        XCTAssertEqual(reopened.state.onlineBattleReceipts.count, 1)
        XCTAssertThrowsError(try reopened.applyVerifiedOnlineBattleEffect(effect(hash: "other")))
    }
    func testFailureLeavesDiskMemoryQuotaAndHoldUnchanged() throws {
        enum Failure: Error { case disk }
        let store = try make(); try store.holdOnlineBattle(key: key(), instanceID: "entrant")
        let failing = open(writer: { _, _ in throw Failure.disk })
        let disk = try Data(contentsOf: folder.appendingPathComponent("save"))
        let memory = try canonical(failing.state)
        XCTAssertThrowsError(try failing.applyVerifiedOnlineBattleEffect(effect()))
        XCTAssertEqual(try canonical(failing.state), memory)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("save")), disk)
        XCTAssertTrue(failing.isHeldForBattle(instanceID: "entrant"))
    }
    func testLossAndDrawOnlyWriteLocalEntrantHP() throws {
        let store = try make()
        XCTAssertEqual(try store.applyVerifiedOnlineBattleEffect(effect("loss", outcome: .loss, hp: 0.7)).grantedXP, 0)
        XCTAssertEqual(store.healthShare(of: "entrant"), 0)
        XCTAssertEqual(try store.applyVerifiedOnlineBattleEffect(effect("draw", outcome: .draw, hp: 0.25)).grantedXP, 0)
        XCTAssertEqual(store.healthShare(of: "entrant"), 0.25)
        XCTAssertEqual(store.healthShare(of: "current"), 1)
        XCTAssertEqual(store.state.active?.usedAtStage, 1_000_000)
    }
    func testDailyTenWinsAndNextDayAndNoActiveDoesNotUseQuota() throws {
        let store = try make()
        for i in 1...11 {
            XCTAssertEqual(try store.applyVerifiedOnlineBattleEffect(effect("b\(i)")).grantedXP, i <= 10 ? 10_000_000 : 0)
        }
        let tomorrow = open(date: now.addingTimeInterval(86400))
        XCTAssertEqual(try tomorrow.applyVerifiedOnlineBattleEffect(effect("tomorrow")).grantedXP, 10_000_000)
        let egg = try make(state(active: false), name: "egg")
        let receipt = try egg.applyVerifiedOnlineBattleEffect(effect())
        XCTAssertEqual(receipt.grantedXP, 0); XCTAssertNil(receipt.recipientInstanceID)
    }
    func testHoldSurvivesPracticeEndAndBlocksHealingReleaseAndImport() throws {
        var s = state(); s.battleHealth["current"] = 0.5
        let store = try make(s)
        try store.holdOnlineBattle(key: key(), instanceID: "current")
        store.setInBattle("entrant"); store.setInBattle(nil)
        XCTAssertTrue(store.isHeldForBattle(instanceID: "current"))
        XCTAssertFalse(store.useHealingItem(.potion, on: "current"))
        XCTAssertFalse(store.buyFreshEgg())
        let envelope = try SaveTransfer.decode(SaveTransfer.encode(state: state(), appVersion: "test", deviceName: "test", now: now))
        XCTAssertThrowsError(try store.applySave(envelope, todayTokensByProvider: [:], todayDate: "day", hasUsageData: false))
        try store.releaseOnlineBattle(key: key())
        XCTAssertFalse(store.isHeldForBattle(instanceID: "current"))
        XCTAssertTrue(store.useHealingItem(.potion, on: "current"))
    }
    func testCorruptFallbackRemainsUntrustedAfterRestart() throws {
        try Data(#"{"onlineBattleReceipts":"damaged"}"#.utf8).write(to: folder.appendingPathComponent("save"))
        let store = open()
        XCTAssertThrowsError(try store.applyVerifiedOnlineBattleEffect(effect()))
        store.setLanguage(.en)
        XCTAssertThrowsError(try open().applyVerifiedOnlineBattleEffect(effect()))
    }
    func testImportAndSnapshotRestorePreserveReceiptUnionAndRejectConflicts() throws {
        let store = try make()
        let snapshot = try store.createManualSnapshot()
        _ = try store.applyVerifiedOnlineBattleEffect(effect())
        try store.restoreSnapshot(snapshot)
        XCTAssertEqual(store.state.onlineBattleReceipts.count, 1)
        XCTAssertEqual(try store.applyVerifiedOnlineBattleEffect(effect()).grantedXP, 10_000_000)
        XCTAssertEqual(store.state.active?.usedAtStage, 1_000_000, "old state restored, original receipt prevents repayment")
        var imported = state()
        imported.onlineBattleReceipts = [OnlineBattleEffectReceipt(key: key(), resultHash: "conflict", localInstanceID: "entrant",
            appliedHPShare: 0.4, grantedXP: 10_000_000, recipientInstanceID: "current", rewardDate: "2026-10-31")]
        let envelope = try SaveTransfer.decode(SaveTransfer.encode(state: imported, appVersion: "test", deviceName: "test", now: now))
        XCTAssertThrowsError(try store.applySave(envelope, todayTokensByProvider: [:], todayDate: "day", hasUsageData: false))
        XCTAssertEqual(store.state.onlineBattleReceipts.first?.resultHash, "hash")
    }
    func testFirstAtomicWriteContainsRecoverableCreditBeforeEvolutionOrGraduation() async throws {
        for (name, credit, stage) in [("evolve", 123_000_000, 0), ("graduate", 373_000_000, 2)] {
            var s = state(credit: credit)
            if stage == 2 { s.active?.pathIDs = [1, 2, 3]; s.active?.stageIndex = 2 }
            var firstWrite: Data?
            let store = try make(s, name: name, writer: { data, url in
                if firstWrite == nil { firstWrite = data }
                try data.write(to: url, options: .atomic)
            })
            let receipt = try store.applyVerifiedOnlineBattleEffect(effect(name))
            let captured = try XCTUnwrap(firstWrite)
            let committed = try JSONDecoder().decode(CompanionState.self, from: captured)
            XCTAssertEqual(committed.active?.usedAtStage, credit + 10_000_000)
            XCTAssertEqual(committed.onlineBattleReceipts, [receipt])
            XCTAssertEqual(committed.battleHealth["entrant"], 0.4)
            try captured.write(to: folder.appendingPathComponent("recovery"))
            let recovered = open("recovery")
            recovered.update(todayTokensByProvider: [:], todayDate: "day", monthTotal: 0, burnTier: .idle, limitWarning: false, hasUsageData: false)
            for _ in 0..<100 where recovered.currentLine == nil && recovered.state.active != nil { await Task.yield() }
            if stage == 0 {
                XCTAssertEqual(recovered.state.active?.stageIndex, 1)
                XCTAssertEqual(recovered.state.active?.usedAtStage, 8_000_000)
            } else {
                XCTAssertNil(recovered.state.active)
                XCTAssertEqual(recovered.state.dex.count, 1)
            }
            _ = try recovered.applyVerifiedOnlineBattleEffect(effect(name))
            XCTAssertEqual(recovered.state.onlineBattleReceipts.count, 1)
        }
    }

    private func canonical(_ value: CompanionState) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }
    func testIndependentScopeKeysAndPracticeRewardsDoNotConsumeOnlineQuota() throws {
        let store = try make()
        XCTAssertTrue(store.grantBattleXP(5_000_000))
        _ = try store.applyVerifiedOnlineBattleEffect(effect())
        for scope in [OnlineBattleScope(originHash: "other", groupID: "group", trainerID: "trainer"),
                      OnlineBattleScope(originHash: "origin", groupID: "other", trainerID: "trainer"),
                      OnlineBattleScope(originHash: "origin", groupID: "group", trainerID: "other")] {
            let input = try VerifiedOnlineBattleEffect(key: .init(scope: scope, battleID: "battle"), resultHash: "hash",
                localInstanceID: "entrant", remainingHPShare: 1, outcome: .win)
            XCTAssertEqual(try store.applyVerifiedOnlineBattleEffect(input).grantedXP, 10_000_000)
        }
        XCTAssertEqual(store.state.onlineBattleReceipts.count, 4)
        XCTAssertEqual(store.state.active?.usedAtStage, 46_000_000)
        XCTAssertEqual(store.healthShare(of: "entrant"), 1)
        XCTAssertNil(store.state.battleHealth["entrant"])
    }
    func testHoldConflictsFaintedAndCancellationOnlyReleaseTheirOwnKey() throws {
        let store = try make()
        try store.holdOnlineBattle(key: key(), instanceID: "entrant")
        try store.holdOnlineBattle(key: key(), instanceID: "entrant")
        XCTAssertEqual(store.state.onlineBattleHolds.count, 1)
        XCTAssertThrowsError(try store.holdOnlineBattle(key: key(), instanceID: "another"))
        XCTAssertThrowsError(try store.holdOnlineBattle(key: key("different"), instanceID: "entrant"))
        XCTAssertThrowsError(try store.applyVerifiedOnlineBattleEffect(effect("different")))
        let wrongInstance = try VerifiedOnlineBattleEffect(key: key(), resultHash: "hash", localInstanceID: "another",
            remainingHPShare: 0.5, outcome: .win)
        XCTAssertThrowsError(try store.applyVerifiedOnlineBattleEffect(wrongInstance))
        try store.releaseOnlineBattle(key: key("unknown"))
        XCTAssertTrue(store.isHeldForBattle(instanceID: "entrant"))
        let before = store.state
        try store.releaseOnlineBattle(key: key())
        XCTAssertEqual(store.state.battleHealth, before.battleHealth)
        XCTAssertEqual(store.state.onlineBattleReceipts, [])
        XCTAssertEqual(store.state.active?.usedAtStage, before.active?.usedAtStage)
        store.setHealthShare(0, of: "entrant")
        XCTAssertThrowsError(try store.holdOnlineBattle(key: key(), instanceID: "entrant"))
        store.setInBattle("current")
        XCTAssertThrowsError(try store.holdOnlineBattle(key: key(), instanceID: "current"))
        let practiceConflict = try VerifiedOnlineBattleEffect(key: key(), resultHash: "hash", localInstanceID: "current",
            remainingHPShare: 0.2, outcome: .draw)
        XCTAssertThrowsError(try store.applyVerifiedOnlineBattleEffect(practiceConflict))
        store.setInBattle(nil)
        _ = try store.applyVerifiedOnlineBattleEffect(effect())
        try store.holdOnlineBattle(key: key(), instanceID: "entrant")
        XCTAssertFalse(store.isHeldForBattle(instanceID: "entrant"))
    }
    func testLegacyMissingLedgerAcceptsButMalformedAndNullLedgerReject() throws {
        XCTAssertTrue(try JSONDecoder().decode(CompanionState.self, from: Data("{}".utf8)).onlineLedgerTrusted)
        for json in [#"{"onlineBattleReceipts":null}"#, #"{"onlineBattleHolds":"bad"}"#,
                     #"{"onlineLedgerTrusted":null}"#, #"{"onlineBattleReceipts":[{}]}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(CompanionState.self, from: Data(json.utf8)))
        }
        var untrusted = state(); untrusted.onlineLedgerTrusted = false
        let store = try make(untrusted)
        let envelope = try SaveTransfer.decode(SaveTransfer.encode(state: state(), appVersion: "test", deviceName: "test", now: now))
        try store.applySave(envelope, todayTokensByProvider: [:], todayDate: "day", hasUsageData: false)
        XCTAssertFalse(store.state.onlineLedgerTrusted)
        XCTAssertThrowsError(try store.holdOnlineBattle(key: key(), instanceID: "entrant"))
        XCTAssertThrowsError(try store.applyVerifiedOnlineBattleEffect(effect()))
    }
    func testInvalidTypedInputsAndLedgerContentsFailClosed() throws {
        for hp in [-0.1, 1.1, Double.nan, Double.infinity] { XCTAssertThrowsError(try effect(hp: hp)) }
        XCTAssertThrowsError(try effect("")); XCTAssertThrowsError(try effect(hash: ""))
        let receipt = OnlineBattleEffectReceipt(key: key(), resultHash: "hash", localInstanceID: "entrant",
            appliedHPShare: 0.2, grantedXP: 1, recipientInstanceID: "current", rewardDate: "2026-10-31")
        var malformed = state(); malformed.onlineBattleReceipts = [receipt]
        XCTAssertThrowsError(try JSONDecoder().decode(CompanionState.self, from: JSONEncoder().encode(malformed)))
        let hold = OnlineBattleHold(key: key(), instanceID: "entrant")
        malformed = state(); malformed.onlineBattleHolds = [hold, hold]
        XCTAssertThrowsError(try JSONDecoder().decode(CompanionState.self, from: JSONEncoder().encode(malformed)))
        let emptyKey = OnlineBattleReceiptKey(scope: .init(originHash: "", groupID: "g", trainerID: "t"), battleID: "b")
        XCTAssertThrowsError(try OnlineBattleLedger.validate(key: emptyKey, instanceID: "entrant"))
        let store = try make()
        XCTAssertThrowsError(try store.holdOnlineBattle(key: key(), instanceID: ""))
    }

}
