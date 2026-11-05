import SwiftUI

/// The home "Online battle" row: the title, under it the one-line status, and the chevron.
struct OnlineEntryRow: View {
    let l: L
    let subtitle: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Label(l.onlineTitle, systemImage: "network")
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption)
            }.frame(maxWidth: .infinity).contentShape(Rectangle())
        }.buttonStyle(.plain).practiceCard()
    }
}
