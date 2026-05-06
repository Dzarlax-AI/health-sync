import Foundation

/// Parsed AI briefing — Gemini emits four labelled sections per the server's
/// prompt (`internal/ai/prompt.txt`); the Telegram report parses them and
/// lays each one under its matching rule-based block. Mirror of
/// `internal/notify/aiparse.go` so iOS gets the same structured output.
struct AIInsight {
    var sleep: String = ""
    var yesterday: String = ""
    var recovery: String = ""
    var recommendation: String = ""
    /// Raw text — used as fallback when no headers match.
    let raw: String

    var hasAnyBlock: Bool {
        !sleep.isEmpty || !yesterday.isEmpty || !recovery.isEmpty || !recommendation.isEmpty
    }
}

private enum AIBlockKey: String {
    case sleep, yesterday, recovery, recommendation
}

/// Header tokens recognised case-insensitively, en/ru/sr. Mirrors
/// `aiHeaderTokens` in `internal/notify/aiparse.go`.
private let aiHeaderTokens: [AIBlockKey: [String]] = [
    .sleep:          ["sleep", "сон", "san"],
    .yesterday:      ["yesterday", "вчера", "juče", "juce"],
    .recovery:       ["recovery", "восстановление", "oporavak"],
    .recommendation: ["recommendation", "рекомендация", "preporuka"],
]

/// Strip header punctuation and normalise to lowercase for token matching.
private func normaliseHeader(_ line: String) -> String {
    var s = line.trimmingCharacters(in: .whitespacesAndNewlines)
    s = s.trimmingCharacters(in: CharacterSet(charactersIn: ":：—-•*#"))
    s = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return s.lowercased()
}

private func headerKey(_ line: String) -> AIBlockKey? {
    let norm = normaliseHeader(line)
    if norm.isEmpty || norm.count > 30 { return nil }
    for (key, tokens) in aiHeaderTokens {
        if tokens.contains(norm) { return key }
    }
    return nil
}

/// Split Gemini's output into per-section blocks. Returns `.raw` only when
/// no headers matched — callers should render `.raw` as a single italic
/// blob in that case.
func parseAIInsight(_ text: String) -> AIInsight {
    let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
    var out = AIInsight(raw: raw)
    if raw.isEmpty { return out }

    var current: AIBlockKey?
    var buffer = ""

    func flush() {
        let body = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer.removeAll()
        guard let key = current, !body.isEmpty else { return }
        switch key {
        case .sleep:          out.sleep = body
        case .yesterday:      out.yesterday = body
        case .recovery:       out.recovery = body
        case .recommendation: out.recommendation = body
        }
    }

    for line in raw.components(separatedBy: "\n") {
        if let key = headerKey(line) {
            flush()
            current = key
            continue
        }
        if current == nil { continue }
        buffer.append(line)
        buffer.append("\n")
    }
    flush()
    return out
}
