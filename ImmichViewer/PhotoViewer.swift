import AVKit
import SwiftUI
import MapKit
import UniformTypeIdentifiers

/// What the grid hands the viewer when a photo is clicked.
struct ViewerState {
    var index: Int
    /// The clicked cell, in the grid's coordinates (origin at the top left of the window).
    var origin: CGRect?
    /// The cell's thumbnail, shown at once while the large preview loads.
    var image: CGImage?
}

/// One photo over the whole window, title bar included. It grows out of its grid cell and shrinks back into it.
/// ← → or a two-finger swipe step through the timeline; Esc, ✕ or a two-finger swipe down closes. Videos play in place.
/// A click hides the title bar, buttons and info panel; pointing at the title bar shows them while the pointer is there.
/// Pinch or double-click zooms (the original loads for that), ⌘I shows details, ⌘C copies, dragging the photo out saves it.
struct PhotoViewer: View {
    let library: Library
    let assets: [Asset]
    /// Changes when `assets` changes (an edit removed or moved photos), so the viewer finds its photo again.
    let revision: Int
    let context: BrowserContext
    /// Height of the title bar, where the date and buttons sit over the photo.
    let topInset: CGFloat
    let bridge: GridBridge
    /// The grid's photo actions, for this photo; the place is where the photo is now.
    let perform: (PhotoAction, [Int], CLLocationCoordinate2D?) -> Void
    let onClosed: () -> Void

    @State private var index: Int
    @State private var origin: CGRect?
    @State private var image: NSImage?
    @State private var shown = false
    @State private var sliding = false
    /// Horizontal drag or slide of the photo.
    @State private var offset: CGFloat = 0
    /// Where the photo may be: the window left of the info panel.
    @State private var area = CGRect.zero
    /// How far a two-finger swipe has pulled the photo down; far enough closes the viewer.
    @State private var dismiss: CGFloat = 0
    /// The opening animation is over. The video player waits for it, so only the thumbnail grows out of the grid.
    @State private var settled = false
    /// A click hid the title bar, buttons and info panel.
    @State private var chromeHidden = false
    /// The pointer is over the title bar, which shows it while the rest stays hidden.
    @State private var pointerInBar = false
    @State private var player: AVPlayer?
    @State private var swipe = SwipeMonitor()
    @State private var detail: AssetDetail?
    /// The photo shown, to find it again after an edit.
    @State private var shownID = ""
    /// Typing in the info panel: the single-key shortcuts (arrows, Space, ".") leave the keys to the text field.
    @State private var typing = false
    @Environment(\.undoManager) private var undo
    /// 1 = whole photo; above 1 the photo is enlarged and moved by `pan` from the middle.
    @State private var zoom: CGFloat = 1
    @State private var pan = CGSize.zero
    /// The original (or the preview if the key can't download), once zoomed, copied or dragged.
    @State private var full: (id: String, data: Data)?
    @State private var loadingFull = false
    @AppStorage("showInfo") private var showInfo = false
    @AppStorage("videoAutoplay") private var autoplay = true
    @AppStorage("videoMuted") private var muted = false
    @AppStorage("videoLoop") private var loop = false
    @Environment(\.showPerson) private var showPerson

    private static let spring = Animation.spring(duration: 0.35, bounce: 0.1)
    private static let panelWidth: CGFloat = 300
    private static let maxZoom: CGFloat = 8
    private static let dateStyle: Date.FormatStyle = {
        var s = Date.FormatStyle(date: .abbreviated, time: .shortened)
        s.timeZone = .gmt
        return s
    }()

    init(library: Library, assets: [Asset], revision: Int, context: BrowserContext, topInset: CGFloat, bridge: GridBridge,
         start: ViewerState, perform: @escaping (PhotoAction, [Int], CLLocationCoordinate2D?) -> Void, onClosed: @escaping () -> Void) {
        self.library = library
        self.assets = assets
        self.revision = revision
        self.context = context
        self.topInset = topInset
        self.bridge = bridge
        self.perform = perform
        self.onClosed = onClosed
        _index = State(initialValue: start.index)
        _origin = State(initialValue: start.origin)
        _image = State(initialValue: start.image.map { NSImage(cgImage: $0, size: .zero) })
    }

