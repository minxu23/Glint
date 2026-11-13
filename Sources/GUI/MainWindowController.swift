// 主窗口：三栏（侧栏 / 网格或列表 / 信息栏）+ 统一样式的工具栏 + 只在转换时出现的活动条。
//
// 这里是各部分之间的调度：图库（LibraryModel）、转换（ConversionModel）和转换记录的状态
// 在这里汇总，算出各栏要显示的东西交给它们。逻辑都在模型层，这里只做呈现与转发。

import AppKit

final class MainWindowController: NSWindowController, NSWindowDelegate {
    let store: SettingsStore
    let library: LibraryModel
    let conversion = ConversionModel()
    private(set) var record: ConversionRecord?
    private(set) var entry: LibraryEntry = .all
    private(set) var search = ""
    private(set) var browserSettings: BrowserSettings
    private(set) var visible: [PhotoItem] = []
    private var activityDismissed = true
    /// 等扫出来以后要选中的图片（单独添加的）。
    private var pendingSelection: [String]?

    let sidebar = SidebarViewController()
    let browser = BrowserViewController()
    let inspector = InspectorViewController()
    private let outerSplit = NSSplitViewController()
    private let innerSplit = NSSplitViewController()
    private let rightSide = NSViewController()
    private var sidebarItem: NSSplitViewItem!
    private var inspectorItem: NSSplitViewItem!
    let activityBar = ActivityBar()
    private var activityHeight: NSLayoutConstraint!

    private var viewModeItem: NSToolbarItemGroup?
    private var sortItem: NSMenuToolbarItem?
    private(set) var searchItem: NSSearchToolbarItem?
    private let convertButton = NSButton(title: "转换…", target: nil, action: nil)
    private var refreshScheduled = false
    private var sheetController: ConversionSheetController?

    static let defaultSize = NSSize(width: 1180, height: 720)
    static let sidebarWidth: CGFloat = 208
    static let sidebarRange: ClosedRange<CGFloat> = 180...320
    private var needsDefaultSplit = false
    static let minimumSize = NSSize(width: 900, height: 560)

