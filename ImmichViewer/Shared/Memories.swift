import AVFoundation
import ImageIO
import SwiftUI

/// A memory's first photo with its title over a fade, like Photos'. Opens the player: on iOS it grows out of the card to
/// full screen and shrinks back into it (also following a swipe down); on the Mac it grows the same way over the page.
struct MemoryCard: View {
    @Environment(Library.self) private var library
    let memory: Memory
    #if os(iOS)
    @State private var playing = false
    @Namespace private var zoom
    #else
    @Environment(\.openMemory) private var openMemory
    @Environment(\.memoryShowing) private var showing
    /// Where the card is in the window, for the player to grow from.
    @State private var frame = CGRect.zero
    #endif

    var body: some View {
        #if os(macOS)
        Button { openMemory?(MemoryOpen(memory: memory, source: frame)) } label: { cover }
            .buttonStyle(.plain)
            .opacity(showing == memory.id ? 0 : 1) // the player stands in for it, grown out of this place
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
        #else
        Button { playing = true } label: { cover }
            .buttonStyle(.plain)
            .matchedTransitionSource(id: memory.id, in: zoom) { $0.clipShape(.rect(cornerRadius: 14)) }
            .fullScreenCover(isPresented: $playing) {
                NavigationStack { MemoryPlayer(memory: memory).collectionDestinations() }
                    .navigationTransition(.zoom(sourceID: memory.id, in: zoom))
            }
        #endif
    }

    private var cover: some View {
        Thumb(id: memory.assets[0].id, store: library.thumbs)
            .aspectRatio(1.4, contentMode: .fit)
            .overlay(alignment: .bottomLeading) { MemoryCaption(memory: memory) }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
    }
}

/// The card's title and date over a fade; the Mac's player wears it too while on the card, so it lands as the card.
private struct MemoryCaption: View {
    let memory: Memory

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(memory.title).font(.headline)
            Text(memory.subtitle).font(.caption)
        }
        .foregroundStyle(.white)
        .padding(12)
        .padding(.top, 36)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom))
    }
}

/// Every memory the server has that is due, newest first (Collections shows only today's).
struct MemoryGrid: View {
    @Environment(Library.self) private var library
    @State private var memories: [Memory]?
    @State private var failed = false
    @State private var open: MemoryOpen?

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16)], spacing: 16) {
                ForEach(memories ?? []) { MemoryCard(memory: $0) }
            }
            .padding(20)
        }
        .pageBar()
        .overlay {
            if failed {
                ContentUnavailableView("Can’t Load", systemImage: "exclamationmark.triangle",
                                       description: Text("The key needs the memory.read permission."))
            } else if let memories {
                if memories.isEmpty { ContentUnavailableView("No Memories", systemImage: "memories") }
            } else {
                ProgressView()
            }
        }
        .memoryHost($open, title: "Memories")
        .task(id: library.serverURL) {
            guard let api = library.api else { return }
            do {
                memories = try await api.memories()
                failed = false
            } catch is CancellationError {
            } catch let e as URLError where e.code == .cancelled {
            } catch {
                failed = true
            }
        }
    }
}

/// A memory played full screen like a story: a bar per photo, 5 seconds a photo, a video to its end. Tap the sides
/// (or ← →) to move, the middle (or Space) to pause. The last photo stays up, paused.
struct MemoryPlayer: View {
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("videoMuted") private var muted = false
    let memory: Memory
    /// The card's place in the window (the Mac's): the player grows out of it and shrinks back into it.
    var source: CGRect?
    /// Closes it, on the Mac, once it has shrunk into the card.
    var onClose: (() -> Void)?
    /// Grown to fill the page; until then it sits on the card.
    @State private var expanded = false
    /// The growing is over: a video's layer, which can't animate its size, shows only then.
    @State private var settled = false
    @State private var index = 0
    /// Bumped to play the same photo again.
    @State private var round = 0
    /// How much of the photo showing has played, 0 to 1.
    @State private var progress = 0.0
    @State private var paused = false
    @State private var player: AVPlayer?
    /// Set while its grid is on top, which pauses it.
    @State private var covered = MemoryPhotos.Covered()
    #if os(macOS)
    @FocusState private var focused: Bool
    #endif

    private var last: Int { memory.assets.count - 1 }
    private var open: Bool { source == nil || expanded }
    private static let photoSeconds = 5.0

