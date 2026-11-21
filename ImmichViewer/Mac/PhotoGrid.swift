#if os(macOS)
import AppKit
import SwiftUI

/// The photo wall: an AppKit NSCollectionView with a custom square-grid layout, wrapped for SwiftUI.
/// It fills the whole window; `insets` keep the first and last rows clear of the title bar and the bottom bar.
struct PhotoGrid: NSViewRepresentable {
    let library: Library
    let data: GridData
    let level: Int
    let showHeaders: Bool
    let style: GridStyle
    let insets: NSEdgeInsets
    /// False while a photo is open over the grid: keys go to the viewer.
    let active: Bool
    let onZoom: (Int) -> Void
    let onOpen: (Int, CGRect?, CGImage?) -> Void
    /// A key for the chosen photos (indices into `data.assets`): "." favorite, ⌘⌫ delete.
    let onAction: (PhotoAction, [Int]) -> Void
    /// The right-click menu for the chosen photos.
    let menu: ([Int]) -> NSMenu?
    let bridge: GridBridge
    /// False: the system scroll bar instead of the time scrubber (search results, best match first).
    var scrubbed = true

    func makeCoordinator() -> GridController { GridController(library: library) }

    func makeNSView(context: Context) -> NSScrollView {
        let controller = context.coordinator
        let collection = GridCollectionView()
        collection.collectionViewLayout = controller.layout
        collection.dataSource = controller
        collection.prefetchDataSource = controller
        collection.isSelectable = false
        collection.backgroundColors = [.clear]
        collection.register(ThumbCell.self, forItemWithIdentifier: ThumbCell.id)
        collection.register(HeaderView.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                            withIdentifier: HeaderView.id)
        collection.onClick = { [weak controller] in controller?.clicked(at: $0, $1, count: $2) }
        collection.onMenu = { [weak controller] in controller?.menu(at: $0) }
        collection.onSelectAll = { [weak controller] in controller?.selectAll() }
        collection.onMagnify = { [weak controller] in controller?.pinched(phase: $0, magnification: $1, at: $2) }
        collection.onKey = { [weak controller] in controller?.key($0) ?? false }

        let scroll = ScrubbedScrollView()
        scroll.documentView = collection
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(controller, selector: #selector(GridController.scrolled),
                                               name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        controller.collection = collection
        controller.bridge = bridge
        bridge.controller = controller
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let controller = context.coordinator
        controller.onZoom = onZoom
        controller.onOpen = onOpen
        controller.onAction = onAction
        controller.menu = menu
        controller.active = active
        (scroll as? ScrubbedScrollView)?.scrubbed = scrubbed
        controller.update(data: data, level: level, header: showHeaders ? 40 : 0, style: style, insets: insets)
    }
}

/// How the cells look, from Settings and the ⋯ menu.
struct GridStyle: Equatable {
    var fit = false
    var spacing = 1.0
    var radius = 0.0
    var badge = true
}

/// The grid's scroll position for SwiftUI (date capsule, scrubber), and ways to move it.
@MainActor @Observable
final class GridBridge {
    @ObservationIgnored weak var controller: GridController?
    /// The photo at the top of the visible area.
    var top = 0
    /// How far down the grid is scrolled, 0...1.
    var fraction = 0.0
    /// How many photos are chosen.
    var chosen = 0

    /// Selects photo `index`, scrolls it into view and returns where it is, for the viewer's closing animation.
    func reveal(_ index: Int) -> CGRect? { controller?.reveal(index) }
    func scroll(to fraction: Double) { controller?.scroll(to: fraction) }
    /// Where photo `index` sits on the scrubber, 0...1.
    func fraction(of index: Int) -> Double { controller?.fraction(of: index) ?? 0 }
    /// Scrolls photo `index` to the top of the visible area.
    func jump(to index: Int) { controller?.jump(to: index, select: false) }
}

/// Assets and their sections, swapped together so the grid never sees a mismatched pair.
struct GridData {
    var assets: [Asset] = []
    var sections: [Section] = []
    var years: [(year: Int, index: Int)] = []
    var id = 0
}

@MainActor
final class GridController: NSObject, NSCollectionViewDataSource, NSCollectionViewPrefetching {
    let layout = GridLayout()
    let library: Library
    weak var collection: NSCollectionView?
    weak var bridge: GridBridge?
    var active = true
    var onZoom: (Int) -> Void = { _ in }
    var onOpen: (Int, CGRect?, CGImage?) -> Void = { _, _, _ in }
    var onAction: (PhotoAction, [Int]) -> Void = { _, _ in }
    var menu: ([Int]) -> NSMenu? = { _ in nil }

    private var data = GridData(id: -1)
    private var level = -1
    private var requestedLevel = -1
    private var pinchStartLevel = 0
    private var pinchScale = 1.0
    private var pinch: Pinch?
    /// While pinching: takes every pinch and scroll event in the window, so the end of the gesture always arrives
    /// (even over the bottom bar or the scrubber) and the hidden grid doesn't scroll away under the picture.
    private var pinchMonitor: Any?
    /// Ends a pinch whose last event never came.
    private var pinchWatchdog: DispatchWorkItem?
    private var style = GridStyle()
    private var insets = NSEdgeInsets()
    /// The chosen photos, with a ring: one from the arrow keys or a click, more with ⌘-click, ⇧-click or ⌘A.
    private var picked = Set<String>()
    /// Where the arrow keys and ⇧-click start from, an index into `data.assets`.
    private var selected: Int?
    /// The photo to keep in place on the next zoom, and its distance from the top of the visible area.
    private var pendingAnchor: (path: IndexPath, screenY: Double)?
    private var zoomOverlay: NSView?

