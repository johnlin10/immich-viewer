#if os(iOS)
import AVKit
import CoreLocation
import SwiftUI

/// The iOS photo page: the grid (`PhoneGrid`), the date capsule, Select, and the ⋯ menu with the filter, sort and
/// grouping, and what can be done to the chosen photos.
/// Same initializer as the Mac's, so the shared person, album and tag pages use it unchanged.
struct TimelineBrowser: View {
    @Environment(Library.self) private var library
    @Environment(\.undoManager) private var undo
    let title: String
    let subtitle: String
    let assets: [Asset]
    /// Changes whenever `assets` is replaced, so the grid regroups.
    let revision: Int
    let context: BrowserContext
    @AppStorage("newestFirst") private var newestFirst = true
    @AppStorage("grouping") private var grouping = Grouping.day
    @AppStorage("phoneColumns") private var columns = 4
    /// Not kept: every page opens showing everything.
    @State private var filter = PhotoFilter()
    @State private var list: [Asset] = []
    @State private var sections: [Section] = []
    @State private var dataID = 0
    /// The first photo at the top of the screen, for the date capsule.
    @State private var top = 0
    /// A face in the photo view was tapped.
    @State private var person: Person?
    /// Select mode: a tap checks or unchecks a photo instead of opening it.
    @State private var selecting = false
    @State private var chosen: Set<String> = []
    @State private var editor = PhotoEditor()