    var body: some View {
        if assets.indices.contains(index) {
            let asset = assets[index]
            GeometryReader { geo in
                let panel = panelShown ? Self.panelWidth : 0
                let space = CGRect(x: 0, y: 0, width: max(geo.size.width - panel, 1), height: max(geo.size.height, 1))
                let fitted = fitted(in: space)
                let rect = shown ? pulled(zoomed(fitted).offsetBy(dx: offset, dy: 0)) : (origin ?? fitted)
                ZStack {
                    // the grid shows through more the further the photo is pulled down
                    Color.black.opacity(shown ? 1 - min(max(dismiss, 0) / 400, 0.7) : 0)
                    if let image {
                        Image(nsImage: image).resizable().scaledToFill()
                            .frame(width: rect.width, height: rect.height).clipped()
                            .position(x: rect.midX, y: rect.midY)
                            .opacity(shown || origin != nil ? 1 : 0)
                            // an enlarged photo stays left of the info panel
                            .mask(alignment: .topLeading) {
                                let clip = zoom > 1 ? space : CGRect(origin: .zero, size: geo.size)
                                Rectangle().frame(width: clip.width, height: clip.height).offset(x: clip.minX, y: clip.minY)
                            }
                    } else if shown {
                        ProgressView().controlSize(.large).position(x: space.midX + offset, y: space.midY)
                    }
                    ViewerInput(
                        isZoomed: { zoom > 1 },
                        onMagnify: { magnify($0, $1, at: $2) },
                        onDoubleClick: { toggleZoom(at: $0) },
                        onPan: { panBy($0, $1) },
                        onTap: toggleChrome,
                        onHover: { p in
                            let inBar = p.map { $0.y < topInset } ?? false
                            if inBar != pointerInBar { withAnimation(.easeOut(duration: 0.2)) { pointerInBar = inBar } }
                        },
                        titleBar: chromeShown,
                        dragItem: { point in
                            guard !asset.isVideo, let image, rect.contains(point) else { return nil }
                            return (promise(for: asset), image, rect)
                        })
                    if let player, shown, settled {
                        // over the thumbnail, which shows until the first frame arrives
                        PlayerView(player: player, onTap: toggleChrome)
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                    }
                    if loadingFull {
                        ProgressView().controlSize(.small)
                            .padding(8)
                            .glassEffect(.regular, in: .circle)
                            .position(x: space.maxX - 28, y: space.maxY - 28)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if panelShown {
                        InfoPanel(asset: asset, detail: detail, typing: $typing,
                                  onPerson: { person in
                                      close()
                                      showPerson(person)
                                  },
                                  onDescribe: { text in
                                      Task { await library.describe(asset.id, text, was: detail?.exifInfo?.description ?? "", undo: undo) }
                                  },
                                  onRate: { stars in
                                      Task { await library.rate(asset.id, stars, was: detail?.exifInfo?.rating, undo: undo) }
                                  },
                                  onDate: { act(.adjustDate) },
                                  onPlace: { act(.setLocation) })
                            .frame(width: Self.panelWidth, height: max(geo.size.height - topInset, 1))
                            .offset(y: topInset)
                            .transition(.move(edge: .trailing))
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if shown, !chromeHidden, let people = detail?.people, !people.isEmpty {
                        FaceRow(people: people) { person in
                            close()
                            showPerson(person)
                        }
                        .frame(maxWidth: max(space.width - 32, 1), alignment: .leading)
                        .padding(16)
                        .transition(.opacity)
                    }
                }
                .onChange(of: space, initial: true) {
                    area = space
                    clampPan()
                }
            }
            .ignoresSafeArea(edges: .vertical)
            .background {
                // keys anywhere in the window
                Group {
                    Group {
                        Button("") { go(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
                        Button("") { go(1) }.keyboardShortcut(.rightArrow, modifiers: [])
                        Button("", action: escape).keyboardShortcut(.cancelAction)
                        Button("") { asset.isVideo ? togglePlay() : close() }.keyboardShortcut(.space, modifiers: [])
                        Button("") { copy(asset) }.keyboardShortcut("c")
                        Button("") { act(.favorite) }.keyboardShortcut(".", modifiers: [])
                        Button("") { act(.trash) }.keyboardShortcut(.delete)
                    }
                    .disabled(typing)
                    Button("") { setZoom(zoom * 2, at: center) }.keyboardShortcut("=")
                    Button("") { setZoom(zoom / 2, at: center) }.keyboardShortcut("-")
                }
                .opacity(0)
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(asset.date.formatted(Self.dateStyle))
                        .font(.headline).monospacedDigit()
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 3) // readable over a bright photo
                        .opacity(shown ? 1 : 0)
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .navigation) {
                    Button(action: close) { Image(systemName: "xmark") }
                        .help("Close (Esc)")
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    let favorite = asset.isFavorite == true
                    Button { act(.favorite) } label: {
                        Label(favorite ? "Remove from Favorites" : "Add to Favorites", systemImage: favorite ? "heart.fill" : "heart")
                            .labelStyle(.iconOnly)
                    }
                    .help(favorite ? "Remove from Favorites (.)" : "Add to Favorites (.)")
                    Button {
                        withAnimation(Self.spring) {
                            showInfo = !panelShown
                            chromeHidden = false
                        }
                    } label: {
                        Image(systemName: showInfo ? "info.circle.fill" : "info.circle")
                    }
                    .keyboardShortcut("i")
                    .help("Info (⌘I)")
                    Menu {
                        PhotoMenu(library: library, count: 1, allFavorite: asset.isFavorite == true, context: context) { act($0) }
                        Divider()
                        Button("Open in Browser", systemImage: "safari") { library.openInBrowser(asset) }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuIndicator(.hidden)
                    .help("More")
                }
            }
            .onAppear {
                swipe.start(onPan: { panBy($0, $1) }, onChange: drag, onEnd: dragEnded, onPull: pull, onPullEnd: pullEnded)
                withAnimation(Self.spring) { shown = true } completion: { settled = true }
            }
            .onDisappear {
                swipe.stop()
                player?.pause()
            }
            .task(id: [asset.id, "\(library.edits)"]) { // again after a change, to show what the server made of it
                if shownID != asset.id { detail = nil }
                shownID = asset.id
                let new = await library.detail(asset)
                if !Task.isCancelled { detail = new }
            }
            .onChange(of: revision) { found() }
            .task(id: asset.id) {
                player?.pause()
                player = nil
                if asset.isVideo, let video = library.player(for: asset) {
                    video.isMuted = muted
                    player = video
                    if autoplay { video.play() }
                }
                await load(asset)
                if loop, let player {
                    for await _ in NotificationCenter.default.notifications(named: AVPlayerItem.didPlayToEndTimeNotification,
                                                                           object: player.currentItem) {
                        await player.seek(to: .zero)
                        player.play()
                    }
                }
            }
        }
    }

    private var center: CGPoint { CGPoint(x: area.midX, y: area.midY) }

    /// Does a grid action to this photo.
    private func act(_ action: PhotoAction) {
        let place = detail?.exifInfo.flatMap { e in e.latitude.flatMap { lat in e.longitude.map { CLLocationCoordinate2D(latitude: lat, longitude: $0) } } }
        perform(action, [index], place)
    }

    /// After an edit: the photo may have moved (new date) or gone (deleted, archived); then the next one shows.
    private func found() {
        if let i = assets.firstIndex(where: { $0.id == shownID }) {
            index = i
        } else if assets.isEmpty {
            onClosed()
        } else {
            index = min(index, assets.count - 1)
            resetZoom()
            image = library.thumbs.anyCached(assets[index].id).map { NSImage(cgImage: $0, size: .zero) }
        }
    }
    private var chromeShown: Bool { !chromeHidden || pointerInBar }
    private var panelShown: Bool { showInfo && shown && !chromeHidden }

    /// `r` pulled down by a swipe, shrinking to half size as it goes.
    private func pulled(_ r: CGRect) -> CGRect {
        guard dismiss != 0 else { return r }
        let s = max(0.5, 1 - max(dismiss, 0) / max(area.height, 1))
        let w = r.width * s, h = r.height * s
        return CGRect(x: r.midX - w / 2, y: r.midY + dismiss - h / 2, width: w, height: h)
    }

    /// The photo's rectangle when it fills `area` without cropping.
    private func fitted(in area: CGRect) -> CGRect {
        guard let size = image?.size, size.width > 0, size.height > 0 else { return area }
        let s = min(area.width / size.width, area.height / size.height)
        let w = size.width * s, h = size.height * s
        return CGRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h)
    }

    /// `fitted` enlarged by `zoom` and moved by `pan`.
    private func zoomed(_ fitted: CGRect) -> CGRect {
        let w = fitted.width * zoom, h = fitted.height * zoom
        return CGRect(x: fitted.midX + pan.width - w / 2, y: fitted.midY + pan.height - h / 2, width: w, height: h)
    }

    private func load(_ asset: Asset) async {
        if image == nil, let api = library.api, let thumb = await library.thumbs.image(asset.id, pixels: 0, api: api),
           !Task.isCancelled {
            image = NSImage(cgImage: thumb, size: .zero)
        }
        if let preview = await library.preview(asset), !Task.isCancelled, full?.id != asset.id { image = preview }
    }

    /// The original for this photo, downloaded once.
    private func fullData(_ asset: Asset) async -> Data? {
        if let full, full.id == asset.id { return full.data }
        loadingFull = true
        defer { loadingFull = false }
        guard let data = await library.full(asset) else { return nil }
        if assets[index].id == asset.id { full = (asset.id, data) }
        return data
    }

    // MARK: zoom

    /// Zooms to `z`, keeping the point under `p` where it is.
    private func setZoom(_ z: CGFloat, at p: CGPoint) {
        let asset = assets[index]
        guard !asset.isVideo, image != nil else { return }
        let z = min(max(z, 1), Self.maxZoom)
        let c = CGPoint(x: area.midX, y: area.midY) // the fitted photo's middle
        let k = z / zoom
        pan = CGSize(width: p.x - c.x - (p.x - c.x - pan.width) * k, height: p.y - c.y - (p.y - c.y - pan.height) * k)
        zoom = z
        clampPan()
        if z > 1, full?.id != asset.id, !loadingFull {
            Task {
                guard let data = await fullData(asset), assets[index].id == asset.id, let big = NSImage(data: data) else { return }
                image = big // same shape, so nothing moves; only sharper
            }
        }
    }

    /// Keeps the enlarged photo covering the area wherever it can.
    private func clampPan() {
        let f = fitted(in: area)
        let maxX = max(0, (f.width * zoom - area.width) / 2), maxY = max(0, (f.height * zoom - area.height) / 2)
        pan = CGSize(width: min(max(pan.width, -maxX), maxX), height: min(max(pan.height, -maxY), maxY))
    }

    private func magnify(_ phase: NSEvent.Phase, _ amount: CGFloat, at p: CGPoint) {
        guard shown, !sliding else { return }
        setZoom(zoom * (1 + amount), at: p)
        if phase.contains(.ended), zoom < 1.1 { withAnimation(Self.spring) { setZoom(1, at: p) } }
    }

    /// Double-click: 3× at the pointer, or back to the whole photo.
    private func toggleZoom(at p: CGPoint) {
        guard shown, !sliding else { return }
        withAnimation(Self.spring) { setZoom(zoom > 1 ? 1 : 3, at: p) }
    }

    /// Scrolling or dragging an enlarged photo moves it. False when not zoomed, so swipes still change photos.
    private func panBy(_ dx: CGFloat, _ dy: CGFloat) -> Bool {
        guard zoom > 1 else { return false }
        pan.width += dx
        pan.height += dy
        clampPan()
        return true
    }

    private func resetZoom() {
        zoom = 1
        pan = .zero
    }

    // MARK: actions

    private func escape() {
        if zoom > 1 { withAnimation(Self.spring) { resetZoom() } } else { close() }
    }

    private func close() {
        guard shown else { return }
        chromeHidden = false
        pointerInBar = false
        origin = bridge.reveal(index) // the grid may have scrolled; nil fades out instead
        offset = 0
        resetZoom()
        player?.pause()
        player = nil // the thumbnail flies back into the grid
        withAnimation(Self.spring) { shown = false } completion: { onClosed() }
    }

    /// A click on the photo: hide or show the title bar, buttons and info panel.
    private func toggleChrome() {
        guard shown, !sliding else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            chromeHidden.toggle()
            pointerInBar = false
        }
    }

    /// A two-finger swipe down (`dy` > 0) pulls the photo after the fingers; up only gives a little.
    private func pull(_ dy: CGFloat) {
        guard shown, !sliding, zoom == 1 else { return }
        dismiss = dy > 0 ? dy : dy / 4
    }

    private func pullEnded(_ dy: CGFloat) {
        guard shown, !sliding, dismiss != 0 else { return }
        if dy > 100 { close() } else { withAnimation(Self.spring) { dismiss = 0 } }
    }

    private func togglePlay() {
        guard let player else { return }
        if player.timeControlStatus == .paused { player.play() } else { player.pause() }
    }

    /// ⌘C: the original (or preview) as an image other apps can paste.
    private func copy(_ asset: Asset) {
        guard !asset.isVideo else { return }
        Task {
            guard let data = await fullData(asset), let image = NSImage(data: data) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
        }
    }

    /// A file the receiving app (Finder, Mail, Messages…) asks for when the drag ends; downloaded then.
    private func promise(for asset: Asset) -> NSFilePromiseProvider {
        let name = detail?.originalFileName ?? "\(asset.id).jpg"
        return FilePromise(name: library.canDownload == false ? (name as NSString).deletingPathExtension + ".jpg" : name) {
            await fullData(asset)
        }
    }

    /// Slides the photo out and the next (`d` = 1, older) or previous (-1) one in.
    private func go(_ d: Int) {
        guard shown, !sliding else { return }
        let next = index + d
        guard assets.indices.contains(next) else {
            withAnimation(Self.spring) { offset = 0 }
            return
        }
        sliding = true
        player?.pause()
        let width = area.width + (panelShown ? Self.panelWidth : 0)
        withAnimation(.easeIn(duration: 0.12)) { offset = -CGFloat(d) * width } completion: {
            index = next
            resetZoom()
            image = library.thumbs.anyCached(assets[next].id).map { NSImage(cgImage: $0, size: .zero) }
            offset = CGFloat(d) * width
            withAnimation(.easeOut(duration: 0.18)) { offset = 0 } completion: { sliding = false }
        }
    }

    private func drag(_ dx: CGFloat) {
        guard shown, !sliding else { return }
        let edge = (dx > 0 && index == 0) || (dx < 0 && index == assets.count - 1)
        offset = edge ? dx / 3 : dx // resist past the first and last photo
    }

    private func dragEnded(_ dx: CGFloat) {
        guard shown, !sliding else { return }
        if dx < -80 { go(1) } else if dx > 80 { go(-1) } else { withAnimation(Self.spring) { offset = 0 } }
    }
}

/// Two-finger swipes anywhere in the window, also over the video player: sideways to change photos, down to close.
/// Scrolling pans a zoomed photo. While the viewer is open it takes every scroll event, so the grid underneath stays put.
@MainActor
final class SwipeMonitor {
    private var monitor: Any?
    private var dx: CGFloat = 0
    /// How far the fingers moved down, whatever the scroll direction setting.
    private var dy: CGFloat = 0
    private var horizontal: Bool?