    init(library: Library) { self.library = library }

    private var scrollView: NSScrollView? { collection?.enclosingScrollView }

    /// Top of the area not covered by the title bar, in collection-view coordinates.
    private var contentTop: Double { (scrollView?.contentView.bounds.minY ?? 0) + insets.top }
    private var contentHeight: Double { (scrollView?.contentView.bounds.height ?? 0) - insets.top - insets.bottom }

    private var pixels: Int {
        ThumbnailStore.pixels(forSide: layout.math.side, scale: Double(collection?.window?.backingScaleFactor ?? 2))
    }

    func update(data: GridData, level: Int, header: Double, style: GridStyle, insets: NSEdgeInsets) {
        guard let collection, let scroll = scrollView else { return }
        if insets.top != self.insets.top || insets.bottom != self.insets.bottom {
            self.insets = insets
            scroll.contentInsets = insets
        }
        if style != self.style {
            self.style = style
            for case let cell as ThumbCell in collection.visibleItems() { cell.style = style }
        }
        if data.id != self.data.id {
            // keep the photo at the top in place across a regroup or a refreshed list
            let top = topAnchor().map { (id: self.data.assets[index($0.path)].id, screenY: $0.screenY) }
            let selectedID = selected.map { self.data.assets[$0].id }
            // the column shift stays only while its section is unchanged
            if let shift = layout.shift, shift.section >= min(data.sections.count, self.data.sections.count)
                || data.sections[shift.section].range != self.data.sections[shift.section].range { layout.shift = nil }
            self.data = data
            selected = selectedID.flatMap { id in data.assets.firstIndex { $0.id == id } }
            // deleted, archived or filtered out ones go; not setPicked: the visible cells are still the old list's
            // (indexing the new one with them crashed), and reloadData below draws the rings afresh
            picked.formIntersection(data.assets.lazy.map(\.id))
            bridge?.chosen = picked.count
            self.level = level
            requestedLevel = level
            layout.target = zoomLevels[level]
            layout.header = header
            layout.spacing = style.spacing
            collection.reloadData()
            if let top, let i = data.assets.firstIndex(where: { $0.id == top.id }),
               let s = data.sections.firstIndex(where: { $0.range.contains(i) }) {
                collection.layoutSubtreeIfNeeded()
                keep((IndexPath(item: i - data.sections[s].range.lowerBound, section: s), top.screenY))
            }
            scrolled()
            // on the first load the grid has no size yet; ask again once it has been laid out
            DispatchQueue.main.async { [weak self] in self?.scrolled() }
        } else if pinch == nil, level != self.level || header != layout.header || style.spacing != layout.spacing {
            // (during a pinch the grid sets its own level; the stored one may lag a step behind)
            // buttons and ⌘−/⌘= zoom around the middle of the screen; clicks and pinches set their own anchor
            let anchor = pendingAnchor ?? centerAnchor()
            pendingAnchor = nil
            let oldSide = layout.math.side
            let overlay = beginZoom()
            let from = anchor.map { center($0.path) }
            let oldX = anchor.map { layout.math.itemFrame($0.path.section, $0.path.item).midX }
            self.level = level
            requestedLevel = level
            layout.target = zoomLevels[level]
            layout.header = header
            layout.spacing = style.spacing
            if let anchor, let oldX, anchor.path.section < data.sections.count {
                layout.shift = columns(level).shift(putting: anchor.path.item, of: anchor.path.section, under: oldX)
            }
            layout.invalidateLayout()
            collection.layoutSubtreeIfNeeded()
            if let anchor, anchor.path.section < data.sections.count {
                keep(anchor)
                collection.layoutSubtreeIfNeeded() // create the cells at the new scroll position
            }
            redrawVisible()
            if let overlay, oldSide > 0 {
                let mid = CGPoint(x: overlay.bounds.midX, y: overlay.bounds.midY)
                finishZoom(overlay, scale: layout.math.side / oldSide, from: from ?? mid, to: anchor.map { center($0.path) } ?? mid)
            }
        }
    }

    /// Cells already on screen were decoded for the old size.
    private func redrawVisible() {
        guard let collection else { return }
        let pixels = pixels
        for case let cell as ThumbCell in collection.visibleItems() {
            if let p = collection.indexPath(for: cell) { cell.show(data.assets[index(p)], pixels: pixels, library: library) }
        }
    }

    /// Starts a zoom: the grid as it is now, copied into an overlay that will scale away.
    private func beginZoom() -> NSView? {
        zoomOverlay?.removeFromSuperview()
        zoomOverlay = nil
        guard let scroll = scrollView, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            collection?.alphaValue = 1
            return nil
        }
        let overlay = PassthroughView(frame: scroll.bounds)
        overlay.wantsLayer = true
        scroll.addSubview(overlay)
        overlay.layer!.addSublayer(snapshot(in: overlay))
        zoomOverlay = overlay
        return overlay
    }

