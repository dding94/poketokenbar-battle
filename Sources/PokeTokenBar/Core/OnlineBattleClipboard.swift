import AppKit

/// Codes on the clipboard. Only a click reaches this: nothing reads or writes the clipboard on its own.
enum OnlineBattleClipboard {
    /// The nspasteboard.org convention clipboard histories look for. Its value is not read, only its presence.
    static var concealedType: NSPasteboard.PasteboardType { .init("org.nspasteboard.ConcealedType") }

    /// False when the pasteboard refused it, so the code can stay on screen.
    static func write(_ text: String, to pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { return false }
        pasteboard.setData(Data(), forType: concealedType)
        return true
    }

    /// A code that did its job does not linger. Anything else on the clipboard is the person's own and stays.
    static func forget(_ code: String, on pasteboard: NSPasteboard = .general) {
        guard let text = pasteboard.string(forType: .string), holds(code, in: text) else { return }
        pasteboard.clearContents()
    }

    private static func holds(_ code: String, in text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines), wanted = code.trimmingCharacters(in: .whitespacesAndNewlines)
        if value == wanted { return true }
        guard let token = OnlineBattleSetupInput.inviteToken(wanted) else { return false }
        if OnlineBattleSetupInput.inviteToken(value) == token { return true }
        // A manual build's host copies the address and the code as two labelled lines. A longer message is not that.
        guard value.components(separatedBy: .newlines).filter({ !$0.isEmpty }).count == 2 else { return false }
        var probe = OnlineBattleSetupInput(server: "https://probe.example.invalid")
        return probe.pasteInvitation(value, embeddedServer: nil) == nil && probe.invite == token
    }
}
