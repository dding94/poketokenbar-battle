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
    /// A reroll or a Mint changes the stats behind the snapshot this hold's room was consented with, so the room would
    /// stop at the next confirm or ready with "entry changed". The hold exists from the request to the settlement.
    func testAHeldIndividualKeepsItsIVsAndNatureUntilTheHoldEnds() throws {
        var s = state(); s.inventory = [ItemKind.ivReroll.rawValue: 1, ItemKind.mint.rawValue: 1]
        s.active?.nature = .hardy
        let store = try make(s)
        let ivs = store.state.active?.profile?.ivs
        try store.holdOnlineBattle(key: key(), instanceID: "current")
        XCTAssertNil(store.useIVReroll(), "the room's snapshot has these IVs")
        XCTAssertNil(store.useMint(), "the room's snapshot has this nature")
        XCTAssertEqual(store.state.active?.profile?.ivs, ivs)
        XCTAssertEqual(store.state.active?.nature, .hardy)
        XCTAssertEqual(store.itemCount(.ivReroll), 1, "a refused use spends nothing")
        XCTAssertEqual(store.itemCount(.mint), 1, "a refused use spends nothing")
        try store.releaseOnlineBattle(key: key())
        XCTAssertNotNil(store.useIVReroll())
        XCTAssertNotNil(store.useMint())
    }
    /// The boundary of healing someone other than the current Pokémon: a graduate in a room or waiting for its result
    /// takes no item, and the settlement's HP is what a Potion then starts from. The Potion refused during the hold
    /// stays in the bag rather than being overwritten by the settlement.
    func testAGraduateHeldForAResultTakesNoItemUntilItSettles() throws {
        var s = state(); s.inventory = [ItemKind.potion.rawValue: 1, ItemKind.mint.rawValue: 1, ItemKind.ivReroll.rawValue: 1]
        s.battleHealth["entrant"] = 0.5
        s.dex = [DexEntry(baseID: 7, finalID: 9, chainOrder: [7, 8, 9], rarity: .common, caughtAt: nil, nature: .calm,
                          profile: PokemonProfile.generate(seed: 2, instanceID: "entrant"))]
        let store = try make(s), before = store.state.dex[0]
        try store.holdOnlineBattle(key: key(), instanceID: "entrant")
        for kind in [ItemKind.potion, .mint, .ivReroll] {
            XCTAssertEqual(store.itemVerdict(kind, on: "entrant"), .inBattle, "\(kind)")
        }
        XCTAssertEqual(store.itemTargets(.potion).map(\.verdict), [.inBattle], "the row says why instead of vanishing")
        XCTAssertFalse(store.useHealingItem(.potion, on: "entrant"))
        XCTAssertNil(store.useMint(on: "entrant")); XCTAssertNil(store.useIVReroll(on: "entrant"))
        XCTAssertEqual(store.state.dex[0].nature, before.nature); XCTAssertEqual(store.state.dex[0].profile, before.profile)
        XCTAssertEqual(store.state.inventory, s.inventory, "nothing spent")
        XCTAssertNotNil(store.itemTargets(.mint).first { $0.id == "current" && $0.verdict == .usable }, "others stay reachable")
        // The result arrives while the hold still stands, then the HP it set is what the bag works from.
        _ = try store.applyVerifiedOnlineBattleEffect(effect(outcome: .win, hp: 0.2))
        XCTAssertFalse(store.isHeldForBattle(instanceID: "entrant"))
        XCTAssertEqual(store.healthShare(of: "entrant"), 0.2)
        XCTAssertTrue(store.useHealingItem(.potion, on: "entrant"))
        XCTAssertEqual(store.healthShare(of: "entrant"), 0.2 + BattleItem.potionHeal, accuracy: 1e-9)
        XCTAssertEqual(open().state.battleHealth["entrant"] ?? -1, 0.2 + BattleItem.potionHeal, accuracy: 1e-9, "the save agrees after a restart")
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

    func testAtomicWriterSeesOldPublishedStateAndFailureCannotReleaseHold() throws {
        var store: CompanionStore!
        var fail = false
        var inspectCommit = false
        var writes = 0
        store = try make(writer: { data, url in
            writes += 1
            if inspectCommit {
                XCTAssertEqual(store.state.onlineBattleReceipts.count, 0)
                XCTAssertEqual(store.healthShare(of: "entrant"), 1)
                XCTAssertTrue(store.isHeldForBattle(instanceID: "entrant"))
                let candidate = try JSONDecoder().decode(CompanionState.self, from: data)
                XCTAssertEqual(candidate.onlineBattleReceipts.count, 1)
                XCTAssertEqual(candidate.active?.usedAtStage, 11_000_000)
                XCTAssertTrue(candidate.onlineBattleHolds.isEmpty)
            }
            if fail { throw OnlineBattleEffectError.invalidEffect }
            try data.write(to: url, options: .atomic)
        })
        try store.holdOnlineBattle(key: key(), instanceID: "entrant")
        fail = true
        XCTAssertThrowsError(try store.releaseOnlineBattle(key: key()))
        XCTAssertTrue(store.isHeldForBattle(instanceID: "entrant"))
        fail = false; inspectCommit = true
        _ = try store.applyVerifiedOnlineBattleEffect(effect())
        XCTAssertEqual(writes, 3)
        _ = try store.applyVerifiedOnlineBattleEffect(effect())
        XCTAssertEqual(writes, 3, "duplicates never call the writer")
    }
    func testUnpaidNoActiveReceiptsDoNotConsumeLaterQuota() throws {
        let store = try make(state(active: false))
        for i in 0..<11 { XCTAssertEqual(try store.applyVerifiedOnlineBattleEffect(effect("egg\(i)")).grantedXP, 0) }
        let envelope = try SaveTransfer.decode(SaveTransfer.encode(state: state(), appVersion: "test", deviceName: "test", now: now))
        try store.applySave(envelope, todayTokensByProvider: [:], todayDate: "day", hasUsageData: false)
        for i in 0..<10 { XCTAssertEqual(try store.applyVerifiedOnlineBattleEffect(effect("active\(i)")).grantedXP, 10_000_000) }
        XCTAssertEqual(try store.applyVerifiedOnlineBattleEffect(effect("eleventh")).grantedXP, 0)
    }
    func testIncomingAndCurrentReceiptUnionKeepsBothAndDeduplicates() throws {
        let current = try make()
        let receipt = try current.applyVerifiedOnlineBattleEffect(effect())
        let incoming = try make(name: "incoming")
        let other = try incoming.applyVerifiedOnlineBattleEffect(effect("other"))
        var incomingState = incoming.state; incomingState.onlineBattleReceipts.append(receipt)
        let envelope = try SaveTransfer.decode(SaveTransfer.encode(state: incomingState, appVersion: "test", deviceName: "test", now: now))
        try current.applySave(envelope, todayTokensByProvider: [:], todayDate: "day", hasUsageData: false)
        XCTAssertEqual(current.state.onlineBattleReceipts, [receipt, other])
        XCTAssertEqual(try current.applyVerifiedOnlineBattleEffect(effect("other")), other)
        XCTAssertEqual(try current.applyVerifiedOnlineBattleEffect(effect()), receipt)
    }
    func testRecoveredSnapshotAndMissingFallbackFileRemainUntrusted() throws {
        let original = try make()
        _ = try original.createManualSnapshot()
        _ = try original.applyVerifiedOnlineBattleEffect(effect())
        try Data("broken".utf8).write(to: folder.appendingPathComponent("save"))
        let recovered = open()
        XCTAssertNotNil(recovered.state.active, "snapshot really recovered the older active individual")
        XCTAssertFalse(recovered.state.onlineLedgerTrusted)
        XCTAssertThrowsError(try recovered.applyVerifiedOnlineBattleEffect(effect()))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("save"))
        let missing = open()
        XCTAssertFalse(missing.state.onlineLedgerTrusted, "corrupt marker survives an unsuccessful fallback write")
        XCTAssertThrowsError(try missing.applyVerifiedOnlineBattleEffect(effect()))
    }
    func testConcurrentDuplicateDeliveriesPayOnce() async throws {
        let store = try make()
        let input = try effect()
        async let first = Task { @MainActor in try store.applyVerifiedOnlineBattleEffect(input) }.value
        async let second = Task { @MainActor in try store.applyVerifiedOnlineBattleEffect(input) }.value
        let receipts = try await (first, second)
        XCTAssertEqual(receipts.0, receipts.1)
        XCTAssertEqual(store.state.onlineBattleReceipts.count, 1)
        XCTAssertEqual(store.state.active?.usedAtStage, 11_000_000)
    }

    func testImportDoesNotResurrectACompletedBattleHold() throws {
        let store = try make()
        try store.holdOnlineBattle(key: key(), instanceID: "entrant")
        let stale = try SaveTransfer.decode(store.exportedSaveData(appVersion: "test", deviceName: "test"))
        _ = try store.applyVerifiedOnlineBattleEffect(effect())
        XCTAssertFalse(store.isHeldForBattle(instanceID: "entrant"))
        try store.applySave(stale, todayTokensByProvider: [:], todayDate: "day", hasUsageData: false)
        _ = try store.applyVerifiedOnlineBattleEffect(effect())
        XCTAssertFalse(store.isHeldForBattle(instanceID: "entrant"))
        XCTAssertEqual(store.state.onlineBattleReceipts.count, 1)
    }
    func testPresentUnreadableStateIsNotAFreshTrustedLedger() throws {
        XCTAssertTrue(open("fresh").state.onlineLedgerTrusted, "a genuinely missing file remains a new installation")
        let unreadable = folder.appendingPathComponent("directory")
        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
        XCTAssertThrowsError(try Data(contentsOf: unreadable), "real read failure reaches the load branch")
        var writes = 0
        let store = open("directory", writer: { _, _ in writes += 1 })
        XCTAssertFalse(store.state.onlineLedgerTrusted)
        XCTAssertThrowsError(try store.applyVerifiedOnlineBattleEffect(effect())) { error in
            XCTAssertEqual(error as? OnlineBattleEffectError, .untrustedLedger)
        }
        XCTAssertEqual(writes, 0)
    }

    func testMalformedReceiptDayCannotHidePaidRewardFromQuota() throws {
        for day in ["2026-99-99", "2026-2-2", "garbage"] {
            let receipt = OnlineBattleEffectReceipt(key: key(), resultHash: "hash", localInstanceID: "entrant",
                appliedHPShare: 0.2, grantedXP: 10_000_000, recipientInstanceID: "current", rewardDate: day)
            var malformed = state(); malformed.onlineBattleReceipts = [receipt]
            XCTAssertThrowsError(try JSONDecoder().decode(CompanionState.self, from: JSONEncoder().encode(malformed)))
        }
    }

    func testPaidReceiptRequiresRecipientAndUnpaidReceiptCannotNameOne() throws {
        for (xp, recipient) in [(10_000_000, nil as String?), (10_000_000, ""), (0, "current")] {
            let receipt = OnlineBattleEffectReceipt(key: key(), resultHash: "hash", localInstanceID: "entrant",
                appliedHPShare: 0.2, grantedXP: xp, recipientInstanceID: recipient, rewardDate: "2026-10-31")
            var malformed = state(); malformed.onlineBattleReceipts = [receipt]
            XCTAssertThrowsError(try JSONDecoder().decode(CompanionState.self, from: JSONEncoder().encode(malformed)))
        }
    }

    func testRewardDayUsesInjectedLocalCalendarAtMidnightAndDST() throws {
        var korea = Calendar(identifier: .gregorian); korea.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Seoul"))
        var losAngeles = Calendar(identifier: .gregorian); losAngeles.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let parser = ISO8601DateFormatter()
        let midnight = try XCTUnwrap(parser.date(from: "2026-11-01T15:00:00Z"))
        XCTAssertEqual(OnlineBattleLedger.day(midnight.addingTimeInterval(-1), calendar: korea), "2026-11-01")
        XCTAssertEqual(OnlineBattleLedger.day(midnight, calendar: korea), "2026-11-02")
        for hour in ["08", "09"] {
            let repeatedHour = try XCTUnwrap(parser.date(from: "2026-11-01T\(hour):30:00Z"))
            XCTAssertEqual(OnlineBattleLedger.day(repeatedHour, calendar: losAngeles), "2026-11-01")
        }
    }

}