    /// The cells and headers on screen as plain layers, in the overlay's coordinates.
    private func snapshot(in overlay: NSView) -> CALayer {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let container = CALayer()
        container.anchorPoint = .zero
        container.frame = overlay.bounds
        guard let collection else { return container }
        for case let cell as ThumbCell in collection.visibleItems() {
            guard let source = cell.view.layer else { continue }
            let copy = CALayer()
            copy.frame = cell.view.convert(cell.view.bounds, to: overlay)
            copy.contents = source.contents
            copy.name = collection.indexPath(for: cell).map { data.assets[index($0)].id } // to follow a photo across a reflow
            // a cell that just scrolled in may still be loading; use any size already in memory
            if copy.contents == nil, let p = collection.indexPath(for: cell) {
                let id = data.assets[index(p)].id
                copy.contents = library.thumbs.anyCached(id)
                if copy.contents == nil, let api = library.api {
                    let store = library.thumbs, pixels = pixels
                    Task { copy.contents = await store.image(id, pixels: pixels, api: api) } // fades in while zooming
                }
            }
            copy.contentsGravity = source.contentsGravity
            copy.backgroundColor = copy.contents == nil || !style.fit ? source.backgroundColor : nil
            copy.cornerRadius = source.cornerRadius
            copy.masksToBounds = true
            container.addSublayer(copy)
        }
        for header in collection.visibleSupplementaryViews(ofKind: NSCollectionView.elementKindSectionHeader) {
            guard let rep = header.bitmapImageRepForCachingDisplay(in: header.bounds) else { continue }
            header.cacheDisplay(in: header.bounds, to: rep)
            let copy = CALayer()
            copy.frame = header.convert(header.bounds, to: overlay)
            copy.contents = rep.cgImage
            container.addSublayer(copy)
        }
        return container
    }

