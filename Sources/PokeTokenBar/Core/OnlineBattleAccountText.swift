import Foundation

/// Wording for what an account brings along from another save, server or code.
extension L {
    /// A room entered with a pokemon this save does not have or cannot field. It is left out of the lists until it ends.
    var onlineOtherSaveBattle: String {
        online("다른 세이브에서 시작한 경기가 있어 이 세이브로는 이어갈 수 없어요. 그 포켓몬이 없거나 상태가 달라요. 경기를 시작한 세이브로 돌아가거나 시간이 지나 끝나기를 기다려 주세요. 체력과 경험치는 바뀌지 않아요.",
               "A battle started on another save cannot continue on this one: its Pokémon is missing here or in a different state. Go back to the save that started it, or wait for it to time out. HP and XP will not change.")
    }
    /// Above the join form of a build that fixed a server other than the address saved earlier. Never names either address.
    var onlineServerMoved: String {
        online("서버가 바뀌었어요. 이전 계정은 여기서 쓸 수 없으니 방장에게 새 초대코드를 받아 다시 가입해 주세요.",
               "The server has moved. Your earlier account does not carry over, so ask your host for a new invite code and join again.")
    }
    /// The choice arrived after the round closed. It did not fail: the turn went on without it.
    var onlineErrorRoundPassed: String {
        online("시간이 지나 이번 턴은 자동으로 처리됐어요. 화면을 최신 상태로 바꿨어요.", "Time ran out, so this turn was handled automatically. The screen is up to date now.")
    }
    var onlineOtherSaveResultTitle: String { online("기록으로만 남겼어요", "Kept as a record") }
    var onlineOtherSaveResultDetail: String {
        // No settlement receipt exists in this save, so nothing is claimed about what it did or did not change.
        online("이 세이브에 없는 포켓몬으로 치른 경기예요.", "This battle used a Pokémon this save does not have.")
    }
}
