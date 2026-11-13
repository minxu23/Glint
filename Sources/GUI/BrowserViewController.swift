// 中间一栏：缩略图网格（NSCollectionView）或列表（NSTableView），空状态，Quick Look，右键菜单。
// 网格和列表共用选中状态（按路径），切换时保持。

import AppKit
import Quartz

protocol BrowserDelegate: AnyObject {
    func browserSelectionChanged(_ paths: [String])
    func browserConvert()
    func browserAddFolder()
    func browserSortChanged(_ order: SortOrder)
    func browserZoom(by delta: Double)
    func browserMark(for path: String) -> ConversionMark?
}

final class BrowserViewController: NSViewController {
    weak var delegate: BrowserDelegate?
    var onDrop: (([URL]) -> Void)? { didSet { (view as? DropTargetView)?.onDrop = onDrop } }

    private(set) var items: [PhotoItem] = []
    private var indexByPath: [String: Int] = [:]
    private(set) var selection: [String] = []
    private(set) var mode: BrowserMode = .grid
    private var cellSize: CGFloat = CGFloat(CellSize.default)
    private var sortOrder = SortOrder()

    let grid = BrowserCollectionView()
    private let gridScroll = NSScrollView()
    private let layout = SquareGridLayout()
    let table = BrowserTableView()
    private let tableScroll = NSScrollView()
    private let empty = EmptyStateView()
    private var applyingSelection = false
    private var listLoads: [Int: Operation] = [:]