    /// One continuous zoom: the old grid grows (or shrinks) by `r` around the anchor and fades out,
    /// while the new grid, copied under it, comes from the opposite scale to its real size.
    /// The anchor photo sits at the same spot in both, so they move as one picture.
    private func finishZoom(_ overlay: NSView, scale r: Double, from p0: CGPoint, to p1: CGPoint) {
        guard let collection, let old = overlay.layer?.sublayers?.first else { return }
        let new = snapshot(in: overlay)
        overlay.layer!.insertSublayer(new, below: old)
        collection.alphaValue = 0 // the copies stand in for the real grid until the end

        // containers have their anchor at the origin: these map p0 to p1 and back
        let grow = CATransform3DConcat(CATransform3DMakeScale(r, r, 1),
                                       CATransform3DMakeTranslation(p1.x - r * p0.x, p1.y - r * p0.y, 0))
        let shrink = CATransform3DConcat(CATransform3DMakeScale(1 / r, 1 / r, 1),
                                         CATransform3DMakeTranslation(p0.x - p1.x / r, p0.y - p1.y / r, 0))
        let timing = CAMediaTimingFunction(controlPoints: 0.2, 0, 0, 1)
        func animate(_ layer: CALayer, _ key: String, from: Any, to: Any) {
            let a = CABasicAnimation(keyPath: key)
            a.fromValue = from
            a.toValue = to
            a.duration = 0.35
            a.timingFunction = timing
            layer.add(a, forKey: key)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self, weak overlay, weak collection] in
            // a newer zoom may have taken over; then it owns the overlay and the grid's visibility
            guard let self, let overlay, self.zoomOverlay === overlay else { return }
            overlay.removeFromSuperview()
            self.zoomOverlay = nil
            collection?.alphaValue = 1
        }
        old.transform = grow
        old.opacity = 0
        animate(old, "transform", from: CATransform3DIdentity, to: grow)
        animate(old, "opacity", from: 1, to: 0)
        animate(new, "transform", from: shrink, to: CATransform3DIdentity)
        CATransaction.commit()
    }

    /// A grid frame in the scroll view's coordinates, origin at the top left (as SwiftUI sees it).
    private func onScreen(_ frame: CGRect) -> CGRect? {
        guard let collection, let scroll = scrollView else { return nil }
        let r = collection.convert(frame, to: scroll)
        return scroll.isFlipped ? r : CGRect(x: r.minX, y: scroll.bounds.height - r.maxY, width: r.width, height: r.height)
    }

    private func center(_ path: IndexPath) -> CGPoint {
        guard let collection, let overlay = zoomOverlay else { return .zero }
        let f = collection.convert(layout.math.itemFrame(path.section, path.item), to: overlay)
        return CGPoint(x: f.midX, y: f.midY)
    }

    func reveal(_ i: Int) -> CGRect? {
        guard let path = indexPath(i) else { return nil }
        let frame = layout.math.itemFrame(path.section, path.item)
        if frame.minY < contentTop || frame.maxY > contentTop + contentHeight {
            keep((path, contentHeight / 2))
            collection?.layoutSubtreeIfNeeded()
        }
        select(i)
        return onScreen(frame)
    }

    private func indexPath(_ i: Int) -> IndexPath? {
        guard let s = data.sections.firstIndex(where: { $0.range.contains(i) }) else { return nil }
        return IndexPath(item: i - data.sections[s].range.lowerBound, section: s)
    }

    /// Chooses just photo `i` (or none).
    private func select(_ i: Int?) {
        selected = i
        setPicked(i.map { [data.assets[$0].id] } ?? [])
    }

    private func setPicked(_ ids: Set<String>) {
        picked = ids
        bridge?.chosen = ids.count
        guard let collection else { return }
        for case let cell as ThumbCell in collection.visibleItems() {
            if let p = collection.indexPath(for: cell) { cell.ring = ids.contains(data.assets[index(p)].id) }
        }
    }

    /// The chosen photos as indices, in grid order.
    private var chosen: [Int] { data.assets.indices.filter { picked.contains(data.assets[$0].id) } }

    func selectAll() {
        guard active else { return }
        setPicked(Set(data.assets.map(\.id)))
    }

    /// Right-click: the chosen photos' menu; a photo that isn't chosen becomes the only one.
    func menu(at point: NSPoint) -> NSMenu? {
        guard active, let collection, let path = collection.indexPathForItem(at: point) else { return nil }
        let i = index(path)
        if !picked.contains(data.assets[i].id) { select(i) }
        return menu(chosen)
    }

    /// Selects photo `i` and scrolls just enough to show it.
    private func selectAndShow(_ i: Int) {
        guard let path = indexPath(i) else { return }
        select(i)
        let f = layout.math.itemFrame(path.section, path.item)
        let header = layout.math.firstRow(path.section, path.item) ? layout.header : 0
        if f.minY - header < contentTop { keep((path, 0)) } else if f.maxY > contentTop + contentHeight { keep((path, contentHeight)) }
    }

    /// Puts photo `i` at the top of the visible area (with its section title).
    func jump(to i: Int, select: Bool) {
        guard let path = indexPath(i) else { return }
        if select { self.select(i) }
        keep((path, 0))
    }

    /// Scroll distance in points from the first row to the last screenful.
    private var scrollRange: Double { max(1, layout.math.height - contentHeight) }

    func scroll(to fraction: Double) {
        guard let scroll = scrollView else { return }
        let clip = scroll.contentView
        var bounds = clip.bounds
        bounds.origin.y = min(max(fraction, 0), 1) * scrollRange - insets.top
        clip.setBoundsOrigin(clip.constrainBoundsRect(bounds).origin)
        scroll.reflectScrolledClipView(clip)
    }

    func fraction(of i: Int) -> Double {
        guard let path = indexPath(i) else { return 0 }
        let header = layout.math.firstRow(path.section, path.item) ? layout.header : 0
        return min(max((layout.math.itemFrame(path.section, path.item).minY - header) / scrollRange, 0), 1)
    }

    /// Arrow keys move the selection, Return or Space open it, ⌘↑ ⌘↓ go to the ends, Esc clears it.
    /// "." favorites the chosen photos (or takes them out of Favorites), ⌘⌫ deletes them.
    func key(_ event: NSEvent) -> Bool {
        guard active, !data.assets.isEmpty else { return false }
        let last = data.assets.count - 1
        let command = event.modifierFlags.contains(.command)
        // the first arrow press picks the photo at the top left
        let current = selected ?? topAnchor().map { index($0.path) } ?? 0
        if event.charactersIgnoringModifiers == ".", !command, !picked.isEmpty {
            onAction(.favorite, chosen)
            return true
        }
        switch event.keyCode {
        case 123: selectAndShow(selected == nil ? current : max(current - 1, 0))
        case 124: selectAndShow(selected == nil ? current : min(current + 1, last))
        case 125, 126:
            let down = event.keyCode == 125
            if command { jump(to: down ? last : 0, select: true); break }
            guard selected != nil else { selectAndShow(current); break }
            if let p = indexPath(current), let next = layout.math.row(from: p.section, p.item, down: down) {
                selectAndShow(data.sections[next.section].range.lowerBound + next.item)
            }
        case 115: jump(to: 0, select: true) // Home
        case 119: jump(to: last, select: true) // End
        case 36, 76, 49: // Return, Enter, Space
            guard let selected, let p = indexPath(selected) else { return false }
            open(p)
        case 53: select(nil)
        case 51 where command && !picked.isEmpty: onAction(.trash, chosen) // ⌘⌫
        default: return false
        }
        return true
    }

    private func open(_ path: IndexPath) {
        let i = index(path)
        select(i)
        onOpen(i, onScreen(layout.math.itemFrame(path.section, path.item)), collection?.item(at: path)?.view.layer?.contents as! CGImage?)
    }

    /// Scrolls so the anchor photo sits where it was on screen, moved just enough to be fully visible.
    private func keep(_ anchor: (path: IndexPath, screenY: Double)) {
        guard let scroll = scrollView else { return }
        let frame = layout.math.itemFrame(anchor.path.section, anchor.path.item)
        var top = frame.midY - anchor.screenY
        top = min(top, frame.minY - (layout.header > 0 && layout.math.firstRow(anchor.path.section, anchor.path.item) ? layout.header : 0))
        top = max(top, frame.maxY - contentHeight)
        let clip = scroll.contentView
        var bounds = clip.bounds
        bounds.origin.y = top - insets.top
        clip.setBoundsOrigin(clip.constrainBoundsRect(bounds).origin)
        scroll.reflectScrolledClipView(clip)
    }

    /// The photo in the middle of the visible area.
    private func centerAnchor() -> (path: IndexPath, screenY: Double)? {
        let y = contentTop + contentHeight / 2
        guard let row = layout.math.visible(y, y + 1).last, !row.items.isEmpty else { return topAnchor() }
        let m = layout.math
        let column = Int((m.width / 2) / (m.side + m.spacing))
        let item = min(max(row.items.lowerBound + column - m.column(row.section, row.items.lowerBound), row.items.lowerBound),
                       row.items.upperBound - 1)
        return (IndexPath(item: item, section: row.section), m.itemFrame(row.section, item).midY - contentTop)
    }

    /// The first photo at the top of the visible area.
    private func topAnchor() -> (path: IndexPath, screenY: Double)? {
        guard let first = layout.math.visible(contentTop, contentTop + 1).first else { return nil }
        let path = IndexPath(item: first.items.first ?? 0, section: first.section)
        return (path, layout.math.itemFrame(path.section, path.item).midY - contentTop)
    }

    /// Asks SwiftUI for another zoom level, keeping `path` (or the photo nearest `point`) in place.
    private func requestZoom(_ target: Int, at point: NSPoint) {
        let target = min(max(target, 0), zoomLevels.count - 1)
        guard target != requestedLevel, let collection else { return }
        let path = collection.indexPathForItem(at: point) ?? layout.math.visible(point.y, point.y + 1).first
            .map { IndexPath(item: $0.items.first ?? 0, section: $0.section) }
        if let path { pendingAnchor = (path, layout.math.itemFrame(path.section, path.item).midY - contentTop) }
        requestedLevel = target
        onZoom(target)
    }

    /// Like Photos: a click chooses the photo, a double click opens it, ⌘ and ⇧ add to the choice.
    func clicked(at point: NSPoint, _ modifiers: NSEvent.ModifierFlags, count: Int) {
        guard let collection, let path = collection.indexPathForItem(at: point) else {
            if modifiers.isDisjoint(with: [.command, .shift]) { select(nil) } // a click between photos clears the choice
            return
        }
        let i = index(path), id = data.assets[i].id
        if modifiers.contains(.command) {
            var ids = picked
            if ids.remove(id) == nil { ids.insert(id) }
            selected = i
            return setPicked(ids)
        }
        if modifiers.contains(.shift) {
            let from = selected ?? i
            return setPicked(picked.union(data.assets[min(from, i)...max(from, i)].map(\.id)))
        }
        if count >= 2 { open(path) } else { select(i) }
    }

    /// A pinch in progress, as pictures in the zoom overlay: `base` is the grid at one zoom step, `target` the next step
    /// in the direction the fingers go, underneath it. `photo` is the one that was under the pointer.
    private struct Pinch {
        struct Picture {
            var level: Int
            var layer: CALayer
            /// The photo's middle in this picture and its cells' size, in overlay coordinates.
            var center: CGPoint
            var side: Double
            /// How the real grid was laid out for it.
            var shift: GridMath.Shift?
            var y: Double
        }
        var photo: IndexPath
        var pointer: CGPoint
        var start: CGPoint
        var startSide: Double
        /// How far the fingers have scaled the grid since they went down.
        var scale = 1.0
        var base: Picture
        var target: Picture?
        /// The photo's size and middle right now: it grows or shrinks around the pointer, so the spot under the
        /// pointer stays under it.
        var side: Double { startSide * scale }
        var spot: CGPoint {
            CGPoint(x: pointer.x + (start.x - pointer.x) * scale, y: pointer.y + (start.y - pointer.y) * scale)
        }
    }

    /// A pinch is a transition the fingers drive, like in Photos: the grid grows or shrinks around the pointer and
    /// fades into the next zoom step, whose picture is lined up so the same photo sits in the same place. Once the
    /// photos reach the next step's size, that step becomes the base and the one after it is prepared, so one pinch
    /// can go through several steps. Letting go settles on whichever step the photos are closer to.
    func pinched(phase: NSEvent.Phase, magnification: Double, at point: NSPoint) {
        if phase.contains(.began) { startPinch(at: point) }
        guard var p = pinch else { return stepPinch(phase, magnification, point) }
        p.scale *= 1 + magnification
        // past the smallest and largest step it only gives a little
        let low = p.base.level > 0 ? 0.0 : 0.95, high = p.base.level + 1 < zoomLevels.count ? .infinity : 1.15
        p.scale = min(max(p.side / p.base.side, low), high) * p.base.side / p.startSide
        pinch = p
        advance()
        if phase.contains(.ended) || phase.contains(.cancelled) {
            endPinch()
        } else {
            let watchdog = DispatchWorkItem { [weak self] in self?.endPinch() }
            pinchWatchdog?.cancel()
            pinchWatchdog = watchdog
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: watchdog)
        }
    }

    private func startPinch(at point: NSPoint) {
        stopPinchEvents()
        pinch = nil
        guard let collection, let overlay = beginZoom() else { return }
        guard let layer = overlay.layer?.sublayers?.first,
              let photo = collection.indexPathForItem(at: point) ?? layout.math.visible(point.y, point.y + 1).first
                .map({ IndexPath(item: $0.items.first ?? 0, section: $0.section) }) ?? centerAnchor()?.path
        else {
            overlay.removeFromSuperview()
            zoomOverlay = nil
            collection.alphaValue = 1
            return
        }
        collection.alphaValue = 0 // the pictures stand in for the grid until the fingers let go
        let base = Pinch.Picture(level: level, layer: layer, center: center(photo), side: layout.math.side,
                                 shift: layout.shift, y: center(photo).y)
        pinch = Pinch(photo: photo, pointer: collection.convert(point, to: overlay), start: base.center,
                      startSide: base.side, base: base)
        pinchMonitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify, .scrollWheel]) { [weak self] event in
            guard let self, self.pinch != nil, let collection = self.collection, event.window === collection.window else { return event }
            if event.type == .magnify {
                self.pinched(phase: event.phase, magnification: Double(event.magnification),
                             at: collection.convert(event.locationInWindow, from: nil))
            }
            return nil
        }
    }

    private func stopPinchEvents() {
        if let pinchMonitor { NSEvent.removeMonitor(pinchMonitor) }
        pinchMonitor = nil
        pinchWatchdog?.cancel()
        pinchWatchdog = nil
    }

    /// Prepares the step the fingers are heading to, moves on to it once the photos have reached its size, then
    /// places the pictures.
    private func advance() {
        guard var p = pinch else { return }
        for _ in 0..<zoomLevels.count {
            let to = p.base.level + (p.side > p.base.side ? 1 : -1)
            guard p.side != p.base.side, zoomLevels.indices.contains(to) else { break }
            if p.target?.level != to {
                p.target?.layer.removeFromSuperlayer()
                p.target = prepare(to, for: p)
            }
            guard let t = p.target, to > p.base.level ? p.side >= t.side : p.side <= t.side else { break }
            p.base.layer.removeFromSuperlayer() // past this step: it becomes the base
            p.base = t
            p.target = nil
        }
        pinch = p
        place(p)
    }

    /// Moves the real (hidden) grid to step `to`, with the photo where the fingers will have taken it by the time it
    /// reaches that size (in the nearest column), and adds a picture of it under the base.
    private func prepare(_ to: Int, for p: Pinch) -> Pinch.Picture? {
        guard let collection, let overlay = zoomOverlay else { return nil }
        let math = columns(to), k = math.side / p.startSide
        let spot = CGPoint(x: p.pointer.x + (p.start.x - p.pointer.x) * k, y: p.pointer.y + (p.start.y - p.pointer.y) * k)
        let shift = math.shift(putting: p.photo.item, of: p.photo.section, under: collection.convert(spot, from: overlay).x)
        setLevel(to, shift: shift, keeping: p.photo, at: spot.y)
        let layer = snapshot(in: overlay)
        overlay.layer?.insertSublayer(layer, below: p.base.layer)
        return Pinch.Picture(level: to, layer: layer, center: center(p.photo), side: layout.math.side, shift: shift, y: spot.y)
    }

    /// The grid's geometry at zoom step `l` (columns and cell size; no items).
    private func columns(_ l: Int) -> GridMath {
        GridMath(counts: [], width: layout.math.width, target: zoomLevels[l], header: 0, spacing: layout.spacing)
    }

    private func setLevel(_ l: Int, shift: GridMath.Shift?, keeping photo: IndexPath, at y: Double) {
        guard let collection else { return }
        level = l
        requestedLevel = l
        layout.target = zoomLevels[l]
        layout.shift = shift
        layout.invalidateLayout()
        collection.layoutSubtreeIfNeeded()
        keep((photo, y - insets.top))
        collection.layoutSubtreeIfNeeded()
        redrawVisible()
    }

    /// How far the photos have gone from the base's size to the target's, 0...1.
    private func progress(_ p: Pinch) -> Double {
        guard let t = p.target, abs(log(t.side / p.base.side)) > 0.001 else { return 0 }
        return min(max(log(p.side / p.base.side) / log(t.side / p.base.side), 0), 1)
    }

    /// The transform that shows `picture` with its photo `side` big and its middle at `spot`.
    private func mapping(_ picture: Pinch.Picture, side: Double, at spot: CGPoint) -> CATransform3D {
        let s = side / picture.side
        return CATransform3DConcat(CATransform3DMakeScale(s, s, 1),
                                   CATransform3DMakeTranslation(spot.x - s * picture.center.x, spot.y - s * picture.center.y, 0))
    }

    private func place(_ p: Pinch) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let t = progress(p)
        p.base.layer.transform = mapping(p.base, side: p.side, at: p.spot)
        p.base.layer.opacity = Float(1 - t)
        if let target = p.target {
            target.layer.isHidden = t == 0
            target.layer.transform = mapping(target, side: p.side, at: p.spot)
        }
        CATransaction.commit()
    }

    /// The fingers let go: the pictures finish (or undo) the transition, then the real grid comes back.
    private func endPinch() {
        stopPinchEvents()
        guard let p = pinch, zoomOverlay != nil else {
            pinch = nil
            return
        }
        pinch = nil
        let target = progress(p) >= 0.5 ? p.target : nil
        let final = target ?? p.base
        if level != final.level || layout.shift != final.shift { // the real grid is on the other step
            setLevel(final.level, shift: final.shift, keeping: p.photo, at: final.y)
        }
        let spot = center(p.photo) // where the real grid has it
        let timing = CAMediaTimingFunction(controlPoints: 0.2, 0, 0, 1)
        func animate(_ layer: CALayer, _ key: String, to value: Any) {
            let a = CABasicAnimation(keyPath: key)
            a.fromValue = layer.value(forKeyPath: key)
            a.toValue = value
            a.duration = 0.25
            a.timingFunction = timing
            layer.setValue(value, forKeyPath: key)
            layer.add(a, forKey: key)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let overlay = zoomOverlay
        CATransaction.setCompletionBlock { [weak self, weak overlay] in
            guard let self, let overlay, self.zoomOverlay === overlay else { return }
            overlay.removeFromSuperview()
            self.zoomOverlay = nil
            self.collection?.alphaValue = 1
        }
        animate(p.base.layer, "transform", to: NSValue(caTransform3D: mapping(p.base, side: final.side, at: spot)))
        animate(p.base.layer, "opacity", to: NSNumber(value: target == nil ? 1 : 0))
        if let other = p.target, !other.layer.isHidden {
            animate(other.layer, "transform", to: NSValue(caTransform3D: mapping(other, side: final.side, at: spot)))
        }
        CATransaction.commit()
        onZoom(final.level)
    }

    /// With Reduce Motion: one zoom step for every ~35% of pinch, several steps in one gesture.
    private func stepPinch(_ phase: NSEvent.Phase, _ magnification: Double, _ point: NSPoint) {
        if phase.contains(.began) {
            pinchStartLevel = level
            pinchScale = 1
        }
        pinchScale = max(0.05, pinchScale * (1 + magnification))
        let steps = Int((log(pinchScale) / log(1.35)).rounded(.towardZero))
        requestZoom(pinchStartLevel + steps, at: point)
    }

    private func index(_ p: IndexPath) -> Int { data.sections[p.section].range.lowerBound + p.item }

    @objc func scrolled() {
        guard let first = layout.math.visible(contentTop, contentTop + 1).first, !data.assets.isEmpty else { return }
        let top = index(IndexPath(item: first.items.first ?? 0, section: first.section))
        let fraction = min(max(contentTop / scrollRange, 0), 1)
        // may run inside a SwiftUI update, which mustn't change observed state
        DispatchQueue.main.async { [weak bridge] in
            guard let bridge else { return }
            if bridge.top != top { bridge.top = top }
            if bridge.fraction != fraction { bridge.fraction = fraction }
        }
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int { data.sections.count }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        data.sections[section].range.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt p: IndexPath) -> NSCollectionViewItem {
        let cell = collectionView.makeItem(withIdentifier: ThumbCell.id, for: p) as! ThumbCell
        cell.style = style
        cell.ring = picked.contains(data.assets[index(p)].id)
        cell.show(data.assets[index(p)], pixels: pixels, library: library)
        return cell
    }

    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind,
                        at p: IndexPath) -> NSView {
        let header = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: HeaderView.id, for: p) as! HeaderView
        header.label.stringValue = data.sections[p.section].title
        return header
    }

    /// Decodes photos just outside the visible area before they scroll in.
    func collectionView(_ collectionView: NSCollectionView, prefetchItemsAt paths: [IndexPath]) {
        guard let api = library.api else { return }
        let store = library.thumbs, pixels = pixels
        let ids = paths.map { data.assets[index($0)].id }.filter { store.cached($0, pixels: pixels) == nil }
        guard !ids.isEmpty else { return }
        Task.detached(priority: .utility) {
            for id in ids { _ = await store.image(id, pixels: pixels, api: api) }
        }
    }
}

