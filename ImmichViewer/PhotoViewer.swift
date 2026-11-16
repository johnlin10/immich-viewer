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

/// One photo over the whole window. It grows out of its grid cell and shrinks back into it.
/// ← → or a two-finger swipe step through the timeline, Esc closes. Videos play in place.
/// Pinch or double-click zooms (the original loads for that), ⌘I shows details, ⌘C copies, dragging the photo out saves it.
struct PhotoViewer: View {
    let library: Library
    let assets: [Asset]
    /// Height of the title bar; the photo stays below it, the date sits in it.
    let topInset: CGFloat
    let bridge: GridBridge
    let onClosed: () -> Void

    @State private var index: Int
    @State private var origin: CGRect?
    @State private var image: NSImage?
    @State private var shown = false
    @State private var sliding = false
    /// Horizontal drag or slide of the photo.
    @State private var offset: CGFloat = 0
    /// Where the photo may be, below the title bar and left of the info panel.
    @State private var area = CGRect.zero
    @State private var player: AVPlayer?
    @State private var swipe = SwipeMonitor()
    @State private var detail: AssetDetail?
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

    private static let spring = Animation.spring(duration: 0.35, bounce: 0.1)
    private static let panelWidth: CGFloat = 300
    private static let maxZoom: CGFloat = 8
    private static let dateStyle: Date.FormatStyle = {
        var s = Date.FormatStyle(date: .abbreviated, time: .shortened)
        s.timeZone = .gmt
        return s
    }()

    init(library: Library, assets: [Asset], topInset: CGFloat, bridge: GridBridge, start: ViewerState, onClosed: @escaping () -> Void) {
        self.library = library
        self.assets = assets
        self.topInset = topInset
        self.bridge = bridge
        self.onClosed = onClosed
        _index = State(initialValue: start.index)
        _origin = State(initialValue: start.origin)
        _image = State(initialValue: start.image.map { NSImage(cgImage: $0, size: .zero) })
    }

