import SwiftUI

/// The event the person should look at, shown above whatever screen the popover is on. With the popover in front this
/// replaces the macOS notification, so it has to be visible everywhere. The whole bar goes to the event.
@MainActor
struct OnlineAttentionBanner: View {
    let attention: OnlineAttention
    let l: L
    let onOpen: () -> Void
    /// Only an ended request can be closed unread: every other event stays until it is answered.
    var onDismiss: (() -> Void)?

    var body: some View {
        // Only a turn counts down, so nothing redraws on a timer for the other kinds.
        if attention.deadline == nil {
            content(now: Date())
        } else {
            TimelineView(.periodic(from: Date(), by: 1)) { context in content(now: context.date) }
        }
    }

    private func content(now: Date) -> some View {
        let text = l.onlineAttentionCopy(attention, now: now).banner
        return HStack(alignment: .top, spacing: 8) {
            Button(action: onOpen) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "bell.badge.fill").foregroundStyle(Color.accentColor).accessibilityHidden(true)
                    Text(text).font(.callout).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(text)
            .accessibilityIdentifier("online.attentionBanner")
            if let onDismiss {
                Button(action: onDismiss) { Image(systemName: "xmark").font(.caption).foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .help(l.onlineDismissNotice).accessibilityLabel(l.onlineDismissNotice)
                    .accessibilityIdentifier("online.attentionBanner.dismiss")
            }
        }
        .padding(10)
        .frame(width: PopoverMetrics.contentWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1))
    }
}
