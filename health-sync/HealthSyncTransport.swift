import Foundation

/// Strict writer for the ingest endpoints. Dashboard reads keep using
/// `ServerClient`; uploads need stronger acknowledgement validation before a
/// local checkpoint can advance.
final class URLSessionSyncTransport: @unchecked Sendable, SyncTransport {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.httpAdditionalHeaders = ["Accept": "application/json"]
            self.session = URLSession(configuration: config,
                                      delegate: NoRedirectDelegate(),
                                      delegateQueue: nil)
        }
    }

    func uploadMetrics(_ payload: HealthPayload,
                       configuration: SyncConfiguration,
                       session: SyncUploadSession? = nil) async throws -> TransportReceipt {
        let data = try JSONEncoder().encode(payload)
        let object = try await post(path: "/health", body: data, configuration: configuration, session: session)
        guard object.string("status") == "ok", !object.hasMeaningfulError,
              let id = object.validID else {
            throw SyncTransportError.invalidAcknowledgement
        }
        return TransportReceipt(id: id)
    }

    func uploadWorkouts(_ payload: WorkoutsPayload,
                        configuration: SyncConfiguration) async throws -> WorkoutTransportReceipt {
        let data = try JSONEncoder().encode(payload)
        let object = try await post(path: "/health/workouts", body: data, configuration: configuration)
        guard object.string("status") == "ok", !object.hasMeaningfulError,
              let id = object.validID else {
            throw SyncTransportError.invalidAcknowledgement
        }
        guard let ingested = object.int("ingested"), let failed = object.int("failed") else {
            throw SyncTransportError.invalidAcknowledgement
        }
        let expected = payload.data.workouts.count
        guard failed == 0, ingested == expected else {
            throw SyncTransportError.partialAcknowledgement
        }
        return WorkoutTransportReceipt(id: id, ingested: ingested, failed: failed)
    }

    /// A deliberate, user-initiated configuration probe. The normal sync path
    /// never uses it as a substitute for a strict upload acknowledgement.
    func validate(configuration: SyncConfiguration) async throws {
        var request = try makeRequest(path: "/health", configuration: configuration)
        request.httpMethod = "GET"
        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SyncTransportError.network }
        guard !(300..<400).contains(http.statusCode) else { throw SyncTransportError.redirected }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 { throw SyncTransportError.unauthorized }
            throw SyncTransportError.http(status: http.statusCode,
                                          retryAfter: retryAfter(from: http))
        }
        guard isJSON(http), let raw = try? JSONSerialization.jsonObject(with: data),
              let object = raw as? [String: Any], JSONObject(object).string("status") == "ok",
              !JSONObject(object).hasMeaningfulError else {
            throw SyncTransportError.invalidAcknowledgement
        }
    }

    private func post(path: String, body: Data, configuration: SyncConfiguration,
                      session: SyncUploadSession? = nil) async throws -> JSONObject {
        var request = try makeRequest(path: path, configuration: configuration)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let session {
            request.setValue(session.id, forHTTPHeaderField: "X-Sync-Session")
            request.setValue(String(session.total), forHTTPHeaderField: "X-Sync-Session-Total")
        }

        let (data, response) = try await data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SyncTransportError.network }
        guard !(300..<400).contains(http.statusCode) else { throw SyncTransportError.redirected }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 { throw SyncTransportError.unauthorized }
            throw SyncTransportError.http(status: http.statusCode,
                                          retryAfter: retryAfter(from: http))
        }
        guard isJSON(http) else { throw SyncTransportError.invalidAcknowledgement }
        guard let raw = try? JSONSerialization.jsonObject(with: data),
              let object = raw as? [String: Any] else {
            throw SyncTransportError.invalidAcknowledgement
        }
        return JSONObject(object)
    }

    private func makeRequest(path: String, configuration: SyncConfiguration) throws -> URLRequest {
        guard var components = URLComponents(url: configuration.endpoint,
                                             resolvingAgainstBaseURL: false) else {
            throw SyncTransportError.configuration
        }
        components.path = (components.path == "/" ? "" : components.path) + path
        guard let url = components.url else { throw SyncTransportError.configuration }
        var request = URLRequest(url: url, timeoutInterval: 120)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(configuration.apiKey, forHTTPHeaderField: "X-API-Key")
        return request
    }

    private func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch is CancellationError {
            throw SyncTransportError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw SyncTransportError.cancelled
        } catch {
            throw SyncTransportError.network
        }
    }

    private func retryAfter(from response: HTTPURLResponse) -> Date? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces) else {
            return nil
        }
        if let seconds = TimeInterval(raw), seconds >= 0 { return Date().addingTimeInterval(seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter.date(from: raw)
    }

    private func isJSON(_ response: HTTPURLResponse) -> Bool {
        response.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("json") == true
    }
}

private struct JSONObject {
    let values: [String: Any]

    init(_ values: [String: Any]) { self.values = values }

    func string(_ key: String) -> String? { values[key] as? String }

    func int(_ key: String) -> Int? {
        guard let number = values[key] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let decimal = NSDecimalNumber(decimal: number.decimalValue)
        let whole = decimal.rounding(accordingToBehavior: NSDecimalNumberHandler(
            roundingMode: .plain, scale: 0, raiseOnExactness: false,
            raiseOnOverflow: false, raiseOnUnderflow: false, raiseOnDivideByZero: false
        ))
        guard decimal.compare(whole) == .orderedSame,
              decimal.compare(NSDecimalNumber(value: Int.max)) != .orderedDescending,
              decimal.compare(NSDecimalNumber(value: Int.min)) != .orderedAscending else { return nil }
        return decimal.intValue
    }

    var validID: Int64? {
        guard let number = values["id"] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let decimal = number.decimalValue
        let integer = NSDecimalNumber(decimal: decimal)
        let whole = integer.rounding(accordingToBehavior: NSDecimalNumberHandler(
            roundingMode: .plain, scale: 0, raiseOnExactness: false,
            raiseOnOverflow: false, raiseOnUnderflow: false, raiseOnDivideByZero: false
        ))
        guard integer != .notANumber,
              integer.compare(NSDecimalNumber(value: 0)) == .orderedDescending,
              integer.compare(whole) == .orderedSame,
              integer.compare(NSDecimalNumber(value: Int64.max)) != .orderedDescending else { return nil }
        return integer.int64Value
    }

    var hasMeaningfulError: Bool {
        guard let value = values["error"], !(value is NSNull) else { return false }
        if let string = value as? String { return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return true
    }
}