    var body: some View {
        GeometryReader { safe in // inside the safe area: how far down the status or title bar reaches
            GeometryReader { page in
                // on the card's place until grown: every size below is worked out here, so all of them animate together
                let full = page.frame(in: .global)
                let rect = open ? CGRect(origin: .zero, size: page.size)
                                : source!.offsetBy(dx: -full.minX, dy: -full.minY)
                ZStack {
                    Color.black.opacity(open ? 1 : 0)
                    stage(size: rect.size, top: safe.safeAreaInsets.top)
                        .frame(width: rect.width, height: rect.height)
                        .clipShape(.rect(cornerRadius: open ? 0 : 14))
                        .position(x: rect.midX, y: rect.midY)
                }
            }
            #if os(macOS)
            .ignoresSafeArea(edges: .vertical) // up into the title bar, like the single photo view; the sidebar stays
            #else
            .ignoresSafeArea() // the whole screen: the fade behind the bars starts at its top edge
            #endif
        }
        #if os(iOS)
        .background(Color.black)
        .navigationTitle(memory.title)
        #endif
        .task(id: [index, round]) { await play() }
        .onChange(of: paused) { if paused { player?.pause() } else { player?.play() } }
        .onDisappear { player?.pause() }
        .onChange(of: covered.value) { if covered.value { paused = true } }
        #if os(macOS)
        .toolbar { // the page's own are hidden meanwhile
            ToolbarItem(placement: .navigation) { Button("Back", systemImage: "chevron.backward", action: close) }
            ToolbarItemGroup {
                Button("Pause / Play", systemImage: paused ? "play.fill" : "pause.fill", action: togglePause)
                    .help("Pause / Play")
                NavigationLink(value: MemoryPhotos(memory: memory, covered: covered)) { Label("Show All Photos", systemImage: "square.grid.2x2") }
                    .help("Show All Photos")
            }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear {
            focused = true
            withAnimation(reduceMotion ? nil : Self.grow) { expanded = true } completion: { settled = true }
        }
        .onKeyPress(.leftArrow) { go(index - 1); return .handled }
        .onKeyPress(.rightArrow) { go(index + 1); return .handled }
        .onKeyPress(.space) { togglePause(); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
        #else
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden()
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        #endif
    }

    /// The memory's view at `size`: photos, bars and title (`top` down, clear of the title bar).
    private func stage(size: CGSize, top: CGFloat) -> some View {
        let asset = memory.assets[index]
        let video = asset.isVideo && (source == nil || settled) ? player : nil
        return ZStack {
            MemorySlide(asset: asset, player: video, size: size, fill: !open,
                        first: index == 0 ? library.thumbs.anyCached(asset.id) : nil) // the card's picture, at once
                .id(index)
                .transition(.opacity)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: index)
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .bottomLeading) { if source != nil { MemoryCaption(memory: memory).opacity(open ? 0 : 1) } }
        .overlay(alignment: .top) { header(top: top).opacity(open ? 1 : 0) }
        .overlay { // paused: say so, and that a tap plays on
            if paused, open {
                Image(systemName: "play.fill").font(.largeTitle).foregroundStyle(.white)
                    .frame(width: 80, height: 80)
                    .background(.black.opacity(0.4), in: .circle)
                    .allowsHitTesting(false)
                    .transition(.identity) // gone at once when it starts shrinking
            }
        }
        .contentShape(Rectangle())
        .gesture(SpatialTapGesture().onEnded { tap(at: $0.location.x, width: size.width) })
    }

    /// The progress bars, with the title under them, `top` down from the stage's top edge (clear of the status or
    /// title bar); the fade behind them starts at the edge.
    private func header(top: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                ForEach(memory.assets.indices, id: \.self) { i in
                    let value = i < index ? 1 : i == index ? progress : 0
                    Capsule().fill(.white.opacity(0.3)).frame(height: 3)
                        .overlay(alignment: .leading) { GeometryReader { Capsule().fill(.white).frame(width: $0.size.width * value) } }
                }
            }
            #if os(iOS) // the Mac has them in the title bar
            HStack(alignment: .top, spacing: 12) {
                Button("Close", systemImage: "xmark") { dismiss() }.circleGlass()
                VStack(alignment: .leading, spacing: 2) {
                    Text(memory.title).font(.headline)
                    Text(memory.subtitle).font(.caption)
                }
                .shadow(radius: 4)
                Spacer()
                NavigationLink(value: MemoryPhotos(memory: memory, covered: covered)) { Label("Show All Photos", systemImage: "square.grid.2x2") }
                    .circleGlass()
            }
            #endif
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        #if os(macOS) // just the bars, on the window's very top edge, above the title bar's buttons and title
        .padding(.top, 2)
        .padding(.bottom, top + 12)
        #else
        .padding(.top, top + 8)
        .padding(.bottom, 24)
        #endif
        .background { // the white title stays readable on a bright photo
            LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        }
    }

    private static let grow = Animation.smooth(duration: 0.4)

    /// Back into the card it came from, then gone.
    private func close() {
        guard let onClose else { return dismiss() }
        player?.pause()
        paused = true // nothing moves on meanwhile
        settled = false
        withAnimation(reduceMotion ? nil : Self.grow) {
            expanded = false
            index = 0 // fades back to the card's own picture on the way, so the card takes over seamlessly
        } completion: { onClose() }
    }

    private func tap(at x: CGFloat, width: CGFloat) {
        if x < width / 3 {
            go(index - 1)
        } else if x > width * 2 / 3 {
            go(index + 1)
        } else {
            togglePause()
        }
    }

    /// Photo `i` from its start, and playing. Past the last one does nothing.
    private func go(_ i: Int) {
        guard i <= last else { return }
        paused = false
        if max(i, 0) == index { round += 1 } else { index = max(i, 0) }
    }

