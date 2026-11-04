import SwiftUI

enum OnlineBattleStandingDisplay {
    static func winRate(_ row: OnlineBattleStanding) -> String {
        guard row.wins + row.losses + row.draws >= 5, let rate = row.winRate else { return "-" }
        return String(format: "%.1f%%", rate * 100)
    }
    static func isChampion(_ row: OnlineBattleStanding, in board: OnlineBattleStandings) -> Bool {
        board.championTrainerId == row.trainerId && row.streak > 0
    }
}

@MainActor
struct OnlineBattleStandingsScreen: View {
    let model: OnlineBattlePresentation
    let l: L

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { model.send(.backToLobby) } label: {
                    Label(l.onlineDone, systemImage: "chevron.left")
                }.buttonStyle(.borderless).accessibilityIdentifier("online.standings.back")
                Spacer(minLength: 4)
                Button { model.send(.refreshStandings) } label: {
                    Image(systemName: "arrow.clockwise")
                }.buttonStyle(.borderless).accessibilityLabel(l.onlineRefresh)
                    .disabled(model.standingsLoading)
                    .accessibilityIdentifier("online.standings.refresh")
            }
            Text(l.onlineStandings).font(.headline)
            Text(model.account?.group.name ?? l.onlineTitle)
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if model.standingsLoading {
                Label(l.onlineStandingsLoading, systemImage: "hourglass")
                    .font(.caption).practiceCard()
            }
            if let error = model.standingsError {
                VStack(alignment: .leading, spacing: 8) {
                    Label(l.onlineStandingsUnavailable, systemImage: "exclamationmark.triangle")
                        .font(.callout.bold())
                    Text(error).font(.caption).fixedSize(horizontal: false, vertical: true)
                    Button(l.onlineRetry) { model.send(.refreshStandings) }
                        .disabled(model.standingsLoading)
                        .accessibilityIdentifier("online.standings.retry")
                }.frame(maxWidth: .infinity, alignment: .leading).practiceCard()
            } else if let standings = model.standings,
                      standings.groupId == model.account?.group.groupId {
                if standings.rows.isEmpty {
                    Text(l.onlineNoStandings).font(.caption).foregroundStyle(.secondary).practiceCard()
                } else {
                    ForEach(standings.rows) { row in
                        standing(row, board: standings).practiceCard(padding: 9)
                    }
                    Text(l.onlineStandingsRateHint)
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if !model.standingsLoading {
                Text(l.onlineStandingsUnavailable)
                    .font(.caption).foregroundStyle(.secondary).practiceCard()
            }
        }
    }

    private func standing(_ row: OnlineBattleStanding, board: OnlineBattleStandings) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 5) {
                Text(row.displayName).font(.subheadline.bold())
                    .lineLimit(1).truncationMode(.middle)
                if OnlineBattleStandingDisplay.isChampion(row, in: board) {
                    Label(l.onlineChampion, systemImage: "crown.fill")
                        .font(.caption2.bold()).foregroundStyle(.orange)
                        .accessibilityIdentifier("online.standings.champion")
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 9) {
                Text(l.onlineRecord(row.wins, row.losses, row.draws))
                Spacer(minLength: 0)
                Text(l.onlineWinRate(OnlineBattleStandingDisplay.winRate(row)))
            }.font(.caption).monospacedDigit().foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Text(l.onlineCurrentStreak(row.streak))
                Spacer(minLength: 0)
                Text(l.onlineBestStreak(row.bestStreak))
            }.font(.caption2).monospacedDigit().foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("online.standings.row.\(row.trainerId)")
    }
}