    override func loadView() {
        let root = DropTargetView()
        view = root

        layout.cellSize = cellSize
        grid.collectionViewLayout = layout
        grid.isSelectable = true
        grid.allowsMultipleSelection = true
        grid.allowsEmptySelection = true
        grid.backgroundColors = [.textBackgroundColor]
        grid.register(ThumbnailItem.self, forItemWithIdentifier: ThumbnailItem.identifier)
        grid.dataSource = self
        grid.delegate = self
        grid.owner = self
        grid.setAccessibilityLabel("缩略图")
        gridScroll.documentView = grid
        gridScroll.hasVerticalScroller = true
        gridScroll.drawsBackground = true
        gridScroll.backgroundColor = .textBackgroundColor

        configureTable()

        empty.button.target = self
        empty.button.action = #selector(addFolder)
        for v in [gridScroll, tableScroll, empty] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: root.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: root.trailingAnchor),
                v.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
                v.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            ])
        }
        tableScroll.isHidden = true
        empty.isHidden = true
    }

    @objc private func addFolder() { delegate?.browserAddFolder() }

    private var lastTableWidth: CGFloat = 0

    override func viewDidLayout() {
        super.viewDidLayout()
        // 宽度变了就让能伸缩的两列（名称、备注）把空出来的宽度分掉。
        let width = tableScroll.contentView.bounds.width
        if abs(width - lastTableWidth) > 0.5 {
            lastTableWidth = width
            fitColumns(to: width)
        }
    }

    // MARK: 列表

    private struct Column {
        let id: String, title: String, width: CGFloat, min: CGFloat, sort: SortKey?
    }
    private let columns = [
        Column(id: "name", title: "名称", width: 220, min: 120, sort: .name),
        Column(id: "captured", title: "拍摄时间", width: 128, min: 90, sort: .captured),
        Column(id: "format", title: "格式", width: 44, min: 40, sort: .format),
        Column(id: "dims", title: "尺寸", width: 92, min: 60, sort: nil),
        Column(id: "size", title: "大小", width: 60, min: 50, sort: .size),
        Column(id: "notes", title: "备注", width: 160, min: 60, sort: nil),
        Column(id: "conv", title: "转换", width: 84, min: 70, sort: nil),
    ]

    private func configureTable() {
        table.rowHeight = 40
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = false
        // 只有名称和备注两列跟着窗口伸缩，别的列宽固定；都缩到最小以后出横向滚动条。
        // 每一列的文字都在自己的列里截断（名称中间截断），不会压到别的列。
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.intercellSpacing = NSSize(width: 6, height: 0)
        for c in columns {
            let col = NSTableColumn(identifier: .init(c.id))
            col.title = c.title
            col.width = c.width
            col.minWidth = c.min
            col.resizingMask = c.id == "name" || c.id == "notes" ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            if let key = c.sort { col.sortDescriptorPrototype = NSSortDescriptor(key: key.rawValue, ascending: true) }
            if c.id == "size" { col.headerCell.alignment = .right }
            table.addTableColumn(col)
        }
        table.dataSource = self
        table.delegate = self
        table.owner = self
        table.target = self
        table.doubleAction = #selector(openClicked)
        table.setAccessibilityLabel("图片列表")
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.hasHorizontalScroller = true
        tableScroll.autohidesScrollers = true
    }

    /// 固定宽度的列不动，剩下的宽度按 2:1 分给名称和备注（各自不小于最小宽度）。
    private func fitColumns(to width: CGFloat) {
        guard let name = table.tableColumn(withIdentifier: .init("name")),
              let notes = table.tableColumn(withIdentifier: .init("notes")) else { return }
        let fixed = table.tableColumns.filter { $0 !== name && $0 !== notes }.reduce(0) { $0 + $1.width }
        let spacing = table.intercellSpacing.width * CGFloat(table.numberOfColumns) + 24
        let free = width - fixed - spacing
        name.width = max(name.minWidth, (free * 2 / 3).rounded(.down))
        notes.width = max(notes.minWidth, free - name.width)
    }

    // MARK: 外部接口

    /// 换上新的条目。顺序没变时只刷新单元内容，不整个重载（保持滚动位置与动画）。
    func setItems(_ newItems: [PhotoItem], emptyMessage: String?, welcome: Bool) {
        let samePaths = newItems.map(\.path) == items.map(\.path)
        items = newItems
        indexByPath = Dictionary(uniqueKeysWithValues: newItems.enumerated().map { ($1.path, $0) })
        let showEmpty = newItems.isEmpty
        empty.isHidden = !showEmpty
        if showEmpty { empty.show(welcome: welcome, message: emptyMessage ?? "这里没有图片") }
        gridScroll.isHidden = showEmpty || mode != .grid
        tableScroll.isHidden = showEmpty || mode != .list
        selection = selection.filter { indexByPath[$0] != nil }
        if samePaths {
            refreshVisibleCells()
        } else {
            for op in listLoads.values { op.cancel() }
            listLoads = [:]
            grid.reloadData()
            table.reloadData()
            applySelection()
        }
    }

    /// 只刷新可见单元的标记与描述（元数据补到了、转换状态变了）。
    func refreshVisibleCells(paths: Set<String>? = nil) {
        for ip in grid.indexPathsForVisibleItems() {
            guard ip.item < items.count, paths == nil || paths!.contains(items[ip.item].path),
                  let cell = grid.item(at: ip) as? ThumbnailItem else { continue }
            configure(cell, items[ip.item], animated: true)
        }
        let visibleRows = table.rows(in: table.visibleRect)
        if visibleRows.length > 0 {
            let rows = IndexSet(integersIn: visibleRows.location..<(visibleRows.location + visibleRows.length))
                .filter { paths == nil || ($0 < items.count && paths!.contains(items[$0].path)) }
            table.reloadData(forRowIndexes: IndexSet(rows), columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        }
    }

    func setMode(_ m: BrowserMode) {
        guard m != mode else { return }
        mode = m
        gridScroll.isHidden = items.isEmpty || m != .grid
        tableScroll.isHidden = items.isEmpty || m != .list
        applySelection()
        view.window?.makeFirstResponder(m == .grid ? grid : table)
        scrollSelectionVisible()
    }

    func setCellSize(_ size: Double) {
        cellSize = CGFloat(size)
        layout.cellSize = cellSize
        layout.invalidateLayout()
    }

    func setSortOrder(_ order: SortOrder) {
        sortOrder = order
        let key = order.key.rawValue
        if table.sortDescriptors.first?.key != key || table.sortDescriptors.first?.ascending != order.ascending {
            applyingSelection = true
            table.sortDescriptors = [NSSortDescriptor(key: key, ascending: order.ascending)]
            applyingSelection = false
        }
    }

    func select(paths: [String]) {
        selection = paths.filter { indexByPath[$0] != nil }
        applySelection()
        scrollSelectionVisible()
    }

    var focusView: NSView { mode == .grid ? grid : table }

    /// 第一屏的缩略图都出来了没有（测量用）。
    var visibleThumbnailsReady: Bool {
        let visible = grid.indexPathsForVisibleItems()
        guard !visible.isEmpty else { return false }
        return visible.allSatisfy { ip in
            (grid.item(at: ip) as? ThumbnailItem)?.loaded == true
        }
    }

    // MARK: 选中

    private func applySelection() {
        applyingSelection = true
        let indexes = selection.compactMap { indexByPath[$0] }
        grid.selectionIndexPaths = Set(indexes.map { IndexPath(item: $0, section: 0) })
        table.selectRowIndexes(IndexSet(indexes), byExtendingSelection: false)
        applyingSelection = false
    }

    private func scrollSelectionVisible() {
        guard let first = selection.compactMap({ indexByPath[$0] }).min() else { return }
        if mode == .grid {
            grid.scrollToItems(at: [IndexPath(item: first, section: 0)], scrollPosition: .nearestHorizontalEdge)
        } else {
            table.scrollRowToVisible(first)
        }
    }

    private func selectionChanged(_ indexes: [Int]) {
        guard !applyingSelection else { return }
        selection = indexes.sorted().compactMap { $0 < items.count ? items[$0].path : nil }
        delegate?.browserSelectionChanged(selection)
        if QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().reloadData()
        }
    }

    var selectedItems: [PhotoItem] { selection.compactMap { indexByPath[$0].map { items[$0] } } }

    // MARK: 单元

    fileprivate func configure(_ cell: ThumbnailItem, _ item: PhotoItem, animated: Bool) {
        let mark = delegate?.browserMark(for: item.path)
        cell.cell.setBadges(hasNotes: item.hasNotes, mark: mark, animated: animated)
        cell.view.setAccessibilityLabel(accessibilityDescription(item, mark: mark))
        cell.view.toolTip = item.name
        guard cell.path != item.path || !cell.loaded else { return }
        cell.path = item.path
        let pixels = layout.itemSize.width * (view.window?.backingScaleFactor ?? 2)
        if let hit = ThumbnailLoader.shared.cached(item, pixels: pixels) {
            cell.cell.setImage(hit)
            cell.loaded = true
            return
        }
        cell.loaded = false
        cell.cell.setImage(nil)
        cell.loading?.cancel()
        let path = item.path
        cell.loading = ThumbnailLoader.shared.load(item, pixels: pixels) { [weak cell] image in
            guard let cell, cell.path == path else { return }
            cell.cell.setImage(image)
            cell.loaded = true
        }
    }

    // MARK: 动作

    @objc func openClicked() {
        let urls = selectedItems.map(\.url)
        for url in urls { NSWorkspace.shared.open(url) }
    }

    @objc func revealSelected() {
        let urls = selectedItems.map(\.url)
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    @objc func copyPaths() {
        let text = selectedItems.map(\.path).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func convertSelected() { delegate?.browserConvert() }

    /// 编辑 › 拷贝：选中图片时拷贝文件。
    @objc func copy(_ sender: Any?) {
        let urls = selectedItems.map { $0.url as NSURL }
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls)
    }

    func validate(_ action: Selector) -> Bool {
        switch action {
        case #selector(copy(_:)), #selector(openClicked), #selector(revealSelected), #selector(copyPaths):
            return !selection.isEmpty
        default: return true
        }
    }

    /// 右键菜单。点在没选中的图上时先选中它。
    fileprivate func contextMenu(forIndex index: Int?) -> NSMenu? {
        if let index, index < items.count, !selection.contains(items[index].path) {
            select(paths: [items[index].path])
            delegate?.browserSelectionChanged(selection)
        }
        guard !selection.isEmpty else { return nil }
        let menu = NSMenu()
        if selectedItems.contains(where: \.isConvertible) {
            menu.addItem(withTitle: "转换…", action: #selector(convertSelected), keyEquivalent: "").target = self
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "用默认应用打开", action: #selector(openClicked), keyEquivalent: "").target = self
        menu.addItem(withTitle: "在访达中显示", action: #selector(revealSelected), keyEquivalent: "").target = self
        menu.addItem(withTitle: "拷贝路径", action: #selector(copyPaths), keyEquivalent: "").target = self
        return menu
    }

    // MARK: Quick Look

    func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
        } else if !selection.isEmpty {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    fileprivate func zoom(_ delta: Double) { delegate?.browserZoom(by: delta) }
}

// MARK: - 网格的数据源与代理

extension BrowserViewController: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { items.count }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(withIdentifier: ThumbnailItem.identifier, for: indexPath) as! ThumbnailItem
        configure(cell, items[indexPath.item], animated: false)
        return cell
    }

    func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem,
                        forRepresentedObjectAt indexPath: IndexPath) {
        guard let cell = item as? ThumbnailItem else { return }
        cell.loading?.cancel()
        cell.loading = nil
        if !cell.loaded { cell.path = nil }
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        selectionChanged(collectionView.selectionIndexPaths.map(\.item))
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        selectionChanged(collectionView.selectionIndexPaths.map(\.item))
    }
}

// MARK: - 列表的数据源与代理

extension BrowserViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue, row < items.count else { return nil }
        let item = items[row]
        let mark = delegate?.browserMark(for: item.path)
        switch id {
        case "name":
            let cell = tableView.makeView(withIdentifier: .init("nameCell"), owner: self) as? NameCellView ?? NameCellView()
            cell.identifier = .init("nameCell")
            cell.configure(item)
            let pixels = 28 * (view.window?.backingScaleFactor ?? 2)
            if let hit = ThumbnailLoader.shared.cached(item, pixels: pixels) {
                cell.thumb.layer?.contents = hit
            } else {
                listLoads[row]?.cancel()
                let path = item.path
                listLoads[row] = ThumbnailLoader.shared.load(item, pixels: pixels) { [weak cell] image in
                    guard let cell, cell.path == path else { return }
                    cell.thumb.layer?.contents = image
                }
            }
            return cell
        case "conv":
            let cell = tableView.makeView(withIdentifier: .init("convCell"), owner: self) as? ConversionCellView ?? ConversionCellView()
            cell.identifier = .init("convCell")
            cell.configure(mark)
            return cell
        default:
            let cellID = NSUserInterfaceItemIdentifier("text." + id)
            let cell = tableView.makeView(withIdentifier: cellID, owner: self) as? TextCellView ?? TextCellView()
            cell.identifier = cellID
            let text: String
            switch id {
            case "captured": text = item.info?.captured?.compact ?? ""
            case "format": text = item.format.label
            case "dims": text = item.info?.dimensions ?? ""
            case "size": text = shortSize(item.size)
            case "notes": text = item.info?.notes.first.map { $0.text.replacingOccurrences(of: "\n", with: " ") } ?? ""
            default: text = ""
            }
            cell.configure(text, rightAligned: id == "size", secondary: id != "notes")
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        selectionChanged(Array(table.selectedRowIndexes))
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !applyingSelection, let d = tableView.sortDescriptors.first, let key = d.key.flatMap(SortKey.init) else { return }
        delegate?.browserSortChanged(SortOrder(key: key, ascending: d.ascending))
    }
}

