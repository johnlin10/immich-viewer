import ImageIO
import SwiftUI

/// Crops a photo: drag the corners to resize the frame, drag inside it to move it. The photo shows as it looks now
/// (turned, if it was); the server keeps the original and stores the crop as an edit.
struct CropSheet: View {
    let asset: Asset
    let library: Library
    let undo: UndoManager?
    @State private var loaded = false
    @State private var error: String?
    @State private var picture: CGImage?
    @State private var old: PixelCrop?
    @State private var angle = 0
    @State private var size: CGSize?
    @State private var mirrored = false
    /// The frame, 0…1 in the photo as shown.
    @State private var rect = CGRect(x: 0, y: 0, width: 1, height: 1)
    @Environment(\.dismiss) private var dismiss

    private static let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
    private var canCrop: Bool { picture != nil && size != nil && !mirrored }

    var body: some View {
        content
            .task { await load() }
            #if os(iOS)
            .navigationTitle("Crop")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", role: .cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Crop", role: .confirm, action: save).disabled(!canCrop) }
                ToolbarItem(placement: .bottomBar) { Button("Reset") { rect = Self.whole }.disabled(!canCrop) }
            }
            .modifier(Navigation())
            .interactiveDismissDisabled() // a drag from the frame must not close the sheet
            #else
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button("Reset") { rect = Self.whole }.disabled(!canCrop)
                    Spacer()
                    Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Crop", action: save).keyboardShortcut(.defaultAction).disabled(!canCrop)
                }
                .padding(20)
            }
            .frame(minWidth: 640, minHeight: 520)
            #endif
    }

    #if os(iOS)
    private struct Navigation: ViewModifier {
        func body(content: Content) -> some View { NavigationStack { content } }
    }
    #endif

    @ViewBuilder private var content: some View {
        if let error {
            Text(error).foregroundStyle(.secondary).padding().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !loaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let picture {
            VStack(spacing: 12) {
                if mirrored {
                    Text("This photo was mirrored in Immich’s web app, so it can’t be cropped here.").font(.callout)
                } else if size == nil {
                    Text("The server doesn’t have this photo’s size, so it can’t be cropped.").font(.callout)
                }
                GeometryReader { geo in
                    let scale = min(geo.size.width / Double(picture.width), geo.size.height / Double(picture.height))
                    CropFrame(picture: picture, rect: $rect, fit: CGSize(width: Double(picture.width) * scale, height: Double(picture.height) * scale))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(canCrop)
                }
            }
            .padding(.horizontal, 20).padding(.top, 12)
        }
    }

    private func load() async {
        do {
            let info = try await library.cropInfo(asset.id)
            guard let source = CGImageSourceCreateWithData(info.preview as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil), let turned = Self.turned(image, by: info.angle) else {
                throw URLError(.cannotDecodeContentData)
            }
            picture = turned
            old = info.crop
            angle = info.angle
            size = info.size
            mirrored = info.mirrored
            if let crop = info.crop, let size = info.size { rect = shownRect(crop, angle: info.angle, size: size) }
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    private func save() {
        guard let size else { return }
        let whole = rect.minX < 0.005 && rect.minY < 0.005 && rect.maxX > 0.995 && rect.maxY > 0.995
        let new = whole ? nil : pixelCrop(rect, angle: angle, size: size)
        if new != old { Task { await library.crop(asset.id, to: new, was: old, undo: undo) } }
        dismiss()
    }

    /// `image` turned `angle` degrees clockwise.
    private static func turned(_ image: CGImage, by angle: Int) -> CGImage? {
        guard angle != 0 else { return image }
        let w = Double(image.width), h = Double(image.height)
        let sideways = angle % 180 != 0
        guard let context = CGContext(data: nil, width: sideways ? image.height : image.width, height: sideways ? image.width : image.height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: Double(context.width) / 2, y: Double(context.height) / 2)
        context.rotate(by: -Double(angle) * .pi / 180) // the context's y points up
        context.draw(image, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
        return context.makeImage()
    }
}

/// The photo with the frame over it: the outside dimmed, thirds inside, handles at the corners.
private struct CropFrame: View {
    let picture: CGImage
    @Binding var rect: CGRect
    let fit: CGSize
    /// The frame when the drag began.
    @State private var start: CGRect?
    private let smallest = 0.05

    var body: some View {
        let box = CGRect(x: rect.minX * fit.width, y: rect.minY * fit.height, width: rect.width * fit.width, height: rect.height * fit.height)
        ZStack(alignment: .topLeading) {
            Image(decorative: picture, scale: 1).resizable().frame(width: fit.width, height: fit.height)
            Path { p in
                p.addRect(CGRect(origin: .zero, size: fit))
                p.addRect(box)
            }
            .fill(.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)
            Path { p in
                for i in 1...2 {
                    let x = box.minX + box.width * Double(i) / 3, y = box.minY + box.height * Double(i) / 3
                    p.move(to: CGPoint(x: x, y: box.minY)); p.addLine(to: CGPoint(x: x, y: box.maxY))
                    p.move(to: CGPoint(x: box.minX, y: y)); p.addLine(to: CGPoint(x: box.maxX, y: y))
                }
            }
            .stroke(.white.opacity(0.5), lineWidth: 0.5)
            .allowsHitTesting(false)
            Rectangle().stroke(.white, lineWidth: 1)
                .contentShape(Rectangle())
                .frame(width: box.width, height: box.height)
                .offset(x: box.minX, y: box.minY)
                .gesture(DragGesture().onChanged { drag in
                    let from = start ?? rect
                    start = from
                    let x = min(max(from.minX + drag.translation.width / fit.width, 0), 1 - from.width)
                    let y = min(max(from.minY + drag.translation.height / fit.height, 0), 1 - from.height)
                    rect = CGRect(x: x, y: y, width: from.width, height: from.height)
                }.onEnded { _ in start = nil })
            corner(left: true, top: true, box: box)
            corner(left: false, top: true, box: box)
            corner(left: true, top: false, box: box)
            corner(left: false, top: false, box: box)
        }
        .frame(width: fit.width, height: fit.height)
    }

    /// An L at a corner of the frame, with a 44 pt target for the finger.
    private func corner(left: Bool, top: Bool, box: CGRect) -> some View {
        let x = left ? box.minX : box.maxX, y = top ? box.minY : box.maxY
        let dx = left ? 1.0 : -1.0, dy = top ? 1.0 : -1.0
        return Path { p in
            p.move(to: CGPoint(x: 22 + dx * 20, y: 22)); p.addLine(to: CGPoint(x: 22, y: 22)); p.addLine(to: CGPoint(x: 22, y: 22 + dy * 20))
        }
        .stroke(.white, lineWidth: 3)
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .offset(x: x - 22, y: y - 22)
        .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
            let from = start ?? rect
            start = from
            let dx = drag.translation.width / fit.width, dy = drag.translation.height / fit.height
            var x0 = from.minX, x1 = from.maxX, y0 = from.minY, y1 = from.maxY
            if left { x0 = min(max(x0 + dx, 0), x1 - smallest) } else { x1 = max(min(x1 + dx, 1), x0 + smallest) }
            if top { y0 = min(max(y0 + dy, 0), y1 - smallest) } else { y1 = max(min(y1 + dy, 1), y0 + smallest) }
            rect = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        }.onEnded { _ in start = nil })
    }
}
