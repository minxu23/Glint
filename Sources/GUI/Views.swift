// 自定义视图：空状态的拖放区、文件列表的行视图。

import AppKit

// MARK: - 拖放区（列表为空时显示）

final class DropZoneView: NSView {
    var onChooseFiles: (() -> Void)?
    private let dashLayer = CAShapeLayer()

    var isHighlighted = false {
        didSet { needsDisplay = true; updateDash() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        dashLayer.fillColor = nil
        dashLayer.lineDashPattern = [7, 5]
        dashLayer.lineWidth = 2
        layer?.addSublayer(dashLayer)

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 46, weight: .light)
        icon.contentTintColor = .tertiaryLabelColor

        let title = NSTextField(labelWithString: "把 JPEG 文件或文件夹拖到这里")
        title.font = .systemFont(ofSize: 17, weight: .regular)

        let subtitle = NSTextField(labelWithString: "转换成 HEIF，完整保留拍摄时间、拍摄位置、备注等全部元数据")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor

        let button = NSButton(title: "选择文件或文件夹…", target: self, action: #selector(choose))
        button.bezelStyle = .rounded
        button.controlSize = .large

        let stack = NSStackView(views: [icon, title, subtitle, button])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(16, after: subtitle)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
        ])
    }

    @objc private func choose() { onChooseFiles?() }

    override func layout() {
        super.layout()
        let rect = bounds.insetBy(dx: 18, dy: 18)
        dashLayer.frame = bounds
        dashLayer.path = CGPath(roundedRect: rect, cornerWidth: 12, cornerHeight: 12, transform: nil)
        updateDash()
    }

    private func updateDash() {
        dashLayer.strokeColor = isHighlighted
            ? NSColor.controlAccentColor.cgColor
            : NSColor.separatorColor.cgColor
    }

    override func updateLayer() { updateDash() }
}

// MARK: - 文件列表的行

final class FileRowView: NSTableCellView {
    static let height: CGFloat = 46

    var onShowIssues: ((NSView) -> Void)?

    private let statusImage = NSImageView()
    private let spinner = NSProgressIndicator()
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")
    private let badge = BadgeView()
    private let issuesButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        statusImage.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        statusImage.setContentHuggingPriority(.required, for: .horizontal)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        nameLabel.font = .systemFont(ofSize: 13)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        sizeLabel.textColor = .secondaryLabelColor
        sizeLabel.alignment = .right
        sizeLabel.setContentHuggingPriority(.required, for: .horizontal)

        issuesButton.bezelStyle = .inline
        issuesButton.controlSize = .small
        issuesButton.contentTintColor = .systemOrange
        issuesButton.imagePosition = .imageLeading
        issuesButton.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                     accessibilityDescription: nil)
        issuesButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.systemOrange]))
        issuesButton.target = self
        issuesButton.action = #selector(showIssues)
        issuesButton.isHidden = true
        issuesButton.setContentHuggingPriority(.required, for: .horizontal)

        let statusContainer = NSView()
        statusContainer.translatesAutoresizingMaskIntoConstraints = false
        statusContainer.widthAnchor.constraint(equalToConstant: 18).isActive = true
        for v in [statusImage, spinner] {
            v.translatesAutoresizingMaskIntoConstraints = false
            statusContainer.addSubview(v)
            v.centerXAnchor.constraint(equalTo: statusContainer.centerXAnchor).isActive = true
            v.centerYAnchor.constraint(equalTo: statusContainer.centerYAnchor).isActive = true
        }

        let text = NSStackView(views: [nameLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)
        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 44),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let row = NSStackView(views: [statusContainer, text, NSView(), issuesButton, sizeLabel, badge])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @objc private func showIssues() { onShowIssues?(issuesButton) }

    func configure(with row: FileRow) {
        nameLabel.stringValue = row.name
        let detail = row.detailText
        detailLabel.stringValue = detail
        detailLabel.isHidden = detail.isEmpty

        switch row.status {
        case .pending:
            setStatus("circle.dashed", .tertiaryLabelColor)
        case .running:
            statusImage.isHidden = true
            spinner.startAnimation(nil)
        case .done:
            setStatus(row.issues.isEmpty ? "checkmark.circle.fill" : "checkmark.circle",
                      row.issues.isEmpty ? .systemGreen : .systemOrange)
        case .skipped:
            setStatus("minus.circle", .secondaryLabelColor)
        case .failed:
            setStatus("xmark.circle.fill", .systemRed)
        }

        if row.status == .done, let pct = row.savingPercent {
            sizeLabel.stringValue = "\(humanSize(row.inBytes)) → \(humanSize(row.outBytes))"
            badge.isHidden = false
            badge.set(text: pct >= 0 ? "省 \(pct)%" : "大 \(-pct)%",
                      color: pct >= 0 ? .systemGreen : .systemOrange)
        } else {
            sizeLabel.stringValue = ""
            badge.isHidden = true
        }

        if row.issues.isEmpty {
            issuesButton.isHidden = true
        } else {
            issuesButton.isHidden = false
            // 纯文本标题不受 contentTintColor 影响，得用富文本才能上色。
            issuesButton.attributedTitle = NSAttributedString(
                string: "\(row.issues.count) 处差异",
                attributes: [.foregroundColor: NSColor.systemOrange,
                             .font: NSFont.systemFont(ofSize: 11, weight: .medium)])
        }
    }

    private func setStatus(_ symbol: String, _ color: NSColor) {
        spinner.stopAnimation(nil)
        statusImage.isHidden = false
        statusImage.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        statusImage.contentTintColor = color
    }
}

// MARK: - 节省比例的小标签

final class BadgeView: NSView {
    private let label = NSTextField(labelWithString: "")
    private var tint: NSColor = .systemGreen

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(text: String, color: NSColor) {
        label.stringValue = text
        label.textColor = color
        tint = color
        needsDisplay = true
        updateAppearance()
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        updateAppearance()
    }

    private func updateAppearance() {
        layer?.backgroundColor = tint.withAlphaComponent(0.15).cgColor
    }

    override func updateLayer() { updateAppearance() }
}

// MARK: - 接收拖放

final class DragDestinationView: NSView {
    var onDropURLs: (([URL]) -> Void)?
    var onHighlight: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func urls(from sender: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        return sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !urls(from: sender).isEmpty else { return [] }
        onHighlight?(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { onHighlight?(false) }

    override func draggingEnded(_ sender: NSDraggingInfo) { onHighlight?(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onHighlight?(false)
        let dropped = urls(from: sender)
        guard !dropped.isEmpty else { return false }
        onDropURLs?(dropped)
        return true
    }
}