    var body: some View {
        ZStack(alignment: .topLeading) {
            PhoneGrid(library: library, assets: list, sections: sections, headers: grouping != .none,
                      pinHeaders: grouping == .day, dataID: dataID, columns: columns, context: context,
                      selecting: selecting, chosen: chosen,
                      handlers: PhoneGrid.Handlers(
                        refresh: context == .library ? { await library.refresh() } : nil,
                        onColumns: { columns = $0 }, onTop: { top = $0 }, onPerson: { person = $0 },
                        onToggle: { id in
                            if chosen.remove(id) == nil { chosen.insert(id) }
                        },
                        onSelect: { id in
                            chosen = [id]
                            setSelecting(true)
                        },
                        onAction: { act($0, on: $1) }))
                .ignoresSafeArea()
            if grouping != .day, list.indices.contains(top) { // by day, the pinned header shows the date
                Text(list[top].date.formatted(Self.capsuleStyle))
                    .font(.headline).monospacedDigit()
                    .padding(.horizontal, 14)
                    .frame(height: 32)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.leading, 12)
                    .padding(.top, 6)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if filter.isActive, list.isEmpty, !assets.isEmpty {
                ContentUnavailableView("No Matches", systemImage: "line.3.horizontal.decrease.circle")
            }
        }
        .toolbar {
            // two items swapped inside an animation: the toolbar morphs the glass from "Select" into ✕ and back
            if selecting {
                ToolbarItem(placement: .primaryAction) {
                    Button("Cancel", systemImage: "xmark") { setSelecting(false) }
                }
            } else {
                ToolbarItem(placement: .primaryAction) {
                    Button("Select") { setSelecting(true) }.disabled(list.isEmpty)
                }
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if selecting, !chosen.isEmpty {
                        let picked = list.filter { chosen.contains($0.id) }
                        SwiftUI.Section {
                            PhotoMenu(library: library, count: picked.count, allFavorite: picked.allSatisfy { $0.isFavorite == true },
                                      context: context) { act($0, on: picked) }
                        }
                    }
                    SwiftUI.Section {
                        Menu {
                            Toggle(isOn: $filter.photos) { Label("Photos", systemImage: "photo") }
                            Toggle(isOn: $filter.videos) { Label("Videos", systemImage: "video") }
                            Toggle(isOn: $filter.live) { Label("Live Photos", systemImage: "livephoto") }
                            Divider()
                            Toggle(isOn: $filter.favorites) { Label("Favorites", systemImage: "heart") }
                            Divider()
                            Button("Clear Filters", systemImage: "xmark.circle") { filter = PhotoFilter() }.disabled(!filter.isActive)
                        } label: {
                            Label("Filter", systemImage: filter.isActive ? "line.3.horizontal.decrease.circle.fill"
                                                                         : "line.3.horizontal.decrease.circle")
                        }
                        Picker(selection: $newestFirst) {
                            Label("Newest First", systemImage: "arrow.down").tag(true)
                            Label("Oldest First", systemImage: "arrow.up").tag(false)
                        } label: {
                            Label("Sort", systemImage: "arrow.up.arrow.down")
                        }
                        .pickerStyle(.menu)
                        Picker(selection: $grouping) {
                            ForEach(Grouping.allCases, id: \.self) { Text($0.label).tag($0) }
                        } label: {
                            Label("Group By", systemImage: "square.grid.3x3")
                        }
                        .pickerStyle(.menu)
                    }
                    CollectionMenu(library: library, context: context, editor: editor, undo: undo)
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
        }
        .pageBar() // the grid sets its own soft edge
        .navigationTitle(title)
        .navigationSubtitle(selecting ? (chosen.isEmpty ? String(localized: "Select Items") : String(localized: "\(chosen.count) selected"))
                            : countSubtitle(subtitle, shown: list.count, filtered: filter.isActive))
        .navigationDestination(item: $person) { CollectionTimeline(context: .person($0.id), fallbackTitle: $0.name) }
        .photoEditor(editor, library: library, undo: undo)
        .onChange(of: revision, initial: true) { regroup() }
        .onChange(of: grouping) { regroup() }
        .onChange(of: newestFirst) { regroup() }
        .onChange(of: filter) { regroup() }
        .onChange(of: selecting) { if !selecting { chosen = [] } }
    }

    private static let capsuleStyle: Date.FormatStyle = {
        var style = Date.FormatStyle(date: .long, time: .omitted)
        style.timeZone = .gmt // wall-clock dates kept as UTC
        return style
    }()

    /// Select mode ends once something is done to the photos; for Delete, once they are gone (it can be cancelled).
    private func act(_ action: PhotoAction, on picked: [Asset]) {
        editor.perform(action, on: picked, context: context, library: library, undo: undo)
        if case .trash = action {} else { setSelecting(false) }
    }

    /// In or out of select mode, animated: the button morphs and the subtitle changes with it.
    private func setSelecting(_ on: Bool) {
        withAnimation(.smooth) { selecting = on }
    }

    private func regroup() {
        list = filter.apply(newestFirst ? assets : assets.reversed())
        sections = makeSections(list, by: grouping)
        dataID += 1
        if !chosen.isEmpty {
            let shown = Set(list.map(\.id))
            chosen.formIntersection(shown)
            if chosen.isEmpty { setSelecting(false) } // all deleted, or filtered out
        }
    }
}

/// One photo at a time, like the Mac viewer: swipe for the next, pinch or double-tap to zoom, ✕ or swipe down to close.
/// A tap hides the bars and faces and turns the background black; another brings them back. ⓘ shows the details.
struct PhotoPager: View {
    @Environment(Library.self) private var library
    @Environment(\.undoManager) private var undo
    let assets: [Asset]
    /// Counts up when `assets` is replaced after an edit.
    let version: Int
    @Binding var position: Int?
    let context: BrowserContext
    let close: () -> Void
    /// A face or a person in the details was tapped: close and show their photos.
    let onPerson: (Person) -> Void
    /// The photos that can be swiped to, around the one opened. Kept in @State: a window that moved with every swipe
    /// removed pages before the current one and the pager jumped ahead.
    // ponytail: a fixed window of 2,000, so a 100k+ library doesn't build a pager of every photo; recentre it if people swipe that far
    @State private var window: Range<Int>
    @State private var chromeHidden = false
    @State private var showInfo = false
    @State private var detail: AssetDetail?
    /// The shown photo's moving part, when it's a Live Photo. Long-press the photo or tap LIVE to play it.
    @State private var livePlayer: AVPlayer?
    @State private var livePlaying = false
    /// The shown video's player, for the controls under it, and whether it's playing.
    @State private var video: (id: String, player: AVPlayer)?
    @State private var videoRunning = false
    @AppStorage("videoMuted") private var muted = false
    @State private var editor = PhotoEditor()
    /// The details sheet's own, for the changes made from it: a sheet can't come from under another sheet.
    @State private var infoEditor = PhotoEditor()

