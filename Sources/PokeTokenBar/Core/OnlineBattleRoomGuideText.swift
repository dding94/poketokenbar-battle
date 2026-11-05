import Foundation

/// Room-guide wording. It only says what this app knows: an opponent shown as online may still be
/// away, so nothing here promises that the other side has seen anything.
extension L {
    func onlineStepName(_ step: OnlineRoomStep) -> String { "" }
    func onlineRoomGuide(_ progress: OnlineRoomProgress, opponent: String?) -> String { "" }
    func onlineActionBlock(_ block: OnlineActionBlock) -> String { "" }
    func onlineRequestSent(opponent: String?) -> String { "" }
    func onlineRequestAge(seconds: Int) -> String { "" }
    var onlineOwnReady: String { "" }
    func onlineOpponentOffline(_ opponent: String?) -> String { "" }
}
