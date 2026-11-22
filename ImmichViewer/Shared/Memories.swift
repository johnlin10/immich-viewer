import AVFoundation
import ImageIO
import SwiftUI

/// A memory's first photo with its title over a fade, like Photos'. Opens the player: on iOS it grows out of the card to
/// full screen and shrinks back into it (also following a swipe down); on the Mac it is pushed, and grows from the card's place.
struct MemoryCard: View {
    @Environment(Library.self) private var library
    let memory: Memory
    #if os(iOS)
    @State private var playing = false
    @Namespace private var zoom
    #else
    /// Where the card is in the window, for the player to grow from.
    @State private var frame = CGRect.zero
    #endif

    var body: some View {
        #if os(macOS)
        NavigationLink(value: MemoryOpen(memory: memory, source: frame)) { cover }
            .buttonStyle(.plain)
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
            .overlay(alignment: .bottomLeading) {
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
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
    }
}

/// Every memory the server has that is due, newest first (Collections shows only today's).
struct MemoryGrid: View {
    @Environment(Library.self) private var library
    @State private var memories: [Memory]?
    @State private var failed = false

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
        .navigationTitle("Memories")
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
    /// Grown to fill the page; until then it sits on the card.
    @State private var expanded = false
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
        GeometryReader { page in
            // on the card's place until grown: the photo's size and corners animate from it
            let full = page.frame(in: .global)
            let rect = open ? CGRect(origin: .zero, size: page.size)
                            : source!.offsetBy(dx: -full.minX, dy: -full.minY)
            stage
                .frame(width: rect.width, height: rect.height)
                .clipShape(.rect(cornerRadius: open ? 0 : 14))
                .position(x: rect.midX, y: rect.midY)
        }
        .background(Color.black.opacity(open ? 1 : 0).ignoresSafeArea())
        .navigationTitle(memory.title)
        #if os(macOS)
        .navigationSubtitle(memory.subtitle)
        #endif
        .task(id: [index, round]) { await play() }
        .onChange(of: paused) { if paused { player?.pause() } else { player?.play() } }
        .onDisappear { player?.pause() }
        .onChange(of: covered.value) { if covered.value { paused = true } }
        #if os(macOS)
        .navigationBarBackButtonHidden() // its own, which shrinks it back first
        .toolbar {
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
            withAnimation(reduceMotion ? nil : Self.grow) { expanded = true }
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

    /// The memory's view: photos, bars and title.
    private var stage: some View {
        let asset = memory.assets[index]
        return GeometryReader { geo in
            ZStack {
                MemorySlide(asset: asset, player: asset.isVideo ? player : nil, fill: !open)
                    .id(index)
                    .transition(.opacity)
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: index)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .top) { header.opacity(open ? 1 : 0) }
            .overlay { // paused: say so, and that a tap plays on
                if paused, open {
                    Image(systemName: "play.fill").font(.largeTitle).foregroundStyle(.white)
                        .frame(width: 80, height: 80)
                        .background(.black.opacity(0.4), in: .circle)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { tap(at: $0.location.x, width: geo.size.width) })
        }
    }

    /// The progress bars, with the title under them.
    private var header: some View {
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
        .padding(.top, 8)
        .padding(.bottom, 24)
        .background { // the white title stays readable on a bright photo
            LinearGradient(colors: [.black.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
        }
    }

    private static let grow = Animation.smooth(duration: 0.4)

    /// Back into the card it came from, then off the stack.
    private func close() {
        guard source != nil, !reduceMotion else { return dismiss() }
        player?.pause()
        withAnimation(Self.grow) { expanded = false } completion: { dismiss() }
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

/// A memory opened from its card on the Mac, with the card's place in the window. The place counts in ==, or the
/// link keeps the place it had when first drawn (none, in a grid that loads after it).
struct MemoryOpen: Hashable {
    let memory: Memory
    let source: CGRect
    func hash(into hasher: inout Hasher) { hasher.combine(memory) }
}

/// One photo fitted to the screen (or filling it, like its card, while growing), the small picture at once and the
/// large one when it's there; a video plays over it.
private struct MemorySlide: View {
    @Environment(Library.self) private var library
    let asset: Asset
    let player: AVPlayer?
    var fill = false
    @State private var image: CGImage?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image {
                    // sized by hand, not by content mode, so fill to fit animates
                    let ratio = CGFloat(image.width) / CGFloat(max(image.height, 1))
                    let wider = geo.size.width / max(geo.size.height, 1) > ratio
                    let byHeight = wider != fill
                    Image(decorative: image, scale: 1).resizable()
                        .frame(width: byHeight ? geo.size.height * ratio : geo.size.width,
                               height: byHeight ? geo.size.height : geo.size.width / ratio)
                }
                if let player { PlayerLayer(player: player, gravity: fill ? .resizeAspectFill : .resizeAspect) }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .clipped()
        .task(id: asset.id) {
            guard let api = library.api else { return }
            image = await library.thumbs.image(asset.id, pixels: 0, api: api)
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