/// No scroll bar while `scrubbed`: the time scrubber takes its place. Setting `hasVerticalScroller = false` once isn't
/// enough, AppKit turns it back on later, so it is fixed here.
final class ScrubbedScrollView: NSScrollView {
    var scrubbed = true {
        didSet { if scrubbed != oldValue { hasVerticalScroller = !scrubbed } }
    }

    override var hasVerticalScroller: Bool {
        get { !scrubbed }
        set { super.hasVerticalScroller = !scrubbed }
    }
}

/// Shows layers without taking any clicks.
final class PassthroughView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Handles clicks itself: NSCollectionView's own mouse tracking (for selection) would swallow them.
final class GridCollectionView: NSCollectionView {
    var onClick: (NSPoint, NSEvent.ModifierFlags, Int) -> Void = { _, _, _ in }
    var onMenu: (NSPoint) -> NSMenu? = { _ in nil }
    var onSelectAll: () -> Void = {}
    var onMagnify: (NSEvent.Phase, Double, NSPoint) -> Void = { _, _, _ in }
    var onKey: (NSEvent) -> Bool = { _ in false }
    private var downPoint: NSPoint?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(self) } // arrow keys work right away
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        downPoint = convert(event.locationInWindow, from: nil)
    }

    override func keyDown(with event: NSEvent) {
        if !onKey(event) { nextResponder?.keyDown(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let down = downPoint, hypot(point.x - down.x, point.y - down.y) < 5 { onClick(point, event.modifierFlags, event.clickCount) }
        downPoint = nil
    }

    override func menu(for event: NSEvent) -> NSMenu? { onMenu(convert(event.locationInWindow, from: nil)) }

    /// Edit > Select All (⌘A).
    override func selectAll(_ sender: Any?) { onSelectAll() }


    // NSCollectionView turns Select All off when it isn't selectable itself
    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool { true }

    override func magnify(with event: NSEvent) {
        onMagnify(event.phase, Double(event.magnification), convert(event.locationInWindow, from: nil))
    }
}

/// Lays out only what is on screen, using GridMath, so 100k+ items stay fast.
final class GridLayout: NSCollectionViewLayout {
    var target = 76.0
    var header = 0.0
    var spacing = 1.0
    var shift: GridMath.Shift?
    private(set) var math = GridMath(counts: [], width: 0, target: 76, header: 0)

    override func prepare() {
        guard let collection = collectionView else { return }
        let counts = (0..<collection.numberOfSections).map { collection.numberOfItems(inSection: $0) }
        let width = collection.enclosingScrollView?.contentSize.width ?? collection.bounds.width
        math = GridMath(counts: counts, width: width, target: target, header: header, spacing: spacing, shift: shift)
    }

    override var collectionViewContentSize: NSSize { NSSize(width: math.width, height: math.height) }

    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool { newBounds.width != math.width }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        var result: [NSCollectionViewLayoutAttributes] = []
        for v in math.visible(rect.minY, rect.maxY) {
            if header > 0 { result.append(headerAttributes(v.section)) }
            for i in v.items { result.append(itemAttributes(IndexPath(item: i, section: v.section))) }
        }
        return result
    }

    override func layoutAttributesForItem(at p: IndexPath) -> NSCollectionViewLayoutAttributes? { itemAttributes(p) }

    override func layoutAttributesForSupplementaryView(ofKind kind: NSCollectionView.SupplementaryElementKind,
                                                       at p: IndexPath) -> NSCollectionViewLayoutAttributes? {
        header > 0 ? headerAttributes(p.section) : nil
    }

    private func itemAttributes(_ p: IndexPath) -> NSCollectionViewLayoutAttributes {
        let a = NSCollectionViewLayoutAttributes(forItemWith: p)
        a.frame = math.itemFrame(p.section, p.item)
        return a
    }

    private func headerAttributes(_ section: Int) -> NSCollectionViewLayoutAttributes {
        let a = NSCollectionViewLayoutAttributes(forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                                                 with: IndexPath(item: 0, section: section))
        a.frame = math.headerFrame(section)
        return a
    }
}

