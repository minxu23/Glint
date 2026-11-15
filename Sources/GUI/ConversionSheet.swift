// 转换面板：点「转换…」从工具栏下滑出的 sheet（宽 460，规格第 8.1 节）。
// 打开时从存储读设置，「删除源文件」「覆盖同名的 HEIF」「也转 CMYK 的 JPEG」每次都是关的；
// 点「转换」时写回存储。「高级」里还有画质核对：开关、两个门槛、不达标时的处理；门槛填得不对时
// 下面一行红字说明，「转换」按钮灰掉（PanelSettings.blocksStart）。
// 「源文件」一栏照 ConversionTargets.deleteChoice 摆：有 JPEG 时是删除的复选框（混着 RAW 时
// 写明只删 JPEG、RAW 原片始终保留），只有 RAW 时没有复选框，只写一句不删。

import AppKit

final class ConversionSheetController: NSViewController, NSTextFieldDelegate {
    private let targets: ConversionTargets
    private(set) var settings: PanelSettings
    private let store: SettingsStore
    /// 点了「转换」：交回最终的设置。
    var onStart: ((PanelSettings) -> Void)?
    var onCancel: (() -> Void)?

    private let formatPopup = NSPopUpButton()
    private let qualitySlider = NSSlider()
    private let qualityValue = makeLabel("", size: 13, monospacedDigits: true)
    private let qualityHintLabel = makeLabel("", size: 11, color: .secondaryLabelColor)
    private let outputPopup = NSPopUpButton()
    private let outputPath = makeLabel("", size: 11, color: .secondaryLabelColor)
    private let verifyCheck = NSButton(checkboxWithTitle: "转完逐项校验", target: nil, action: nil)
    private let captionCheck = NSButton(checkboxWithTitle: "把备注写进文件", target: nil, action: nil)
    private let deleteCheck = NSButton(checkboxWithTitle: "校验无差异后删除源文件", target: nil, action: nil)
    private let deleteNote = makeLabel("删除后不进废纸篓", size: 11, color: .secondaryLabelColor)
    private let advancedToggle = NSButton()
    private let advancedBox = NSStackView()
    private let exifCheck = NSButton(checkboxWithTitle: "EXIF 交给系统重写", target: nil, action: nil)
    private let overwriteCheck = NSButton(checkboxWithTitle: "覆盖同名的 HEIF", target: nil, action: nil)
    private let cmykCheck = NSButton(checkboxWithTitle: "也转 CMYK 的 JPEG", target: nil, action: nil)
    private let qualityCheck = NSButton(checkboxWithTitle: "转完核对画质", target: nil, action: nil)
    private let ssimField = NSTextField()
    private let psnrField = NSTextField()
    private let skipRadio = NSButton(radioButtonWithTitle: "不转，保留 JPEG", target: nil, action: nil)
    private let retryRadio = NSButton(radioButtonWithTitle: "提高质量重编一次再判", target: nil, action: nil)
    private let qualityProblemLabel = makeLabel("", size: 11, color: .systemRed)
    private var qualityControls: [NSControl] = []
    /// 门槛输入框里的文字不合法时给用户看的说明（PanelSettings.takeThresholdInput）；合法是 nil。
    private var thresholdProblem: String?
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private let startButton = NSButton(title: "转换", target: nil, action: nil)
    private var grid = NSGridView()