    func start(onPan: @escaping (CGFloat, CGFloat) -> Bool, onChange: @escaping (CGFloat) -> Void, onEnd: @escaping (CGFloat) -> Void,
               onPull: @escaping (CGFloat) -> Void, onPullEnd: @escaping (CGFloat) -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            if self?.horizontal != true, onPan(event.scrollingDeltaX, event.scrollingDeltaY) { return nil }
            guard let self, event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty else { return nil }
            if event.phase.contains(.began) {
                dx = 0
                dy = 0
                horizontal = nil
            }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                if horizontal == true { onEnd(dx) } else if horizontal == false { onPullEnd(dy) }
                horizontal = nil
                return nil
            }
            if horizontal == nil, event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 {
                horizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            }
            if horizontal == true {
                dx += event.scrollingDeltaX
                onChange(dx)
            } else if horizontal == false {
                dy += event.isDirectionInvertedFromDevice ? event.scrollingDeltaY : -event.scrollingDeltaY
                onPull(dy)
            }
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Mouse and trackpad over the photo: pinch, click, double-click, drag to pan or to drag the photo out, and where the pointer is.
/// Also keeps clicks from reaching the grid underneath, and fades the window's title bar. Coordinates match SwiftUI's (origin top left).
struct ViewerInput: NSViewRepresentable {
    let isZoomed: () -> Bool
    let onMagnify: (NSEvent.Phase, CGFloat, CGPoint) -> Void
    let onDoubleClick: (CGPoint) -> Void
    let onPan: (CGFloat, CGFloat) -> Bool
    /// A single click that didn't drag, sent once it is clear no second click follows.
    let onTap: () -> Void
    /// The pointer moved (nil: it left the window).
    let onHover: (CGPoint?) -> Void
    /// Whether the title bar (window buttons and toolbar) shows.
    let titleBar: Bool
    /// What to drag out from a point: the promised file, its picture and where it is.
    let dragItem: (CGPoint) -> (NSFilePromiseProvider, NSImage, CGRect)?

