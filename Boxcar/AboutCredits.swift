import AppKit

enum AboutCredits {
    private static let authorName = "Nate Silva"
    private static let authorURL = URL(string: "https://natesilva.dev")

    static var attributedString: NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        let text = NSMutableAttributedString(
            string: "Copyright © 2026 \(authorName)",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraphStyle,
            ]
        )
        if let authorURL {
            text.addAttribute(.link, value: authorURL, range: (text.string as NSString).range(of: authorName))
        }
        return text
    }
}
