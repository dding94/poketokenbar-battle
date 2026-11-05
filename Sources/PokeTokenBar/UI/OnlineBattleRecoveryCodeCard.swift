import AppKit
import SwiftUI

/// The recovery code, shown once. It leaves the screen two ways: copied (the clipboard has it, so the screen forgets it,
/// like a host's one-time code) or written down (the person ticks the box, then the keep button opens).
@MainActor
struct OnlineBattleRecoveryCodeCard: View {
    let model: OnlineBattlePresentation
    let l: L
    var writeClipboard: (String) -> Bool = { text in
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }

    /// Puts the shown code on the clipboard; only then does the screen forget it. A refused write keeps it on screen.
    func copyCode() {
        guard let code = model.recoveryCode, writeClipboard(code) else { return }
        model.send(.recoveryCopied)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(l.onlineRecoveryTitle, systemImage: "key").font(.headline)
            Text(l.onlineRecoveryHint).font(.callout).fixedSize(horizontal: false, vertical: true)
            if let code = model.recoveryCode {
                Text(code).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("online.recovery.code")
            }
            Button(l.onlineRecoveryCopy) { copyCode() }
                .accessibilityIdentifier("online.recovery.copy")
            Toggle(l.onlineRecoveryWrittenDown, isOn: Binding(get: { model.recoveryWrittenDown },
                                                              set: { model.send(.setRecoveryWrittenDown($0)) }))
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("online.recovery.written")
            Button(l.onlineRecoverySaved) { model.send(.acknowledgeRecoveryCode) }
                .buttonStyle(.borderedProminent).disabled(!model.canAcknowledgeRecoveryCode)
                .accessibilityIdentifier("online.recovery.keep")
            if !model.canAcknowledgeRecoveryCode {
                Text(l.onlineRecoveryNeedsCheck).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("online.recovery.reason")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .practiceCard()
        .privacySensitive()
    }
}
