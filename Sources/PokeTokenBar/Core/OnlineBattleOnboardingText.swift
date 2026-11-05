import Foundation

/// Words for the first minutes: the recovery code screen, the first lobby, its empty state and its rows.
/// Kept out of `OnlineBattleLocalization.swift`, which several online changes edit at once.
extension L {
    var onlineRecoveryCopy: String { online("복사", "Copy") }
    var onlineRecoveryWrittenDown: String { online("코드를 적어 뒀어요", "I wrote the code down") }
    /// Why the keep button is shut: the person has to copy the code or write it down first.
    var onlineRecoveryNeedsCheck: String {
        online("복사해 두거나 적어 둔 뒤에 눌러 주세요. 복사하면 이 화면에서 코드가 사라져요.",
               "Copy it or write it down first. Copying hides the code from this screen.")
    }
    /// The host panel's wording (`onlineHostCopied`) for the recovery code.
    var onlineRecoveryCopied: String {
        online("복구코드를 복사하고 화면에서 가렸어요. 다시 볼 수 없으니, 잃어버렸다면 방장에게 재연결 코드를 요청하세요.",
               "Recovery code copied and hidden. It cannot be shown again; if you lose it, ask the host for a reconnect code.")
    }

    var onlineFirstStepsTitle: String { online("이제 이렇게 해요", "Here is how it goes") }
    var onlineFirstSteps: [String] {
        [online("1. 동료와 출전할 포켓몬을 고르고 ‘정식전 신청’을 눌러요.", "1. Pick a member and your Pokémon, then send a challenge."),
         online("2. 상대가 수락하면 최종 확인과 전투 준비 순서로 이어져요.", "2. When they accept, you confirm, then get ready."),
         online("3. 팝오버를 닫아도 메뉴바 표식으로 알려 줘요.", "3. With this window closed, the menu bar mark tells you when it is your turn.")]
    }
    var onlineFirstStepsDismiss: String { online("알겠어요", "Got it") }

    func onlineNoPeers(isHost: Bool) -> String {
        isHost
            ? online("아직 다른 동료가 없어요. 오른쪽 위 ‘멤버 관리’에서 초대코드를 만들어 보내 주세요.",
                     "No one else has joined yet. Create an invite code under Manage members at the top right and send it.")
            : online("아직 다른 동료가 없어요. 방장에게 초대코드를 받아 함께 들어오세요.",
                     "No one else is here yet. Ask the host for an invite code and join together.")
    }

    func onlineLobbyBadge(_ badge: OnlineLobbyRowBadge) -> String {
        switch badge {
        case .received: online("받은 신청", "Received")
        case .sent: online("보낸 신청", "Sent")
        case .myTurn: online("내 차례", "Your turn")
        }
    }

    /// The line above the challenge button. The whole name is in it; the screen lets it wrap.
    func onlineChallengeConfirm(opponent: String) -> String {
        online("‘\(opponent)’님에게 정식전을 신청해요.", "You are about to challenge ‘\(opponent)’ to an official battle.")
    }
}