    /// Asset dates are wall-clock time stored as UTC.
    private static let dayStyle = gmt(Date.FormatStyle(date: .abbreviated, time: .omitted))
    private static let timeStyle = gmt(Date.FormatStyle(date: .omitted, time: .shortened))
    private static func gmt(_ style: Date.FormatStyle) -> Date.FormatStyle {
        var style = style
        style.timeZone = .gmt
        return style
    }

    init(assets: [Asset], version: Int, position: Binding<Int?>, context: BrowserContext, close: @escaping () -> Void,
         onPerson: @escaping (Person) -> Void) {
        self.assets = assets
        self.version = version
        _position = position
        self.context = context
        self.close = close
        self.onPerson = onPerson
        let start = position.wrappedValue ?? 0
        _window = State(initialValue: max(0, start - 1000)..<min(assets.count, start + 1000))
    }

    private var asset: Asset? { position.flatMap { assets.indices.contains($0) ? assets[$0] : nil } }
    /// Where the photo was taken, for Set Location.
    private var place: CLLocationCoordinate2D? {
        detail?.exifInfo.flatMap { e in e.latitude.flatMap { lat in e.longitude.map { CLLocationCoordinate2D(latitude: lat, longitude: $0) } } }
    }
    private var shownVideo: AVPlayer? { video != nil && video?.id == asset?.id ? video?.player : nil }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(window.clamped(to: 0..<assets.count), id: \.self) { i in // the list may have just got shorter
                    PhonePhoto(asset: assets[i], cached: library.thumbs.anyCached(assets[i].id), playing: i == position) {
                        chromeHidden.toggle()
                    } onPlayer: { player in
                        video = (assets[i].id, player)
                    } onSwipeUp: {
                        chromeHidden = false
                        showInfo = true
                    } onPress: { pressed in
                        livePlaying = pressed && livePlayer != nil
                    }
                        .id(assets[i].id) // another photo at this place after an edit: start over
                        .containerRelativeFrame([.horizontal, .vertical])
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $position)
        .scrollIndicators(.hidden)
        .ignoresSafeArea()
        .overlay {
            if let livePlayer { LiveVideo(player: livePlayer, playing: $livePlaying).ignoresSafeArea() }
        }
        .background(chromeHidden ? Color.black : Color(.systemBackground))
        .overlay(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                if let shownVideo {
                    VideoControls(player: shownVideo, running: $videoRunning).id(ObjectIdentifier(shownVideo))
                }
                if let people = detail?.people, !people.isEmpty { FaceRow(people: people, onPerson: open) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .opacity(chromeHidden ? 0 : 1)
            .allowsHitTesting(!chromeHidden)
        }
        // while a video plays, the bars and its controls go away after a moment, as in Photos; paused, they stay
        .task(id: videoRunning && !chromeHidden) {
            guard videoRunning, !chromeHidden else { return }
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { chromeHidden = true }
        }
        .overlay(alignment: .topLeading) {
            if livePlayer != nil {
                Button { livePlaying = true } label: { LiveBadge() }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .opacity(chromeHidden ? 0 : 1)
                    .allowsHitTesting(!chromeHidden)
            }
        }
        // Our own bar rather than the navigation bar, so it only fades, like the Mac's. A safe-area bar keeps the
        // system's progressive blur under it when a zoomed photo runs beneath.
        .safeAreaBar(edge: .top) {
            ZStack {
                HStack {
                    Button(action: close) { Label("Close", systemImage: "xmark").circleGlass() }
                    Spacer()
                    if let asset {
                        Menu {
                            PhotoMenu(library: library, count: 1, allFavorite: asset.isFavorite == true, context: context) {
                                editor.perform($0, on: [asset], context: context, library: library, undo: undo, place: place)
                            }
                            Divider()
                            Button("Info", systemImage: "info.circle") { showInfo = true }
                            Button("Open in Browser", systemImage: "safari") { library.openInBrowser(asset) }
                        } label: {
                            Label("More", systemImage: "ellipsis").circleGlass()
                        }
                    }
                }
                .buttonStyle(.plain)
                if let asset { // two lines, like Photos, so it fits between the buttons
                    VStack(spacing: 0) {
                        Text(asset.date.formatted(Self.dayStyle)).font(.subheadline.bold())
                        Text(asset.date.formatted(Self.timeStyle)).font(.caption)
                    }
                    .monospacedDigit()
                    .padding(.horizontal, 16)
                    .frame(height: 44)
                    .glassEffect(.regular, in: .capsule)
                }
            }
            .padding(.horizontal, 16)
            .opacity(chromeHidden ? 0 : 1)
            .allowsHitTesting(!chromeHidden)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .scrollEdgeEffectHidden(chromeHidden, for: .top)
        .animation(.easeInOut(duration: 0.25), value: chromeHidden)
        .statusBarHidden(chromeHidden)
        .sheet(isPresented: $showInfo) {
            if let asset {
                let edit = { (action: PhotoAction) in
                    infoEditor.perform(action, on: [asset], context: context, library: library, undo: undo, place: place)
                }
                InfoPanel(asset: asset, detail: detail, typing: .constant(false), onPerson: open,
                          onDescribe: { text in
                              Task { await library.describe(asset.id, text, was: detail?.exifInfo?.description ?? "", undo: undo) }
                          },
                          onRate: { stars in Task { await library.rate(asset.id, stars, was: detail?.exifInfo?.rating, undo: undo) } },
                          onDate: { edit(.adjustDate) },
                          onPlace: { edit(.setLocation) },
                          onAddTag: { edit(.addTag) },
                          onUntag: { tag in Task { await library.untag([asset.id], tag, undo: undo) } },
                          onChangePerson: { person in
                              if let face = person.faces?.first { edit(.changePerson(face: face.id, from: person.id)) }
                          })
                    .photoEditor(infoEditor, library: library, undo: undo)
                    .presentationDetents([.medium, .large])
                    .presentationBackgroundInteraction(.enabled(upThrough: .medium)) // keep swiping photos, like the Mac's panel
            }
        }
        .photoEditor(editor, library: library, undo: undo)
        .onChange(of: library.edits) { // what the server made of a change: stars, description, tags, people
            Task { if let asset, let new = await library.detail(asset), asset.id == self.asset?.id { detail = new } }
        }
        .onChange(of: version) { // recentred, in case the photo moved far (a new date)
            let start = position ?? 0
            window = max(0, start - 1000)..<min(assets.count, start + 1000)
        }
        .task(id: asset?.id) {
            detail = nil
            livePlaying = false
            livePlayer = nil
            guard let asset else { return }
            let new = await library.detail(asset)
            guard !Task.isCancelled else { return }
            detail = new
            if !asset.isVideo, let id = new?.livePhotoVideoId, let player = library.player(video: id) {
                player.isMuted = muted
                livePlayer = player // loads now, so a press plays at once
            }
        }
    }

    private func open(_ person: Person) { onPerson(person) }
}

private extension View {
    /// The photo view's round glass buttons, all the same size whatever the symbol.
    func circleGlass() -> some View {
        labelStyle(.iconOnly)
            .font(.title3)
            .frame(width: 44, height: 44)
            .contentShape(.circle)
            .glassEffect(.regular.interactive(), in: .circle)
    }
}

/// One photo (thumbnail at once, then the large preview) or a video, which plays while it's the one showing.
private struct PhonePhoto: View {
    @Environment(Library.self) private var library
    let asset: Asset
    let playing: Bool
    let onTap: () -> Void
    /// The video's player, once it's the one showing: the controls under it are the pager's, with the bars.
    let onPlayer: (AVPlayer) -> Void
    let onSwipeUp: () -> Void
    /// A long press starts (true) or ends (false): plays a Live Photo.
    let onPress: (Bool) -> Void
    @State private var image: UIImage?
    @State private var player: AVPlayer?