    final class InputView: NSView, NSDraggingSource {
        var input: ViewerInput?
        private var last: CGPoint?
        private var dragStart: CGPoint?
        private var down: CGPoint?
        private var moved = false
        private var pendingTap: DispatchWorkItem?
        private var tracking: NSTrackingArea?
        override var isFlipped: Bool { true }

        var titleBar = true {
            didSet {
                guard titleBar != oldValue else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.25
                    titleBarView?.animator().alphaValue = titleBar ? 1 : 0
                }
            }
        }

        /// The window's title bar with its buttons and toolbar.
        private var titleBarView: NSView? { window?.standardWindowButton(.closeButton)?.superview }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { titleBarView?.alphaValue = 1 } // the grid always has its title bar
            super.viewWillMove(toWindow: newWindow)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            // by position only, so it also reports the pointer over the title bar
            let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                      owner: self)
            addTrackingArea(area)
            tracking = area
        }

        override func mouseMoved(with event: NSEvent) { input?.onHover(point(event)) }
        override func mouseExited(with event: NSEvent) { input?.onHover(nil) }

        private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

        override func mouseDown(with event: NSEvent) {
            last = point(event)
            dragStart = last
            down = last
            moved = false
            if event.clickCount == 2 {
                pendingTap?.cancel()
                input?.onDoubleClick(point(event))
            }
        }

