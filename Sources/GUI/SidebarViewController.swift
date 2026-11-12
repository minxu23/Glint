// 侧栏：图库 / 转换 / 文件夹三组，source list 样式，每项右边是张数。底部一个「添加文件夹…」。

import AppKit

/// 侧栏上的一行。用类而不是值：NSOutlineView 按对象身份认行。
final class SidebarNode {
    enum Kind { case header, entry }
    let id: String
    let kind: Kind
    var title: String
    var entry: LibraryEntry?
    var symbol: String?
    var symbolColor: NSColor = .controlAccentColor
    var count: Int = 0
    var missing = false
    /// 是用户加进来的那一层文件夹（右键能「从侧栏移除」）。
    var isRootFolder = false
    var children: [SidebarNode] = []

    init(id: String, kind: Kind, title: String) {
        self.id = id
        self.kind = kind
        self.title = title
    }
}

protocol SidebarDelegate: AnyObject {
    func sidebar(didSelect entry: LibraryEntry)
    func sidebarAddFolder()
    func sidebarRemoveFolder(_ path: String)
}

final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    weak var delegate: SidebarDelegate?
    var onDrop: (([URL]) -> Void)? { didSet { (view as? DropTargetView)?.onDrop = onDrop } }

    let outline = NSOutlineView()
    private let scroll = NSScrollView()
    private var roots: [SidebarNode] = []
    private var nodes: [String: SidebarNode] = [:]
    /// 收起来的文件夹（按 id）。默认都展开。
    private var collapsed = Set<String>()
    private var reloading = false

    override func loadView() {
        let root = DropTargetView()
        view = root

        outline.style = .sourceList
        outline.headerView = nil
        outline.floatsGroupRows = false
        outline.rowSizeStyle = .default
        outline.indentationPerLevel = 14
        outline.autoresizesOutlineColumn = false
        let column = NSTableColumn(identifier: .init("main"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.dataSource = self
        outline.delegate = self
        outline.setAccessibilityLabel("侧栏")
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu

        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true

        let add = NSButton(title: "添加文件夹…", image: symbolImage("plus", size: 12) ?? NSImage(),
                           target: self, action: #selector(addFolder))
        add.isBordered = false
        add.imagePosition = .imageLeading
        add.contentTintColor = .secondaryLabelColor
        add.font = .systemFont(ofSize: 12)
        add.setAccessibilityLabel("添加文件夹")

        for v in [scroll, add] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: add.topAnchor, constant: -8),
            add.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            add.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
    }

    @objc private func addFolder() { delegate?.sidebarAddFolder() }

    // MARK: 数据

    private func node(_ id: String, _ kind: SidebarNode.Kind, _ title: String) -> SidebarNode {
        let n = nodes[id] ?? SidebarNode(id: id, kind: kind, title: title)
        n.title = title
        n.children = []
        nodes[id] = n
        return n
    }

    private func entryNode(_ entry: LibraryEntry, id: String, title: String, symbol: String,
                           color: NSColor = .controlAccentColor, count: Int) -> SidebarNode {
        let n = node(id, .entry, title)
        n.entry = entry
        n.symbol = symbol
        n.symbolColor = color
        n.count = count
        return n
    }

    /// 按图库和转换记录重建各行，保留选中和展开状态。
    func update(library: Library, record: ConversionRecord?, selected: LibraryEntry) {
        var newRoots: [SidebarNode] = []
        let lib = node("h.library", .header, "图库")
        lib.children = [
            entryNode(.all, id: "all", title: "全部图片", symbol: "photo.on.rectangle", count: library.count(of: .all)),
            entryNode(.convertible, id: "convertible", title: "可以转换", symbol: "arrow.left.arrow.right",
                      count: library.count(of: .convertible)),
            entryNode(.withNotes, id: "notes", title: "有备注", symbol: "text.alignleft", count: library.count(of: .withNotes)),
        ]
        newRoots.append(lib)
        if let record {
            let conv = node("h.conversion", .header, "转换")
            let last = entryNode(.conversion(.all), id: "conv", title: "最近一次转换", symbol: "clock",
                                 count: record.count(.all))
            if record.count(.differences) > 0 {
                last.children.append(entryNode(.conversion(.differences), id: "conv.diff", title: "有差异",
                                               symbol: "exclamationmark.triangle.fill", color: .systemOrange,
                                               count: record.count(.differences)))
            }
            if record.count(.failures) > 0 {
                last.children.append(entryNode(.conversion(.failures), id: "conv.fail", title: "失败",
                                               symbol: "xmark.circle.fill", color: .systemRed,
                                               count: record.count(.failures)))
            }
            conv.children = [last]
            newRoots.append(conv)
        }
        let folders = node("h.folders", .header, "文件夹")
        func folderNode(_ f: FolderNode, isRoot: Bool) -> SidebarNode {
            let n = entryNode(.folder(f.path), id: "f:" + f.path, title: f.name, symbol: "folder", count: f.count)
            n.missing = f.missing
            n.isRootFolder = isRoot
            n.children = f.children.map { folderNode($0, isRoot: false) }
            return n
        }
        folders.children = library.folderTree().map { folderNode($0, isRoot: true) }
        if !library.looseFiles.isEmpty {
            folders.children.append(entryNode(.looseFiles, id: "loose", title: "单独添加的图片", symbol: "photo",
                                              count: library.count(of: .looseFiles)))
        }
        if !folders.children.isEmpty { newRoots.append(folders) }
        roots = newRoots

        reloading = true
        outline.reloadData()
        for r in roots { outline.expandItem(r) }
        func expand(_ n: SidebarNode) {
            for c in n.children where !c.children.isEmpty {
                if !collapsed.contains(c.id) { outline.expandItem(c) }
                expand(c)
            }
        }
        roots.forEach(expand)
        select(selected)
        reloading = false
    }

    func select(_ entry: LibraryEntry) {
        let target = nodes.values.first { $0.entry == entry && outline.row(forItem: $0) >= 0 }
        let row = target.map { outline.row(forItem: $0) } ?? -1
        if row >= 0, outline.selectedRow != row {
            outline.selectRowIndexes([row], byExtendingSelection: false)
        }
    }

    // MARK: NSOutlineView

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SidebarNode)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? SidebarNode)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? SidebarNode)?.children.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? SidebarNode)?.kind == .header
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? SidebarNode)?.kind == .entry
    }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool {
        (item as? SidebarNode)?.kind != .header
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let n = item as? SidebarNode else { return nil }
        if n.kind == .header {
            let id = NSUserInterfaceItemIdentifier("HeaderCell")
            let cell = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? {
                let c = NSTableCellView()
                c.identifier = id
                let label = makeLabel("", size: 11, weight: .semibold, color: .secondaryLabelColor)
                label.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(label)
                c.textField = label
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                    label.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                ])
                return c
            }()
            cell.textField?.stringValue = n.title
            return cell
        }
        let id = NSUserInterfaceItemIdentifier("EntryCell")
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? SidebarEntryCell ?? {
            let c = SidebarEntryCell()
            c.identifier = id
            return c
        }()
        cell.configure(n)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !reloading, let n = outline.item(atRow: outline.selectedRow) as? SidebarNode, let entry = n.entry else { return }
        delegate?.sidebar(didSelect: entry)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !reloading, let n = notification.userInfo?["NSObject"] as? SidebarNode else { return }
        collapsed.insert(n.id)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !reloading, let n = notification.userInfo?["NSObject"] as? SidebarNode else { return }
        collapsed.remove(n.id)
    }

    // MARK: 右键

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let n = outline.item(atRow: outline.clickedRow) as? SidebarNode, case .folder(let path)? = n.entry else { return }
        let reveal = NSMenuItem(title: "在访达中显示", action: #selector(revealFolder(_:)), keyEquivalent: "")
        reveal.representedObject = path
        reveal.target = self
        reveal.isEnabled = !n.missing
        menu.addItem(reveal)
        if n.isRootFolder {
            let remove = NSMenuItem(title: "从侧栏移除", action: #selector(removeFolder(_:)), keyEquivalent: "")
            remove.representedObject = path
            remove.target = self
            menu.addItem(remove)
        }
    }

    @objc private func revealFolder(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    @objc private func removeFolder(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        delegate?.sidebarRemoveFolder(path)
    }
}

/// 侧栏的一行：图标、名字、右边的张数（次要色、等宽数字）。找不到的文件夹置灰，张数换成「找不到」。
final class SidebarEntryCell: NSTableCellView {
    private let icon = NSImageView()
    private let name = makeLabel("", size: 13)
    private let count = makeLabel("", size: 12, color: .secondaryLabelColor, monospacedDigits: true)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        count.alignment = .right
        count.setContentHuggingPriority(.required, for: .horizontal)
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        icon.setContentHuggingPriority(.required, for: .horizontal)
        for v in [icon, name, count] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        textField = name
        imageView = icon
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            count.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 6),
            count.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            count.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ n: SidebarNode) {
        icon.image = n.symbol.flatMap { symbolImage($0, size: 13) }
        icon.contentTintColor = n.missing ? .tertiaryLabelColor : n.symbolColor
        name.stringValue = n.title
        name.textColor = n.missing ? .tertiaryLabelColor : .labelColor
        count.stringValue = n.missing ? "找不到" : n.count.formatted(.number.locale(Locale(identifier: "zh_CN")))
        setAccessibilityLabel(n.missing ? "\(n.title)，找不到" : "\(n.title)，\(n.count) 张")
    }
}
