import CoreGraphics
import Foundation

/// One photo or video on the timeline. `date` is the local wall-clock time stored as if it were UTC,
/// the same way Immich's web timeline does it, so grouping by day never depends on this Mac's time zone.
struct Asset: Codable, Equatable, Sendable {
    let id: String
    var date: Date
    let isVideo: Bool
    /// Optional so lists saved before v0.6 still load.
    var isFavorite: Bool?
    /// A Live Photo (or motion photo). nil in lists saved before v0.8, until the next sync.
    var isLive: Bool?
}

/// Immich sends times like `2026-11-10T21:45:03` or `...03.886` with no zone; like the web UI, read them as UTC.
/// Strings that do carry a zone (`Z`, `+08:00`) keep it. Not Sendable: make one per task.
struct UTCDateParser {
    private let plain = ISO8601DateFormatter()
    private let fraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func date(_ string: String) -> Date? {
        let time = string.dropFirst(19) // after yyyy-MM-ddTHH:mm:ss
        let zoned = time.contains { $0 == "Z" || $0 == "+" || $0 == "-" }
        let s = zoned ? string : string + "Z"
        return fraction.date(from: s) ?? plain.date(from: s)
    }
}

enum Grouping: String, CaseIterable {
    case day, month, none

    var label: LocalizedStringResource {
        switch self {
        case .day: "Days"
        case .month: "Months"
        case .none: "All"
        }
    }
}

/// Cell sizes in points for the zoom steps, smallest first.
let zoomLevels: [Double] = [16, 24, 36, 52, 76, 110, 160, 220]

struct Section {
    let title: String
    let range: Range<Int>
}

/// Splits `assets` (newest first) into day or month sections, or one section for `.none`.
func makeSections(_ assets: [Asset], by grouping: Grouping) -> [Section] {
    guard !assets.isEmpty else { return [] }
    guard grouping != .none else { return [Section(title: "", range: assets.indices)] }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    var style = grouping == .day ? Date.FormatStyle(date: .complete, time: .omitted) : Date.FormatStyle().year().month(.wide)
    style.timeZone = .gmt

    var sections: [Section] = []
    var start = 0, lastDay = Int.min, lastKey = Int.min
    for (i, asset) in assets.enumerated() {
        let day = Int((asset.date.timeIntervalSince1970 / 86400).rounded(.down))
        if day == lastDay { continue }
        lastDay = day
        let key: Int
        if grouping == .day {
            key = day
        } else {
            let c = calendar.dateComponents([.year, .month], from: asset.date)
            key = c.year! * 12 + c.month!
        }
        if key != lastKey {
            if i > 0 { sections.append(Section(title: assets[start].date.formatted(style), range: start..<i)) }
            start = i
            lastKey = key
        }
    }
    sections.append(Section(title: assets[start].date.formatted(style), range: start..<assets.count))
    return sections
}

/// Square-grid geometry, like Photos: columns fill the width, each section has an optional header.
/// One section can start `shift.slots` cells in, so a photo keeps its column when the zoom changes.
/// Pure math so it is cheap to query for 100k+ items and testable without AppKit.
struct GridMath {
    struct Shift: Equatable {
        var section: Int
        var slots: Int
    }

    let width: Double
    let side: Double
    let spacing: Double
    let header: Double
    let columns: Int
    let counts: [Int]
    let shift: Shift?
    let tops: [Double]
    let height: Double

    init(counts: [Int], width: Double, target: Double, header: Double, spacing: Double = 1, shift: Shift? = nil) {
        let width = max(width, 1)
        let columns = max(1, Int((width + spacing) / (target + spacing)))
        let side = (width - spacing * Double(columns - 1)) / Double(columns)
        var tops: [Double] = []
        var y = 0.0
        for (s, n) in counts.enumerated() {
            tops.append(y)
            let lead = shift?.section == s ? shift!.slots % columns : 0
            y += header + Double((n + lead + columns - 1) / columns) * (side + spacing)
        }
        (self.width, self.side, self.spacing, self.header, self.columns, self.counts, self.shift, self.tops, self.height) =
            (width, side, spacing, header, columns, counts, shift, tops, y)
    }

    /// Empty cells before the first photo of section `s`.
    func lead(_ s: Int) -> Int { shift?.section == s ? shift!.slots % columns : 0 }

    /// The column of item `i` in section `s`.
    func column(_ s: Int, _ i: Int) -> Int { (i + lead(s)) % columns }

    /// Whether item `i` is in the first row of section `s`, right under its header.
    func firstRow(_ s: Int, _ i: Int) -> Bool { i + lead(s) < columns }

    /// The shift that puts item `i` of section `s` in the column under `x`.
    func shift(putting i: Int, of s: Int, under x: Double) -> Shift {
        let c = min(max(Int(x / (side + spacing)), 0), columns - 1)
        return Shift(section: s, slots: ((c - i) % columns + columns) % columns)
    }

    func itemFrame(_ section: Int, _ item: Int) -> CGRect {
        let slot = item + lead(section)
        return CGRect(x: Double(slot % columns) * (side + spacing),
                      y: tops[section] + header + Double(slot / columns) * (side + spacing),
                      width: side, height: side)
    }

    func headerFrame(_ section: Int) -> CGRect {
        CGRect(x: 0, y: tops[section], width: width, height: header)
    }

