#if os(iOS)
import SwiftUI
import UIKit
import AVFoundation // AVMakeRect

/// The iOS photo grid as a UICollectionView laid out by `GridMath`, like the Mac's NSCollectionView:
/// only the squares on screen exist, so 100k+ photos scroll and update without stalling.
/// Tapping a photo zooms it out of its square into the photo view, and closing zooms it back into the right square.
struct PhoneGrid: UIViewControllerRepresentable {
    let library: Library
    let assets: [Asset]
    let sections: [Section]
    let headers: Bool
    /// Days: each day's header sticks to the top while its photos scroll under it, instead of the date capsule.
    var pinHeaders = false
    /// Changes whenever `assets` or `sections` are replaced, so the grid reloads.
    let dataID: Int
    let columns: Int
    /// What the page shows, for the menus.
    let context: BrowserContext
    /// Select mode: a tap checks or unchecks a photo instead of opening it. `chosen`: the checked ones.
    let selecting: Bool
    let chosen: Set<String>
    let handlers: Handlers

    struct Handlers {
        var refresh: (() async -> Void)?
        var onColumns: (Int) -> Void = { _ in }
        /// The photo at the top of the screen changed to another day.
        var onTop: (Int) -> Void = { _ in }
        var onPerson: (Person) -> Void = { _ in }
        /// A tap in select mode.
        var onToggle: (String) -> Void = { _ in }
        /// Select in a photo's long-press menu: select mode, with that photo checked.
        var onSelect: (String) -> Void = { _ in }
        /// From a photo's long-press menu.
        var onAction: (PhotoAction, [Asset]) -> Void = { _, _ in }
    }

    func makeUIViewController(context: Context) -> PhoneGridController { PhoneGridController(library: library) }

    func updateUIViewController(_ controller: PhoneGridController, context: Context) {
        controller.handlers = handlers
        controller.context = self.context
        controller.update(assets: assets, sections: sections, headers: headers, pinHeaders: pinHeaders, dataID: dataID,
                          columns: columns, selecting: selecting, chosen: chosen)
    }
}

final class PhoneGridController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate {
    private let library: Library
    private let layout = PhoneGridLayout()
    private var collection: UICollectionView!
    private var assets: [Asset] = []
    private var sections: [Section] = []
    private var dataID = -1
    private var lastTopDay = Int.min
    private var pinch: Pinch?
    /// Pictures of the grid that stand in for it while the fingers zoom it.
    private var zoomOverlay: UIView?
    /// By day: the top section's date stays at the top, over the photos, with the system's blur behind it.
    /// It floats outside the list, since the blur covers what's in the list; the list's own copy of it is hidden.
    private var pinHeaders = false
    /// Where the system blur reaches down behind the date. Fixed below the bars, so it never moves with the dates.
    private let blurZone = UIView()
    /// The dates themselves, drawn over the blur: the top day's, and the next day's while its header is inside the zone.
    private let floatingLabel = UILabel()
    private let incomingLabel = UILabel()
    var handlers = PhoneGrid.Handlers()
    var context = BrowserContext.library
    private var selecting = false
    private var chosen: Set<String> = []
    /// The open photo view, which follows the list as it changes.
    private var pager: PagerState?
    private weak var pagerHost: UIViewController?
    /// The open and close of the photo view; a presented view controller holds its transitioning delegate weakly.
    private var zoom: PhotoZoom?