        override func mouseDragged(with event: NSEvent) {
            if let down, hypot(point(event).x - down.x, point(event).y - down.y) > 4 { moved = true }
            guard let input, let last, let start = dragStart else { return }
            let p = point(event)
            if input.isZoomed() {
                _ = input.onPan(p.x - last.x, p.y - last.y)
                self.last = p
            } else if hypot(p.x - start.x, p.y - start.y) > 4, let (promise, image, frame) = input.dragItem(start) {
                dragStart = nil // one drag per press
                let item = NSDraggingItem(pasteboardWriter: promise)
                item.setDraggingFrame(frame, contents: image)
                beginDraggingSession(with: [item], event: event, source: self)
            }
        }

        override func mouseUp(with event: NSEvent) {
            if event.clickCount == 1, !moved {
                // wait: a double-click zooms instead
                let tap = DispatchWorkItem { [weak self] in self?.input?.onTap() }
                pendingTap = tap
                DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: tap)
            }
            last = nil
            dragStart = nil
            down = nil
        }

        override func magnify(with event: NSEvent) { input?.onMagnify(event.phase, event.magnification, point(event)) }
        override func smartMagnify(with event: NSEvent) { input?.onDoubleClick(point(event)) }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? .copy : []
        }
    }

    func makeNSView(context: Context) -> InputView { InputView() }
    func updateNSView(_ view: InputView, context: Context) {
        view.input = self
        view.titleBar = titleBar
    }
}