    private func togglePause() {
        if index == last, progress >= 1 { // the end: play the last photo again
            go(last)
        } else {
            paused.toggle()
        }
    }

    /// Plays the photo showing, then moves on.
    private func play() async {
        let asset = memory.assets[index]
        progress = 0
        player?.pause()
        player = nil
        if index < last, let api = library.api, !memory.assets[index + 1].isVideo { // the next one, already loading
            let next = memory.assets[index + 1].id
            Task { _ = try? await api.thumbnail(next, size: "preview") }
        }
        if asset.isVideo, let video = library.player(for: asset) {
            video.isMuted = muted
            player = video
            if !paused { video.play() }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let item = video.currentItem else { break }
                let (time, length) = (video.currentTime().seconds, item.duration.seconds)
                if length.isFinite, length > 0 {
                    progress = min(time / length, 1)
                    if time >= length - 0.1 { break }
                }
                if item.status == .failed { break }
            }
        } else {
            while progress < 1, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                if !paused { progress += 0.05 / Self.photoSeconds }
            }
        }
        guard !Task.isCancelled else { return }
        if index < last {
            go(index + 1)
        } else {
            progress = 1
            paused = true
        }
    }
}

/// A memory's photos as the usual grid, in the server's order (like Search): open one, choose, edit.
/// A value pushed on the stack: a destination bound to the player's state looped the Mac's layout.
struct MemoryPhotos: Hashable {
    let memory: Memory
    /// The player's, told when the grid shows (on the Mac the player below doesn't disappear).
    let covered: Covered

    @Observable final class Covered: Hashable {
        var value = false
        static func == (a: Covered, b: Covered) -> Bool { a === b }
        func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
    }
}

/// A memory opened from its card, with the card's place in the window.
struct MemoryOpen {
    let memory: Memory
    let source: CGRect
}

extension EnvironmentValues {
    /// Opens a memory over the page its card is on (the Mac's).
    @Entry var openMemory: ((MemoryOpen) -> Void)?
    /// The memory open over the page, whose card the player stands in for.
    @Entry var memoryShowing: String?
}

extension View {
    /// A page with memory cards and this title. On the Mac a card's memory plays over it (`open`), growing out of the
    /// card with the page still underneath, and the title bar is the memory's meanwhile.
    func memoryHost(_ open: Binding<MemoryOpen?>, title: LocalizedStringKey) -> some View {
        #if os(macOS)
        environment(\.openMemory) { open.wrappedValue = $0 }
            .environment(\.memoryShowing, open.wrappedValue?.memory.id)
            .overlay {
                if let shown = open.wrappedValue {
                    MemoryPlayer(memory: shown.memory, source: shown.source) { open.wrappedValue = nil }
                }
            }
            .navigationTitle(open.wrappedValue.map { Text($0.memory.title) } ?? Text(title))
            .navigationSubtitle(open.wrappedValue?.memory.subtitle ?? "")
            .navigationBarBackButtonHidden(open.wrappedValue != nil) // its own Back shrinks it first
        #else
        navigationTitle(title)
        #endif
    }
}

/// One photo fitted to the screen (or filling it, like its card, while growing), the small picture at once and the
/// large one when it's there; a video plays over it.
private struct MemorySlide: View {
    @Environment(Library.self) private var library
    let asset: Asset
    let player: AVPlayer?
    /// Given, not read from a GeometryReader, so the picture's size animates with the frame around it.
    let size: CGSize
    var fill = false
    @State private var image: CGImage?

    init(asset: Asset, player: AVPlayer?, size: CGSize, fill: Bool, first: CGImage?) {
        (self.asset, self.player, self.size, self.fill) = (asset, player, size, fill)
        _image = State(initialValue: first)
    }

    var body: some View {
        ZStack {
            if let image {
                // sized by hand, not by content mode, so filling the card turns smoothly into fitting the page
                let ratio = CGFloat(image.width) / CGFloat(max(image.height, 1))
                let wider = size.width / max(size.height, 1) > ratio
                let byHeight = wider != fill
                Image(decorative: image, scale: 1).resizable()
                    .frame(width: byHeight ? size.height * ratio : size.width,
                           height: byHeight ? size.height : size.width / ratio)
            }
            if let player { PlayerLayer(player: player, gravity: .resizeAspect) }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .task(id: asset.id) {
            guard let api = library.api else { return }
            if image == nil { image = await library.thumbs.image(asset.id, pixels: 0, api: api) }
            if let data = try? await api.thumbnail(asset.id, size: "preview"),
               let source = CGImageSourceCreateWithData(data as CFData, nil),
               let full = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                image = full
            }
        }
    }
}

#if os(iOS)
private extension View {
    /// The round glass buttons over the photo.
    func circleGlass() -> some View {
        labelStyle(.iconOnly)
            .font(.title3)
            .frame(width: 44, height: 44)
            .contentShape(.circle)
            .glassEffect(.regular.interactive(), in: .circle)
    }
}
#endif
