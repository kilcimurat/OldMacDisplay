import AppKit

/// Shared visual vocabulary for the two panes.
///
/// Both tabs were built as a single flat column of labels, which left no visual
/// hierarchy: a heading, a live status line and a preference all carried the
/// same weight. These helpers give the panes one set of cards, titles and
/// spacings so the two halves of the app look like the same app.
///
/// Everything here is AppKit that predates Catalina — no SF Symbols, no
/// `NSStackView` API added after 10.15 — because the Receiver runs on 10.15.
enum PaneStyle {

    enum Metrics {
        /// Outer margin around a pane's content.
        static let paneInset: CGFloat = 18
        /// Padding inside a card.
        static let cardPadding: CGFloat = 14
        /// Gap between cards.
        static let sectionSpacing: CGFloat = 14
        /// Gap between rows inside a card.
        static let rowSpacing: CGFloat = 6
    }

    // MARK: - Text

    static func title(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 15, weight: .semibold)
        return field
    }

    /// Small all-caps heading that names a card, as macOS settings panes do.
    static func sectionHeading(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text.uppercased())
        field.font = .systemFont(ofSize: 10, weight: .semibold)
        field.textColor = .tertiaryLabelColor
        return field
    }

    static func caption(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.textColor = .secondaryLabelColor
        return field
    }

    /// A value that changes while the app runs. Monospaced digits so numbers
    /// stop jittering as they update.
    static func liveValue() -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        field.textColor = .secondaryLabelColor
        return field
    }

    static func secondary(_ text: String = "") -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 12)
        field.textColor = .secondaryLabelColor
        return field
    }

    // MARK: - Containers

    /// A rounded panel holding one group of related controls.
    static func card(_ content: NSView) -> NSView {
        let box = NSBox()
        box.boxType = .custom
        box.borderWidth = 1
        box.cornerRadius = 8
        box.fillColor = .controlBackgroundColor
        box.borderColor = .separatorColor
        box.contentViewMargins = .zero
        box.titlePosition = .noTitle

        content.translatesAutoresizingMaskIntoConstraints = false
        box.contentView = content

        let padding = Metrics.cardPadding
        if let container = box.contentView?.superview ?? box.contentView {
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: container.leadingAnchor,
                                                 constant: padding),
                content.trailingAnchor.constraint(equalTo: container.trailingAnchor,
                                                  constant: -padding),
                content.topAnchor.constraint(equalTo: container.topAnchor, constant: padding),
                content.bottomAnchor.constraint(equalTo: container.bottomAnchor,
                                                constant: -padding)
            ])
        }
        return box
    }

    /// A card with a heading above it, returned as one stacked unit.
    static func section(_ heading: String, _ content: NSView) -> NSStackView {
        let panel = card(content)
        let stack = NSStackView(views: [sectionHeading(heading), panel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        // A leading-aligned stack sizes the card to its content, which leaves a
        // half-width panel whenever the content is short or still empty. The
        // card is the section, so it spans the section.
        panel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    static func column(_ views: [NSView], spacing: CGFloat = Metrics.rowSpacing) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    static func row(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = spacing
        return stack
    }

    /// Flexible gap that pushes what follows to the trailing edge.
    static func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        return view
    }

    /// Sets a label's text and takes it out of the layout when it has none.
    ///
    /// The panes are columns of live values, several of which are empty until
    /// something is streaming. Left visible, each one reserves a blank line and
    /// the card fills with gaps.
    static func setText(_ field: NSTextField, _ text: String) {
        field.stringValue = text
        field.isHidden = text.isEmpty
    }

    // MARK: - Status light

    /// The coloured dot beside a status line.
    final class StatusDot: NSView {
        enum State { case idle, working, live, failed }

        override var intrinsicContentSize: NSSize { NSSize(width: 10, height: 10) }

        init() {
            super.init(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
            wantsLayer = true
            layer?.cornerRadius = 5
            apply(.idle)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        func apply(_ state: State) {
            let color: NSColor
            switch state {
            case .idle:    color = .systemGray
            case .working: color = .systemOrange
            case .live:    color = .systemGreen
            case .failed:  color = .systemRed
            }
            layer?.backgroundColor = color.cgColor
        }
    }
}
