@preconcurrency import Foundation
import Testing
@testable import health_sync

@Suite(.serialized)
struct HealthSyncTransportTests {
    @Test func metricsAcceptsStrictNumericAcknowledgement() async throws {
        StubURLProtocol.set(status: 200, headers: ["Content-Type": "application/json"],
                            body: Data(#"{"status":"ok","id":123}"#.utf8))
        defer { StubURLProtocol.reset() }

        let receipt = try await makeTransport().uploadMetrics(
            HealthPayload(metrics: [
                MetricData(name: "heart_rate", units: "bpm",
                           data: [.avg(date: "2026-01-01 00:00:00 +0000", value: 60, source: "Watch")])
            ]),
            configuration: testConfiguration()
        )

        #expect(receipt == TransportReceipt(id: 123))
    }

    @Test func metricsRejectsRedirectAcknowledgement() async throws {
        StubURLProtocol.set(status: 302,
                            headers: ["Content-Type": "application/json", "Location": "https://elsewhere.example"],
                            body: Data(#"{"status":"ok","id":123}"#.utf8))
        defer { StubURLProtocol.reset() }

        do {
            _ = try await makeTransport().uploadMetrics(
                HealthPayload(metrics: [
                    MetricData(name: "heart_rate", units: "bpm",
                               data: [.avg(date: "2026-01-01 00:00:00 +0000", value: 60, source: "Watch")])
                ]),
                configuration: testConfiguration()
            )
            Issue.record("A redirect must be rejected before acknowledgement parsing")
        } catch let error as SyncTransportError {
            #expect(error == .redirected)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func metricsRejectsHTMLWithSuccessfulHTTPStatus() async throws {
        StubURLProtocol.set(status: 200, headers: ["Content-Type": "text/html"],
                            body: Data("<html>ok</html>".utf8))
        defer { StubURLProtocol.reset() }

        do {
            _ = try await makeTransport().uploadMetrics(metricPayload(), configuration: testConfiguration())
            Issue.record("HTML must not be accepted as an upload acknowledgement")
        } catch let error as SyncTransportError {
            #expect(error == .invalidAcknowledgement)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func workoutsRejectFailedCountAndMeaningfulError() async throws {
        let payload = workoutPayload()
        let responses = [
            #"{"status":"ok","id":123,"ingested":0,"failed":1}"#,
            #"{"status":"ok","id":123,"ingested":1,"failed":0,"error":"rejected"}"#
        ]

        for (index, body) in responses.enumerated() {
            StubURLProtocol.set(status: 200, headers: ["Content-Type": "application/json"],
                                body: Data(body.utf8))
            do {
                _ = try await makeTransport().uploadWorkouts(payload, configuration: testConfiguration())
                Issue.record("Workout acknowledgement should be rejected: \(body)")
            } catch let error as SyncTransportError {
                let expected: SyncTransportError = index == 0 ? .partialAcknowledgement : .invalidAcknowledgement
                #expect(error == expected)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
        StubURLProtocol.reset()
    }

    @Test func acknowledgementsRejectBooleanAndFractionalNumbers() async throws {
        let metricIDs = ["true", "1.5"]
        for id in metricIDs {
            StubURLProtocol.set(status: 200, headers: ["Content-Type": "application/json"],
                                body: Data(#"{"status":"ok","id":"PLACEHOLDER"}"#.replacingOccurrences(of: "\"PLACEHOLDER\"", with: id).utf8))
            do {
                _ = try await makeTransport().uploadMetrics(metricPayload(), configuration: testConfiguration())
                Issue.record("Metric id should be rejected: \(id)")
            } catch let error as SyncTransportError {
                #expect(error == .invalidAcknowledgement)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }

        let workoutAcknowledgements = [
            #"{"status":"ok","id":true,"ingested":1,"failed":0}"#,
            #"{"status":"ok","id":1.5,"ingested":1,"failed":0}"#,
            #"{"status":"ok","id":123,"ingested":true,"failed":0}"#,
            #"{"status":"ok","id":123,"ingested":1.5,"failed":0}"#,
            #"{"status":"ok","id":123,"ingested":1,"failed":true}"#,
            #"{"status":"ok","id":123,"ingested":1,"failed":0.5}"#
        ]
        for body in workoutAcknowledgements {
            StubURLProtocol.set(status: 200, headers: ["Content-Type": "application/json"],
                                body: Data(body.utf8))
            do {
                _ = try await makeTransport().uploadWorkouts(workoutPayload(), configuration: testConfiguration())
                Issue.record("Workout acknowledgement should be rejected: \(body)")
            } catch let error as SyncTransportError {
                #expect(error == .invalidAcknowledgement)
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
        }
        StubURLProtocol.reset()
    }

    @Test func retryAfter429IsPropagated() async throws {
        StubURLProtocol.set(status: 429,
                            headers: ["Content-Type": "application/json", "Retry-After": "12"],
                            body: Data(#"{"status":"error"}"#.utf8))
        defer { StubURLProtocol.reset() }
        let started = Date()

        do {
            _ = try await makeTransport().uploadMetrics(metricPayload(), configuration: testConfiguration())
            Issue.record("HTTP 429 must throw")
        } catch let error as SyncTransportError {
            guard case .http(let status, let retryAt) = error else {
                Issue.record("Unexpected transport error: \(error)")
                return
            }
            #expect(status == 429)
            #expect(retryAt != nil)
            if let retryAt {
                #expect(retryAt >= started.addingTimeInterval(10))
                #expect(retryAt <= Date().addingTimeInterval(14))
            }
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private func makeTransport() -> URLSessionSyncTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: configuration,
                                 delegate: NoRedirectDelegate(),
                                 delegateQueue: nil)
        return URLSessionSyncTransport(session: session)
    }

    private func testConfiguration() -> SyncConfiguration {
        SyncConfiguration(
            endpoint: URL(string: "https://health.example.test")!,
            apiKey: "test-key",
            fingerprint: "test-fingerprint",
            metricGroups: [.vitals],
            workoutsEnabled: true,
            backgroundEnabled: false,
            syncOnLaunch: false,
            interval: 900,
            workoutHRTimeline: false
        )
    }

    private func metricPayload() -> HealthPayload {
        HealthPayload(metrics: [
            MetricData(name: "heart_rate", units: "bpm",
                       data: [.avg(date: "2026-01-01 00:00:00 +0000", value: 60, source: "Watch")])
        ])
    }

    private func workoutPayload() -> WorkoutsPayload {
        WorkoutsPayload(items: [
            WorkoutItem(id: "workout-1", name: "Walking",
                        start: "2026-01-01 00:00:00 +0000",
                        end: "2026-01-01 01:00:00 +0000",
                        duration: 3600, isIndoor: false, location: "Outdoor",
                        avgHeartRate: nil, maxHeartRate: nil,
                        activeEnergyBurned: nil, intensity: nil, distance: nil,
                        avgSpeed: nil, maxSpeed: nil, elevationUp: nil,
                        temperature: nil, humidity: nil,
                        heartRateData: [], stepCount: [])
        ])
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private struct Response {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var response = Response(
        status: 500,
        headers: ["Content-Type": "application/json"],
        body: Data()
    )

    static func set(status: Int, headers: [String: String], body: Data) {
        lock.withLock {
            response = Response(status: status, headers: headers, body: body)
        }
    }

    static func reset() {
        set(status: 500, headers: ["Content-Type": "application/json"], body: Data())
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let value = Self.lock.withLock { Self.response }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url,
                                              statusCode: value.status,
                                              httpVersion: "HTTP/1.1",
                                              headerFields: value.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: value.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
