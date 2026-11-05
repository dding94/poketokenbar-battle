import SwiftUI

/// The home "Online battle" row: the title, under it the one-line status, and the chevron.
@MainActor
struct OnlineEntryRow: View {
    let l: L
    let subtitle: String?
    /// Shown under the subtitle while macOS notifications are off, so the menu-bar mark is not the only cue.
    var hint: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Label(l.onlineTitle, systemImage: "network")
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    }
                    if let hint {
                        Text(hint).font(.caption2).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption)
            }.frame(maxWidth: .infinity).contentShape(Rectangle())
        }.buttonStyle(.plain).practiceCard()
    }
}