// MARK: - Quick Look 数据源

extension BrowserViewController: QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { selectedItems.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        selectedItems[index].url as NSURL
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        // 方向键交给网格/列表，选中跟着动，预览跟着换。
        guard event.type == .keyDown else { return false }
        focusView.keyDown(with: event)
        return true
    }
}

// MARK: - 子类：键盘、双击、右键、捏合

final class BrowserCollectionView: NSCollectionView {
    weak var owner: BrowserViewController?

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " { owner?.toggleQuickLook(); return }
        if event.keyCode == 36 || event.keyCode == 76 { owner?.openClicked(); return }   // 回车
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2, indexPathForItem(at: convert(event.locationInWindow, from: nil)) != nil {
            owner?.openClicked()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let ip = indexPathForItem(at: convert(event.locationInWindow, from: nil))
        return owner?.contextMenu(forIndex: ip?.item)
    }

    override func magnify(with event: NSEvent) {
        owner?.zoom(Double(event.magnification) * 160)
    }
}

final class BrowserTableView: NSTableView {
    weak var owner: BrowserViewController?

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " { owner?.toggleQuickLook(); return }
        if event.keyCode == 36 || event.keyCode == 76 { owner?.openClicked(); return }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        return owner?.contextMenu(forIndex: row >= 0 ? row : nil)
    }
}

