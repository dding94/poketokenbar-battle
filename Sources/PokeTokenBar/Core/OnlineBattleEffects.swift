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
    func isHeldForBattle(instanceID: String) -> Bool
}
