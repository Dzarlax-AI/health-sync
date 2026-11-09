import Foundation

/// Date-only API bounds use calendar days, independently of device DST/offset.
struct MetricDateWindow: Hashable {
    let from: String
    let to: String

    init?(from: String, to: String) {
        guard Self.date(from) != nil, Self.date(to) != nil, from <= to else { return nil }
        self.from = from
        self.to = to
    }

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    static func date(_ value: String) -> Date? {
        guard value.count == 10 else { return nil }
        let pieces = value.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces[0].count == 4, pieces[1].count == 2, pieces[2].count == 2,
              let year = Int(pieces[0]), year > 0, let month = Int(pieces[1]), let day = Int(pieces[2]),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              iso(date) == value else { return nil }
        return date
    }

    static func iso(_ date: Date, timeZone: TimeZone = .gmt) -> String {
        var calendar = calendar
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func ending(at end: String, days: Int, minimum: String? = nil) -> Self? {
        guard days > 0, let endDate = date(end),
              let start = calendar.date(byAdding: .day, value: -(days - 1), to: endDate) else { return nil }
        if let minimum, date(minimum) == nil || minimum > end { return nil }
        return Self(from: max(iso(start), minimum ?? iso(start)), to: end)
    }

    var caption: String {
        let format = Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: .gmt)
        guard let start = Self.date(from), let end = Self.date(to) else { return "" }
        return from == to ? start.formatted(format) : "\(start.formatted(format)) – \(end.formatted(format))"
    }
}

@MainActor
@Observable
final class MetricDetailController {
    private(set) var points: [DataPoint] = []
    private(set) var displayedWindow: MetricDateWindow?
    private(set) var availableRange: MetricDateWindow?
    private(set) var isLoading = false
    private(set) var loadError: String?
    private var requestID = UUID()
    private var appliedIdentity: String?
    private let data: @MainActor (String, MetricDateWindow) async throws -> MetricDataResponse
    private let range: @MainActor (String) async throws -> MetricDateRange
    private let context: @MainActor () throws -> String

    init(data: @escaping @MainActor (String, MetricDateWindow) async throws -> MetricDataResponse = {
        try await ServerClient.shared.metricData(name: $0, from: $1.from, to: $1.to, bucket: "day")
    }, range: @escaping @MainActor (String) async throws -> MetricDateRange = {
        try await ServerClient.shared.metricRange(name: $0)
    }, context: @escaping @MainActor () throws -> String = { try ServerClient.shared.dashboardContext() }) {
        self.data = data
        self.range = range
        self.context = context
    }

    func load(metric: String, window: MetricDateWindow) async {
        guard !Task.isCancelled else { return }
        let id = UUID()
        requestID = id
        isLoading = true
        defer { if requestID == id { isLoading = false } }
        loadError = nil
        availableRange = nil
        do {
            let requestedContext = try context()
            let identity = requestedContext + "|" + metric
            if appliedIdentity != identity {
                points = []
                displayedWindow = nil
                appliedIdentity = identity
            }
            // The range is advisory: a failed metadata read must not discard a valid chart.
            async let bounds = readRange(metric)
            async let values = readData(metric, window)
            let (dataResult, rangeResult) = await (values, bounds)
            guard requestID == id, !Task.isCancelled else { return }
            guard (try? context()) == requestedContext else {
                points = []; displayedWindow = nil; appliedIdentity = nil
                loadError = ServerError.configurationChanged.localizedDescription
                return
            }
            availableRange = rangeResult
            switch dataResult {
            case .success(let response):
                points = response.points ?? []
                displayedWindow = window
            case .failure(let error): loadError = error.localizedDescription
            }
        } catch {
            guard requestID == id, !Task.isCancelled else { return }
            points = []; displayedWindow = nil; appliedIdentity = nil
            loadError = error.localizedDescription
        }
    }

    private func readRange(_ metric: String) async -> MetricDateWindow? {
        guard let value = try? await range(metric) else { return nil }
        return MetricDateWindow(from: value.min, to: value.max)
    }

    private func readData(_ metric: String, _ window: MetricDateWindow) async -> Result<MetricDataResponse, Error> {
        do { return .success(try await data(metric, window)) }
        catch { return .failure(error) }
    }
}
