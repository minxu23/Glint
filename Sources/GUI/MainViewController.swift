// 主窗口：上半部是拖放区/文件列表，下半部是设置和操作栏。

import AppKit
import UniformTypeIdentifiers

final class MainViewController: NSViewController {
    private let model = ConversionModel()

    private let dropZone = DropZoneView()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let contentContainer = NSView()

    private let warningBar = NSView()
    private let warningLabel = NSTextField(labelWithString: "")

    private let qualitySlider = NSSlider()
    private let qualityValue = NSTextField(labelWithString: "80")
    private let qualityHint = NSTextField(labelWithString: "")
    private let outputPicker = NSSegmentedControl()
    private let chooseFolderButton = NSButton()
    private let outputPathLabel = NSTextField(labelWithString: "")
    private let recursiveCheck = NSButton(checkboxWithTitle: "递归子文件夹", target: nil, action: nil)
    private let verifyCheck = NSButton(checkboxWithTitle: "转换后校验元数据", target: nil, action: nil)
    private let overwriteCheck = NSButton(checkboxWithTitle: "覆盖同名文件", target: nil, action: nil)
    private let deleteCheck = NSButton(checkboxWithTitle: "校验无损后删除源文件", target: nil, action: nil)

    private let summaryLabel = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    private let progressLabel = NSTextField(labelWithString: "")
    private let clearButton = NSButton()
    private let addButton = NSButton()
    private let startButton = NSButton()
    private let cancelButton = NSButton()

    private var settingsControls: [NSControl] = []

    override func loadView() {
        view = DragDestinationView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(greaterThanOrEqualToConstant: 700).isActive = true
        view.heightAnchor.constraint(greaterThanOrEqualToConstant: 540).isActive = true
        buildUI()
    }

    /// 供 AppDelegate 转交"用本应用打开"的文件。
    func add(urls: [URL]) {
        _ = view   // 文件可能在窗口显示之前就送进来，先确保视图已加载
        model.add(urls: urls)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if let drag = view as? DragDestinationView {
            drag.onDropURLs = { [weak self] urls in self?.model.add(urls: urls) }
            drag.onHighlight = { [weak self] on in self?.dropZone.isHighlighted = on }
        }
        model.onChange = { [weak self] in self?.refresh() }
        refresh()
    }

    // MARK: 构建界面

