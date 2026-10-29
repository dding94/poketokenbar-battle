import AppKit
import SwiftUI

@MainActor
struct PracticeBattleView: View {
    let roster: PracticeRoster
    @Bindable var model: PracticeBattle
    var artwork = true
    var liveUpdates = true
    var body: some View { Text("준비 중") }
}