    init(targets: ConversionTargets, store: SettingsStore) {
        self.targets = targets
        self.store = store
        settings = PanelSettings.load(from: store)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let title = makeLabel(targets.title, size: 15, weight: .semibold)
        let detail = makeWrappingLabel(targets.detail, size: 12, color: .secondaryLabelColor)
        detail.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        detail.preferredMaxLayoutWidth = 420

        formatPopup.addItems(withTitles: ["HEIF（.heic）"])
        formatPopup.setAccessibilityLabel("转成")

        qualitySlider.minValue = 0.4
        qualitySlider.maxValue = 1.0
        qualitySlider.numberOfTickMarks = 13
        qualitySlider.allowsTickMarkValuesOnly = true
        qualitySlider.doubleValue = settings.quality
        qualitySlider.target = self
        qualitySlider.action = #selector(qualityChanged)
        qualitySlider.setAccessibilityLabel("画质")
        qualitySlider.translatesAutoresizingMaskIntoConstraints = false
        qualitySlider.widthAnchor.constraint(equalToConstant: 250).isActive = true
        qualityValue.alignment = .right
        qualityValue.translatesAutoresizingMaskIntoConstraints = false
        qualityValue.widthAnchor.constraint(equalToConstant: 28).isActive = true
        let qualityRow = NSStackView(views: [qualitySlider, qualityValue])
        qualityRow.spacing = 10

        outputPopup.addItems(withTitles: ["源文件旁边", "指定文件夹…"])
        outputPopup.target = self
        outputPopup.action = #selector(outputChanged)
        outputPopup.setAccessibilityLabel("保存到")
        outputPath.lineBreakMode = .byTruncatingMiddle
        outputPath.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for c in [verifyCheck, captionCheck, deleteCheck, exifCheck, overwriteCheck, cmykCheck] {
            c.target = self
            c.action = #selector(toggled(_:))
        }
        let verifyBlock = check(verifyCheck, "比对拍摄时间、位置、备注和扩展属性，列出丢失或变化的每一项")
        let captionBlock = check(captionCheck, targets.captionHint)
        let deleteBlock: NSView
        switch targets.deleteChoice {
        case let .offered(title, hint, _):
            deleteCheck.title = title
            deleteBlock = check(deleteCheck, hint, extra: deleteNote)
        case .unavailable(let text):
            let label = makeWrappingLabel(text, size: 13)
            label.preferredMaxLayoutWidth = 320
            deleteBlock = label
        }
        let metaBlock = vstack([verifyBlock, captionBlock], spacing: 6)

        advancedToggle.bezelStyle = .disclosure
        advancedToggle.setButtonType(.pushOnPushOff)
        advancedToggle.title = ""
        advancedToggle.target = self
        advancedToggle.action = #selector(toggleAdvanced)
        advancedToggle.setAccessibilityLabel("高级")
        let advancedLabel = makeLabel("高级", size: 13)
        let advancedHeader = NSStackView(views: [advancedToggle, advancedLabel])
        advancedHeader.spacing = 4
        advancedBox.orientation = .vertical
        advancedBox.alignment = .leading
        advancedBox.spacing = 6
        advancedBox.addArrangedSubview(check(exifCheck, "默认把源文件的 EXIF 原样搬过去。个别软件读不了这样的文件时再勾"))
        advancedBox.addArrangedSubview(check(overwriteCheck, nil))
        advancedBox.addArrangedSubview(check(cmykCheck, targets.cmykHint))
        advancedBox.addArrangedSubview(qualityBlock())
        // 这批里有 CMYK 的就展开「高级」，免得用户不知道有几张会被跳过。
        advancedToggle.state = targets.cmykCount > 0 ? .on : .off
        advancedBox.isHidden = targets.cmykCount == 0

        let rule = NSBox()
        rule.boxType = .separator
        // 横跨两列的分隔线给定宽度：不给的话，「源文件」那栏的说明折成两行时，合并单元格里的
        // 分隔线会被压成一个点（混着 RAW 的那段说明就是这样）。
        rule.translatesAutoresizingMaskIntoConstraints = false
        rule.widthAnchor.constraint(equalToConstant: 420).isActive = true
        grid = NSGridView(views: [
            [formLabel("转成"), formatPopup],
            [formLabel("画质"), qualityRow],
            [NSGridCell.emptyContentView, qualityHintLabel],
            [formLabel("保存到"), outputPopup],
            [NSGridCell.emptyContentView, outputPath],
            [rule, NSGridCell.emptyContentView],
            [formLabel("元数据"), metaBlock],
            [formLabel("源文件"), deleteBlock],
            [NSGridCell.emptyContentView, vstack([advancedHeader, advancedBox], spacing: 6)],
        ])
        grid.columnSpacing = 12
        grid.rowSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = 64
        for r in [6, 7, 8] { grid.row(at: r).yPlacement = .top }
        for r in 0..<grid.numberOfRows { grid.cell(atColumnIndex: 0, rowIndex: r).yPlacement = r >= 6 ? .top : .center }
        grid.mergeCells(inHorizontalRange: NSRange(location: 0, length: 2), verticalRange: NSRange(location: 5, length: 1))
        grid.row(at: 2).topPadding = -6
        grid.row(at: 4).topPadding = -6
        grid.row(at: 5).topPadding = 2
        grid.row(at: 5).bottomPadding = 2

        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        startButton.bezelStyle = .rounded
        startButton.keyEquivalent = "\r"
        startButton.target = self
        startButton.action = #selector(start)
        let buttons = NSStackView(views: [NSView(), cancelButton, startButton])
        buttons.spacing = 8

        let separator = NSBox()
        separator.boxType = .separator
        let root = vstack([title, detail, grid, buttons], spacing: 2)
        root.setCustomSpacing(16, after: detail)
        root.setCustomSpacing(18, after: grid)
        root.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false
        buttons.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(root)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 460),
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            buttons.widthAnchor.constraint(equalToConstant: 420),
        ])
        view = container
        refresh()
    }

    /// 画质核对那一块：复选框、两个门槛、不达标时怎么办、填错时的红字。复选框以下缩进一格。
    private func qualityBlock() -> NSView {
        qualityCheck.target = self
        qualityCheck.action = #selector(toggled(_:))
        for (field, text, label) in [(ssimField, settings.ssimText, "局部相似度门槛"), (psnrField, settings.psnrText, "PSNR 门槛")] {
            field.stringValue = text
            field.delegate = self
            field.alignment = .right
            field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            field.controlSize = .small
            field.setAccessibilityLabel(label)
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 48).isActive = true
        }
        for radio in [skipRadio, retryRadio] {
            radio.target = self
            radio.action = #selector(dropActionChanged(_:))
            radio.font = .systemFont(ofSize: 12)
        }
        qualityControls = [ssimField, psnrField, skipRadio, retryRadio]
        func row(_ views: [NSView]) -> NSStackView {
            let h = NSStackView(views: views)
            h.spacing = 6
            h.alignment = .firstBaseline
            return h
        }
        let ssimRow = row([makeLabel("局部相似度不低于", size: 12), ssimField,
                           makeLabel("（0–1，16×16 小块里最差的 1%）", size: 11, color: .secondaryLabelColor)])
        let psnrRow = row([makeLabel("PSNR 不低于", size: 12), psnrField, makeLabel("dB", size: 12),
                           makeLabel("（0–100）", size: 11, color: .secondaryLabelColor)])
        let dropRow = row([makeLabel("不达标时", size: 12), skipRadio, retryRadio])
        let help = makeWrappingLabel("转好的 HEIF 先和原图比一遍，画质下降明显的按下面的门槛处理。只对 JPEG",
                                     size: 11, color: .secondaryLabelColor)
        help.preferredMaxLayoutWidth = 300
        let inner = vstack([help, ssimRow, psnrRow, dropRow, qualityProblemLabel], spacing: 5)
        inner.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
        return vstack([qualityCheck, inner], spacing: 2)
    }

    private func vstack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = spacing
        return s
    }

    private func formLabel(_ text: String) -> NSTextField {
        let l = makeLabel(text, size: 13, color: .secondaryLabelColor)
        l.alignment = .right
        return l
    }

    /// 一个复选框，下面一行小字说明。
    private func check(_ box: NSButton, _ help: String?, extra: NSView? = nil) -> NSView {
        var views: [NSView] = [box]
        if let help {
            let l = makeWrappingLabel(help, size: 11, color: .secondaryLabelColor)
            l.preferredMaxLayoutWidth = 300
            let indent = NSStackView(views: [l])
            indent.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
            views.append(indent)
        }
        if let extra {
            let indent = NSStackView(views: [extra])
            indent.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0)
            views.append(indent)
        }
        return vstack(views, spacing: 2)
    }

    // MARK: 状态

    private func refresh() {
        qualitySlider.doubleValue = settings.quality
        qualityValue.stringValue = "\(Int((settings.quality * 100).rounded()))"
        qualityHintLabel.stringValue = qualityHint(settings.quality)
        outputPopup.selectItem(at: settings.outputFolder == nil ? 0 : 1)
        outputPath.isHidden = settings.outputFolder == nil
        if grid.numberOfRows > 4 { grid.row(at: 4).isHidden = settings.outputFolder == nil }
        outputPath.stringValue = settings.outputFolder.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? ""
        verifyCheck.state = settings.effectiveVerify ? .on : .off
        verifyCheck.isEnabled = !settings.verifyLocked
        let canEmbed = targets.captionOutsideCount > 0
        captionCheck.isEnabled = canEmbed
        captionCheck.state = canEmbed && settings.embedCaption ? .on : .off
        deleteCheck.state = settings.deleteOriginal ? .on : .off
        deleteNote.superview?.isHidden = !settings.deleteOriginal
        exifCheck.state = settings.systemExif ? .on : .off
        overwriteCheck.state = settings.overwrite ? .on : .off
        cmykCheck.state = settings.convertCMYK ? .on : .off
        qualityCheck.state = settings.qualityCheck ? .on : .off
        for control in qualityControls { control.isEnabled = settings.qualityCheck }
        skipRadio.state = settings.onQualityDrop == .skip ? .on : .off
        retryRadio.state = settings.onQualityDrop == .retry ? .on : .off
        qualityProblemLabel.stringValue = thresholdProblem ?? ""
        qualityProblemLabel.isHidden = !settings.blocksStart(thresholdProblem: thresholdProblem)
        startButton.isEnabled = !settings.blocksStart(thresholdProblem: thresholdProblem)
        startButton.title = targets.primaryTitle(settings)
        let deleting = targets.deletes(settings)
        startButton.bezelColor = deleting ? .systemRed : nil
        startButton.hasDestructiveAction = deleting
    }

    @objc private func qualityChanged() {
        settings.quality = steppedQuality(qualitySlider.doubleValue)
        refresh()
    }

    @objc private func toggled(_ sender: NSButton) {
        let on = sender.state == .on
        switch sender {
        case verifyCheck: settings.verify = on
        case captionCheck: settings.embedCaption = on
        case deleteCheck: settings.deleteOriginal = on
        case exifCheck: settings.systemExif = on
        case overwriteCheck: settings.overwrite = on
        case cmykCheck: settings.convertCMYK = on
        case qualityCheck: settings.qualityCheck = on
        default: break
        }
        refresh()
    }

    @objc private func dropActionChanged(_ sender: NSButton) {
        settings.onQualityDrop = sender === retryRadio ? .retry : .skip
        refresh()
    }

    func controlTextDidChange(_ notification: Notification) {
        thresholdProblem = settings.takeThresholdInput(ssim: ssimField.stringValue, psnr: psnrField.stringValue)
        refresh()
    }

    @objc private func toggleAdvanced() {
        advancedBox.isHidden = advancedToggle.state == .off
    }

    @objc private func outputChanged() {
        guard outputPopup.indexOfSelectedItem == 1 else {
            settings.outputFolder = nil
            refresh()
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "选择 HEIF 文件的保存位置"
        panel.prompt = "选择"
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            if response == .OK, let url = panel.url { self.settings.outputFolder = url }
            self.refresh()
        }
        if let window = view.window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    @objc private func cancel() { onCancel?() }

    @objc private func start() {
        guard !settings.blocksStart(thresholdProblem: thresholdProblem) else { return }
        // 存的是用户自己的选择；删除、覆盖、也转 CMYK 不存（PanelSettings.save 不写这三项）。
        var toSave = settings
        if !captionCheck.isEnabled { toSave.embedCaption = settings.embedCaption }
        toSave.save(to: store)
        var final = settings
        if !captionCheck.isEnabled { final.embedCaption = false }
        onStart?(final)
    }

    /// 截图工具用：勾上「删除源文件」（这批里没有 JPEG、没有这个选项时什么都不做）。
    func checkDeleteForSnapshot() {
        guard case .offered = targets.deleteChoice else { return }
        deleteCheck.state = .on
        toggled(deleteCheck)
    }

    /// 截图工具用：展开「高级」；`ssim` 不是 nil 时把它填进局部相似度那一格（看填错时的样子）。
    func showAdvancedForSnapshot(ssim: String? = nil) {
        advancedToggle.state = .on
        toggleAdvanced()
        if let ssim {
            ssimField.stringValue = ssim
            controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        }
    }

    /// 截图工具用：把面板放进一个窗口里渲染。
    func makeWindow() -> NSWindow {
        let w = NSWindow(contentViewController: self)
        w.styleMask = [.titled]
        return w
    }
}
