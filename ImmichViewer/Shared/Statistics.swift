import Charts
import SwiftUI

/// Counts behind the Statistics page, worked out once from the Library timeline. Dates are wall-clock times stored
/// as UTC, like `Asset.date`, so every calendar here is in GMT.
struct LibraryStats: Sendable {
    struct Kinds: Sendable {
        var photos = 0, videos = 0
        var total: Int { photos + videos }
    }

    var all = Kinds()
    var live = 0, favorites = 0
    /// Items on each day (its 00:00).
    var days: [Date: Int] = [:]
    /// Each month's (its first day's 00:00) photos and videos.
    var months: [Date: Kinds] = [:]
    var years: [Int: Kinds] = [:]
    /// Sunday first.
    var weekdays = [Int](repeating: 0, count: 7)
    var hours = [Int](repeating: 0, count: 24)

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        calendar.locale = .current
        return calendar
    }()

    init(_ assets: [Asset]) {
        // plain arithmetic per photo; the calendar only once per day that has any
        var perDay: [Int: Kinds] = [:]
        for asset in assets {
            let t = asset.date.timeIntervalSince1970
            let day = Int((t / 86400).rounded(.down))
            if asset.isVideo { all.videos += 1; perDay[day, default: Kinds()].videos += 1 }
            else { all.photos += 1; perDay[day, default: Kinds()].photos += 1 }
            if asset.isLive == true { live += 1 }
            if asset.isFavorite == true { favorites += 1 }
            hours[min(23, max(0, Int(t - Double(day) * 86400) / 3600))] += 1
            weekdays[((day + 4) % 7 + 7) % 7] += 1 // 1970-01-01 was a Thursday
        }
        let calendar = Self.calendar
        for (day, kinds) in perDay {
            let date = Date(timeIntervalSince1970: Double(day) * 86400)
            days[date] = kinds.total
            let parts = calendar.dateComponents([.year, .month], from: date)
            let month = calendar.date(from: parts)!
            months[month, default: Kinds()].photos += kinds.photos
            months[month, default: Kinds()].videos += kinds.videos
            years[parts.year!, default: Kinds()].photos += kinds.photos
            years[parts.year!, default: Kinds()].videos += kinds.videos
        }
    }

    var first: Date? { days.keys.min() }
    var busiest: [(day: Date, count: Int)] {
        days.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key > $1.key) }.prefix(5).map { ($0.key, $0.value) }
    }
}

/// Statistics on the Library: totals, a heat map and bar chart by day or month, and when the photos were taken.
struct StatisticsView: View {
    @Environment(Library.self) private var library
    @State private var stats: LibraryStats?
    @AppStorage("statsScale") private var byMonth = false
    @State private var year: Int?
    @State private var heatWidth = 300.0

    private var calendar: Calendar { LibraryStats.calendar }

    var body: some View {
        ScrollView {
            if let stats, stats.all.total > 0 {
                content(stats)
                    .padding()
                    .frame(maxWidth: 900)
                    .frame(maxWidth: .infinity)
            } else if stats != nil {
                ContentUnavailableView("No Photos", systemImage: "chart.bar")
            } else {
                ProgressView().padding(40)
            }
        }
        .navigationTitle("Statistics")
        // the wall-clock dates are stored as UTC: label them in UTC too
        .environment(\.timeZone, .gmt)
        .environment(\.calendar, calendar)
        .task(id: library.revision) {
            let assets = library.assets
            stats = await Task.detached(priority: .userInitiated) { LibraryStats(assets) }.value
        }
    }