    init(store: SettingsStore, library: LibraryModel = LibraryModel(), autosave: Bool = true) {
        self.store = store
        self.library = library
        browserSettings = BrowserSettings.load(from: store)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: MainWindowController.defaultSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.minSize = MainWindowController.minimumSize
        window.title = appName
        window.toolbarStyle = .unified
        window.autorecalculatesKeyViewLoop = true
        super.init(window: window)
        window.delegate = self
        buildSplits(autosave: autosave)
        window.contentViewController = outerSplit
        window.setContentSize(MainWindowController.defaultSize)
        buildToolbar()
        if autosave {
            window.center()
            // 窗口、分栏的 autosave 名和工具栏标识符存进了用户设置，应用改名 Glint 后保持「吉光.」
            // 开头的旧名字：改了，用户记住的窗口位置和分栏宽度就丢了。它们不显示在界面上。
            window.setFrameAutosaveName("吉光.主窗口")
        }
        wireModels()
        applyBrowserSettings()
        library.addFolders(SavedFolders.load(from: store).map { URL(fileURLWithPath: $0) })
        refreshNow()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: 搭窗口

    private func buildSplits(autosave: Bool) {
        sidebar.delegate = self
        browser.delegate = self
        inspector.delegate = self
        inspector.reshowHandler = { [weak self] in self?.refreshInspector() }
        let drop: ([URL]) -> Void = { [weak self] urls in self?.add(urls: urls) }
        _ = sidebar.view; _ = browser.view; _ = inspector.view
        sidebar.onDrop = drop
        browser.onDrop = drop
        inspector.onDrop = drop

        let browserItem = NSSplitViewItem(viewController: browser)
        browserItem.minimumThickness = 360
        if #available(macOS 14.0, *) {
            inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
        } else {
            inspectorItem = NSSplitViewItem(viewController: inspector)
        }
        inspectorItem.canCollapse = true
        inspectorItem.minimumThickness = InspectorViewController.minimumWidth
        inspectorItem.maximumThickness = InspectorViewController.maximumWidth
        inspectorItem.preferredThicknessFraction = 0
        innerSplit.addSplitViewItem(browserItem)
        innerSplit.addSplitViewItem(inspectorItem)
        innerSplit.splitView.isVertical = true
        innerSplit.splitView.dividerStyle = .thin

        let container = NSView()
        rightSide.view = container
        rightSide.addChild(innerSplit)
        let inner = innerSplit.view
        activityBar.isHidden = true
        activityBar.button.target = self
        activityBar.button.action = #selector(activityButton)
        activityBar.onLink = { [weak self] entry in self?.selectEntry(entry) }
        for v in [inner, activityBar] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }
        activityHeight = activityBar.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: container.topAnchor),
            inner.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            inner.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            inner.bottomAnchor.constraint(equalTo: activityBar.topAnchor),
            activityBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            activityBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            activityBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            activityHeight,
        ])

        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = MainWindowController.sidebarRange.lowerBound
        sidebarItem.maximumThickness = MainWindowController.sidebarRange.upperBound
        sidebarItem.canCollapse = true
        let rightItem = NSSplitViewItem(viewController: rightSide)
        rightItem.minimumThickness = 600
        outerSplit.addSplitViewItem(sidebarItem)
        outerSplit.addSplitViewItem(rightItem)

        // 默认宽度：侧栏 208，信息栏 280。记住的宽度由 autosave 恢复。
        outerSplit.splitView.setPosition(208, ofDividerAt: 0)
        innerSplit.splitView.setPosition(MainWindowController.defaultSize.width - 208 - InspectorViewController.width,
                                         ofDividerAt: 0)
        if autosave {
            // 还没存过分栏位置（首次启动）时，等窗口布局好以后放到规格的宽度（见 showWindow）。
            let saved = ["吉光.侧栏", "吉光.信息栏"].contains {
                UserDefaults.standard.object(forKey: "NSSplitView Subview Frames \($0)") != nil
            }
            needsDefaultSplit = !saved
            outerSplit.splitView.autosaveName = "吉光.侧栏"
            innerSplit.splitView.autosaveName = "吉光.信息栏"
        }
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        if needsDefaultSplit {
            needsDefaultSplit = false
            applyDefaultSplitPositions()
        }
    }

    /// 布局定下来以后把分栏放到默认宽度：侧栏 208，信息栏 280（截图工具、首次启动）。
    func applyDefaultSplitPositions() {
        window?.contentView?.layoutSubtreeIfNeeded()
        outerSplit.splitView.setPosition(MainWindowController.sidebarWidth, ofDividerAt: 0)
        rightSide.view.layoutSubtreeIfNeeded()
        let width = rightSide.view.bounds.width
        if !inspectorItem.isCollapsed {
            innerSplit.splitView.setPosition(width - InspectorViewController.width, ofDividerAt: 0)
        }
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    /// 把信息栏拖到给定宽度（截图工具用；夹在最小、最大宽度之间）。
    func setInspectorWidth(_ width: CGFloat) {
        rightSide.view.layoutSubtreeIfNeeded()
        let w = min(InspectorViewController.maximumWidth, max(InspectorViewController.minimumWidth, width))
        innerSplit.splitView.setPosition(rightSide.view.bounds.width - w, ofDividerAt: 0)
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    private func wireModels() {
        library.onChange = { [weak self] in self?.setNeedsRefresh() }
        library.onInfo = { [weak self] paths in self?.infoArrived(paths) }
        library.onFoldersChange = { [weak self] folders in
            guard let self else { return }
            SavedFolders.save(folders, to: self.store)
        }
        conversion.onRowChange = { [weak self] row in self?.rowChanged(row) }
        conversion.onChange = { [weak self] in self?.conversionChanged() }
    }

    private func applyBrowserSettings() {
        browser.setMode(browserSettings.mode)
        browser.setCellSize(browserSettings.cellSize)
        browser.setSortOrder(browserSettings.sort)
        inspectorItem.isCollapsed = !browserSettings.inspectorVisible
        viewModeItem?.selectedIndex = browserSettings.mode == .grid ? 0 : 1
    }

    private func saveBrowserSettings() { browserSettings.save(to: store) }

    // MARK: 刷新

    func setNeedsRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshScheduled = false
            self?.refreshNow()
        }
    }

    func refreshNow() {
        let lib = library.library
        if pendingSelection != nil, !lib.looseFiles.isEmpty, entry != .looseFiles { entry = .looseFiles }
        if case .conversion = entry, record == nil { entry = .all }
        if case .folder(let path) = entry, !lib.folders.contains(where: { path == $0 || isPath(path, inside: $0) }) { entry = .all }
        if entry == .looseFiles, lib.looseFiles.isEmpty { entry = .all }
        visible = lib.visibleItems(in: entry, record: record, search: search, order: browserSettings.sort)
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = !q.isEmpty && lib.items(in: entry, record: record).count > 0 ? "没有找到「\(q)」" : "这里没有图片"
        browser.setItems(visible, emptyMessage: message, welcome: lib.isEmpty)
        if let pending = pendingSelection {
            let ready = pending.filter { path in visible.contains { $0.path == path } }
            if !ready.isEmpty {
                pendingSelection = nil
                browser.select(paths: ready)
            }
        }
        sidebar.update(library: lib, record: record, selected: entry)
        refreshTitle()
        refreshInspector()
        refreshToolbar()
        refreshActivity()
    }

    private var entryTitle: String { entry.title() }

    private func refreshTitle() {
        guard let window else { return }
        if library.library.isEmpty {
            window.title = appName
            window.subtitle = ""
            return
        }
        window.title = entryTitle
        let scanning = !library.library.scanning.isEmpty
        window.subtitle = subtitle(items: visible, selected: browser.selectedItems, scanning: scanning)
    }

    func refreshInspector() {
        let selected = browser.selectedItems
        if selected.count == 1, let item = selected.first {
            let row = record?.row(for: item.path)
            var stillThere = true
            var product: PhotoItem?
            if let row {
                stillThere = library.library.items[row.job.input.standardizedFileURL.path] != nil
                product = row.dest.flatMap { library.library.items[$0.standardizedFileURL.path] }
            }
            inspector.show(.single(item, row: row, record: record, sourceStillThere: stillThere, productItem: product))
        } else {
            let isConversion: Bool = { if case .conversion = entry { return true }; return false }()
            inspector.show(.summary(title: library.library.isEmpty ? appName : entryTitle,
                                    items: ItemsSummary(items: selected.isEmpty ? visible : selected, selected: !selected.isEmpty),
                                    record: selected.isEmpty && isConversion ? record : nil))
        }
    }

    private func currentTargets() -> ConversionTargets {
        ConversionTargets(selected: browser.selectedItems, visible: visible, entry: entry, entryName: entryTitle, search: search)
    }

    private func refreshToolbar() {
        let targets = currentTargets()
        convertButton.isEnabled = !targets.isEmpty && !conversion.isRunning
        convertButton.toolTip = conversion.isRunning ? "正在转换" : targets.isEmpty ? ConversionTargets.emptyHint : targets.title
        viewModeItem?.selectedIndex = browserSettings.mode == .grid ? 0 : 1
        rebuildSortMenu()
    }

    private func refreshActivity() {
        guard let record, record.isRunning || !activityDismissed else {
            setActivityVisible(false)
            return
        }
        activityBar.update(record)
        setActivityVisible(true)
    }

    private func setActivityVisible(_ visible: Bool) {
        let target: CGFloat = visible ? ActivityBar.height : 0
        guard activityHeight.constant != target else { return }
        activityBar.isHidden = false
        if reduceMotion || window?.isVisible != true {
            activityHeight.constant = target
            activityBar.isHidden = !visible
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                ctx.allowsImplicitAnimation = true
                activityHeight.animator().constant = target
            }, completionHandler: { [weak self] in self?.activityBar.isHidden = !visible })
        }
    }

    private func infoArrived(_ paths: Set<String>) {
        // 排序和过滤可能因为元数据变了（拍摄时间、有备注），整个重算一次；顺序没变时只刷新单元。
        setNeedsRefresh()
        browser.refreshVisibleCells(paths: paths)
    }

    // MARK: 来源

    /// 拖进来的、「打开方式」送进来的：文件夹加到「文件夹」，图片归到「单独添加的图片」。
    func add(urls: [URL]) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let folders = urls.filter(folderExistsOnDisk)
            let files = urls.filter { !folderExistsOnDisk($0) }
            DispatchQueue.main.async {
                guard let self else { return }
                if !folders.isEmpty { self.library.addFolders(folders) }
                if !files.isEmpty { self.library.addFiles(files) }
                if let first = folders.first {
                    self.selectEntry(.folder(first.standardizedFileURL.path))
                } else if !files.isEmpty {
                    // 单独送进来的图片（拖进来、「打开方式」）：扫出来以后选中它们，信息栏直接显示。
                    // 条目要等图片 stat 完（后台）才出现，到时候再切过去。
                    self.pendingSelection = files.map { $0.standardizedFileURL.path }
                    self.browser.select(paths: [])
                }
            }
        }
    }

    func selectEntry(_ e: LibraryEntry) {
        entry = e
        browser.select(paths: [])
        refreshNow()
        // 加文件夹时条目可能还没扫出来：等扫出来以后侧栏再选中它。
        sidebar.select(e)
    }

    // MARK: 转换

    @objc func showConversion(_ sender: Any?) {
        let targets = currentTargets()
        guard !targets.isEmpty, !conversion.isRunning, sheetController == nil, let window else { return }
        let sheet = ConversionSheetController(targets: targets, store: store)
        sheetController = sheet
        let sheetWindow = NSWindow(contentViewController: sheet)
        sheet.onCancel = { [weak self, weak sheetWindow] in
            if let sheetWindow { window.endSheet(sheetWindow) }
            self?.sheetController = nil
        }
        sheet.onStart = { [weak self, weak sheetWindow] settings in
            if let sheetWindow { window.endSheet(sheetWindow) }
            self?.sheetController = nil
            self?.startConversion(targets, settings: settings)
        }
        window.beginSheet(sheetWindow)
    }

    /// 截图工具用：不弹 sheet，直接给出面板的控制器。
    func makeConversionSheet() -> ConversionSheetController? {
        let targets = currentTargets()
        return targets.isEmpty ? nil : ConversionSheetController(targets: targets, store: store)
    }

    func startConversion(_ targets: ConversionTargets, settings: PanelSettings) {
        guard !targets.isEmpty, !conversion.isRunning else { return }
        conversion.replaceJobs(targets.jobs)
        conversion.outputFolder = settings.outputFolder
        conversion.outputMode = settings.outputFolder == nil ? .sameFolder : .chosenFolder
        conversion.updateOptions { targets.apply(settings, to: &$0) }
        record = ConversionRecord(rows: conversion.rows, startedAt: Date(), deleteRequested: targets.deletes(settings),
                                  isRunning: true)
        activityDismissed = false
        conversion.start()
        if !conversion.isRunning {
            // 没开起来（保存位置建不出来等）：说清楚，记录撤掉。
            let message = conversion.warning ?? "没能开始转换"
            record = nil
            activityDismissed = true
            refreshNow()
            let alert = NSAlert()
            alert.messageText = "没能开始转换"
            alert.informativeText = message
            if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
            return
        }
        refreshNow()
    }

    @objc func cancelConversion(_ sender: Any?) { conversion.cancel() }

    private func rowChanged(_ row: FileRow) {
        guard var rec = record else { return }
        if let i = rec.rows.firstIndex(where: { $0.job.input == row.job.input }) { rec.rows[i] = row }
        record = rec
        let source = row.job.input.standardizedFileURL.path
        var paths: Set<String> = [source]
        if row.status == .done, let dest = row.dest {
            library.adoptProduct(url: dest, size: row.outBytes)
            paths.insert(dest.standardizedFileURL.path)
            if rec.sourceDeleted(row) { library.forgetItem(source) }
        }
        browser.refreshVisibleCells(paths: paths)
        setNeedsRefresh()
    }

    private func conversionChanged() {
        guard var rec = record else { return }
        let wasRunning = rec.isRunning
        rec.rows = conversion.rows
        rec.isRunning = conversion.isRunning
        rec.wasCancelled = conversion.wasCancelled
        record = rec
        if wasRunning && !rec.isRunning {
            // 转完：重新读取受影响的文件夹，新出来的 HEIF 以磁盘为准。
            var paths = rec.rows.map { $0.job.input.standardizedFileURL.path }
            paths += rec.rows.compactMap { $0.dest?.standardizedFileURL.path }
            library.reload(affecting: paths)
            if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        }
        setNeedsRefresh()
    }

    @objc private func activityButton() {
        if conversion.isRunning {
            conversion.cancel()
        } else {
            activityDismissed = true
            refreshActivity()
        }
    }

    // MARK: 视图切换

    @objc func showGrid(_ sender: Any?) { setMode(.grid) }
    @objc func showList(_ sender: Any?) { setMode(.list) }

    private func setMode(_ m: BrowserMode) {
        browserSettings.mode = m
        browser.setMode(m)
        saveBrowserSettings()
        refreshToolbar()
    }

    @objc private func viewModeChanged(_ sender: NSToolbarItemGroup) {
        setMode(sender.selectedIndex == 1 ? .list : .grid)
    }

    @objc func zoomIn(_ sender: Any?) { zoom(by: CellSize.step) }
    @objc func zoomOut(_ sender: Any?) { zoom(by: -CellSize.step) }

    private func zoom(by delta: Double) {
        let new = CellSize.clamp(browserSettings.cellSize + delta)
        guard new != browserSettings.cellSize else { return }
        browserSettings.cellSize = new
        browser.setCellSize(new)
        saveBrowserSettings()
    }

    @objc func toggleSidebarPane(_ sender: Any?) {
        let item = sidebarItem!
        if reduceMotion { item.isCollapsed.toggle() } else { item.animator().isCollapsed.toggle() }
    }

    @objc func toggleInspectorPane(_ sender: Any?) {
        let item = inspectorItem!
        let collapse = !item.isCollapsed
        if reduceMotion { item.isCollapsed = collapse } else { item.animator().isCollapsed = collapse }
        browserSettings.inspectorVisible = !collapse
        saveBrowserSettings()
    }

    @objc func reloadLibrary(_ sender: Any?) { library.reload() }

    @objc func focusSearch(_ sender: Any?) {
        searchItem?.beginSearchInteraction()
    }

    @objc func addFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = "选择装照片的文件夹"
        panel.prompt = "添加"
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            self?.add(urls: panel.urls)
        }
    }

    @objc func openSelected(_ sender: Any?) { browser.openClicked() }
    @objc func revealSelected(_ sender: Any?) { browser.revealSelected() }

    // MARK: 排序

    private func rebuildSortMenu() {
        guard let sortItem else { return }
        let menu = NSMenu()
        for key in SortKey.allCases {
            let item = NSMenuItem(title: key.title, action: #selector(sortKeyChosen(_:)), keyEquivalent: "")
            item.representedObject = key.rawValue
            item.target = self
            item.state = browserSettings.sort.key == key ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for (title, asc) in [("升序", true), ("降序", false)] {
            let item = NSMenuItem(title: title, action: #selector(sortDirectionChosen(_:)), keyEquivalent: "")
            item.tag = asc ? 1 : 0
            item.target = self
            item.state = browserSettings.sort.ascending == asc ? .on : .off
            menu.addItem(item)
        }
        sortItem.menu = menu
    }

    @objc private func sortKeyChosen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let key = SortKey(rawValue: raw) else { return }
        setSort(SortOrder(key: key, ascending: browserSettings.sort.ascending))
    }

    @objc private func sortDirectionChosen(_ sender: NSMenuItem) {
        setSort(SortOrder(key: browserSettings.sort.key, ascending: sender.tag == 1))
    }

    private func setSort(_ order: SortOrder) {
        browserSettings.sort = order
        browser.setSortOrder(order)
        saveBrowserSettings()
        refreshNow()
    }

    // MARK: 搜索

    @objc private func searchChanged(_ sender: NSSearchField) {
        setSearch(sender.stringValue)
    }

    func setSearch(_ text: String) {
        search = text
        searchItem?.searchField.stringValue = text
        refreshNow()
    }

    // MARK: 截图工具用

    /// 选中这些文件名对应的图片（当前视图里的）。
    func selectNames(_ names: [String]) {
        let paths = visible.filter { names.contains($0.name) }.map(\.path)
        browser.select(paths: paths)
        browserSelectionChanged(browser.selection)
    }

    func dismissActivity() {
        activityDismissed = true
        refreshActivity()
    }
}

// MARK: - 工具栏

extension NSToolbarItem.Identifier {
    static let viewMode = Self("吉光.viewMode")
    static let sort = Self("吉光.sort")
    static let search = Self("吉光.search")
    static let convert = Self("吉光.convert")
    static let inspector = Self("吉光.inspector")
}

extension MainWindowController: NSToolbarDelegate {
    private func buildToolbar() {
        let toolbar = NSToolbar(identifier: "吉光.工具栏")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.sidebarTrackingSeparator, .flexibleSpace, .viewMode, .sort, .search, .convert, .inspector]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .viewMode:
            let images = [symbolImage("square.grid.2x2", size: 13, label: "网格")!, symbolImage("list.bullet", size: 13, label: "列表")!]
            let group = NSToolbarItemGroup(itemIdentifier: id, images: images, selectionMode: .selectOne,
                                           labels: ["网格", "列表"], target: self, action: #selector(viewModeChanged(_:)))
            group.label = "显示方式"
            group.toolTip = "网格或列表"
            group.selectedIndex = browserSettings.mode == .grid ? 0 : 1
            viewModeItem = group
            return group
        case .sort:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.image = symbolImage("arrow.up.arrow.down", size: 13, label: "排序")
            item.label = "排序"
            item.toolTip = "排序"
            item.showsIndicator = false
            sortItem = item
            rebuildSortMenu()
            return item
        case .search:
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.searchField.placeholderString = "搜索文件名和备注"
            item.searchField.sendsSearchStringImmediately = true
            item.searchField.target = self
            item.searchField.action = #selector(searchChanged(_:))
            item.label = "搜索"
            item.preferredWidthForSearchField = 180
            searchItem = item
            return item
        case .convert:
            let item = NSToolbarItem(itemIdentifier: id)
            convertButton.image = symbolImage("arrow.left.arrow.right", size: 12)
            convertButton.imagePosition = .imageLeading
            convertButton.bezelStyle = .rounded
            convertButton.bezelColor = .controlAccentColor
            convertButton.target = self
            convertButton.action = #selector(showConversion(_:))
            convertButton.setAccessibilityLabel("转换")
            item.view = convertButton
            item.label = "转换"
            return item
        case .inspector:
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = symbolImage("sidebar.right", size: 13, label: "信息栏")
            item.label = "信息栏"
            item.toolTip = "显示或隐藏信息栏"
            item.target = self
            item.action = #selector(toggleInspectorPane(_:))
            item.isBordered = true
            return item
        default:
            return nil
        }
    }
}