    /// Sections touching the vertical range minY..<maxY, with the items whose rows touch it.
    func visible(_ minY: Double, _ maxY: Double) -> [(section: Int, items: Range<Int>)] {
        // binary search: first section whose bottom is below minY
        var lo = 0, hi = tops.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if bottom(mid) <= minY { lo = mid + 1 } else { hi = mid }
        }
        var result: [(section: Int, items: Range<Int>)] = []
        let rowHeight = side + spacing
        var s = lo
        while s < tops.count, tops[s] < maxY {
            let base = tops[s] + header
            let lead = lead(s)
            let lastRow = (counts[s] + lead + columns - 1) / columns - 1
            let r0 = max(0, Int(((minY - base) / rowHeight).rounded(.down)))
            let r1 = min(lastRow, Int(((maxY - base) / rowHeight).rounded(.down)))
            result.append((s, r0 <= r1 ? max(0, r0 * columns - lead)..<min(counts[s], (r1 + 1) * columns - lead) : 0..<0))
            s += 1
        }
        return result
    }

    private func bottom(_ s: Int) -> Double { s + 1 < tops.count ? tops[s + 1] : height }
}

extension GridMath {
    /// The item one row below (or above) in the same column, or the nearest one if that row is shorter.
    /// Crosses into the next (previous) section; nil at the very end (start).
    func row(from section: Int, _ item: Int, down: Bool) -> (section: Int, item: Int)? {
        let column = column(section, item)
        func clamp(_ i: Int, _ s: Int) -> Int { min(max(i, 0), counts[s] - 1) }
        if down {
            if (item + lead(section)) / columns < (counts[section] + lead(section) - 1) / columns {
                return (section, min(item + columns, counts[section] - 1))
            }
            guard let s = counts.indices.dropFirst(section + 1).first(where: { counts[$0] > 0 }) else { return nil }
            return (s, clamp(column - lead(s), s))
        }
        if !firstRow(section, item) { return (section, max(item - columns, 0)) }
        guard let s = counts.indices.prefix(section).last(where: { counts[$0] > 0 }) else { return nil }
        return (s, clamp((counts[s] + lead(s) - 1) / columns * columns + column - lead(s), s))
    }
}

/// Where `day` (00:00 wall-clock, stored as UTC like `Asset.date`) starts in `assets`, sorted either way.
/// A day without photos gives the next one in display order.
func index(of day: Date, in assets: [Asset]) -> Int? {
    guard let first = assets.first, let last = assets.last else { return nil }
    let i = first.date >= last.date
        ? assets.firstIndex { $0.date < day.addingTimeInterval(86400) }
        : assets.firstIndex { $0.date >= day }
    return i ?? assets.count - 1
}

/// The first index of each year in `assets` (sorted either way), for the scrubber's year marks.
func yearStarts(_ assets: [Asset]) -> [(year: Int, index: Int)] {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    var result: [(year: Int, index: Int)] = []
    var current: DateInterval?
    for (i, asset) in assets.enumerated() where current.map({ !($0.start..<$0.end).contains(asset.date) }) ?? true {
        current = calendar.dateInterval(of: .year, for: asset.date)
        result.append((calendar.component(.year, from: asset.date), i))
    }
    return result
}

/// The filter menu on photo pages. Photos and videos are either-or (neither or both: every kind); Favorites narrows further.
struct PhotoFilter: Equatable {
    var photos = false
    var videos = false
    var favorites = false
    var live = false

    var isActive: Bool { photos || videos || favorites || live }

    /// Photos, videos and Live Photos are kinds: any picked one matches, none picked means all. Favorites narrows that.
    func apply(_ assets: [Asset]) -> [Asset] {
        guard isActive else { return assets }
        let anyKind = !(photos || videos || live)
        return assets.filter { asset in
            (anyKind || (asset.isVideo ? videos : photos) || (live && asset.isLive == true)) && (!favorites || asset.isFavorite == true)
        }
    }
}

/// A crop in the original's pixels, upright (EXIF orientation applied): what Immich's `crop` edit takes.
struct PixelCrop: Equatable, Sendable { var x, y, width, height: Int }

/// `rect`, 0…1 in the photo as shown (turned `angle` degrees clockwise), in the upright original's pixels
/// (`size`), rounded and kept inside it.
func pixelCrop(_ rect: CGRect, angle: Int, size: CGSize) -> PixelCrop {
    let a = cropPoint(rect.minX, rect.minY, angle: angle, toOriginal: true)
    let b = cropPoint(rect.maxX, rect.maxY, angle: angle, toOriginal: true)
    func span(_ p: Double, _ q: Double, _ length: Double) -> (Int, Int) {
        let start = min(max(Int((min(p, q) * length).rounded()), 0), Int(length) - 1)
        let end = min(max(Int((max(p, q) * length).rounded()), start + 1), Int(length))
        return (start, end - start)
    }
    let (x, w) = span(a.x, b.x, size.width)
    let (y, h) = span(a.y, b.y, size.height)
    return PixelCrop(x: x, y: y, width: w, height: h)
}

/// The other way: where `crop` sits, 0…1, in the photo as shown.
func shownRect(_ crop: PixelCrop, angle: Int, size: CGSize) -> CGRect {
    let a = cropPoint(Double(crop.x) / size.width, Double(crop.y) / size.height, angle: angle, toOriginal: false)
    let b = cropPoint(Double(crop.x + crop.width) / size.width, Double(crop.y + crop.height) / size.height, angle: angle, toOriginal: false)
    return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
}

/// A point, 0…1, between the photo as shown (turned `angle` clockwise) and the upright original.
private func cropPoint(_ p: Double, _ q: Double, angle: Int, toOriginal: Bool) -> (x: Double, y: Double) {
    switch ((angle % 360) + 360) % 360 {
    case 90: toOriginal ? (q, 1 - p) : (1 - q, p)
    case 180: (1 - p, 1 - q)
    case 270: toOriginal ? (1 - q, p) : (q, 1 - p)
    default: (p, q)
    }
}