    @ViewBuilder private func content(_ stats: LibraryStats) -> some View {
        let years = stats.years.keys.sorted(by: >)
        let shownYear = year.flatMap { years.contains($0) ? $0 : nil } ?? years[0]
        VStack(alignment: .leading, spacing: 16) {
            overview(stats)

            Picker("Scale", selection: $byMonth) {
                Text("Day").tag(false)
                Text("Month").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if byMonth {
                card("Heat Map") { monthHeatMap(stats, years: years) }
                card("Items per Month") { monthBars(stats) }
            } else {
                card("Heat Map", accessory: { yearPicker(years, shown: shownYear) }) { dayHeatMap(stats, year: shownYear) }
                card("Items per Day") { dayBars(stats, year: shownYear) }
            }

            card("By Year") { yearBars(stats, years: years) }
            card("By Weekday") {
                Chart(Array(stats.weekdays.enumerated()), id: \.offset) { day, count in
                    BarMark(x: .value("Weekday", calendar.shortWeekdaySymbols[day]), y: .value("Items", count))
                }
                .chartXScale(domain: calendar.shortWeekdaySymbols)
                .frame(height: 160)
            }
            card("By Hour") {
                Chart(Array(stats.hours.enumerated()), id: \.offset) { hour, count in
                    BarMark(x: .value("Hour", hour), y: .value("Items", count))
                }
                .chartXScale(domain: -0.5...23.5)
                .chartXAxis { AxisMarks(values: [0, 6, 12, 18, 23]) }
                .frame(height: 160)
            }
            card("Busiest Days") {
                VStack(spacing: 8) {
                    ForEach(stats.busiest, id: \.day) { item in
                        LabeledContent {
                            Text("\(item.count) items")
                        } label: {
                            Text(item.day, format: gmt(.dateTime.year().month().day().weekday()))
                        }
                    }
                }
            }
        }
    }

    // MARK: Overview

    private func overview(_ stats: LibraryStats) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], spacing: 12) {
            tile("Items", stats.all.total, "photo.on.rectangle")
            tile("Photos", stats.all.photos, "photo")
            tile("Videos", stats.all.videos, "video")
            tile("Live Photos", stats.live, "livephoto")
            tile("Favorites", stats.favorites, "heart")
            tile("People", library.people.filter { !$0.name.isEmpty }.count, "person.crop.circle")
            tile("Albums", library.albums.count, "rectangle.stack")
            tile("Tags", library.tags.count, "tag")
            if let first = stats.first {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Since", systemImage: "calendar").font(.caption).foregroundStyle(.secondary)
                    Text(first, format: gmt(.dateTime.year().month())).font(.title3.weight(.semibold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(.background.secondary, in: .rect(cornerRadius: 14))
            }
        }
    }

    private func tile(_ title: LocalizedStringKey, _ value: Int, _ symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value, format: .number).font(.title3.weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
    }

    private func card<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        card(title, accessory: { EmptyView() }, content: content)
    }

    private func card<Accessory: View, Content: View>(_ title: LocalizedStringKey, @ViewBuilder accessory: () -> Accessory,
                                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                accessory()
            }
            content()
        }
        .padding()
        .background(.background.secondary, in: .rect(cornerRadius: 18))
    }

    private func yearPicker(_ years: [Int], shown: Int) -> some View {
        Picker("Year", selection: Binding { shown } set: { year = $0 }) {
            ForEach(years, id: \.self) { Text(verbatim: String($0)).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
    }

    /// 0 for nothing, then from a light to a full tint; square root so one huge day doesn't wash out the rest.
    private func shade(_ count: Int, max: Int) -> Color {
        count == 0 ? Color.secondary.opacity(0.12) : Color.accentColor.opacity(0.25 + 0.75 * (Double(count) / Double(Swift.max(max, 1))).squareRoot())
    }

    // MARK: By day

    private struct DayCell: Identifiable {
        let date: Date, week: Date, weekday: Int, count: Int
        var id: Date { date }
    }

    private func cells(_ stats: LibraryStats, year: Int) -> [DayCell] {
        guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let end = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1)) else { return [] }
        return stride(from: start, to: min(end, .now), by: 86400).map { date in // up to today in this year
            let weekday = calendar.component(.weekday, from: date) - 1
            return DayCell(date: date, week: date.addingTimeInterval(-86400 * Double(weekday)), weekday: weekday, count: stats.days[date] ?? 0)
        }
    }

    /// A column per week, a row per weekday, like a contributions calendar.
    private func dayHeatMap(_ stats: LibraryStats, year: Int) -> some View {
        let cells = cells(stats, year: year)
        let top = cells.map(\.count).max() ?? 0
        let firstWeek = cells.first?.week ?? .now
        var columns: [[DayCell?]] = []
        for cell in cells {
            let column = Int((cell.week.timeIntervalSince(firstWeek) / 604800).rounded())
            while columns.count <= column { columns.append(Array(repeating: nil, count: 7)) }
            columns[column][cell.weekday] = cell
        }
        let symbols = calendar.shortWeekdaySymbols
        return VStack(alignment: .leading, spacing: 8) {
            heatGrid(counts: columns.map { $0.map { $0?.count } }, top: top,
                     rowLabel: { $0 % 2 == 1 ? symbols[$0] : "" }, // every other one, like the usual calendar
                     columnLabel: { i in
                         // the month's name over the week its 1st falls in
                         columns[i].compactMap { $0 }.first { calendar.component(.day, from: $0.date) == 1 }
                             .map { $0.date.formatted(gmt(.dateTime.month(.abbreviated))) }
                     },
                     help: { i, row in columns[i][row].map { "\($0.date.formatted(gmt(.dateTime.month().day()))): \($0.count)" } ?? "" })
            legend(top: top, total: cells.reduce(0) { $0 + $1.count })
        }
    }

    private func dayBars(_ stats: LibraryStats, year: Int) -> some View {
        Chart(cells(stats, year: year).filter { $0.count > 0 }) { cell in
            BarMark(x: .value("Day", cell.date, unit: .day), y: .value("Items", cell.count))
        }
        .chartXScale(domain: calendar.date(from: DateComponents(year: year, month: 1, day: 1))!...calendar.date(from: DateComponents(year: year, month: 12, day: 31))!)
        .chartXAxis { AxisMarks(values: .stride(by: .month)) { AxisValueLabel(format: .dateTime.month(.abbreviated)) } }
        .frame(height: 180)
    }

    // MARK: By month

    /// A column per year (oldest first, like the day map's weeks), a row per month.
    private func monthHeatMap(_ stats: LibraryStats, years: [Int]) -> some View {
        let years = years.sorted()
        let columns = years.map { year in
            (1...12).map { month -> Int? in stats.months[calendar.date(from: DateComponents(year: year, month: month, day: 1))!]?.total ?? 0 }
        }
        let top = columns.joined().compactMap { $0 }.max() ?? 0
        let symbols = calendar.shortMonthSymbols
        let step = years.count <= 12 ? 2 : 5 // a year's label needs about two columns
        return VStack(alignment: .leading, spacing: 8) {
            heatGrid(counts: columns, top: top,
                     rowLabel: { symbols[$0] },
                     columnLabel: { years[$0] % step == 0 || years.count == 1 ? String(years[$0]) : nil },
                     help: { i, row in "\(years[i]) \(symbols[row]): \(columns[i][row] ?? 0)" })
            legend(top: top, total: nil)
        }
    }

    /// Squares in columns (weeks or years, newest last) and rows (weekdays or months). They fill the width up to
    /// 16 pt; where that would make them smaller than 11 pt, they stay 11 pt and the grid scrolls sideways instead,
    /// starting at the newest end. The row names stay put at the left. Plain views rather than Charts, which squashes
    /// rectangles on two category axes.
    private func heatGrid(counts: [[Int?]], top: Int, rowLabel: @escaping (Int) -> String, columnLabel: @escaping (Int) -> String?,
                          help: @escaping (Int, Int) -> String) -> some View {
        let gap = 3.0, labelWidth = 26.0
        let fit = (heatWidth - labelWidth - gap * Double(counts.count)) / Double(max(counts.count, 1))
        let size = min(16, max(11, fit.rounded(.down)))
        let rows = counts.first?.count ?? 0
        return HStack(alignment: .top, spacing: gap) {
            VStack(alignment: .leading, spacing: gap) {
                Color.clear.frame(height: 14)
                ForEach(0..<rows, id: \.self) { Text(verbatim: rowLabel($0)).frame(height: size) }
            }
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: labelWidth, alignment: .leading)
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: gap) {
                    ForEach(counts.indices, id: \.self) { i in
                        VStack(spacing: gap) {
                            Color.clear.frame(width: size, height: 14).overlay(alignment: .leading) {
                                if let label = columnLabel(i) {
                                    Text(verbatim: label).font(.caption2).foregroundStyle(.secondary).fixedSize()
                                }
                            }
                            ForEach(0..<rows, id: \.self) { row in
                                RoundedRectangle(cornerRadius: size / 4)
                                    .fill(counts[i][row].map { shade($0, max: top) } ?? .clear)
                                    .frame(width: size, height: size)
                                    .help(help(i, row))
                            }
                        }
                    }
                }
                .padding(.trailing, 24) // room for the last column's label, which runs past it
            }
            .scrollIndicators(.hidden)
            .defaultScrollAnchor(.trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: Double.self) { $0.size.width } action: { heatWidth = $0 }
    }

    /// `style` in GMT, which is how the wall-clock dates are stored.
    private func gmt(_ style: Date.FormatStyle) -> Date.FormatStyle {
        var style = style
        style.timeZone = .gmt
        return style
    }

    private func monthBars(_ stats: LibraryStats) -> some View {
        Chart(stats.months.sorted { $0.key < $1.key }, id: \.key) { month, kinds in
            BarMark(x: .value("Month", month, unit: .month), y: .value("Items", kinds.photos))
                .foregroundStyle(by: .value("Kind", String(localized: "Photos")))
            BarMark(x: .value("Month", month, unit: .month), y: .value("Items", kinds.videos))
                .foregroundStyle(by: .value("Kind", String(localized: "Videos")))
        }
        .frame(height: 200)
    }

    private func yearBars(_ stats: LibraryStats, years: [Int]) -> some View {
        // years as numbers, not names: a long span gets a readable axis instead of a label per bar
        Chart(years.reversed(), id: \.self) { year in
            let kinds = stats.years[year] ?? LibraryStats.Kinds()
            BarMark(x: .value("Year", year), y: .value("Items", kinds.photos))
                .foregroundStyle(by: .value("Kind", String(localized: "Photos")))
            BarMark(x: .value("Year", year), y: .value("Items", kinds.videos))
                .foregroundStyle(by: .value("Kind", String(localized: "Videos")))
        }
        .chartXScale(domain: Double(years.last!) - 0.5...Double(years[0]) + 0.5)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: min(years.count, 8))) { value in
                AxisValueLabel { Text(verbatim: value.as(Int.self).map(String.init) ?? "") }
            }
        }
        .frame(height: 200)
    }

    private func legend(top: Int, total: Int?) -> some View {
        HStack(spacing: 4) {
            if let total { Text("\(total) items").foregroundStyle(.secondary) }
            Spacer()
            Text("Less").foregroundStyle(.secondary)
            ForEach(Array([0, 1, top / 4, top / 2, top].enumerated()), id: \.offset) { _, count in
                RoundedRectangle(cornerRadius: 2).fill(shade(count, max: top)).frame(width: 10, height: 10)
            }
            Text("More").foregroundStyle(.secondary)
        }
        .font(.caption)
    }
}
