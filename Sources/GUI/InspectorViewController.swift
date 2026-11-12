// 右边的信息栏：选中一张时是它的信息（预览、转换结果、备注、拍摄、文件），
// 选中多张或没选中时是汇总（规格第 7 节）。某一组没有内容就整组不显示。

import AppKit

/// 信息栏要显示的东西。由主窗口按当前状态拼好交过来，信息栏只管摆。
enum InspectorContent {
    case single(PhotoItem, row: FileRow?, record: ConversionRecord?, sourceStillThere: Bool, productItem: PhotoItem?)
    case summary(title: String, items: ItemsSummary, record: ConversionRecord?)
}

protocol InspectorDelegate: AnyObject {
    /// 「显示转出的文件」：选中那张 HEIF。
    func inspectorShowProduct(_ path: String)
}

final class InspectorViewController: NSViewController {
    weak var delegate: InspectorDelegate?
    var onDrop: (([URL]) -> Void)? { didSet { (view as? DropTargetView)?.onDrop = onDrop } }

    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private var previewOp: Operation?
    private var previewPath: String?
    /// 展开了「显示全部」的备注（按文字）。
    private var expandedNotes = Set<String>()
    private var shownPath: String?

    static let width: CGFloat = 280
    static let minimumWidth: CGFloat = 240
    static let maximumWidth: CGFloat = 400
    /// 内容的宽度：栏宽减去左右各 16。每次摆内容时按当时的栏宽重算，栏宽变了就重摆一次。
    private var inner: CGFloat = 280 - 32
    private var lastContent: InspectorContent?
    private var laidOutWidth: CGFloat = 0

    private var availableInner: CGFloat {
        let width = scroll.contentView.bounds.width > 0 ? scroll.contentView.bounds.width : view.bounds.width
        return max(120, floor(width) - 32)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let width = availableInner
        if abs(width - laidOutWidth) > 0.5, let content = lastContent {
            show(content)
        }
    }

    override func loadView() {
        let root = DropTargetView()
        view = root
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 20, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        scroll.documentView = doc
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
        view.setAccessibilityLabel("信息栏")
    }

    // MARK: 拼内容

    func show(_ content: InspectorContent) {
        lastContent = content
        inner = availableInner
        laidOutWidth = inner
        let keepScroll = scroll.contentView.bounds.origin
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var groups: [NSView] = []
        switch content {
        case let .single(item, row, record, stillThere, product):
            if shownPath != item.path { expandedNotes = [] }
            let same = shownPath == item.path
            shownPath = item.path
            groups.append(headerGroup(item))
            if let row, let record { groups.append(conversionGroup(item, row: row, record: record, sourceStillThere: stillThere, product: product)) }
            if let notes = item.info?.notes, !notes.isEmpty { groups.append(notesGroup(notes)) }
            if let info = item.info, let g = captureGroup(info) { groups.append(g) }
            groups.append(fileGroup(item))
            if same { scroll.contentView.scroll(to: keepScroll) } else { scroll.contentView.scroll(to: .zero) }
        case let .summary(title, summary, record):
            shownPath = nil
            groups.append(summaryGroup(title, summary))
            if let record, let g = recordSummaryGroup(record) { groups.append(g) }
            scroll.contentView.scroll(to: .zero)
        }
        for (i, g) in groups.enumerated() {
            if i > 0 { addSeparator() }
            add(g)
        }
    }

    private func add(_ v: NSView) {
        stack.addArrangedSubview(v)
        v.widthAnchor.constraint(equalToConstant: inner).isActive = true
    }

    private func addSeparator() {
        let gap1 = NSView(), gap2 = NSView()
        gap1.heightAnchor.constraint(equalToConstant: 12).isActive = true
        gap2.heightAnchor.constraint(equalToConstant: 12).isActive = true
        let line = NSBox()
        line.boxType = .separator
        stack.addArrangedSubview(gap1)
        add(line)
        stack.addArrangedSubview(gap2)
    }