    init(library: Library) {
        self.library = library
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        collection = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collection.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collection.backgroundColor = .systemBackground
        collection.contentInsetAdjustmentBehavior = .always // also beside an iPad's sidebar and a phone's notch
        collection.dataSource = self
        collection.delegate = self
        collection.topEdgeEffect.style = .soft // a progressive blur under the title, not the solid backdrop iOS picks here
        collection.register(PhoneCell.self, forCellWithReuseIdentifier: "cell")
        collection.register(PhoneHeader.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
                            withReuseIdentifier: "header")
        collection.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:))))
        view.addSubview(collection)
        blurZone.isUserInteractionEnabled = false
        let plate = UIView(frame: blurZone.bounds) // the blur takes its shape from what's in the zone: a fixed plate
        plate.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        blurZone.addSubview(plate)
        let edge = UIScrollEdgeElementContainerInteraction() // the blur under the bars reaches down behind the date
        edge.scrollView = collection
        edge.edge = .top
        blurZone.addInteraction(edge)
        view.addSubview(blurZone)
        for label in [floatingLabel, incomingLabel] {
            label.font = PhoneHeader.font
            label.isUserInteractionEnabled = false
            view.addSubview(label)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateFloating()
    }

    func update(assets: [Asset], sections: [Section], headers: Bool, pinHeaders: Bool, dataID: Int, columns: Int,
                selecting: Bool, chosen: Set<String>) {
        if selecting != self.selecting || chosen != self.chosen {
            self.selecting = selecting
            self.chosen = chosen
            for case let cell as PhoneCell in collection.visibleCells {
                if let path = collection.indexPath(for: cell) {
                    cell.setChecked(chosen.contains(self.assets[index(of: path)].id), animated: true)
                }
            }
        }
        if (handlers.refresh != nil) != (collection.refreshControl != nil) {
            collection.refreshControl = handlers.refresh == nil ? nil : {
                let control = UIRefreshControl()
                control.addTarget(self, action: #selector(pullToRefresh(_:)), for: .valueChanged)
                return control
            }()
        }
        if dataID != self.dataID {
            let first = self.assets.isEmpty // the page's photos just arrived: start at the top
            self.assets = assets
            self.sections = sections
            self.dataID = dataID
            layout.shift = nil
            layout.counts = sections.map(\.range.count)
            layout.header = headers ? 46 : 0
            self.pinHeaders = pinHeaders && headers
            collection.contentInset.top = self.pinHeaders ? 0 : 44 // otherwise the first row starts below the date capsule
            layout.columns = columns
            collection.reloadData()
            lastTopDay = .min
            if let pager, let host = pagerHost, host.presentingViewController != nil { // a photo was edited, deleted or moved
                if assets.isEmpty { host.dismiss(animated: true) } else { pager.follow(assets) }
            }
            // after this SwiftUI update, once the new layout is in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                collection.layoutIfNeeded()
                // the inset above may have changed under an offset left from the empty list, which would open mid-page
                if first { collection.contentOffset.y = -collection.adjustedContentInset.top }
                self.reportTop()
                self.updateFloating()
            }
        } else if columns != layout.columns, pinch == nil { // mid-pinch the fingers decide
            // keep the photo at the top where it is
            let top = topIndex()
            layout.shift = nil
            layout.columns = columns
            collection.layoutIfNeeded() // the new math, before asking where the photo went
            defer { updateFloating() }
            if let top, let frame = frame(of: top) {
                collection.contentOffset.y = min(frame.minY - layout.headerAbove(path(of: top)) - collection.adjustedContentInset.top,
                                                 max(collection.contentSize.height - collection.bounds.height
                                                     + collection.adjustedContentInset.bottom, -collection.adjustedContentInset.top))
            }
        }
    }

    // MARK: Index ↔ cell

    private func path(of index: Int) -> IndexPath {
        // binary search for the section holding `index`
        var lo = 0, hi = sections.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if sections[mid].range.lowerBound <= index { lo = mid } else { hi = mid - 1 }
        }
        return IndexPath(item: index - sections[lo].range.lowerBound, section: lo)
    }

    private func index(of path: IndexPath) -> Int { sections[path.section].range.lowerBound + path.item }

    private func frame(of index: Int) -> CGRect? {
        guard assets.indices.contains(index) else { return nil }
        return layout.layoutAttributesForItem(at: path(of: index))?.frame
    }

    /// The first photo in the row at the top of the screen.
    private func topIndex() -> Int? {
        let y = collection.contentOffset.y + collection.adjustedContentInset.top
        guard let first = layout.math.visible(y, y + 1).first, sections.indices.contains(first.section) else { return nil }
        return sections[first.section].range.lowerBound + (first.items.isEmpty ? 0 : first.items.lowerBound)
    }

    private func reportTop() {
        guard let i = topIndex(), assets.indices.contains(i) else { return }
        let day = Int((assets[i].date.timeIntervalSince1970 / 86400).rounded(.down))
        if day != lastTopDay {
            lastTopDay = day
            handlers.onTop(i)
        }
    }

    /// The pinned date's top, below the bars.
    private static let pinGap = 4.0
    /// The blur's height below the bars: the pinned date and a margin under it.
    private static var zoneHeight: Double { pinGap + PhoneHeader.font.lineHeight + 12 }

    /// Once a day's date reaches the bars it stays just below them, over a blur that stays put. The next day's date
    /// pushes it up, and it fades as it goes; the next date is drawn over the blur too while it's inside it, so it stays
    /// sharp and takes over in place. Before any of this the list's own header shows, so at rest the large title is clear.
    private func updateFloating() {
        let math = layout.math
        var hidden: Set<Int> = []
        defer {
            layout.hiddenHeaders = hidden // drawn by the floating labels instead
            blurZone.isHidden = hidden.isEmpty
            floatingLabel.isHidden = hidden.isEmpty
            incomingLabel.isHidden = hidden.count < 2
        }
        guard pinHeaders, !math.tops.isEmpty, math.tops.count == sections.count else { return }
        let inset = collection.adjustedContentInset.top
        let lineHeight = PhoneHeader.font.lineHeight
        let textTop = math.header - 8 - lineHeight // the date's top within its header
        let pin = collection.contentOffset.y + inset + Self.pinGap // the pinned date's top, in the list
        var lo = 0, hi = math.tops.count - 1 // the last section whose date has reached the pin
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if math.tops[mid] + textTop <= pin { lo = mid } else { hi = mid - 1 }
        }
        guard math.tops[lo] + textTop < pin else { return } // still in its place
        hidden.insert(lo)
        let push = Self.zoneHeight - Self.pinGap // how far below the pin the next date starts pushing
        blurZone.frame = CGRect(x: 0, y: inset, width: view.bounds.width, height: Self.zoneHeight)
        let pinY = inset + Self.pinGap
        let gap = lo + 1 < math.tops.count ? math.tops[lo + 1] + textTop - pin : .infinity // next date below the pin
        place(floatingLabel, sections[lo].title, y: pinY + min(0, gap - push))
        floatingLabel.alpha = min(1, max(0, gap / push * 2 - 1)) // gone halfway out, before it reaches the title
        if gap < push {
            hidden.insert(lo + 1)
            place(incomingLabel, sections[lo + 1].title, y: pinY + gap)
        }
    }

    private func place(_ label: UILabel, _ text: String, y: Double) {
        if label.text != text {
            label.text = text
            label.sizeToFit()
        }
        label.frame.origin = CGPoint(x: 12, y: y)
    }

    /// Scrolls `index` into view if it isn't, so closing the photo view has a square to shrink into.
    fileprivate func reveal(_ index: Int) -> UIView? {
        guard let frame = frame(of: index) else { return nil }
        let visible = collection.bounds.inset(by: collection.adjustedContentInset)
        if !visible.contains(frame) {
            collection.scrollRectToVisible(frame.insetBy(dx: 0, dy: -visible.height / 3), animated: false)
            collection.layoutIfNeeded()
        }
        return collection.cellForItem(at: path(of: index))
    }

    // MARK: Data source and delegate

    func numberOfSections(in collectionView: UICollectionView) -> Int { sections.count }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { sections[section].range.count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt path: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "cell", for: path) as! PhoneCell
        let side = layout.math.side
        let asset = assets[index(of: path)]
        cell.show(asset, library: library, pixels: ThumbnailStore.pixels(forSide: side, scale: traitCollection.displayScale))
        cell.setChecked(chosen.contains(asset.id), animated: false)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String,
                        at path: IndexPath) -> UICollectionReusableView {
        let header = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "header", for: path) as! PhoneHeader
        header.label.text = sections[path.section].title
        return header
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt path: IndexPath) {
        collectionView.deselectItem(at: path, animated: false)
        if selecting { handlers.onToggle(assets[index(of: path)].id) } else { open(index(of: path)) }
    }

    /// Long press: the photo over a short menu, as in Photos. The full set is in the photo view's ⋯ and, for several, in Select.
    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt paths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard !selecting, let path = paths.first else { return nil }
        let i = index(of: path)
        return UIContextMenuConfiguration(identifier: i as NSNumber, previewProvider: nil) { [weak self] _ in self?.menu(for: self?.assets[i]) }
    }

    /// Tapping the preview opens the photo.
    func collectionView(_ collectionView: UICollectionView, willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration,
                        animator: UIContextMenuInteractionCommitAnimating) {
        guard let i = (configuration.identifier as? NSNumber)?.intValue, assets.indices.contains(i) else { return }
        animator.addCompletion { [weak self] in self?.open(i) }
    }

    private func menu(for asset: Asset?) -> UIMenu? {
        guard let asset else { return nil }
        func item(_ title: String, _ symbol: String, destructive: Bool = false, _ action: PhotoAction) -> UIAction {
            UIAction(title: title, image: UIImage(systemName: symbol), attributes: destructive ? .destructive : []) { [weak self] _ in
                self?.handlers.onAction(action, [asset])
            }
        }
        if context == .trash {
            return UIMenu(children: [item(String(localized: "Restore"), "arrow.uturn.backward", .restore),
                                     item(String(localized: "Delete Permanently…"), "trash", destructive: true, .trash)])
        }
        let favorite = asset.isFavorite == true
        var first: [UIMenuElement] = [
            item(String(localized: "Share…"), "square.and.arrow.up", .download),
            item(favorite ? String(localized: "Remove from Favorites") : String(localized: "Add to Favorites"),
                 favorite ? "heart.slash" : "heart", .favorite),
            UIMenu(title: String(localized: "Add to Album"), image: UIImage(systemName: "rectangle.stack.badge.plus"),
                   children: [UIMenu(options: .displayInline, children: [item(String(localized: "New Album…"), "plus", .newAlbum)])]
                       + library.albums.map { album in item(album.albumName, "rectangle.stack", .add(album: album.id)) }),
        ]
        if case .album = context {
            first.append(item(String(localized: "Remove from Album"), "rectangle.stack.badge.minus", .removeFromAlbum))
        }
        first.append(UIAction(title: String(localized: "Select"), image: UIImage(systemName: "checkmark.circle")) { [weak self] _ in
            self?.handlers.onSelect(asset.id)
        })
        let archive = context == .archive ? item(String(localized: "Unarchive"), "archivebox", .unarchive)
                                          : item(String(localized: "Archive"), "archivebox", .archive)
        return UIMenu(children: [UIMenu(options: .displayInline, children: first),
                                 UIMenu(options: .displayInline, children: [archive, item(String(localized: "Delete…"), "trash", destructive: true, .trash)])])
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        reportTop()
        updateFloating()
    }

    // MARK: Gestures

    /// A pinch in progress, as pictures in the overlay: `base` is the grid at one column count, `target` the next one
    /// in the direction the fingers go, underneath it. `photo` is the one that was under the fingers.
    private struct Pinch {
        struct Picture {
            var columns: Int
            var layer: CALayer
            /// The photo's middle in this picture and its cells' size, in the view's coordinates.
            var center: CGPoint
            var side: Double
            /// How the real grid was laid out for it.
            var shift: GridMath.Shift?
            var y: Double
        }
        var photo: IndexPath
        /// Where the fingers went down and where they are now: the grid follows them, as in Photos.
        var anchor: CGPoint
        var pointer: CGPoint
        var start: CGPoint
        var startSide: Double
        var scale = 1.0
        var base: Picture
        var target: Picture?
        /// The photo's size and middle right now: it grows or shrinks around the fingers.
        var side: Double { startSide * scale }
        var spot: CGPoint {
            CGPoint(x: pointer.x + (start.x - anchor.x) * scale, y: pointer.y + (start.y - anchor.y) * scale)
        }
    }

    /// Up to 8 on a phone; a wider screen (iPad) allows more, down to tiles about 90 points across.
    private var columnRange: ClosedRange<Int> { 2...max(8, Int(view.bounds.width / 90)) }

    /// Like the Mac's (and Photos'): the fingers drive the zoom. The grid grows or shrinks around them and fades into
    /// the next column count, lined up so the same photo sits in the same place; past that count the next one is
    /// prepared, so one pinch can go through several. Letting go settles on whichever count the photos are closer to.
    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        if UIAccessibility.isReduceMotionEnabled { // one step per pinch, no moving pictures
            guard gesture.state == .ended else { return }
            let next = min(max(layout.columns + (gesture.scale > 1 ? -1 : 1), columnRange.lowerBound), columnRange.upperBound)
            if next != layout.columns { handlers.onColumns(next) }
            return
        }
        switch gesture.state {
        case .began:
            startPinch(at: gesture.location(in: view))
        case .changed:
            guard var p = pinch else { return }
            if gesture.numberOfTouches >= 2 { p.pointer = gesture.location(in: view) } // one finger up: stay put
            // past the fewest and most columns it only gives a little
            let low = p.base.columns < columnRange.upperBound ? 0.0 : 0.95
            let high = p.base.columns > columnRange.lowerBound ? Double.infinity : 1.15
            p.scale = min(max(p.startSide * gesture.scale / p.base.side, low), high) * p.base.side / p.startSide
            pinch = p
            advance()
        default:
            endPinch()
        }
    }

    private func startPinch(at point: CGPoint) {
        zoomOverlay?.removeFromSuperview()
        zoomOverlay = nil
        pinch = nil
        let inList = view.convert(point, to: collection)
        guard let photo = collection.indexPathForItem(at: inList) ?? layout.math.visible(inList.y, inList.y + 1).first
            .flatMap({ $0.items.isEmpty ? nil : IndexPath(item: $0.items.lowerBound, section: $0.section) })
        else { return }
        let overlay = UIView(frame: view.bounds)
        overlay.isUserInteractionEnabled = false
        overlay.clipsToBounds = true
        overlay.backgroundColor = .systemBackground // covers the real grid until the fingers let go
        view.insertSubview(overlay, aboveSubview: collection) // under the pinned date
        zoomOverlay = overlay
        let layer = snapshot()
        overlay.layer.addSublayer(layer)
        let base = Pinch.Picture(columns: layout.columns, layer: layer, center: center(photo), side: layout.math.side,
                                 shift: layout.shift, y: center(photo).y)
        pinch = Pinch(photo: photo, anchor: point, pointer: point, start: base.center, startSide: base.side, base: base)
    }

    /// Prepares the column count the fingers are heading to, moves on to it once the photos have reached its size,
    /// then places the pictures.
    private func advance() {
        guard var p = pinch else { return }
        for _ in columnRange {
            let to = p.base.columns + (p.side > p.base.side ? -1 : 1)
            guard p.side != p.base.side, columnRange.contains(to) else { break }
            if p.target?.columns != to {
                p.target?.layer.removeFromSuperlayer()
                p.target = prepare(to, for: p)
            }
            guard let t = p.target, to < p.base.columns ? p.side >= t.side : p.side <= t.side else { break }
            p.base.layer.removeFromSuperlayer() // past this count: it becomes the base
            p.base = t
            p.target = nil
        }
        pinch = p
        place(p)
    }

    /// Moves the real (covered) grid to `to` columns, with the photo where the fingers will have taken it by the time
    /// it reaches that size (in the nearest column), and adds a picture of it under the base.
    private func prepare(_ to: Int, for p: Pinch) -> Pinch.Picture? {
        guard let overlay = zoomOverlay else { return nil }
        let width = layout.math.width
        let math = GridMath(counts: [], width: width, target: (width - Double(to - 1)) / Double(to), header: 0)
        let k = math.side / p.startSide
        let spot = CGPoint(x: p.pointer.x + (p.start.x - p.anchor.x) * k, y: p.pointer.y + (p.start.y - p.anchor.y) * k)
        let shift = math.shift(putting: p.photo.item, of: p.photo.section, under: view.convert(spot, to: collection).x)
        setColumns(to, shift: shift, keeping: p.photo, at: spot.y)
        let layer = snapshot()
        overlay.layer.insertSublayer(layer, below: p.base.layer)
        return Pinch.Picture(columns: to, layer: layer, center: center(p.photo), side: layout.math.side, shift: shift, y: spot.y)
    }

    private func setColumns(_ columns: Int, shift: GridMath.Shift?, keeping photo: IndexPath, at y: Double) {
        layout.columns = columns
        layout.shift = shift
        collection.layoutIfNeeded()
        let frame = layout.math.itemFrame(photo.section, photo.item)
        let inset = collection.adjustedContentInset
        let lowest = -inset.top, highest = max(lowest, layout.math.height - collection.bounds.height + inset.bottom)
        collection.contentOffset.y = min(max(frame.midY - view.convert(CGPoint(x: 0, y: y), to: collection).y
                                             + collection.contentOffset.y, lowest), highest)
        collection.layoutIfNeeded()
    }

    /// The photo's middle on screen, in the view's coordinates.
    private func center(_ path: IndexPath) -> CGPoint {
        let f = collection.convert(layout.math.itemFrame(path.section, path.item), to: view)
        return CGPoint(x: f.midX, y: f.midY)
    }

    /// The cells and dates on screen as plain layers, in the view's coordinates.
    private func snapshot() -> CALayer {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let container = CALayer()
        container.anchorPoint = .zero
        container.frame = view.bounds
        let empty = UIColor.secondarySystemBackground.resolvedColor(with: traitCollection).cgColor
        for case let cell as PhoneCell in collection.visibleCells {
            guard let path = collection.indexPath(for: cell) else { continue }
            let copy = CALayer()
            copy.frame = cell.convert(cell.bounds, to: view)
            copy.contentsGravity = .resizeAspectFill
            copy.masksToBounds = true
            copy.backgroundColor = empty
            // a cell that just came in may still be loading; any size already in memory will do, else it fades in
            let id = assets[index(of: path)].id
            copy.contents = cell.image.image?.cgImage ?? library.thumbs.anyCached(id)
            if copy.contents == nil, let api = library.api {
                let store = library.thumbs, pixels = ThumbnailStore.pixels(forSide: layout.math.side, scale: traitCollection.displayScale)
                Task { copy.contents = await store.image(id, pixels: pixels, api: api) }
            }
            container.addSublayer(copy)
        }
        for header in collection.visibleSupplementaryViews(ofKind: UICollectionView.elementKindSectionHeader) where header.alpha > 0 {
            let copy = CALayer()
            copy.frame = header.convert(header.bounds, to: view)
            copy.contents = UIGraphicsImageRenderer(bounds: header.bounds).image { header.layer.render(in: $0.cgContext) }.cgImage
            container.addSublayer(copy)
        }
        return container
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

    /// The fingers let go: the pictures finish (or undo) the change, then the real grid comes back.
    private func endPinch() {
        guard let p = pinch, let overlay = zoomOverlay else { return }
        pinch = nil
        let target = progress(p) >= 0.5 ? p.target : nil
        let final = target ?? p.base
        if layout.columns != final.columns || layout.shift != final.shift { // the real grid is on the other count
            setColumns(final.columns, shift: final.shift, keeping: p.photo, at: final.y)
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
        CATransaction.setCompletionBlock { [weak self, weak overlay] in
            guard let self, let overlay, self.zoomOverlay === overlay else { return } // a newer pinch owns it now
            overlay.removeFromSuperview()
            self.zoomOverlay = nil
        }
        animate(p.base.layer, "transform", to: NSValue(caTransform3D: mapping(p.base, side: final.side, at: spot)))
        animate(p.base.layer, "opacity", to: NSNumber(value: target == nil ? 1 : 0))
        if let other = p.target, !other.layer.isHidden {
            animate(other.layer, "transform", to: NSValue(caTransform3D: mapping(other, side: final.side, at: spot)))
        }
        CATransaction.commit()
        handlers.onColumns(final.columns)
    }

    @objc private func pullToRefresh(_ control: UIRefreshControl) {
        Task {
            await handlers.refresh?()
            control.endRefreshing()
        }
    }

    // MARK: Photo view

    private func open(_ index: Int) {
        let state = PagerState(position: index, assets: assets)
        let host = PageController(rootView: AnyView(EmptyView()))
        pager = state
        pagerHost = host
        host.rootView = AnyView(
            PagerHost(state: state, context: context,
                      close: { [weak host] in host?.dismiss(animated: true) },
                      onPerson: { [weak self, weak host] person in
                          host?.dismiss(animated: true) { self?.handlers.onPerson(person) }
                      },
                      onDark: { [weak state, weak host] in
                          state?.dark = $0
                          host?.statusBarHidden = $0
                      })
                .environment(library))
        // over, not instead of, the grid: off screen SwiftUI stops updating it, and an edit here must reach it
        host.modalPresentationStyle = .overFullScreen
        let zoom = PhotoZoom(grid: self, state: state, page: host)
        self.zoom = zoom
        host.transitioningDelegate = zoom
        present(host, animated: true)
    }
}

// MARK: Opening and closing a photo

/// Like Photos: only the photo flies between its square in the grid and its place on the screen (cropped to the square
/// at one end, whole at the other) while the page's background fades in or out behind it. UIKit's zoom transition grows
/// the whole screen-sized page instead, a frame with a shadow around the photo. A swipe down drags the photo off and
/// closes it from wherever it's let go, or puts it back.
/// The photo page. Its hidden bars hide the status bar, through the app's root; closing brings it back.
private final class PageController: UIHostingController<AnyView> {
    var statusBarHidden = false { didSet { Immersion.shared.on = statusBarHidden } }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        Immersion.shared.on = false
    }
}