// MARK: - 菜单状态

extension MainWindowController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(showConversion(_:)):
            return !conversion.isRunning && !currentTargets().isEmpty && sheetController == nil
        case #selector(cancelConversion(_:)):
            return conversion.isRunning
        case #selector(openSelected(_:)), #selector(revealSelected(_:)):
            return !browser.selection.isEmpty
        case #selector(showGrid(_:)):
            menuItem.state = browserSettings.mode == .grid ? .on : .off
            return true
        case #selector(showList(_:)):
            menuItem.state = browserSettings.mode == .list ? .on : .off
            return true
        case #selector(zoomIn(_:)):
            return browserSettings.mode == .grid && browserSettings.cellSize < CellSize.range.upperBound
        case #selector(zoomOut(_:)):
            return browserSettings.mode == .grid && browserSettings.cellSize > CellSize.range.lowerBound
        case #selector(toggleSidebarPane(_:)):
            menuItem.title = sidebarItem.isCollapsed ? "显示侧栏" : "隐藏侧栏"
            return true
        case #selector(toggleInspectorPane(_:)):
            menuItem.title = inspectorItem.isCollapsed ? "显示信息栏" : "隐藏信息栏"
            return true
        default:
            return true
        }
    }
}

// MARK: - 各栏的回调

extension MainWindowController: SidebarDelegate, BrowserDelegate, InspectorDelegate {
    func sidebar(didSelect e: LibraryEntry) {
        guard e != entry else { return }
        entry = e
        browser.select(paths: [])
        refreshNow()
    }

    func sidebarAddFolder() { addFolder(nil) }

    func sidebarRemoveFolder(_ path: String) { library.removeFolder(path) }

    func browserSelectionChanged(_ paths: [String]) {
        refreshTitle()
        refreshInspector()
        refreshToolbar()
    }

    func browserConvert() { showConversion(nil) }
    func browserAddFolder() { addFolder(nil) }

    func browserSortChanged(_ order: SortOrder) { setSort(order) }

    func browserZoom(by delta: Double) { zoom(by: delta) }

    func browserMark(for path: String) -> ConversionMark? { record?.mark(for: path) }

    func inspectorShowProduct(_ path: String) {
        if !visible.contains(where: { $0.path == path }) {
            entry = .conversion(.all)
            search = ""
            searchItem?.searchField.stringValue = ""
            refreshNow()
        }
        browser.select(paths: [path])
        browserSelectionChanged(browser.selection)
    }
}
