import Foundation

/// Wording for a challenge that ended, a banner that can be closed, and the waiting screens.
/// It only says what this app knows: an opponent shown as online may be away, so nothing here
/// promises that the other side has seen the request.
extension L {
    func onlineEndedNotice(_ state: OnlineBattleState, opponent: String?, reason: String?) -> String? {
        let name = opponent ?? onlineAnonymous
        switch state {
        case .declined:
            return online("\(name)님이 신청을 거절했어요. 다른 동료에게 신청해 보세요.", "\(name) declined your challenge. Try another trainer.")
        case .cancelled:
            if reason == "participant_left" {
                return online("\(name)님이 그룹을 떠나 신청이 취소됐어요.", "\(name) left the group, so the challenge was cancelled.")
            }
            return online("\(name)님이 신청을 취소했어요.", "\(name) cancelled the challenge.")
        case .expired:
            return online("\(name)님과의 신청 시간이 지났어요. 다시 신청할 수 있어요.", "Your challenge with \(name) timed out. You can send it again.")
        default:
            return nil
        }
    }
    var onlineDismissNotice: String { online("닫기", "Dismiss") }
    var onlineCancelBattle: String { online("대결 취소", "Cancel battle") }
    var onlineVerifyingAuto: String {
        online("자동으로 갱신돼요(보통 수 초). 바로 확인하고 싶을 때만 새로고침을 눌러 주세요.",
               "This updates automatically, usually within a few seconds. Refresh only to check right now.")
    }
    func onlineAwaitingResponse(opponent: String?) -> String {
        let name = opponent ?? onlineAnonymous
        return online("\(name)님의 응답을 기다리는 중이에요. 상대가 바로 확인하지 못할 수도 있어요.",
                      "Waiting for \(name) to respond. They may not see it right away.")
    }
    /// Clock time plus what is left, so a slow minute-level tick is enough.
    func onlineRequestExpiry(remaining: TimeInterval, expiresAt: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: lang == .ko ? "ko_KR" : "en_US_POSIX")
        formatter.dateFormat = lang == .ko ? "M월 d일 HH:mm" : "MMM d, HH:mm"
        let clock = formatter.string(from: expiresAt)
        if remaining <= 0 {
            return online("신청 시간(\(clock))이 지났어요. 곧 정리돼요.", "The challenge time (\(clock)) has passed. It will be cleared soon.")
        }
        let minutes = Int(remaining) / 60
        if minutes < 1 { return online("곧 만료돼요 (\(clock))", "Expires any moment (\(clock))") }
        let koLeft = minutes < 60 ? "약 \(minutes)분" : "약 \(minutes / 60)시간"
        let enLeft = minutes < 60 ? "about \(minutes) min" : "about \(minutes / 60) h"
        return online("응답이 없으면 \(clock)에 만료돼요 (\(koLeft) 남음)", "Expires \(clock) if there is no answer (\(enLeft) left)")
    }
}
