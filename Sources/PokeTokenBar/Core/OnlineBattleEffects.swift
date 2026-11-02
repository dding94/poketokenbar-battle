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
        guard !key.scope.originHash.isEmpty, !key.scope.groupID.isEmpty, !key.scope.trainerID.isEmpty,
              !key.battleID.isEmpty, !resultHash.isEmpty, !localInstanceID.isEmpty,
              remainingHPShare.isFinite, (0...1).contains(remainingHPShare) else {
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
    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
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
                  receipt.grantedXP == 0 || receipt.grantedXP == 10_000_000,
                  (receipt.grantedXP == 0 && receipt.recipientInstanceID == nil)
                    || (receipt.grantedXP > 0 && !(receipt.recipientInstanceID ?? "").isEmpty),
                  receipt.rewardDate.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
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