/// 方形单元的网格：按可用宽度算列数，单元边长在不超过设定值附近均分，间距 10，四周 14。
final class SquareGridLayout: NSCollectionViewFlowLayout {
    var cellSize: CGFloat = 168

    override init() {
        super.init()
        minimumInteritemSpacing = 10
        minimumLineSpacing = 10
        sectionInset = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func prepare() {
        if let width = collectionView?.enclosingScrollView?.contentView.bounds.width ?? collectionView?.bounds.width {
            let available = max(1, width - 28)
            let columns = max(1, ((available + 10) / (cellSize + 10)).rounded())
            let side = floor((available - (columns - 1) * 10) / columns)
            itemSize = NSSize(width: max(40, side), height: max(40, side))
        }
        super.prepare()
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool { true }
}

// MARK: - 列表单元

final class NameCellView: NSTableCellView {
    let thumb = NSView()
    private let name = makeLabel("", size: 13)
    var path: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 4
        thumb.layer?.masksToBounds = true
        thumb.layer?.contentsGravity = .resizeAspectFill
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for v in [thumb, name] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        textField = name
        NSLayoutConstraint.activate([
            thumb.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            thumb.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumb.widthAnchor.constraint(equalToConstant: 28),
            thumb.heightAnchor.constraint(equalToConstant: 28),
            name.leadingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: 8),
            name.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        super.updateLayer()
        thumb.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
    }

    override var wantsUpdateLayer: Bool { true }

    func configure(_ item: PhotoItem) {
        if path != item.path { thumb.layer?.contents = nil }
        path = item.path
        name.stringValue = item.name
        name.toolTip = item.name
        needsDisplay = true
    }
}

final class TextCellView: NSTableCellView {
    private let label = makeLabel("", size: 13)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ text: String, rightAligned: Bool, secondary: Bool) {
        label.stringValue = text
        label.alignment = rightAligned ? .right : .left
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        label.textColor = secondary ? .secondaryLabelColor : .labelColor
    }
}

/// 「转换」列：与网格相同的图标（带颜色）+ 文字（不用彩色）。
final class ConversionCellView: NSTableCellView {
    private let icon = NSImageView()
    private let spinner = NSProgressIndicator()
    private let label = makeLabel("", size: 13, color: .secondaryLabelColor, monospacedDigits: true)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for v in [icon, spinner, label] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            spinner.centerXAnchor.constraint(equalTo: icon.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ mark: ConversionMark?) {
        label.stringValue = mark?.listText ?? ""
        if mark == .running { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        if let mark, let s = markSymbol(mark) {
            icon.isHidden = false
            icon.image = symbolImage(s.name, size: 12)
            icon.contentTintColor = s.color
        } else {
            icon.isHidden = true
        }
    }
}

extension BrowserViewController: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action.map(validate) ?? true
    }
}