    /// `cached`: the grid's thumbnail, usually still in memory, shown at once so a photo never opens on a spinner.
    init(asset: Asset, cached: CGImage?, playing: Bool, onTap: @escaping () -> Void, onPlayer: @escaping (AVPlayer) -> Void,
         onSwipeUp: @escaping () -> Void, onPress: @escaping (Bool) -> Void) {
        self.asset = asset
        self.playing = playing
        self.onTap = onTap
        self.onPlayer = onPlayer
        self.onSwipeUp = onSwipeUp
        self.onPress = onPress
        _image = State(initialValue: cached.map { UIImage(cgImage: $0) })
    }
    @AppStorage("videoAutoplay") private var autoplay = true
    @AppStorage("videoMuted") private var muted = false
    @AppStorage("videoLoop") private var loop = false

    var body: some View {
        Group {
            if asset.isVideo, let player {
                ZStack { // the still until the first frame; the page's background around it, not the player's black
                    if let image { Image(uiImage: image).resizable().scaledToFit() }
                    PlayerLayer(player: player, gravity: .resizeAspect)
                }
                .contentShape(.rect)
                .onTapGesture(perform: onTap)
            } else if let image {
                ZoomableImage(image: image, onTap: onTap, onSwipeUp: onSwipeUp, onPress: onPress)
            } else {
                ProgressView()
            }
        }
        .task(id: asset.id) {
            guard let api = library.api else { return }
            if image == nil, let thumb = await library.thumbs.image(asset.id, pixels: 0, api: api) { image = UIImage(cgImage: thumb) }
            if asset.isVideo {
                player = library.player(for: asset)
                player?.isMuted = muted
                if playing, let player {
                    onPlayer(player)
                    if autoplay { player.play() }
                }
                if loop, let item = player?.currentItem {
                    for await _ in NotificationCenter.default.notifications(named: AVPlayerItem.didPlayToEndTimeNotification, object: item) {
                        await player?.seek(to: .zero)
                        player?.play()
                    }
                }
            } else if let data = try? await api.thumbnail(asset.id, size: "preview"), let big = UIImage(data: data) {
                image = big
            }
        }
        .onChange(of: playing) {
            if playing, let player { onPlayer(player) }
            if playing, autoplay { player?.play() } else { player?.pause() }
        }
        .onDisappear { player?.pause() }
    }
}

/// Photos-style controls under a video, shown and hidden with the bars: play or pause, a scrubber with the time
/// left, and sound on or off.
private struct VideoControls: View {
    let player: AVPlayer
    @Binding var running: Bool
    @AppStorage("videoMuted") private var muted = false
    @State private var time = 0.0
    @State private var duration = 0.0
    @State private var scrubbing = false
    @State private var resume = false