final class ThumbCell: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("thumb")
    private static let placeholder = NSColor.gray.withAlphaComponent(0.2).cgColor
    private var task: Task<Void, Never>?
    private let badge = CATextLayer()
    private var isVideo = false
    private var assetID = ""

    var style = GridStyle() {
        didSet {
            guard style != oldValue else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // fit: the whole photo inside the square (letterboxed) instead of filling it
            view.layer?.contentsGravity = style.fit ? .resizeAspect : .resizeAspectFill
            view.layer?.cornerRadius = min(style.radius, view.bounds.width / 4)
            updateBackground()
            updateBadge()
            CATransaction.commit()
        }
    }

    /// The keyboard selection.
    var ring = false {
        didSet {
            view.layer?.borderWidth = ring ? 3 : 0
            view.layer?.borderColor = NSColor.controlAccentColor.cgColor
        }
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        let layer = view.layer!
        layer.contentsGravity = .resizeAspectFill
        layer.masksToBounds = true
        badge.string = "▶"
        badge.fontSize = 11
        badge.foregroundColor = NSColor.white.cgColor
        badge.alignmentMode = .right
        badge.contentsScale = 2
        badge.shadowOpacity = 0.8
        badge.shadowRadius = 1
        badge.shadowOffset = .zero
        layer.addSublayer(badge)
    }

    override func viewDidLayout() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        badge.frame = CGRect(x: view.bounds.width - 20, y: 2, width: 16, height: 14)
        view.layer?.cornerRadius = min(style.radius, view.bounds.width / 4) // small cells stay square-ish
        updateBadge()
        CATransaction.commit()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        task?.cancel()
    }

    private func updateBadge() {
        badge.isHidden = !isVideo || !style.badge || view.bounds.width < 50 // too busy on tiny cells
    }

    /// Grey square while loading; in fit mode the letterbox bars stay clear once the photo is there.
    private func updateBackground() {
        view.layer?.backgroundColor = view.layer?.contents == nil || !style.fit ? Self.placeholder : nil
    }

    private func setImage(_ image: CGImage?) {
        view.layer?.contents = image
        updateBackground()
    }

    func show(_ asset: Asset, pixels: Int, library: Library) {
        task?.cancel()
        isVideo = asset.isVideo
        updateBadge()
        if let image = library.thumbs.cached(asset.id, pixels: pixels) {
            assetID = asset.id
            setImage(image)
            return
        }
        // same photo at a new size: keep the old image until the sharper one is ready
        if asset.id != assetID { setImage(nil) }
        assetID = asset.id
        guard let api = library.api else { return }
        let store = library.thumbs, id = asset.id
        task = Task { [weak self] in
            let image = await store.image(id, pixels: pixels, api: api)
            guard !Task.isCancelled else { return }
            self?.setImage(image)
        }
    }
}

final class HeaderView: NSView, NSCollectionViewElement {
    static let id = NSUserInterfaceItemIdentifier("header")
    let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}
#endif
