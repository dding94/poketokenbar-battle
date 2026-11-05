import SwiftUI

/// A notice the person can close: an ended challenge or an error. Closing only clears the banner.
struct OnlineBattleNoticeBanner: View {
    let text: String
    let l: L
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(text).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("online.notice")
            }
            HStack {
                Spacer(minLength: 0)
                Button(l.onlineDismissNotice, action: onDismiss)
                    .buttonStyle(.borderless).font(.caption)
                    .accessibilityIdentifier("online.notice.dismiss")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.5), lineWidth: 1))
    }
}
