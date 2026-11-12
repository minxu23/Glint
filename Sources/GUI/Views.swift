// 各处复用的小视图：网格单元与角标、空状态、活动条、接收拖放的根视图、链接样式的按钮。
// 颜色一律用系统语义色；只有叠在照片上的角标用固定的白色与半透明深色（规格第 6.1 节）。

import AppKit

// MARK: - 小工具

/// 系统字体的标签。
func makeLabel(_ text: String = "", size: CGFloat = 13, weight: NSFont.Weight = .regular,
               color: NSColor = .labelColor, monospacedDigits: Bool = false) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = monospacedDigits ? .monospacedDigitSystemFont(ofSize: size, weight: weight)
                                  : .systemFont(ofSize: size, weight: weight)
    label.textColor = color
    return label
}

/// 会自动折行的标签。
func makeWrappingLabel(_ text: String, size: CGFloat = 13, color: NSColor = .labelColor,
                       selectable: Bool = false) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = .systemFont(ofSize: size)
    label.textColor = color
    label.isSelectable = selectable
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return label
}

/// 链接样式的小按钮：强调色文字，没有边框。
final class LinkButton: NSButton {
    private var handler: (() -> Void)?

    convenience init(_ title: String, size: CGFloat = 11, action: @escaping () -> Void) {
        self.init(frame: .zero)
        isBordered = false
        bezelStyle = .inline
        setButtonType(.momentaryChange)
        handler = action
        target = self
        self.action = #selector(fire)
        attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: NSColor.linkColor, .font: NSFont.systemFont(ofSize: size)])
        setAccessibilityLabel(title)
        setContentHuggingPriority(.required, for: .horizontal)
    }

    @objc private func fire() { handler?() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// 「减弱动态效果」打开时不做过渡动画。
var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

/// 一张图的转换状态用的 SF Symbol 与颜色（网格角标、列表、信息栏、侧栏共用）。
func markSymbol(_ mark: ConversionMark) -> (name: String, color: NSColor)? {
    switch mark {
    case .differences: return ("exclamationmark.triangle.fill", .systemOrange)
    case .failed: return ("xmark.circle.fill", .systemRed)
    case .passed: return ("checkmark.circle.fill", .systemGreen)
    case .notVerified: return ("circle.dashed", .secondaryLabelColor)
    case .skipped: return ("minus.circle", .secondaryLabelColor)
    case .running: return nil
    }
}

func symbolImage(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular, label: String? = nil) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: label)?
        .withSymbolConfiguration(.init(pointSize: size, weight: weight))
}

// MARK: - 网格单元

/// 缩略图单元：等比裁切居中、圆角 7；选中时外描一圈强调色（3pt，离图 2pt）。
/// 角上只放规格第 6.1 节那几种标记。
final class ThumbnailCellView: NSView {
    let imageLayer = CALayer()
    private let ring = CALayer()
    private let noteBadge = NSView()
    private let statusBadge = NSView()
    private let statusIcon = NSImageView()
    private let spinner = NSProgressIndicator()

    var isSelected = false { didSet { updateRing() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        imageLayer.cornerRadius = 7
        imageLayer.masksToBounds = true
        imageLayer.contentsGravity = .resizeAspectFill
        layer?.addSublayer(imageLayer)
        ring.borderWidth = 3
        ring.cornerRadius = 7 + 5
        ring.isHidden = true
        layer?.addSublayer(ring)

        // 右下：有备注。
        noteBadge.wantsLayer = true
        noteBadge.layer?.cornerRadius = 5
        noteBadge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.46).cgColor
        let noteIcon = NSImageView(image: symbolImage("text.alignleft", size: 10, weight: .semibold) ?? NSImage())
        noteIcon.contentTintColor = .white
        noteIcon.translatesAutoresizingMaskIntoConstraints = false
        noteBadge.addSubview(noteIcon)
        noteBadge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(noteBadge)

        // 右上：转换中 / 有差异 / 失败。白色圆底。
        statusBadge.wantsLayer = true
        statusBadge.layer?.cornerRadius = 10
        statusBadge.layer?.backgroundColor = NSColor.white.cgColor
        statusBadge.layer?.shadowOpacity = 0.35
        statusBadge.layer?.shadowRadius = 1.5
        statusBadge.layer?.shadowOffset = CGSize(width: 0, height: -0.5)
        statusBadge.translatesAutoresizingMaskIntoConstraints = false
        statusIcon.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        statusBadge.addSubview(statusIcon)
        statusBadge.addSubview(spinner)
        addSubview(statusBadge)

        NSLayoutConstraint.activate([
            noteBadge.widthAnchor.constraint(equalToConstant: 18),
            noteBadge.heightAnchor.constraint(equalToConstant: 18),
            noteBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            noteBadge.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            noteIcon.centerXAnchor.constraint(equalTo: noteBadge.centerXAnchor),
            noteIcon.centerYAnchor.constraint(equalTo: noteBadge.centerYAnchor),
            statusBadge.widthAnchor.constraint(equalToConstant: 20),
            statusBadge.heightAnchor.constraint(equalToConstant: 20),
            statusBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            statusBadge.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            statusIcon.centerXAnchor.constraint(equalTo: statusBadge.centerXAnchor),
            statusIcon.centerYAnchor.constraint(equalTo: statusBadge.centerYAnchor),
            spinner.centerXAnchor.constraint(equalTo: statusBadge.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: statusBadge.centerYAnchor),
        ])
        noteBadge.isHidden = true
        statusBadge.isHidden = true
        // 角标是装饰，含义在单元的无障碍描述里。
        noteBadge.setAccessibilityElement(false)
        statusBadge.setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        ring.frame = bounds.insetBy(dx: -5, dy: -5)
        CATransaction.commit()
    }