    var body: some View {
        HStack(spacing: 12) {
            Button(running ? "Pause" : "Play", systemImage: running ? "pause.fill" : "play.fill") {
                if running {
                    player.pause()
                } else {
                    if duration > 0, time >= duration - 0.1 { player.seek(to: .zero) }
                    player.play()
                }
            }
            .contentTransition(.symbolEffect(.replace))
            Slider(value: $time, in: 0...max(duration, 0.1)) { editing in
                scrubbing = editing
                if editing {
                    resume = running // still while scrubbing, like Photos
                    player.pause()
                } else if resume {
                    player.play()
                }
            }
            .onChange(of: time) {
                if scrubbing { player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
            }
            Text(Duration.seconds(max(0, duration - time).rounded()).formatted(.time(pattern: .minuteSecond)))
                .font(.caption.monospacedDigit())
            Button(muted ? "Unmute" : "Mute", systemImage: muted ? "speaker.slash.fill" : "speaker.wave.2.fill") {
                muted.toggle()
                player.isMuted = muted
            }
            .contentTransition(.symbolEffect(.replace))
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .frame(height: 44)
        .glassEffect(.regular, in: .capsule)
        .onReceive(player.publisher(for: \.timeControlStatus)) { running = $0 != .paused }
        .onDisappear { running = false }
        .task {
            // ponytail: polls the time 5 times a second; a periodic time observer if this ever shows up in a profile
            while !Task.isCancelled {
                if !scrubbing, player.currentTime().seconds.isFinite { time = player.currentTime().seconds }
                if let d = player.currentItem?.duration.seconds, d.isFinite { duration = d }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }
}

/// Pinch and double-tap zoom, then drag around, like Photos. Swiping up (when not zoomed) shows the details. A UIScrollView, since SwiftUI has no zooming scroll view.
private struct ZoomableImage: UIViewRepresentable {
    let image: UIImage
    let onTap: () -> Void
    let onSwipeUp: () -> Void
    let onPress: (Bool) -> Void

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.maximumZoomScale = 4
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        let view = UIImageView(image: image)
        view.contentMode = .scaleAspectFit
        view.frame = scroll.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.addSubview(view)
        context.coordinator.view = view
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        tap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(tap)
        let single = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.singleTap))
        single.require(toFail: tap) // a double tap zooms instead
        let press = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.press(_:)))
        press.minimumPressDuration = 0.3
        press.delegate = context.coordinator
        scroll.addGestureRecognizer(press)
        single.require(toFail: press) // holding plays a Live Photo, it doesn't hide the bars
        scroll.addGestureRecognizer(single)
        let up = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.swipeUp(_:)))
        up.delegate = context.coordinator
        scroll.addGestureRecognizer(up)
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.view?.image = image // the sharper preview replaces the thumbnail
        context.coordinator.onTap = onTap
        context.coordinator.onSwipeUp = onSwipeUp
        context.coordinator.onPress = onPress
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        weak var view: UIImageView?
        var onTap: () -> Void = {}
        var onSwipeUp: () -> Void = {}
        var onPress: (Bool) -> Void = { _ in }

