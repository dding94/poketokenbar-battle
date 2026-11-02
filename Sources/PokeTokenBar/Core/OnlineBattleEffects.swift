import Foundation

struct OnlineBattleScope: Codable, Hashable, Sendable {
    let originHash: String
    let groupID: String
    let trainerID: String
}
struct OnlineBattleReceiptKey: Codable, Hashable, Sendable {
    let scope: OnlineBattleScope
    let battleID: String
}
enum OnlineBattleOutcome: String, Codable, Sendable { case win, loss, draw }
enum OnlineBattleEffectError: Error, Equatable {
    case invalidEffect, conflictingResult, untrustedLedger, individualHeld, faintedIndividual
}
/// Constructed by the replay boundary only after every local terminal field matches the server result.
struct VerifiedOnlineBattleEffect: Sendable {
    let key: OnlineBattleReceiptKey
    let resultHash: String
    let localInstanceID: String
    let remainingHPShare: Double
    let outcome: OnlineBattleOutcome

    init(key: OnlineBattleReceiptKey, resultHash: String, localInstanceID: String,
         remainingHPShare: Double, outcome: OnlineBattleOutcome) throws {
        try OnlineBattleLedger.validate(key: key, instanceID: localInstanceID)
        guard !resultHash.isEmpty, remainingHPShare.isFinite, (0...1).contains(remainingHPShare) else {
            throw OnlineBattleEffectError.invalidEffect
        }
        self.key = key; self.resultHash = resultHash; self.localInstanceID = localInstanceID
        self.remainingHPShare = remainingHPShare; self.outcome = outcome
    }
}
struct OnlineBattleEffectReceipt: Codable, Equatable, Sendable {
    let key: OnlineBattleReceiptKey
    let resultHash: String
    let localInstanceID: String
    let appliedHPShare: Double
    let grantedXP: Int
    let recipientInstanceID: String?
    let rewardDate: String
}
struct OnlineBattleHold: Codable, Equatable, Sendable {
    let key: OnlineBattleReceiptKey
    let instanceID: String
}
@MainActor
protocol OnlineBattleEffects: PracticeBattleEffects {
    @discardableResult func applyVerifiedOnlineBattleEffect(_ effect: VerifiedOnlineBattleEffect) throws -> OnlineBattleEffectReceipt
    func holdOnlineBattle(key: OnlineBattleReceiptKey, instanceID: String) throws
    func releaseOnlineBattle(key: OnlineBattleReceiptKey) throws
}

/// Strict ledger validation intentionally differs from the legacy save's lenient display fields.
enum OnlineBattleLedger {
    static let winXP = 10_000_000
    static let dailyWins = 10

    /// Pure candidate construction: callers publish neither state nor growth before persisting this value.
    static func commit(_ effect: VerifiedOnlineBattleEffect, to state: CompanionState, on date: Date)
        -> (state: CompanionState, receipt: OnlineBattleEffectReceipt) {
        var candidate = state
        let hp = effect.outcome == .loss ? 0 : effect.remainingHPShare
        candidate.battleHealth[effect.localInstanceID] = hp < 1 ? hp : nil
        let rewardDay = day(date)
        let paidToday = state.onlineBattleReceipts.filter { $0.rewardDate == rewardDay && $0.grantedXP > 0 }.count
        let recipient = state.active?.profile?.instanceID
        let xp = effect.outcome == .win && recipient != nil && paidToday < dailyWins ? winXP : 0
        if xp > 0 { candidate.active!.usedAtStage += xp }
        let receipt = OnlineBattleEffectReceipt(key: effect.key, resultHash: effect.resultHash,
            localInstanceID: effect.localInstanceID, appliedHPShare: hp, grantedXP: xp,
            recipientInstanceID: xp > 0 ? recipient : nil, rewardDate: rewardDay)
        candidate.onlineBattleReceipts.append(receipt)
        candidate.onlineBattleHolds.removeAll { $0.key == effect.key }
        return (candidate, receipt)
    }

    static func day(_ date: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = calendar.timeZone
        return formatter.string(from: date)
    }

    private static func validDay(_ value: String) -> Bool {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        guard let date = formatter.date(from: value) else { return false }
        return formatter.string(from: date) == value
    }

    static func validate(key: OnlineBattleReceiptKey, instanceID: String) throws {
        guard !key.scope.originHash.isEmpty, !key.scope.groupID.isEmpty, !key.scope.trainerID.isEmpty,
              !key.battleID.isEmpty, !instanceID.isEmpty else { throw OnlineBattleEffectError.invalidEffect }
    }

    static func merged(_ first: [OnlineBattleEffectReceipt], _ second: [OnlineBattleEffectReceipt]) throws -> [OnlineBattleEffectReceipt] {
        var result: [OnlineBattleEffectReceipt] = []
        var seen: [OnlineBattleReceiptKey: OnlineBattleEffectReceipt] = [:]
        for receipt in first + second {
            try validate(key: receipt.key, instanceID: receipt.localInstanceID)
            guard !receipt.resultHash.isEmpty, receipt.appliedHPShare.isFinite,
                  (0...1).contains(receipt.appliedHPShare),
                  receipt.grantedXP == 0 || receipt.grantedXP == winXP,
                  (receipt.grantedXP == 0 && receipt.recipientInstanceID == nil)
                    || (receipt.grantedXP > 0 && !(receipt.recipientInstanceID ?? "").isEmpty),
                  validDay(receipt.rewardDate)
            else { throw OnlineBattleEffectError.invalidEffect }
            if let old = seen[receipt.key] {
                guard old == receipt else { throw OnlineBattleEffectError.conflictingResult }
            } else {
                seen[receipt.key] = receipt; result.append(receipt)
            }
        }
        return result
    }

    static func validate(holds: [OnlineBattleHold]) throws {
        var keys = Set<OnlineBattleReceiptKey>(), individuals = Set<String>()
        for hold in holds {
            try validate(key: hold.key, instanceID: hold.instanceID)
            guard keys.insert(hold.key).inserted, individuals.insert(hold.instanceID).inserted else {
                throw OnlineBattleEffectError.individualHeld
            }
        }
    }
}