    private func vstack(_ views: [NSView], spacing: CGFloat = 4) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = spacing
        return s
    }

    private func groupTitle(_ text: String) -> NSTextField {
        makeLabel(text, size: 11, weight: .semibold, color: .secondaryLabelColor)
    }

    // MARK: 1. 预览、文件名、一行格式

    private func headerGroup(_ item: PhotoItem) -> NSView {
        let preview = NSView()
        preview.wantsLayer = true
        preview.layer?.cornerRadius = 7
        preview.layer?.masksToBounds = true
        preview.layer?.contentsGravity = .resizeAspectFill
        preview.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.heightAnchor.constraint(equalToConstant: 168).isActive = true
        preview.widthAnchor.constraint(equalToConstant: inner).isActive = true
        preview.setAccessibilityElement(true)
        preview.setAccessibilityRole(.image)
        preview.setAccessibilityLabel("预览")
        let pixels = inner * 2 * (view.window?.backingScaleFactor ?? 2) / 1.6
        if let hit = ThumbnailLoader.shared.cached(item, pixels: pixels) {
            preview.layer?.contents = hit
        } else {
            previewOp?.cancel()
            let path = item.path
            previewPath = path
            previewOp = ThumbnailLoader.shared.load(item, pixels: pixels) { [weak self, weak preview] image in
                guard self?.previewPath == path else { return }
                preview?.layer?.contents = image
            }
        }
        let name = makeWrappingLabel(item.name, size: 14, selectable: true)
        name.preferredMaxLayoutWidth = inner
        name.font = .systemFont(ofSize: 14, weight: .semibold)
        var meta = [item.format.label]
        if let dims = item.info?.dimensions { meta.append(dims) }
        meta.append(shortSize(item.size))
        let line = makeLabel(meta.joined(separator: "，"), size: 11, color: .secondaryLabelColor, monospacedDigits: true)
        let s = vstack([preview, name, line], spacing: 2)
        s.setCustomSpacing(10, after: preview)
        return s
    }

    // MARK: 2. 转换结果

    private func conversionGroup(_ item: PhotoItem, row: FileRow, record: ConversionRecord,
                                 sourceStillThere: Bool, product: PhotoItem?) -> NSView {
        let isSource = row.job.input.standardizedFileURL.path == item.path
        guard let mark = ConversionRecord.mark(of: row) else { return NSView() }
        // 还在的源 JPEG、已经转出了 HEIF：只写一句，详情在产物上。
        if isSource, let dest = row.dest, row.status == .done {
            let title = verdictRow("已转成 HEIF", symbol: "checkmark.circle.fill", color: .systemGreen)
            let link = LinkButton("显示转出的文件") { [weak self] in
                self?.delegate?.inspectorShowProduct(dest.standardizedFileURL.path)
            }
            return vstack([title, link], spacing: 6)
        }
        var views: [NSView] = []
        if mark == .running {
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.startAnimation(nil)
            let label = makeLabel("正在转换", size: 14, weight: .semibold)
            let h = NSStackView(views: [spinner, label])
            h.spacing = 7
            return h
        }
        let symbol = markSymbol(mark)
        views.append(verdictRow(verdictTitle(mark), symbol: symbol?.name, color: symbol?.color ?? .secondaryLabelColor))
        switch row.status {
        case .failed(let why), .skipped(let why):
            views.append(wrapped(makeWrappingLabel(why, size: 12, color: .secondaryLabelColor, selectable: true), inner))
        default: break
        }
        if case .differences(let issues) = row.verification {
            let list = vstack([], spacing: 0)
            for (i, issue) in issues.enumerated() {
                if i > 0 {
                    let line = NSBox()
                    line.boxType = .separator
                    list.addArrangedSubview(line)
                    line.widthAnchor.constraint(equalToConstant: inner).isActive = true
                }
                list.addArrangedSubview(issueRow(issue))
            }
            views.append(list)
            let copy = NSButton(title: "拷贝全部", target: nil, action: nil)
            copy.bezelStyle = .rounded
            copy.controlSize = .small
            copy.font = .systemFont(ofSize: 11)
            let all = issues.joined(separator: "\n")
            copy.target = self
            copy.action = #selector(copyIssues(_:))
            issuesToCopy = all
            views.append(copy)
        }
        if row.status == .done {
            var pairs: [(String, NSView)] = []
            let (volume, delta) = volumeLines(inBytes: row.inBytes, outBytes: row.outBytes)
            pairs.append(("体积", valueStack(volume, small: delta)))
            if let raw = row.rawExif {
                var text = raw.description
                if text.hasPrefix("EXIF ") { text = String(text.dropFirst(5)) }
                pairs.append(("EXIF", makeWrappingLabel(text, size: 13)))
            }
            let source = row.job.input
            if sourceStillThere {
                let s = vstack([makeLabel("还在", size: 13),
                                LinkButton("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([source]) }], spacing: 1)
                pairs.append(("源文件", s))
            } else {
                pairs.append(("源文件", makeLabel("已删除", size: 13)))
            }
            if let re = row.reencode { pairs.append(("重编", makeWrappingLabel(re.description, size: 13))) }
            if let cap = row.caption { pairs.append(("备注", makeWrappingLabel(cap.description, size: 13))) }
            views.append(keyValueGrid(pairs))
            if !row.note.isEmpty {
                views.append(wrapped(makeWrappingLabel(row.note, size: 12, color: .secondaryLabelColor, selectable: true), inner))
            }
        }
        let s = vstack(views, spacing: 8)
        return s
    }

    /// 「拷贝全部」拷的那些差异行（每行一条）。
    private var issuesToCopy = ""

    @objc private func copyIssues(_ sender: NSButton) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(issuesToCopy, forType: .string)
    }

    private func verdictRow(_ text: String, symbol: String?, color: NSColor) -> NSView {
        let label = makeLabel(text, size: 14, weight: .semibold)
        guard let symbol else { return label }
        let icon = NSImageView(image: symbolImage(symbol, size: 15, weight: .semibold) ?? NSImage())
        icon.contentTintColor = color
        let h = NSStackView(views: [icon, label])
        h.spacing = 7
        h.alignment = .centerY
        return h
    }

    /// 一行差异：左边标记（丢失 systemRed / 变化 systemOrange / 注意 次要色），右边正文可选中、自动折行。
    private func issueRow(_ line: String) -> NSView {
        let (tag, text) = splitIssue(line)
        let color: NSColor = tag == .lost ? .systemRed : tag == .changed ? .systemOrange : .secondaryLabelColor
        let badge = makeLabel(tag.label, size: 11, weight: .semibold, color: color)
        badge.setContentHuggingPriority(.required, for: .horizontal)
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.widthAnchor.constraint(equalToConstant: 30).isActive = true
        let body = makeWrappingLabel(text, size: 12, selectable: true)
        body.preferredMaxLayoutWidth = inner - 38
        let h = NSStackView(views: [badge, body])
        h.alignment = .firstBaseline
        h.spacing = 8
        h.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        h.setAccessibilityElement(true)
        h.setAccessibilityLabel("\(tag.label)，\(text)")
        return h
    }

    // MARK: 3. 备注

    private func notesGroup(_ notes: [Note]) -> NSView {
        var views: [NSView] = [groupTitle("备注")]
        for (i, note) in notes.enumerated() {
            let para = NSMutableParagraphStyle()
            para.minimumLineHeight = 13 * 1.5
            para.maximumLineHeight = 13 * 1.5
            let text = NSTextField(wrappingLabelWithString: "")
            text.attributedStringValue = NSAttributedString(string: note.text, attributes: [
                .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor, .paragraphStyle: para])
            text.isSelectable = true
            text.preferredMaxLayoutWidth = inner
            let expanded = expandedNotes.contains(note.text)
            text.maximumNumberOfLines = expanded ? 0 : 12
            text.lineBreakMode = .byWordWrapping
            text.cell?.truncatesLastVisibleLine = true
            views.append(text)
            if !expanded && lineCount(note.text, width: inner, lineHeight: 13 * 1.5) > 12 {
                let more = LinkButton("显示全部") { [weak self] in
                    self?.expandedNotes.insert(note.text)
                    self?.reshow()
                }
                views.append(more)
            }
            views.append(placeRow(note))
            if i < notes.count - 1 {
                let gap = NSView()
                gap.heightAnchor.constraint(equalToConstant: 6).isActive = true
                views.append(gap)
            }
        }
        let s = vstack(views, spacing: 4)
        s.setCustomSpacing(7, after: views[0])
        return s
    }

    var reshowHandler: (() -> Void)?
    private func reshow() { reshowHandler?() }

    private func lineCount(_ text: String, width: CGFloat, lineHeight: CGFloat) -> Int {
        let rect = (text as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                                   options: [.usesLineFragmentOrigin],
                                                   attributes: [.font: NSFont.systemFont(ofSize: 13)])
        return Int((rect.height / 15.5).rounded(.up))
    }

    /// 备注下面那行小字；只存在文件之外的前面放 systemOrange 的三角，文字仍是次要色。
    private func placeRow(_ note: Note) -> NSView {
        let label = makeWrappingLabel(note.placeText, size: 11, color: .secondaryLabelColor)
        label.preferredMaxLayoutWidth = note.isAtRisk ? inner - 16 : inner
        guard note.isAtRisk else { return label }
        let icon = NSImageView(image: symbolImage("exclamationmark.triangle.fill", size: 10) ?? NSImage())
        icon.contentTintColor = .systemOrange
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let h = NSStackView(views: [icon, label])
        h.spacing = 5
        h.alignment = .firstBaseline
        return h
    }

    // MARK: 4. 拍摄

    private func captureGroup(_ info: PhotoInfo) -> NSView? {
        var pairs: [(String, NSView)] = []
        if let t = info.captured { pairs.append(("时间", valueStack(t.display, small: nil))) }
        if let camera = info.cameraName {
            pairs.append(("相机", valueStack(camera, small: info.exposureLine)))
        } else if let exposure = info.exposureLine {
            pairs.append(("参数", makeWrappingLabel(exposure, size: 13)))
        }
        if let lens = info.lens { pairs.append(("镜头", makeWrappingLabel(lens, size: 13))) }
        if let loc = info.location {
            let s = vstack([valueStack(loc.display, small: nil)], spacing: 1)
            if let url = loc.mapsURL {
                s.addArrangedSubview(LinkButton("在地图中打开") { NSWorkspace.shared.open(url) })
            }
            pairs.append(("位置", s))
        }
        guard !pairs.isEmpty else { return nil }
        return vstack([groupTitle("拍摄"), keyValueGrid(pairs)], spacing: 7)
    }

    // MARK: 5. 文件

    private func fileGroup(_ item: PhotoItem) -> NSView {
        let folder = item.url.deletingLastPathComponent()
        let folderText = (folder.path as NSString).abbreviatingWithTildeInPath
        let link = LinkButton(folderText, size: 13) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        link.toolTip = "在访达中显示"
        link.lineBreakMode = .byTruncatingMiddle
        link.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let modified = valueStack(CaptureTime(date: item.modified).display, small: nil)
        return vstack([groupTitle("文件"), keyValueGrid([("位置", link), ("修改", modified)])], spacing: 7)
    }

    // MARK: 汇总

    private func summaryGroup(_ title: String, _ summary: ItemsSummary) -> NSView {
        var views: [NSView] = [wrapped(makeWrappingLabel(summary.title ?? title, size: 14), inner)]
        (views[0] as? NSTextField)?.font = .systemFont(ofSize: 14, weight: .semibold)
        for line in summary.formatLines { views.append(makeLabel(line, size: 13, monospacedDigits: true)) }
        if let notes = summary.notesLine { views.append(makeLabel(notes, size: 13, monospacedDigits: true)) }
        if summary.formatLines.isEmpty { views.append(makeLabel("这里没有图片", size: 13, color: .secondaryLabelColor)) }
        let s = vstack(views, spacing: 4)
        s.setCustomSpacing(8, after: views[0])
        return s
    }

    private func recordSummaryGroup(_ record: ConversionRecord) -> NSView? {
        var views: [NSView] = [groupTitle("转换")]
        if let line = record.savingLine {
            let l = makeLabel(line, size: 13, weight: .medium, monospacedDigits: true)
            views.append(l)
        }
        if let v = record.volumeLine { views.append(makeLabel(v, size: 13, color: .secondaryLabelColor, monospacedDigits: true)) }
        for line in record.classLines { views.append(makeLabel(line, size: 13, monospacedDigits: true)) }
        let top = record.topDifferences()
        if !top.isEmpty {
            let gap = NSView()
            gap.heightAnchor.constraint(equalToConstant: 6).isActive = true
            views.append(gap)
            views.append(groupTitle("最常见的差异"))
            for (family, count) in top {
                let text = makeWrappingLabel("\(family)（\(count) 张）", size: 12, selectable: true)
                text.preferredMaxLayoutWidth = inner
                views.append(text)
            }
        }
        guard views.count > 1 else { return nil }
        return vstack(views, spacing: 4)
    }

    // MARK: 两列明细

    private func valueStack(_ main: String, small: String?) -> NSView {
        let top = wrapped(makeWrappingLabel(main, size: 13), inner - 60)
        top.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        guard let small else { return top }
        let sub = wrapped(makeWrappingLabel(small, size: 11, color: .secondaryLabelColor), inner - 60)
        sub.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        return vstack([top, sub], spacing: 1)
    }

    private func keyValueGrid(_ pairs: [(String, NSView)]) -> NSView {
        let grid = NSGridView(views: pairs.map { [makeLabel($0.0, size: 13, color: .secondaryLabelColor), $0.1] })
        grid.rowSpacing = 5
        grid.columnSpacing = 8
        grid.column(at: 0).width = 52
        grid.column(at: 1).width = inner - 60
        for r in 0..<grid.numberOfRows { grid.row(at: r).yPlacement = .top }
        for (_, v) in pairs {
            if let t = v as? NSTextField { t.preferredMaxLayoutWidth = inner - 60 }
            // 值一栏不许比给它的宽度宽（链接、竖排的两行都一样），宽了就截断或折行，不出界。
            v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            v.widthAnchor.constraint(lessThanOrEqualToConstant: inner - 60).isActive = true
        }
        return grid
    }
}

/// 给会折行的标签定下折行宽度。
private func wrapped(_ label: NSTextField, _ width: CGFloat) -> NSTextField {
    label.preferredMaxLayoutWidth = width
    return label
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