/// The file behind a drag-out, written when the receiving app asks for it.
final class FilePromise: NSFilePromiseProvider, NSFilePromiseProviderDelegate {
    private let name: String
    private let data: @MainActor () async -> Data?

    init(name: String, data: @escaping @MainActor () async -> Data?) {
        self.name = name
        self.data = data
        super.init()
        fileType = UTType.data.identifier
        delegate = self // held weakly; the provider keeps itself alive for the drag
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { name }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        Task { @MainActor in
            guard let data = await data() else { return completionHandler(CocoaError(.fileReadUnknown)) }
            do {
                try data.write(to: url)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }
}

/// The system video player with its floating controls. A click on the picture (not the controls) calls `onTap`.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    let onTap: () -> Void

    /// AVPlayerView keeps clicks to itself, so a window event monitor watches for one that lands on the picture
    /// rather than on the floating controls (buttons in a glass panel).
    final class TapPlayerView: AVPlayerView {
        var onTap: () -> Void = {}
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                if let self, event.window === self.window, event.clickCount == 1, self.onPicture(event) { self.onTap() }
                return event
            }
        }

        private func onPicture(_ event: NSEvent) -> Bool {
            guard let root = window?.contentView?.superview,
                  var view = root.hitTest(root.convert(event.locationInWindow, from: nil)) else { return false }
            while view !== self {
                let name = String(describing: type(of: view))
                if view is NSControl || name.contains("Glass") || name.contains("Movable") { return false }
                guard let up = view.superview else { return false } // not in the player at all
                view = up
            }
            return true
        }
    }

    func makeNSView(context: Context) -> TapPlayerView {
        let view = TapPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: TapPlayerView, context: Context) {
        if view.player !== player { view.player = player }
        view.onTap = onTap
    }
}

