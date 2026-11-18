#if os(macOS)
import SwiftUI

/// Wall-clock dates (`Asset.date`) are kept as UTC; these format them without shifting the day.
private func gmtStyle(_ style: Date.FormatStyle) -> Date.FormatStyle {
    var s = style
    s.timeZone = .gmt
    return s
}

/// The date of the top row, in a glass capsule under the window title.
struct DateCapsule: View {
    let bridge: GridBridge
    let assets: [Asset]
    private static let style = gmtStyle(Date.FormatStyle(date: .long, time: .omitted))

    var body: some View {
        if assets.indices.contains(bridge.top) {
            Text(assets[bridge.top].date.formatted(Self.style))
                .font(.headline).monospacedDigit()
                .padding(.horizontal, 14)
                .frame(height: 32)
                .glassEffect(.regular, in: .capsule)
                .allowsHitTesting(false)
        }
    }
}

/// A handle down the right edge in place of the scroll bar. Hover to see the years, drag to go anywhere.
struct Scrubber: View {
    let bridge: GridBridge
    let assets: [Asset]
    let years: [(year: Int, index: Int)]
    @State private var hovering = false
    @State private var dragging = false
    /// Year labels and where they sit (0...1), worked out when the pointer arrives.
    @State private var marks: [(year: Int, at: Double)] = []
    private static let handle = 32.0
    private static let monthStyle = gmtStyle(Date.FormatStyle().year().month(.wide))

    var body: some View {
        GeometryReader { geo in
            let track = max(geo.size.height - Self.handle, 1)
            let y = bridge.fraction * track + Self.handle / 2
            ZStack(alignment: .topTrailing) {
                Color.clear
                if hovering || dragging {
                    ForEach(spaced(marks, track: track), id: \.year) { mark in
                        Text(String(mark.year))
                            .font(.caption.weight(.semibold)).monospacedDigit()
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .glassEffect(.regular, in: .capsule)
                            .position(x: geo.size.width - 34, y: mark.at * track + Self.handle / 2)
                    }
                    .transition(.opacity)
                }
                Capsule()
                    .fill(dragging ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .frame(width: hovering || dragging ? 6 : 4, height: Self.handle)
                    .position(x: geo.size.width - 6, y: y)
                if dragging, assets.indices.contains(bridge.top) {
                    Text(assets[bridge.top].date.formatted(Self.monthStyle))
                        .font(.headline).monospacedDigit()
                        .fixedSize()
                        .padding(.horizontal, 12)
                        .frame(height: 30)
                        .glassEffect(.regular, in: .capsule)
                        .position(x: geo.size.width - 120, y: y)
                }
            }
            .allowsHitTesting(false) // labels and bubble float over the photos
            .overlay(alignment: .trailing) {
                // only this strip takes the pointer
                Color.clear
                    .frame(width: 20)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { marks = years.map { ($0.year, bridge.fraction(of: $0.index)) } }
                        withAnimation(.easeOut(duration: 0.15)) { hovering = inside }
                    }
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            dragging = true
                            bridge.scroll(to: (drag.location.y - Self.handle / 2) / track)
                        }
                        .onEnded { _ in dragging = false })
            }
        }
        .frame(width: 200)
        .opacity(assets.isEmpty ? 0 : 1)
    }

    /// Leaves out labels that would overlap the one above.
    private func spaced(_ marks: [(year: Int, at: Double)], track: Double) -> [(year: Int, at: Double)] {
        var last = -Double.infinity
        return marks.sorted { $0.at < $1.at }.filter { mark in
            guard mark.at * track - last >= 20 else { return false }
            last = mark.at * track
            return true
        }
    }
}

/// Go to Date… (⌘J): pick a day, the grid scrolls to its first photo (or the next one if that day has none).
struct JumpToDate: View {
    let assets: [Asset]
    let current: Int
    let jump: (Date) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var day = Date()

    private static var gmt: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .gmt
        return c
    }

    /// Wall-clock date (UTC) to the same day in this Mac's calendar, and back, so the picker shows the photo's own day.
    private static func local(_ wall: Date) -> Date {
        Calendar.current.date(from: gmt.dateComponents([.year, .month, .day], from: wall)) ?? wall
    }
    private static func wall(_ local: Date) -> Date {
        gmt.date(from: Calendar.current.dateComponents([.year, .month, .day], from: local)) ?? local
    }

    var body: some View {
        let ends = [assets.first?.date ?? .now, assets.last?.date ?? .now].sorted() // sorted either way
        let range = Self.local(ends[0])...Self.local(ends[1])
        VStack(spacing: 16) {
            Text("Go to Date").font(.headline)
            DatePicker("Date", selection: $day, in: range, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Go") {
                    jump(Self.wall(day))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .onAppear { if assets.indices.contains(current) { day = Self.local(assets[current].date) } }
    }
}
#endif
