// Checks for the grid math and grouping. Run from the project folder:
//   swiftc ImmichViewer/TimelineModel.swift ImmichViewer/ThumbnailStore.swift ImmichViewer/ImmichAPI.swift Tests/main.swift -o /tmp/immichviewer-check && /tmp/immichviewer-check
import Foundation

// 3 columns: (100 + 2) / (30 + 2) = 3.18, side = (100 - 2*2) / 3 = 32, row = 34
let g = GridMath(counts: [5, 1, 7], width: 100, target: 30, header: 10, spacing: 2)
precondition(g.columns == 3 && g.side == 32)
precondition(g.tops == [0, 78, 122] && g.height == 234)
precondition(g.itemFrame(2, 4) == CGRect(x: 34, y: 166, width: 32, height: 32))

func show(_ v: [(section: Int, items: Range<Int>)]) -> String { v.map { "\($0.section):\($0.items)" }.joined(separator: " ") }
precondition(show(g.visible(0, 1)) == "0:0..<0") // header only
precondition(show(g.visible(10, 11)) == "0:0..<3")
precondition(show(g.visible(80, 100)) == "1:0..<1")
precondition(show(g.visible(0, 1000)) == "0:0..<5 1:0..<1 2:0..<7")
precondition(show(g.visible(122, 125)) == "2:0..<0") // header only
precondition(show(g.visible(500, 600)) == "")

let empty = GridMath(counts: [], width: 0, target: 100, header: 0)
precondition(empty.columns == 1 && show(empty.visible(0, 100)) == "")

// newest first: two on day 3 (one late at night), one on day 2, one in the previous month
let day = 86400.0
let jan3 = Date(timeIntervalSince1970: 2 * day) // 1970-01-03
let assets = [
    Asset(id: "a", date: jan3.addingTimeInterval(23 * 3600), isVideo: false),
    Asset(id: "b", date: jan3, isVideo: true),
    Asset(id: "c", date: jan3.addingTimeInterval(-day), isVideo: false),
    Asset(id: "d", date: jan3.addingTimeInterval(-10 * day), isVideo: false),
]
precondition(makeSections(assets, by: .day).map(\.range) == [0..<2, 2..<3, 3..<4])
precondition(makeSections(assets, by: .month).map(\.range) == [0..<3, 3..<4])
precondition(makeSections(assets, by: .none).map(\.range) == [0..<4])
precondition(makeSections([], by: .day).isEmpty)

let parse = UTCDateParser()
let expected = Date(timeIntervalSince1970: 1_794_347_103) // 2026-11-10 21:45:03 UTC
precondition(parse.date("2026-11-10T21:45:03") == expected)
precondition(parse.date("2026-11-10T21:45:03Z") == expected)
precondition(parse.date("2026-11-10T21:45:03+00:00") == expected)
precondition(parse.date("2026-11-11T05:45:03+08:00") == expected)
precondition(abs(parse.date("2026-11-10T21:45:03.886")!.timeIntervalSince(expected) - 0.886) < 0.001)
precondition(parse.date("not a date") == nil)

precondition(zoomLevels == zoomLevels.sorted() && zoomLevels.indices.contains(openLevel))
precondition(ThumbnailStore.pixels(forSide: 16, scale: 2) == 128 && ThumbnailStore.pixels(forSide: 76, scale: 2) == 256)
precondition(ThumbnailStore.pixels(forSide: 110, scale: 2) == 0)

// rows: section 0 has 5 items in 3 columns (rows 0-2, 3-4), section 1 has 1, section 2 has 7
precondition(g.row(from: 0, 1, down: true)! == (0, 4))
precondition(g.row(from: 0, 2, down: true)! == (0, 4)) // shorter last row: nearest
precondition(g.row(from: 0, 4, down: true)! == (1, 0))
precondition(g.row(from: 1, 0, down: true)! == (2, 0))
precondition(g.row(from: 2, 6, down: true) == nil)
precondition(g.row(from: 2, 2, down: false)! == (1, 0))
precondition(g.row(from: 1, 0, down: false)! == (0, 3))
precondition(g.row(from: 0, 4, down: false)! == (0, 1))
precondition(g.row(from: 0, 0, down: false) == nil)

// jump to a day, newest first and oldest first
precondition(index(of: jan3, in: assets) == 0)
precondition(index(of: jan3.addingTimeInterval(-day), in: assets) == 2)
precondition(index(of: jan3.addingTimeInterval(-5 * day), in: assets) == 3) // no photos: the next older one
precondition(index(of: jan3, in: assets.reversed()) == 2)
precondition(index(of: jan3.addingTimeInterval(9 * day), in: assets) == 0)
precondition(index(of: jan3, in: []) == nil)

let y2025 = Date(timeIntervalSince1970: 1_735_689_600) // 2025-01-01 00:00 UTC
let years = [y2025.addingTimeInterval(day), y2025, y2025.addingTimeInterval(-1), y2025.addingTimeInterval(-day)]
    .map { Asset(id: "", date: $0, isVideo: false) }
precondition(yearStarts(years).map { "\($0.year)@\($0.index)" } == ["2025@0", "2024@2"])
precondition(yearStarts(years.reversed()).map { "\($0.year)@\($0.index)" } == ["2024@0", "2025@2"])

print("all checks passed")
