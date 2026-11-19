import AVFoundation
import SwiftUI

/// A Live Photo's moving part over its still. `playing` plays it from the start; the end, or `playing` going false,
/// fades back to the still, like Photos.
struct LiveVideo: View {
    let player: AVPlayer
    @Binding var playing: Bool
    /// Fill on the Mac, where the frame is the photo's own; fit on iOS, where it's the whole screen.
    var gravity: AVLayerVideoGravity = .resizeAspect

    var body: some View {
        PlayerLayer(player: player, gravity: gravity)
            .opacity(playing ? 1 : 0)
            .animation(.easeInOut(duration: 0.2), value: playing)
            .allowsHitTesting(false)
            .onChange(of: playing) {
                if playing {
                    player.seek(to: .zero)
                    player.play()
                } else {
                    player.pause()
                }
            }
            .task {
                for await _ in NotificationCenter.default.notifications(named: AVPlayerItem.didPlayToEndTimeNotification,
                                                                       object: player.currentItem) {
                    playing = false
                }
            }
    }
}

/// The "LIVE" mark Photos puts on a Live Photo.
struct LiveBadge: View {
    var body: some View {
        Label("LIVE", systemImage: "livephoto")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .glassEffect(.regular, in: .capsule)
    }
}

/// Just the picture, no controls: the still underneath already has them.
#if os(macOS)
struct PlayerLayer: NSViewRepresentable {
    let player: AVPlayer
    let gravity: AVLayerVideoGravity

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = gravity
        view.layer = layer
        view.wantsLayer = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view.layer as? AVPlayerLayer)?.player = player
    }
}
#else
struct PlayerLayer: UIViewRepresentable {
    let player: AVPlayer
    let gravity: AVLayerVideoGravity

    final class View: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> View {
        let view = View()
        view.playerLayer.videoGravity = gravity
        return view
    }

    func updateUIView(_ view: View, context: Context) { view.playerLayer.player = player }
}
#endif
