import SwiftUI

/// The three lines shown once on the first lobby, right after the recovery code was kept or copied.
@MainActor
struct OnlineBattleFirstStepsCard: View {
    let steps: OnlineBattleFirstSteps
    let l: L
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if steps.copiedRecoveryCode {
                Label(l.onlineRecoveryCopied, systemImage: "checkmark.circle.fill")
                    .font(.caption).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("online.firststeps.copied")
            }
            Text(l.onlineFirstStepsTitle).font(.subheadline.bold())
            ForEach(Array(l.onlineFirstSteps.enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer(minLength: 0)
                Button(l.onlineFirstStepsDismiss, action: onDismiss)
                    .buttonStyle(.borderless).font(.caption)
                    .accessibilityIdentifier("online.firststeps.dismiss")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .practiceCard()
        .accessibilityIdentifier("online.firststeps")
    }
}
