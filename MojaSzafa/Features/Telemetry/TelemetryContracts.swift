import Foundation

struct TelemetryPreferences: Codable, Sendable, Equatable {
    let version: Int64
    let diagnostics: Bool
    let product: Bool
    let updatedAt: String?
    static let disabled = Self(version: 0, diagnostics: false, product: false, updatedAt: nil)
}

struct TelemetryChoice: Codable, Sendable, Equatable {
    let action = "preferences"
    let operationID: UUID
    let baseVersion: Int64
    let diagnostics: Bool
    let product: Bool
    enum CodingKeys: String, CodingKey { case action, operationID, baseVersion, diagnostics, product }
}

struct TelemetryFrame: Codable, Sendable, Equatable {
    let binaryUUID: UUID
    let offset: UInt64
}

/// Only typed, bounded fields cross the telemetry boundary. Never accept an
/// arbitrary dictionary, localized error, HTTP request or response body here.
struct TelemetryEvent: Codable, Sendable, Equatable, Identifiable {
    let id: UUID
    let kind: String
    var route: String?
    var outcome: String?
    var durationMs: Int?
    var build: String?
    var architecture: String?
    var frames: [TelemetryFrame]?

    static func session(id: UUID = UUID()) -> Self { Self(id: id, kind: "session") }
    static func latency(route: String, kind: String = "api", outcome: TelemetryOutcome, seconds: Double) -> Self? {
        guard seconds.isFinite, seconds >= 0,
              (kind == "api" && route.range(of: "^api_v1_[a-z0-9_]{1,80}$", options: .regularExpression) != nil && route != "api_v1_telemetry")
                || (kind == "sync" && route == "sync_cycle") else { return nil }
        return Self(id: UUID(), kind: kind, route: route, outcome: outcome.rawValue,
                    durationMs: Int(min(3_600_000, (seconds * 1000).rounded())))
    }
}

enum TelemetryOutcome: String, Sendable {
    case success, offline, cancelled, unauthorized, conflict, rejected
    case serverError = "server_error", invalidResponse = "invalid_response"

    static func classify(_ error: any Error) -> Self {
        if error is CancellationError { return .cancelled }
        if let error = error as? URLError {
            if error.code == .cancelled { return .cancelled }
            return .offline
        }
        if let error = error as? APIClientError {
            switch error {
            case .http(let status, _):
                if status == 401 || status == 403 { return .unauthorized }
                return status >= 500 ? .serverError : .rejected
            case .invalidResponse: return .invalidResponse
            default: return .rejected
            }
        }
        if let error = error as? APIv1.Failure {
            switch error.code {
            case "unauthorized", "account_unavailable", "account_deleted": return .unauthorized
            case "version_conflict", "idempotency_conflict": return .conflict
            case "internal_error": return .serverError
            default: return .rejected
            }
        }
        return .rejected
    }
}

protocol TelemetryRepository: Sendable {
    func telemetryPreferences() async throws -> TelemetryPreferences
    func telemetryChoose(_ choice: TelemetryChoice) async throws -> TelemetryPreferences
    func telemetryIngest(version: Int64, events: [TelemetryEvent], probeActivation: Bool) async throws
}

extension APIClient: TelemetryRepository {
    func telemetryPreferences() async throws -> TelemetryPreferences {
        struct Input: Encodable { let action = "get" }
        let result: APIv1.Success<TelemetryPreferences> = try await call("api_v1_telemetry", Input())
        guard result.data.version >= 0 else { throw APIClientError.invalidResponse }
        return result.data
    }
    func telemetryChoose(_ choice: TelemetryChoice) async throws -> TelemetryPreferences {
        let result: APIv1.Success<TelemetryPreferences> = try await call("api_v1_telemetry", choice)
        guard result.data.version > choice.baseVersion else { throw APIClientError.invalidResponse }
        return result.data
    }
    func telemetryIngest(version: Int64, events: [TelemetryEvent], probeActivation: Bool) async throws {
        struct Input: Encodable {
            let action = "ingest"
            let version: Int64
            let events: [TelemetryEvent]
            let probeActivation: Bool
        }
        struct Output: Decodable, Sendable { let accepted: Int; let version: Int64 }
        let input = Input(version: version, events: events, probeActivation: probeActivation)
        guard version >= 0, events.count <= 20, try JSONEncoder().encode(input).count <= 25_000 else {
            throw APIClientError.invalidRequest
        }
        let result: APIv1.Success<Output> = try await call("api_v1_telemetry", input)
        guard result.data.version == version, result.data.accepted == events.count else { throw APIClientError.invalidResponse }
    }
}
