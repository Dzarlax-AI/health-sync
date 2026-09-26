import Foundation

/// Synthetic UI fixtures are unreachable unless the app's isolated test mode
/// is explicitly enabled. They never read credentials or make network calls.
enum InsightFixtures {
    static var enabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-test-mode") &&
        ProcessInfo.processInfo.arguments.contains("--insights-fixture")
    }

    static func sleepNights(days: Int) -> [SleepNight] {
        if enabled && ProcessInfo.processInfo.arguments.contains("--insights-empty-sleep") { return [] }
        let calendar = Calendar(identifier: .gregorian)
        let end = Date(timeIntervalSince1970: 1_790_294_400)
        return (0..<days).map { index in
            let date = calendar.date(byAdding: .day, value: index - days + 1, to: end)!
            let deep = 0.5 + Double(index % 5) * 0.12
            let rem = 1.1 + Double(index % 7) * 0.15
            let core = 3.5 + Double(index % 9) * 0.2
            let unspecified = index % 11 == 0 || index == days - 1 ? 0.4 : 0
            return SleepNight(date: date.formatted(.iso8601.year().month().day().dateSeparator(.dash)),
                              total: deep + rem + core + unspecified, deep: deep, rem: rem,
                              core: core, unspecified: unspecified, awake: 0.2 + Double(index % 4) * 0.15)
        }
    }

    static func metricData(name: String, from: String?) -> MetricDataResponse {
        let points = sleepNights(days: 90).filter { from == nil || $0.date >= from! }.enumerated().map { index, night in
            let value: Double
            switch name {
            case "sleep_total": value = night.total
            case "sleep_deep": value = night.deep
            case "sleep_core": value = night.core
            case "sleep_rem": value = night.rem
            case "sleep_unspecified": value = night.unspecified
            case "sleep_awake": value = night.awake
            case "vo2_max": value = 36 + Double(index % 12) * 0.2
            default: value = 4_000 + Double(index % 17) * 400
            }
            return DataPoint(date: night.date, qty: value, min: nil, max: nil)
        }
        return MetricDataResponse(metric: name, bucket: "day", agg: "sum", points: points,
                                  bySource: nil, pointsBySource: nil)
    }

    static func snapshot(state: String = "ready", mode: String = "preview", staleSlot: String? = nil) throws -> TodayInsightsResponse {
        let arguments = ProcessInfo.processInfo.arguments
        let state = arguments.contains("--insights-failed") ? "failed" :
            arguments.contains("--insights-disabled") ? "disabled" :
            arguments.contains("--insights-generating") ? "generating" : state
        let locale = Locale.preferredLanguages.first ?? "en"
        let ru = locale.hasPrefix("ru"), sr = locale.hasPrefix("sr")
        let titles = ru ? ["Сегодня", "Сон", "Восстановление", "Энергия"] : sr ? ["Danas", "San", "Oporavak", "Energija"] : ["Today", "Sleep", "Recovery", "Energy"]
        func insight(_ title: String) -> [String: Any] {
            ["state": "factual_context", "title": title,
             "observation": arguments.contains("--insights-long-text")
                ? String(repeating: ru ? "Сегодня сон был короче обычного. Сравни самочувствие и данные за предыдущие дни. " : "Sleep was shorter than usual today. Compare how you feel with previous days. ", count: 8)
                : ru ? "Записи за сегодня доступны." : sr ? "Današnji podaci su dostupni." : "Today's records are available.",
             "meaning": ru ? "Часть контекста пока отсутствует." : sr ? "Deo konteksta još nedostaje." : "Some context is still missing.",
             "next_step": ["id": "fixture", "text": ru ? "Сверься со своим самочувствием." : sr ? "Uporedi sa svojim osećajem." : "Compare this with how you feel."],
             "evidence_ids": ["synthetic"], "fallback": false]
        }
        let ai: [String: Any] = ["text": ru ? "Это пример пояснения по тестовым данным. Оценка сервера не учитывает субъективное самочувствие." : sr ? "Ovo je primer tumačenja test podataka. Procena servera ne uključuje subjektivni osećaj." : "This is an explanation of synthetic data. The server assessment does not include how you feel.",
            "stance": "qualify", "alternative_action": ru ? "Сначала оцени, хватает ли сил на обычные дела." : sr ? "Prvo proceni energiju za uobičajene aktivnosti." : "First consider your energy for ordinary activities.", "fact_ids": ["synthetic"], "evidence_ids": ["synthetic"]]
        let keys = ["overall", "sleep", "recovery", "energy"]
        let slots: [[String: Any]] = keys.map { ["key": $0, "state": state, "fresh_for_snapshot": $0 != staleSlot] }
        let domains: [[String: Any]] = Array(keys.dropFirst()).enumerated().map { index, key in
            ["key": key, "band": "fair", "data_state": "partial", "summary": titles[index + 1],
             "insight": insight(titles[index + 1]), "ai_insight": ai,
             "destination": ["kind": key == "sleep" ? "sleep" : "section", "id": key == "energy" ? "activity" : key]]
        }
        let object: [String: Any] = ["date": "2026-09-26", "decision_id": "synthetic", "snapshot_version": "synthetic-v1",
            "generation": ["state": state, "narrative_mode": mode, "fresh_for_snapshot": true, "slots": slots],
            "primary": insight(titles[0]), "ai_insight": ai, "domains": domains, "evidence": [],
            "changes": [["id": "synthetic", "domain": "energy", "severity": "info", "title": titles[3],
                         "detail": ru ? "Добавлены новые записи." : sr ? "Dodati su novi zapisi." : "New records were added.",
                         "evidence_ids": [], "destination": ["kind": "section", "id": "activity"]]]]
        return try JSONDecoder().decode(TodayInsightsResponse.self, from: JSONSerialization.data(withJSONObject: object))
    }

    static func briefing() throws -> BriefingResponse {
        if ProcessInfo.processInfo.arguments.contains("--insights-missing-values") {
            return try JSONDecoder().decode(BriefingResponse.self, from: Data(#"{"date":"2026-09-26"}"#.utf8))
        }
        if ProcessInfo.processInfo.arguments.contains("--insights-server-unavailable") {
            throw URLError(.notConnectedToInternet)
        }
        return try JSONDecoder().decode(BriefingResponse.self, from: Data(#"{"date":"2026-09-26","sleep":{"nights":1,"total_avg":7.3,"deep_avg":0.8,"rem_avg":1.8,"awake_avg":0.38,"efficiency":95},"readiness_today":72,"recovery_pct":84,"readiness_today_label":"Steady","energy_bank":{"capacity":85,"current":58,"drain_so_far":27,"strain":12,"stress":8,"action_verdict":"moderate","verdict_label":"Moderate","verdict_reason":"Synthetic data"}}"#.utf8))
    }

    static func energyHistory() throws -> EnergyHistoryResponse {
        var points: [[String: Any]] = []
        for index in 0..<14 {
            let current: Int = index == 12 ? -12 : (index == 13 ? 54 : 75 - index * 4)
            let point: [String: Any] = ["date": String(format: "2026-09-%02d", index + 12),
                                        "capacity": 85, "current_eod": current,
                                        "drain": 85 - current, "verdict": "moderate"]
            points.append(point)
        }
        let data = try JSONSerialization.data(withJSONObject: ["granularity": "day", "points": points])
        return try JSONDecoder().decode(EnergyHistoryResponse.self, from: data)
    }
}