private final class PhotoZoom: NSObject, UIViewControllerTransitioningDelegate, UIViewControllerAnimatedTransitioning,
                               UIGestureRecognizerDelegate {
    private weak var grid: PhoneGridController?
    private let state: PagerState
    private weak var page: UIViewController?
    /// The photo lifted off the page and the backdrop in its place, while a swipe down drags it or the page closes.
    private var lifted: (photo: UIImageView, backdrop: UIView, start: CGPoint)?

    init(grid: PhoneGridController, state: PagerState, page: UIViewController) {
        self.grid = grid
        self.state = state
        self.page = page
        state.flying = true // set before the page first draws; open() clears it
        super.init()
        let pan = UIPanGestureRecognizer(target: self, action: #selector(drag(_:)))
        pan.delegate = self
        page.view.addGestureRecognizer(pan)
    }

    func animationController(forPresented presented: UIViewController, presenting: UIViewController,
                             source: UIViewController) -> (any UIViewControllerAnimatedTransitioning)? { self }

    func animationController(forDismissed dismissed: UIViewController) -> (any UIViewControllerAnimatedTransitioning)? { self }

    func transitionDuration(using context: (any UIViewControllerContextTransitioning)?) -> TimeInterval { 0.4 }

    func animateTransition(using context: any UIViewControllerContextTransitioning) {
        if let page = context.viewController(forKey: .to), page.isBeingPresented { open(page, context) } else { close(context) }
    }

    /// The photo's square in the grid, scrolled into view.
    private func square() -> PhoneCell? { state.position.flatMap { grid?.reveal($0) } as? PhoneCell }

    private func open(_ page: UIViewController, _ context: any UIViewControllerContextTransitioning) {
        let container = context.containerView
        page.view.frame = context.finalFrame(for: page)
        page.view.alpha = 0
        container.addSubview(page.view)
        guard let cell = square(), let image = cell.image.image else { // not loaded yet: just fade in
            state.flying = false
            UIView.animate(withDuration: 0.25) { page.view.alpha = 1 } completion: { _ in context.completeTransition(true) }
            return
        }
        // the photo flies under the page's bars, which fade in with the background, like in Photos; the page is
        // see-through and its own photo hidden until it lands
        page.view.layoutIfNeeded()
        let opaque = Self.fullScreenBackgrounds(in: page.view) // e.g. the side panel's main column
        opaque.forEach { $0.view.backgroundColor = .clear }
        page.view.backgroundColor = .clear
        let backdrop = Self.backdrop(container, dark: false)
        backdrop.alpha = 0
        let photo = Self.photo(image, frame: cell.convert(cell.bounds, to: container))
        container.insertSubview(backdrop, belowSubview: page.view)
        container.insertSubview(photo, belowSubview: page.view)
        cell.isHidden = true
        UIView.animate(withDuration: 0.25) {
            page.view.alpha = 1
            backdrop.alpha = 1
        }
        UIView.animate(springDuration: 0.4, bounce: 0.12) {
            photo.frame = AVMakeRect(aspectRatio: image.size, insideRect: page.view.frame)
        } completion: { _ in
            cell.isHidden = false
            self.state.flying = false // the page's photo, the thumbnail at once, in the same place
            opaque.forEach { $0.view.backgroundColor = $0.color }
            DispatchQueue.main.async { // after SwiftUI shows it
                photo.removeFromSuperview()
                backdrop.removeFromSuperview()
                context.completeTransition(true)
            }
        }
    }

    private func close(_ context: any UIViewControllerContextTransitioning) {
        guard let page = context.viewController(forKey: .from) else { return context.completeTransition(true) }
        guard let (photo, backdrop, _) = lifted ?? lift(page, into: context.containerView) else {
            UIView.animate(withDuration: 0.25) { page.view.alpha = 0 } completion: { _ in context.completeTransition(true) }
            return
        }
        lifted = nil
        let cell = square()
        let target = cell.map { $0.convert($0.bounds, to: context.containerView) }
        cell?.isHidden = true
        UIView.animate(springDuration: 0.4, bounce: 0.08) {
            if let target { photo.frame = target } else { photo.alpha = 0 }
            backdrop.alpha = 0
        } completion: { _ in
            cell?.isHidden = false
            photo.removeFromSuperview()
            backdrop.removeFromSuperview()
            context.completeTransition(true)
        }
    }

    /// The page's views that fill it with a colour, which would hide the photo flying under its bars.
    private static func fullScreenBackgrounds(in page: UIView) -> [(view: UIView, color: UIColor)] {
        var found: [(UIView, UIColor)] = []
        func walk(_ view: UIView) {
            if let color = view.backgroundColor, color.cgColor.alpha > 0, view.bounds.size == page.bounds.size {
                found.append((view, color))
            }
            view.subviews.forEach(walk)
        }
        page.subviews.forEach(walk)
        return found
    }

    /// Hides the page behind a copy of its photo, in the same place, on a backdrop of the page's colour.
    private func lift(_ page: UIViewController, into container: UIView) -> (UIImageView, UIView, CGPoint)? {
        let frame: CGRect
        let image: UIImage
        if let shown = Self.shownImage(in: page.view), let picture = shown.image {
            image = picture
            frame = AVMakeRect(aspectRatio: picture.size, insideRect: shown.convert(shown.bounds, to: container))
        } else if let picture = square()?.image.image { // a video, or still loading: its thumbnail, fitted to the page
            image = picture
            frame = AVMakeRect(aspectRatio: picture.size, insideRect: page.view.frame)
        } else {
            return nil
        }
        let backdrop = Self.backdrop(container, dark: state.dark)
        let photo = Self.photo(image, frame: frame)
        container.addSubview(backdrop)
        container.addSubview(photo)
        page.view.alpha = 0
        return (photo, backdrop, photo.center)
    }

    @objc private func drag(_ pan: UIPanGestureRecognizer) {
        guard let page, let container = page.view.superview else { return }
        let moved = pan.translation(in: container)
        switch pan.state {
        case .began:
            lifted = lift(page, into: container)
        case .changed:
            guard let (photo, backdrop, start) = lifted else { return }
            let progress = min(1, max(0, moved.y / (container.bounds.height / 2)))
            photo.center = CGPoint(x: start.x + moved.x, y: start.y + moved.y)
            photo.transform = CGAffineTransform(scaleX: 1 - progress / 2, y: 1 - progress / 2)
            backdrop.alpha = 1 - progress
        default:
            guard let (photo, backdrop, start) = lifted else { return }
            if pan.state == .ended, moved.y > 80 || pan.velocity(in: container).y > 600 {
                let frame = photo.frame // the close animates the frame, from where it is now
                photo.transform = .identity
                photo.frame = frame
                page.dismiss(animated: true)
            } else {
                lifted = nil
                UIView.animate(springDuration: 0.3, bounce: 0.15) {
                    photo.transform = .identity
                    photo.center = start
                    backdrop.alpha = 1
                } completion: { _ in
                    page.view.alpha = 1
                    photo.removeFromSuperview()
                    backdrop.removeFromSuperview()
                }
            }
        }
    }

    /// Only a downward swipe, not on the details panel's list, and not while a zoomed-in photo is being moved about.
    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let pan = recognizer as? UIPanGestureRecognizer, let view = pan.view else { return false }
        let velocity = pan.velocity(in: view)
        guard velocity.y > abs(velocity.x) else { return false }
        var hit = view.hitTest(pan.location(in: view), with: nil)
        while let v = hit, v !== view {
            if v is UICollectionView || v is UITableView { return false }
            if let scroll = v as? UIScrollView, scroll.zoomScale > scroll.minimumZoomScale + 0.01 { return false }
            hit = v.superview
        }
        return true
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    private static func backdrop(_ container: UIView, dark: Bool) -> UIView {
        let view = UIView(frame: container.bounds)
        view.backgroundColor = dark ? .black : .systemBackground
        return view
    }

    private static func photo(_ image: UIImage, frame: CGRect) -> UIImageView {
        let view = UIImageView(image: image)
        view.contentMode = .scaleAspectFill // cropped to the square at the grid's end, whole at the screen's
        view.clipsToBounds = true
        view.frame = frame
        return view
    }

    /// The photo on the page: the biggest picture across the middle of the screen.
    private static func shownImage(in page: UIView) -> UIImageView? {
        let middle = CGPoint(x: page.bounds.midX, y: page.bounds.midY)
        var best: UIImageView?
        func look(_ view: UIView) {
            if let picture = view as? UIImageView, picture.image != nil, !picture.isHidden, picture.alpha > 0,
               picture.convert(picture.bounds, to: page).contains(middle),
               picture.bounds.width * picture.bounds.height > best.map({ $0.bounds.width * $0.bounds.height }) ?? 0 {
                best = picture
            }
            view.subviews.forEach(look)
        }
        look(page)
        return best
    }
}

/// Which photo the photo view shows, shared with the grid so closing shrinks into the right square.
@Observable final class PagerState {
    var position: Int?
    /// The grid's photos. Replaced after an edit, with `version` counting up.
    private(set) var assets: [Asset]
    private(set) var version = 0
    /// The page's background is black (its bars hidden).
    var dark = false
    /// The opening photo is flying from its square: the page's own photo waits under it.
    var flying = false

    init(position: Int, assets: [Asset]) {
        self.position = position
        self.assets = assets
    }

    /// The list changed: stay on the same photo wherever it went, or show the next one if it's gone.
    func follow(_ new: [Asset]) {
        let id = position.flatMap { assets.indices.contains($0) ? assets[$0].id : nil }
        position = new.firstIndex { $0.id == id } ?? min(position ?? 0, new.count - 1)
        assets = new
        version += 1
    }
}

private struct PagerHost: View {
    @Bindable var state: PagerState
    let context: BrowserContext
    let close: () -> Void
    let onPerson: (Person) -> Void
    let onDark: (Bool) -> Void

    var body: some View {
        PhotoPager(assets: state.assets, version: state.version, position: $state.position, context: context, close: close,
                   onPerson: onPerson, onDark: onDark, flying: state.flying)
            .overlay { TransferPanel() } // the root's is under this full screen view
    }
}

/// Square cells from `GridMath`, with optional date headers above each section.
final class PhoneGridLayout: UICollectionViewLayout {
    var counts: [Int] = [] { didSet { changed() } }
    var header = 0.0 { didSet { if header != oldValue { changed() } } }
    var columns = 4 { didSet { if columns != oldValue { changed() } } }
    /// Moves one section's photos along a few columns, so a pinch keeps the photo under the fingers in its column.
    var shift: GridMath.Shift? { didSet { if shift != oldValue { changed() } } }
    /// Sections whose headers the floating dates draw instead. In the attributes, since UIKit resets a view's alpha
    /// to them on every layout pass.
    var hiddenHeaders: Set<Int> = [] { didSet { if hiddenHeaders != oldValue { invalidateLayout() } } }
    private(set) var math = GridMath(counts: [], width: 1, target: 76, header: 0)
    private var stale = true

    private func changed() {
        stale = true
        invalidateLayout()
    }

    override func prepare() {
        let width = collectionView.map { usable($0.bounds.width) } ?? 1
        // only the math for a new width or new data, not for every invalidation
        guard stale || width != math.width else { return }
        stale = false
        let target = (width - Double(columns - 1)) / Double(columns)
        math = GridMath(counts: counts, width: width, target: target, header: header, shift: shift)
    }

    override var collectionViewContentSize: CGSize { CGSize(width: math.width, height: math.height) }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool { usable(newBounds.width) != math.width }

    /// The width left between the safe area's sides (an iPad's sidebar floats over the grid).
    private func usable(_ width: Double) -> Double {
        let inset = collectionView?.adjustedContentInset ?? .zero
        return max(1, width - inset.left - inset.right)
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        var result: [UICollectionViewLayoutAttributes] = []
        for v in math.visible(rect.minY, rect.maxY) {
            if header > 0, let h = layoutAttributesForSupplementaryView(ofKind: UICollectionView.elementKindSectionHeader,
                                                                         at: IndexPath(item: 0, section: v.section)) {
                result.append(h)
            }
            for i in v.items { result.append(item(IndexPath(item: i, section: v.section))) }
        }
        return result
    }

    override func layoutAttributesForItem(at path: IndexPath) -> UICollectionViewLayoutAttributes? {
        counts.indices.contains(path.section) && path.item < counts[path.section] ? item(path) : nil
    }

    override func layoutAttributesForSupplementaryView(ofKind kind: String, at path: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard header > 0, counts.indices.contains(path.section) else { return nil }
        let a = UICollectionViewLayoutAttributes(forSupplementaryViewOfKind: kind, with: path)
        a.frame = math.headerFrame(path.section)
        a.alpha = hiddenHeaders.contains(path.section) ? 0 : 1
        return a
    }

    /// The header height above `path` when it's in its section's first row.
    func headerAbove(_ path: IndexPath) -> Double { math.firstRow(path.section, path.item) ? header : 0 }

    private func item(_ path: IndexPath) -> UICollectionViewLayoutAttributes {
        let a = UICollectionViewLayoutAttributes(forCellWith: path)
        a.frame = math.itemFrame(path.section, path.item)
        return a
    }
}

/// One square: the thumbnail from memory at once, else from disk or the server; a play badge on videos.
final class PhoneCell: UICollectionViewCell {
    fileprivate let image = UIImageView()
    private let badge = UIImageView(image: UIImage(systemName: "play.fill"))
    private let check = UIImageView(image: UIImage(systemName: "checkmark.circle.fill",
                                                   withConfiguration: UIImage.SymbolConfiguration(paletteColors: [.white, .tintColor])))
    /// Chosen in select mode: a check in the top left corner, the photo slightly faded.
    private(set) var checked = false

    /// `animated`: the check springs in or shrinks away, for a tap; a cell just shown gets it as it is.
    func setChecked(_ on: Bool, animated: Bool) {
        guard on != checked || !animated else { return }
        checked = on
        check.layer.removeAllAnimations()
        image.layer.removeAllAnimations()
        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            check.isHidden = !on
            check.alpha = 1
            check.transform = .identity
            image.alpha = on ? 0.8 : 1
            return
        }
        check.isHidden = false
        if on {
            check.alpha = 1
            check.transform = CGAffineTransform(scaleX: 0.4, y: 0.4)
            UIView.animate(springDuration: 0.35, bounce: 0.4) { self.check.transform = .identity }
        }
        UIView.animate(withDuration: 0.2) {
            self.image.alpha = on ? 0.8 : 1
            if !on {
                self.check.alpha = 0
                self.check.transform = CGAffineTransform(scaleX: 0.4, y: 0.4)
            }
        } completion: { _ in
            guard !self.checked else { return }
            self.check.isHidden = true
            self.check.alpha = 1
            self.check.transform = .identity
        }
    }
    private var task: Task<Void, Never>?
    private var id = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemBackground
        image.contentMode = .scaleAspectFill
        image.clipsToBounds = true
        image.frame = contentView.bounds
        image.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(image)
        badge.tintColor = .white
        badge.preferredSymbolConfiguration = .init(textStyle: .caption2)
        badge.layer.shadowOpacity = 0.5
        badge.layer.shadowRadius = 2
        badge.layer.shadowOffset = .zero
        contentView.addSubview(badge)
        check.preferredSymbolConfiguration = .init(pointSize: 20)
        check.backgroundColor = .white // a white ring around the blue
        check.isHidden = true
        contentView.addSubview(check)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        badge.sizeToFit()
        badge.frame.origin = CGPoint(x: bounds.maxX - badge.frame.width - 4, y: bounds.maxY - badge.frame.height - 4)
        check.sizeToFit()
        check.frame.origin = CGPoint(x: 5, y: 5)
        check.layer.cornerRadius = check.frame.width / 2
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        task?.cancel()
        image.image = nil
    }

    func show(_ asset: Asset, library: Library, pixels: Int) {
        id = asset.id
        badge.isHidden = !asset.isVideo
        if let cached = library.thumbs.cached(asset.id, pixels: pixels) {
            image.image = UIImage(cgImage: cached)
            return
        }
        guard let api = library.api else { return }
        let thumbs = library.thumbs, id = asset.id
        task = Task { [weak self] in
            let loaded = await thumbs.image(id, pixels: pixels, api: api)
            guard let self, !Task.isCancelled, self.id == id, let loaded else { return }
            self.image.image = UIImage(cgImage: loaded)
        }
    }
}

/// A date over its section, like the Mac's: plain bold text, not pinned.
final class PhoneHeader: UICollectionReusableView {
    static let font = UIFont.systemFont(ofSize: 15, weight: .semibold)
    let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.font = Self.font
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}
#endif
