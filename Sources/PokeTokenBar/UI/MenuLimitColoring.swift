import AppKit

/// Colors the menu bar's limit items in their gauge color.
enum MenuLimitColoring {
    /// Each run colors one whole "Label NN%" item. Labels are unique per provider and the token/cost
    /// line never contains one, so a plain search finds the item. Separators and the token/cost line are
    /// left alone and keep the system text color, which follows the menu bar's light/dark appearance.
    static func apply(_ runs: [UsageStore.MenuLimitColorRun], to string: NSMutableAttributedString) {
        let text = string.string as NSString
        for run in runs {
            let range = text.range(of: run.text)
            guard range.location != NSNotFound else { continue }
            string.addAttribute(.foregroundColor, value: NSColor(run.tier.color), range: range)
        }
    }
}

/// Colors the online mark at the end of the menu bar's first line. An ongoing room keeps the system text color.
enum MenuOnlineMarkColoring {
    static func color(for tone: OnlineMenuMark.Tone) -> NSColor? {
        switch tone {
        case .attention: .systemBlue
        case .urgent: .systemRed
        case .ongoing: nil
        }
    }

    /// The mark sits at the end of the first line, so the last match in the text is the mark itself.
    static func apply(_ mark: OnlineMenuMark?, to string: NSMutableAttributedString) {
        guard let mark, let color = color(for: mark.tone) else { return }
        let range = (string.string as NSString).range(of: mark.text, options: .backwards)
        guard range.location != NSNotFound else { return }
        string.addAttribute(.foregroundColor, value: color, range: range)
    }
}