    override func updateLayer() {
        super.updateLayer()
        applyColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            imageLayer.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            ring.borderColor = NSColor.controlAccentColor.cgColor
        }
    }

    private func updateRing() {
        applyColors()
        ring.isHidden = !isSelected
    }

    func setImage(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.contents = image
        CATransaction.commit()
    }

    /// 只有 `mark.showsOnGrid` 的状态才放标记。
    func setBadges(hasNotes: Bool, mark: ConversionMark?, animated: Bool) {
        noteBadge.isHidden = !hasNotes
        let shown = mark.flatMap { $0.showsOnGrid ? $0 : nil }
        let wasHidden = statusBadge.isHidden
        statusBadge.isHidden = shown == nil
        switch shown {
        case .running?:
            statusIcon.isHidden = true
            spinner.startAnimation(nil)
        case let m?:
            spinner.stopAnimation(nil)
            statusIcon.isHidden = false
            if let s = markSymbol(m) {
                statusIcon.image = symbolImage(s.name, size: m == .failed ? 18 : 12, weight: .semibold)
                statusIcon.contentTintColor = s.color
            }
        case nil:
            spinner.stopAnimation(nil)
        }
        if animated && wasHidden && shown != nil && !reduceMotion {
            statusBadge.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                statusBadge.animator().alphaValue = 1
            }
        } else {
            statusBadge.alphaValue = 1
        }
    }
}

final class ThumbnailItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("ThumbnailItem")
    var cell: ThumbnailCellView { view as! ThumbnailCellView }
    /// 正在生成的缩略图；单元复用或滚出屏幕时取消。
    var loading: Operation?
    var path: String?
    /// 缩略图这一次的生成结束了（成功或读不出），测量「第一屏出齐」用。
    var loaded = false

    override func loadView() {
        view = ThumbnailCellView()
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.image)
    }

    override var isSelected: Bool { didSet { cell.isSelected = isSelected } }

    override func prepareForReuse() {
        super.prepareForReuse()
        loading?.cancel()
        loading = nil
        path = nil
        loaded = false
        cell.setImage(nil)
    }
}

// MARK: - 空状态

final class EmptyStateView: NSView {
    private let icon = NSImageView()
    private let title = makeLabel("", size: 17, weight: .semibold)
    private let detail = makeWrappingLabel("", size: 13, color: .secondaryLabelColor)
    let button = NSButton(title: "添加文件夹…", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.image = symbolImage("photo.on.rectangle.angled", size: 46, weight: .light)
        icon.contentTintColor = .tertiaryLabelColor
        title.alignment = .center
        detail.alignment = .center
        detail.preferredMaxLayoutWidth = 360
        button.bezelStyle = .rounded
        button.controlSize = .large
        let stack = NSStackView(views: [icon, title, detail, button])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(16, after: detail)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -20),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            detail.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 一个文件夹都没加：图标、标题、说明、按钮；其余情形只有一行标题。
    func show(welcome: Bool, message: String) {
        icon.isHidden = !welcome
        detail.isHidden = !welcome
        button.isHidden = !welcome
        title.stringValue = welcome ? "把装照片的文件夹拖进来" : message
        title.font = .systemFont(ofSize: welcome ? 17 : 15, weight: welcome ? .semibold : .regular)
        title.textColor = welcome ? .labelColor : .secondaryLabelColor
        detail.stringValue = "在这里看照片的拍摄时间、位置和备注，把 JPEG 转成更省空间的 HEIF。"
    }
}

// MARK: - 活动条

/// 转换进行中和刚转完时出现在窗口底部（高 40）。
final class ActivityBar: NSView {
    static let height: CGFloat = 40
    private let sentence = NSStackView()
    private let progress = NSProgressIndicator()
    let button = NSButton(title: "取消", target: nil, action: nil)
    var onLink: ((LibraryEntry) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        sentence.orientation = .horizontal
        sentence.spacing = 0
        sentence.alignment = .firstBaseline
        sentence.setHuggingPriority(.defaultLow, for: .horizontal)
        sentence.setClippingResistancePriority(.defaultLow, for: .horizontal)
        progress.style = .bar
        progress.isIndeterminate = false
        progress.controlSize = .small
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.widthAnchor.constraint(equalToConstant: 200).isActive = true
        button.bezelStyle = .rounded
        let separator = NSBox()
        separator.boxType = .separator
        let row = NSStackView(views: [sentence, NSView(), progress, button])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 12)
        for v in [row, separator] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(_ record: ConversionRecord) {
        sentence.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for part in record.activitySentence {
            let view: NSView
            if let link = part.link {
                view = LinkButton(part.text, size: 13) { [weak self] in self?.onLink?(link) }
            } else {
                let label = makeLabel(part.text, size: 13, weight: part.emphasized ? .medium : .regular,
                                      color: part.emphasized ? .labelColor : .secondaryLabelColor, monospacedDigits: true)
                label.lineBreakMode = .byTruncatingTail
                label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                view = label
            }
            sentence.addArrangedSubview(view)
        }
        progress.isHidden = !record.isRunning
        progress.maxValue = Double(max(record.rows.count, 1))
        progress.doubleValue = Double(record.settledCount)
        button.title = record.isRunning ? "取消" : "好"
        button.keyEquivalent = record.isRunning ? "" : ""
        setAccessibilityLabel(record.activityText)
    }
}

// MARK: - 接收拖放

/// 各栏的根视图：整个窗口都接受拖放（文件夹加到「文件夹」，图片归到「单独添加的图片」）。
class DropTargetView: NSView {
    var onDrop: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func urls(_ sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                              options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        urls(sender).isEmpty || onDrop == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let dropped = urls(sender)
        guard !dropped.isEmpty, let onDrop else { return false }
        onDrop(dropped)
        return true
    }
}