    var body: some View {
        if assets.indices.contains(index) {
            let asset = assets[index]
            GeometryReader { geo in
                let panel = showInfo && shown ? Self.panelWidth : 0
                let space = CGRect(x: 0, y: topInset, width: max(geo.size.width - panel, 1), height: max(geo.size.height - topInset, 1))
                let fitted = fitted(in: space)
                let rect = shown ? zoomed(fitted).offsetBy(dx: offset, dy: 0) : (origin ?? fitted)
                ZStack {
                    Color.black.opacity(shown ? 1 : 0)
                    if let image {
                        Image(nsImage: image).resizable().scaledToFill()
                            .frame(width: rect.width, height: rect.height).clipped()
                            .position(x: rect.midX, y: rect.midY)
                            .opacity(shown || origin != nil ? 1 : 0)
                            // an enlarged photo stays in its area; otherwise it may fly over the title bar
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
                        dragItem: { point in
                            guard !asset.isVideo, let image, rect.contains(point) else { return nil }
                            return (promise(for: asset), image, rect)
                        })
                    if let player, shown {
                        // over the thumbnail, which shows until the first frame arrives
                        PlayerView(player: player)
                            .frame(width: fitted.width, height: fitted.height)
                            .position(x: fitted.midX + offset, y: fitted.midY)
                    }
                    if loadingFull {
                        ProgressView().controlSize(.small)
                            .padding(8)
                            .glassEffect(.regular, in: .circle)
                            .position(x: space.maxX - 28, y: space.maxY - 28)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if showInfo && shown {
                        InfoPanel(asset: asset, detail: detail)
                            .frame(width: Self.panelWidth, height: space.height)
                            .offset(y: topInset)
                            .transition(.move(edge: .trailing))
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
                    Button("") { go(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
                    Button("") { go(1) }.keyboardShortcut(.rightArrow, modifiers: [])
                    Button("", action: escape).keyboardShortcut(.cancelAction)
                    Button("") { asset.isVideo ? togglePlay() : close() }.keyboardShortcut(.space, modifiers: [])
                    Button("") { copy(asset) }.keyboardShortcut("c")
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
                        .opacity(shown ? 1 : 0)
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { withAnimation(Self.spring) { showInfo.toggle() } } label: {
                        Image(systemName: showInfo ? "info.circle.fill" : "info.circle")
                    }
                    .keyboardShortcut("i")
                    .help("Info (⌘I)")
                    Button { library.openInBrowser(asset) } label: { Image(systemName: "safari") }
                        .help("Open in Browser (Edit, Delete)")
                    Button(action: close) { Image(systemName: "xmark") }
                        .help("Close (Esc)")
                }
            }
            .onAppear {
                swipe.start(onPan: { panBy($0, $1) }, onChange: drag, onEnd: dragEnded)
                withAnimation(Self.spring) { shown = true }
            }
            .onDisappear {
                swipe.stop()
                player?.pause()
            }
            .task(id: asset.id) {
                detail = nil
                detail = await library.detail(asset)
            }
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
        origin = bridge.reveal(index) // the grid may have scrolled; nil fades out instead
        offset = 0
        resetZoom()
        player?.pause()
        player = nil // the thumbnail flies back into the grid
        withAnimation(Self.spring) { shown = false } completion: { onClosed() }
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
        let width = area.width + (showInfo ? Self.panelWidth : 0)
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

/// Two-finger horizontal swipes anywhere in the window, also over the video player; scrolling pans a zoomed photo.
/// While the viewer is open it takes every scroll event, so the grid underneath stays put.
@MainActor
final class SwipeMonitor {
    private var monitor: Any?
    private var dx: CGFloat = 0
    private var horizontal: Bool?

    func start(onPan: @escaping (CGFloat, CGFloat) -> Bool, onChange: @escaping (CGFloat) -> Void, onEnd: @escaping (CGFloat) -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            if self?.horizontal != true, onPan(event.scrollingDeltaX, event.scrollingDeltaY) { return nil }
            guard let self, event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty else { return nil }
            if event.phase.contains(.began) {
                dx = 0
                horizontal = nil
            }
            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                if horizontal == true { onEnd(dx) }
                horizontal = nil
                return nil
            }
            if horizontal == nil, event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0 {
                horizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            }
            if horizontal == true {
                dx += event.scrollingDeltaX
                onChange(dx)
            }
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// Mouse and trackpad over the photo: pinch, double-click, drag to pan or to drag the photo out.
/// Also keeps clicks from reaching the grid underneath. Coordinates match SwiftUI's (origin top left).
struct ViewerInput: NSViewRepresentable {
    let isZoomed: () -> Bool
    let onMagnify: (NSEvent.Phase, CGFloat, CGPoint) -> Void
    let onDoubleClick: (CGPoint) -> Void
    let onPan: (CGFloat, CGFloat) -> Bool
    /// What to drag out from a point: the promised file, its picture and where it is.
    let dragItem: (CGPoint) -> (NSFilePromiseProvider, NSImage, CGRect)?

    final class InputView: NSView, NSDraggingSource {
        var input: ViewerInput?
        private var last: CGPoint?
        private var dragStart: CGPoint?
        override var isFlipped: Bool { true }

        private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

        override func mouseDown(with event: NSEvent) {
            last = point(event)
            dragStart = last
            if event.clickCount == 2 { input?.onDoubleClick(point(event)) }
        }

        override func mouseDragged(with event: NSEvent) {
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
            last = nil
            dragStart = nil
        }

        override func magnify(with event: NSEvent) { input?.onMagnify(event.phase, event.magnification, point(event)) }
        override func smartMagnify(with event: NSEvent) { input?.onDoubleClick(point(event)) }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? .copy : []
        }
    }

    func makeNSView(context: Context) -> InputView { InputView() }
    func updateNSView(_ view: InputView, context: Context) { view.input = self }
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

/// The system video player with its floating controls.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

/// ⌘I: when, what file, which camera, where and who, from the asset's EXIF in Immich.
struct InfoPanel: View {
    let asset: Asset
    let detail: AssetDetail?
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
                VStack(alignment: .leading, spacing: 2) {
                    Text(asset.date.formatted(Self.dayStyle)).font(.title3.weight(.semibold))
                    Text(asset.date.formatted(Self.timeStyle)).foregroundStyle(.secondary)
                }
                if let detail {
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
                            .id(asset.id)
                    }
                    if let people = detail.people, !people.isEmpty {
                        People(people: people)
                    }
                    if let text = exif?.description, !text.isEmpty {
                        Text(text).textSelection(.enabled)
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

    private struct People: View {
        @Environment(Library.self) private var library
        let people: [Person]

        var body: some View {
            let named = people.filter { !$0.name.isEmpty }
            VStack(alignment: .leading, spacing: 8) {
                Label("People", systemImage: "person.2").foregroundStyle(.secondary)
                ForEach(named) { person in
                    HStack(spacing: 8) {
                        Thumb(id: person.id, store: library.faces)
                            .frame(width: 26, height: 26)
                            .clipShape(Circle())
                        Text(person.name)
                    }
                }
                if named.count < people.count {
                    Text("Plus \(people.count - named.count) unnamed").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }
}