        @objc func singleTap() { onTap() }

        @objc func press(_ press: UILongPressGestureRecognizer) {
            switch press.state {
            case .began: onPress(true)
            case .ended, .cancelled, .failed: onPress(false)
            default: break
            }
        }

        /// Only a mostly-upward drag on an unzoomed photo: sideways pages, downward closes, zoomed pans.
        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            guard let pan = gesture as? UIPanGestureRecognizer, let scroll = pan.view as? UIScrollView else { return true }
            let v = pan.velocity(in: scroll)
            return scroll.zoomScale <= 1 && v.y < 0 && abs(v.y) > abs(v.x) * 1.5
        }

        /// The pager's and the presentation's own gestures otherwise keep a long press from ever starting.
        func gestureRecognizer(_ gesture: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            gesture is UILongPressGestureRecognizer
        }

        @objc func swipeUp(_ pan: UIPanGestureRecognizer) {
            if pan.state == .ended, pan.translation(in: pan.view).y < -40 { onSwipeUp() }
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { view }

        @objc func doubleTap(_ tap: UITapGestureRecognizer) {
            guard let scroll = tap.view as? UIScrollView else { return }
            if scroll.zoomScale > 1 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let point = tap.location(in: view)
                let size = CGSize(width: scroll.bounds.width / 2.5, height: scroll.bounds.height / 2.5)
                scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height),
                            animated: true)
            }
        }
    }
}
#endif