/// ⌘I: when, what file, which camera, where and who, from the asset's EXIF in Immich.
/// The description, stars, date and place can be changed here.
struct InfoPanel: View {
    let asset: Asset
    let detail: AssetDetail?
    @Binding var typing: Bool
    /// A person was clicked: show their photos.
    let onPerson: (Person) -> Void
    let onDescribe: (String) -> Void
    let onRate: (Int?) -> Void
    let onDate: () -> Void
    let onPlace: () -> Void
    @State private var draft = ""
    @FocusState private var editing: Bool
    private static let dayStyle: Date.FormatStyle = {
        var s = Date.FormatStyle(date: .complete, time: .omitted)
        s.timeZone = .gmt
        return s
    }()
    private static let timeStyle: Date.FormatStyle = {
        var s = Date.FormatStyle(date: .omitted, time: .shortened)
        s.timeZone = .gmt
        return s
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Button(action: onDate) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(asset.date.formatted(Self.dayStyle)).font(.title3.weight(.semibold))
                        Text(asset.date.formatted(Self.timeStyle)).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Adjust Date and Time…")
                if let detail {
                    TextField("Add a Description", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...8)
                        .focused($editing)
                        .onSubmit { editing = false }
                    Stars(rating: detail.exifInfo?.rating, onRate: onRate)
                    let exif = detail.exifInfo
                    Row(symbol: asset.isVideo ? "video" : "photo", title: detail.originalFileName, lines: [fileLine(exif)])
                    if let camera = camera(exif) {
                        Row(symbol: "camera", title: camera, lines: [exif?.lensModel])
                        let settings = exposure(exif)
                        if !settings.isEmpty {
                            HStack(spacing: 6) {
                                ForEach(settings, id: \.self) { Chip(text: $0) }
                            }
                        }
                    }
                    if let exif, let place = place(exif) {
                        Row(symbol: "mappin.and.ellipse", title: place, lines: [])
                    }
                    if let lat = exif?.latitude, let lon = exif?.longitude {
                        PlaceMap(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon), name: place(exif!))
                            .id("\(asset.id)\(lat)\(lon)")
                    }
                    Button(exif?.latitude == nil ? "Add Location…" : "Change Location…", action: onPlace)
                        .buttonStyle(.link)
                    if let people = detail.people, !people.isEmpty {
                        People(people: people, onPerson: onPerson)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.ultraThinMaterial)
        .environment(\.colorScheme, .dark) // always over the black viewer
        .onChange(of: detail?.exifInfo?.description, initial: true) { if !editing { draft = $1 ?? "" } }
        .onChange(of: editing) {
            typing = editing
            if !editing, let detail, draft != detail.exifInfo?.description ?? "" { onDescribe(draft) } // saved when the field is left
        }
        .onDisappear { typing = false }
    }

    /// 1–5 stars; clicking the current number of stars clears them.
    private struct Stars: View {
        let rating: Int?
        let onRate: (Int?) -> Void