    private func buildUI() {
        // ---- 内容区：拖放区与文件列表二选一 ----
        dropZone.onChooseFiles = { [weak self] in self?.chooseFiles() }
        configureTable()

        for v in [dropZone, scrollView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            contentContainer.addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
                v.topAnchor.constraint(equalTo: contentContainer.topAnchor),
                v.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            ])
        }

        // ---- 警告条 ----
        buildWarningBar()

        // ---- 设置区 ----
        let settings = buildSettings()

        // ---- 操作栏 ----
        let actions = buildActionBar()

        let root = NSStackView(views: [contentContainer, warningBar, separator(), settings, separator(), actions])
        root.orientation = .vertical
        root.spacing = 0
        root.alignment = .leading
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            root.topAnchor.constraint(equalTo: view.topAnchor),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        for v in [contentContainer, warningBar, settings, actions] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.leadingAnchor.constraint(equalTo: root.leadingAnchor).isActive = true
            v.trailingAnchor.constraint(equalTo: root.trailingAnchor).isActive = true
        }
        contentContainer.setContentHuggingPriority(.defaultLow, for: .vertical)
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }

    private func configureTable() {
        tableView.headerView = nil
        tableView.rowHeight = FileRowView.height
        tableView.style = .plain
        tableView.gridStyleMask = []   // 分隔线由行视图自己画，避免画到空白区域
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.menu = rowContextMenu()
        tableView.target = self

        let column = NSTableColumn(identifier: .init("file"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
    }

    private func rowContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "在访达中显示", action: #selector(revealClicked), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "从列表中移除", action: #selector(removeClicked), keyEquivalent: ""))
        menu.items.forEach { $0.target = self }
        return menu
    }

    private func buildWarningBar() {
        warningBar.wantsLayer = true
        warningBar.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.12).cgColor

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
        icon.contentTintColor = .systemOrange
        icon.setContentHuggingPriority(.required, for: .horizontal)

        warningLabel.font = .systemFont(ofSize: 12)
        warningLabel.maximumNumberOfLines = 3
        warningLabel.isSelectable = true

        let stack = NSStackView(views: [icon, warningLabel])
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        warningBar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: warningBar.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: warningBar.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: warningBar.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: warningBar.bottomAnchor, constant: -8),
        ])
    }

    private func buildSettings() -> NSView {
        // 质量
        qualitySlider.minValue = 0.4
        qualitySlider.maxValue = 1.0
        qualitySlider.doubleValue = model.options.quality
        qualitySlider.numberOfTickMarks = 13
        qualitySlider.allowsTickMarkValuesOnly = true
        qualitySlider.target = self
        qualitySlider.action = #selector(qualityChanged)
        qualitySlider.widthAnchor.constraint(equalToConstant: 230).isActive = true

        qualityValue.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        qualityValue.alignment = .right
        qualityValue.widthAnchor.constraint(equalToConstant: 30).isActive = true

        qualityHint.font = .systemFont(ofSize: 12)
        qualityHint.textColor = .secondaryLabelColor

        let qualityRow = NSStackView(views: [fixedLabel("质量"), qualitySlider, qualityValue, qualityHint])
        qualityRow.orientation = .horizontal
        qualityRow.alignment = .centerY
        qualityRow.spacing = 10

        // 输出位置
        outputPicker.segmentStyle = .texturedRounded
        outputPicker.segmentCount = 2
        outputPicker.setLabel("源文件旁边", forSegment: 0)
        outputPicker.setLabel("指定文件夹", forSegment: 1)
        outputPicker.setWidth(105, forSegment: 0)
        outputPicker.setWidth(105, forSegment: 1)
        outputPicker.selectedSegment = 0
        outputPicker.target = self
        outputPicker.action = #selector(outputModeChanged)

        chooseFolderButton.title = "选择文件夹…"
        chooseFolderButton.bezelStyle = .rounded
        chooseFolderButton.target = self
        chooseFolderButton.action = #selector(chooseOutputFolder)

        outputPathLabel.font = .systemFont(ofSize: 12)
        outputPathLabel.textColor = .secondaryLabelColor
        outputPathLabel.lineBreakMode = .byTruncatingMiddle
        outputPathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let outputRow = NSStackView(views: [fixedLabel("输出到"), outputPicker, chooseFolderButton, outputPathLabel])
        outputRow.orientation = .horizontal
        outputRow.alignment = .centerY
        outputRow.spacing = 10

        // 开关
        recursiveCheck.state = model.options.recursive ? .on : .off
        verifyCheck.state = model.options.verify ? .on : .off
        overwriteCheck.state = model.options.overwrite ? .on : .off
        deleteCheck.state = model.options.deleteOriginal ? .on : .off
        deleteCheck.contentTintColor = .systemRed
        for c in [recursiveCheck, verifyCheck, overwriteCheck, deleteCheck] {
            c.target = self
            c.action = #selector(toggleChanged)
        }
        let toggleRow = NSStackView(views: [fixedLabel(""), recursiveCheck, verifyCheck, overwriteCheck, deleteCheck])
        toggleRow.orientation = .horizontal
        toggleRow.alignment = .centerY
        toggleRow.spacing = 16

        let stack = NSStackView(views: [qualityRow, outputRow, toggleRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)

        settingsControls = [qualitySlider, outputPicker, chooseFolderButton,
                            recursiveCheck, verifyCheck, overwriteCheck, deleteCheck]

        let container = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    private func fixedLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.alignment = .left
        label.widthAnchor.constraint(equalToConstant: 46).isActive = true
        return label
    }

    private func buildActionBar() -> NSView {
        summaryLabel.font = .systemFont(ofSize: 12)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.isSelectable = true
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.controlSize = .small
        progressBar.widthAnchor.constraint(equalToConstant: 150).isActive = true

        progressLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        progressLabel.textColor = .secondaryLabelColor

        clearButton.title = "清空"
        clearButton.bezelStyle = .rounded
        clearButton.target = self
        clearButton.action = #selector(clearClicked)

        addButton.title = "添加…"
        addButton.bezelStyle = .rounded
        addButton.target = self
        addButton.action = #selector(chooseFilesClicked)

        startButton.title = "开始转换"
        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r"
        startButton.target = self
        startButton.action = #selector(startClicked)

        cancelButton.title = "取消"
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)

        let stack = NSStackView(views: [progressBar, progressLabel, summaryLabel, NSView(),
                                        clearButton, addButton, cancelButton, startButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)

        let container = NSView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    // MARK: 刷新

    private func refresh() {
        let hasFiles = !model.rows.isEmpty
        dropZone.isHidden = hasFiles
        scrollView.isHidden = !hasFiles
        tableView.reloadData()

        warningBar.isHidden = model.warning == nil
        warningLabel.stringValue = model.warning ?? ""

        qualityValue.stringValue = "\(Int(model.options.quality * 100))"
        qualityHint.stringValue = hint(for: model.options.quality)

        let chosen = model.outputMode == .chosenFolder
        outputPicker.selectedSegment = chosen ? 1 : 0
        chooseFolderButton.isHidden = !chosen
        outputPathLabel.isHidden = !chosen
        outputPathLabel.stringValue = model.outputFolder.map { abbreviate($0.path) } ?? "尚未选择输出文件夹"

        for c in settingsControls { c.isEnabled = !model.isRunning }

        progressBar.isHidden = !model.isRunning
        progressLabel.isHidden = !model.isRunning
        summaryLabel.isHidden = model.isRunning
        cancelButton.isHidden = !model.isRunning
        startButton.isHidden = model.isRunning
        clearButton.isHidden = !hasFiles || model.isRunning
        addButton.isEnabled = !model.isRunning

        progressBar.maxValue = Double(max(model.rows.count, 1))
        progressBar.doubleValue = Double(model.completedCount)
        progressLabel.stringValue = "\(model.completedCount) / \(model.rows.count)"
        summaryLabel.stringValue = model.summary
        startButton.isEnabled = model.canStart
    }

    private func hint(for quality: Double) -> String {
        switch quality {
        case ..<0.6: return "体积最小，画质损失明显"
        case ..<0.86: return "日常存档的推荐区间"
        case ..<0.96: return "接近原画质，文件更大"
        default: return "几乎不压缩，体积可能超过源文件"
        }
    }

    private func abbreviate(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: 动作

    @objc private func qualityChanged() {
        let stepped = (qualitySlider.doubleValue * 20).rounded() / 20
        // 不再手工 refresh()：updateOptions 会通知，走 onChange 那一条路。
        model.updateOptions { $0.quality = stepped }
    }

    @objc private func outputModeChanged() {
        model.outputMode = outputPicker.selectedSegment == 1 ? .chosenFolder : .sameFolder
        if model.outputMode == .chosenFolder && model.outputFolder == nil { chooseOutputFolder() }
    }

    @objc private func toggleChanged(_ sender: NSButton) {
        let on = sender.state == .on
        switch sender {
        case recursiveCheck: model.updateOptions { $0.recursive = on }
        case verifyCheck: model.updateOptions { $0.verify = on }
        case overwriteCheck: model.updateOptions { $0.overwrite = on }
        case deleteCheck: model.updateOptions { $0.deleteOriginal = on }
        default: break
        }
    }

    @objc private func chooseFilesClicked() { chooseFiles() }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        // 必须把 .folder 一起列进来：只写 .jpeg 时选中文件夹「添加」按钮是灰的，
        // 于是没法整个文件夹批量添加，只能一张张挑。
        panel.allowedContentTypes = [.jpeg, .folder]
        panel.message = "选择要转换的 JPEG 文件，或包含 JPEG 的整个文件夹"
        panel.prompt = "添加"
        guard panel.runModal() == .OK else { return }
        model.add(urls: panel.urls)
    }

    @objc private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "选择 HEIF 文件的输出位置"
        panel.prompt = "选择"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.outputFolder = url
    }

    @objc private func clearClicked() { model.clear() }

    @objc private func cancelClicked() { model.cancel() }

    @objc private func startClicked() {
        guard model.options.deleteOriginal else { model.start(); return }
        let alert = NSAlert()
        alert.messageText = "转换后删除源 JPEG？"
        alert.informativeText = "每张图会先逐条比对元数据，只有确认完全无损才删除对应的源文件；有任何差异的会被保留。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除源文件")
        alert.addButton(withTitle: "取消")
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.model.start() }
        }
    }

    @objc private func revealClicked() {
        let index = tableView.clickedRow
        guard model.rows.indices.contains(index) else { return }
        let row = model.rows[index]
        NSWorkspace.shared.activateFileViewerSelecting([row.dest ?? row.job.input])
    }

    @objc private func removeClicked() {
        let index = tableView.clickedRow
        guard model.rows.indices.contains(index) else { return }
        model.remove(at: index)
    }

    private func showIssues(_ issues: [String], from anchor: NSView) {
        let text = NSTextField(wrappingLabelWithString: issues.map { "• \($0)" }.joined(separator: "\n"))
        text.font = .systemFont(ofSize: 12)
        text.isSelectable = true
        text.preferredMaxLayoutWidth = 420
        text.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "元数据校验发现 \(issues.count) 处差异")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(title)
        content.addSubview(text)
        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            title.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            text.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            text.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            text.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            text.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            text.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])

        let controller = NSViewController()
        controller.view = content

        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }
}

// MARK: - 表格数据源

extension MainViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { model.rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("FileRow")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? FileRowView) ?? {
            let v = FileRowView()
            v.identifier = id
            return v
        }()
        let item = model.rows[row]
        cell.configure(with: item)
        cell.onShowIssues = { [weak self] anchor in self?.showIssues(item.issues, from: anchor) }
        return cell
    }
}