        var body: some View {
            HStack(spacing: 2) {
                ForEach(1...5, id: \.self) { n in
                    Button { onRate(rating == n ? nil : n) } label: {
                        Image(systemName: n <= (rating ?? 0) ? "star.fill" : "star")
                            .foregroundStyle(n <= (rating ?? 0) ? Color.yellow : .secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(rating == n ? "Clear Rating" : "\(n) Stars")
                    .help(rating == n ? "Clear Rating" : "\(n) Stars")
                }
            }
        }
    }

    private func fileLine(_ exif: AssetDetail.Exif?) -> String? {
        var parts: [String] = []
        if let w = exif?.exifImageWidth, let h = exif?.exifImageHeight { parts.append("\(Int(w)) × \(Int(h))") }
        if let w = exif?.exifImageWidth, let h = exif?.exifImageHeight, w * h >= 1_000_000 {
            parts.append((w * h / 1_000_000).formatted(.number.precision(.fractionLength(0))) + " MP")
        }
        if let bytes = exif?.fileSizeInByte { parts.append(Int64(bytes).formatted(.byteCount(style: .file))) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "Apple iPhone 15 Pro", without repeating a make the model already starts with.
    private func camera(_ exif: AssetDetail.Exif?) -> String? {
        let make = exif?.make ?? "", model = exif?.model ?? ""
        if model.isEmpty { return make.isEmpty ? nil : make }
        return make.isEmpty || model.localizedCaseInsensitiveContains(make) ? model : "\(make) \(model)"
    }

    private func exposure(_ exif: AssetDetail.Exif?) -> [String] {
        guard let exif else { return [] }
        var out: [String] = []
        if let f = exif.fNumber { out.append("ƒ/" + f.formatted(.number.precision(.fractionLength(0...1)))) }
        if let t = exif.exposureTime, !t.isEmpty { out.append(t + " s") }
        if let mm = exif.focalLength { out.append(mm.formatted(.number.precision(.fractionLength(0...1))) + " mm") }
        if let iso = exif.iso { out.append("ISO \(Int(iso))") }
        return out
    }

    private func place(_ exif: AssetDetail.Exif) -> String? {
        var parts: [String] = []
        for part in [exif.city, exif.state, exif.country] {
            if let part, !part.isEmpty, !parts.contains(part) { parts.append(part) } // a city that is also its state shows once
        }
        return parts.isEmpty ? nil : parts.joined(separator: String(localized: "place.separator", defaultValue: ", ",
                                                                         comment: "Between city, state and country"))
    }

    private struct Row: View {
        let symbol: String
        let title: String
        let lines: [String?]

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).textSelection(.enabled)
                    ForEach(lines.compactMap { $0 }, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
                }
            }
        }
    }

    private struct Chip: View {
        let text: String
        var body: some View {
            Text(text)
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(.quaternary, in: .capsule)
                .fixedSize()
        }
    }

    /// A small map; click to open the place in Maps.
    private struct PlaceMap: View {
        let coordinate: CLLocationCoordinate2D
        let name: String?

        var body: some View {
            Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 3000, longitudinalMeters: 3000)),
                interactionModes: []) {
                Marker(name ?? "", coordinate: coordinate)
            }
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .onTapGesture {
                let item = MKMapItem(location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude), address: nil)
                item.name = name
                item.openInMaps()
            }
            .help("Open in Maps")
        }
    }

    /// Everyone in the photo, named or not; click one for their photos.
    private struct People: View {
        @Environment(Library.self) private var library
        let people: [Person]
        let onPerson: (Person) -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Label("People", systemImage: "person.2").foregroundStyle(.secondary)
                ForEach(people) { person in
                    Button { onPerson(person) } label: {
                        HStack(spacing: 8) {
                            Thumb(id: person.id, store: library.faces)
                                .frame(width: 26, height: 26)
                                .clipShape(Circle())
                            Text(person.name.isEmpty ? String(localized: "Unnamed") : person.name)
                                .foregroundStyle(person.name.isEmpty ? .secondary : .primary)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show Their Photos")
                }
            }
        }
    }
}

/// The people in the photo as faces over its bottom left corner; click one for their photos.
struct FaceRow: View {
    @Environment(Library.self) private var library
    let people: [Person]
    let onPerson: (Person) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(people) { person in
                    Button { onPerson(person) } label: {
                        HStack(spacing: 6) {
                            Thumb(id: person.id, store: library.faces)
                                .frame(width: 24, height: 24)
                                .clipShape(Circle())
                            if !person.name.isEmpty { Text(person.name).lineLimit(1) }
                        }
                        .padding(.leading, 4)
                        .padding(.trailing, person.name.isEmpty ? 4 : 10)
                        .padding(.vertical, 4)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .help(person.name.isEmpty ? String(localized: "Unnamed") : person.name)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
