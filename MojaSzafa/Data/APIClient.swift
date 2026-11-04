import Foundation

extension APIClient: WeatherForecastRepository {
    func forecast(latitude: Double, longitude: Double) async throws -> CityForecast {
        guard latitude.isFinite, longitude.isFinite, abs(latitude) <= 90, abs(longitude) <= 180 else {
            throw APIClientError.invalidRequest
        }
        let token = try await accessToken()
        guard !token.isEmpty, !token.contains(where: { $0.isWhitespace }) else { throw APIClientError.invalidConfiguration }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = "/v1/weather"
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = "POST"; request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode([
            "latitude": (latitude * 100).rounded() / 100,
            "longitude": (longitude * 100).rounded() / 100
        ])
        let (data, response) = try await transport.send(request)
        if response.statusCode == 401 { await unauthorized(token) }
        guard response.statusCode == 200, response.url == request.url, data.count <= 16384 else {
            throw APIClientError.http(status: response.statusCode, requestID: nil)
        }
        struct Forecast: Decodable {
            let celsius: Double; let validAt: String; let updatedAt: String
            let source: String; let attributionURL: String; let licenseURL: String
        }
        struct Envelope: Decodable { let data: Forecast }
        let value = try JSONDecoder().decode(Envelope.self, from: data).data
        let dates = ISO8601DateFormatter()
        guard value.celsius.isFinite, (-80...60).contains(value.celsius),
              value.source == "MET Norway", value.attributionURL == "https://api.met.no/",
              value.licenseURL == "https://creativecommons.org/licenses/by/4.0/",
              let valid = dates.date(from: value.validAt), let updated = dates.date(from: value.updatedAt) else {
            throw APIClientError.invalidResponse
        }
        try Task.checkCancellation()
        return CityForecast(celsius: value.celsius, validAt: valid, updatedAt: updated,
            attributionURL: URL(string: value.attributionURL)!, attributionImageURL: nil)
    }
}

/// Wire contracts are versioned independently from domain/view models.
enum APIv1 {
    enum Category: String, Codable, Sendable, CaseIterable {
        case top, bottom, shoes, dress, jumpsuit, outerwear, accessory, other
    }
    enum Availability: String, Codable, Sendable, CaseIterable { case available, laundry, unavailable }

    struct GarmentFields: Codable, Sendable, Equatable {
        let name: String
        let category: Category
        let priceGrosz: Int64?
        let availability: Availability
        var archived: Bool? = nil

        enum CodingKeys: String, CodingKey {
            case name, category, availability, archived
            case priceGrosz = "price_grosz"
        }
        func validate() throws {
            guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  name.unicodeScalars.count <= 200,
                  priceGrosz.map({ $0 >= 0 }) ?? true else { throw APIClientError.invalidRequest }
        }
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            try c.encode(category, forKey: .category)
            try c.encode(priceGrosz, forKey: .priceGrosz)
            try c.encode(availability, forKey: .availability)
            try c.encodeIfPresent(archived, forKey: .archived)
        }
    }
    struct GarmentDTO: Decodable, Sendable, Equatable {
        let id: UUID
        let version: Int64
        let name: String
        let category: Category
        let priceGrosz: Int64?
        let availability: Availability
        var archived: Bool? = nil
        enum CodingKeys: String, CodingKey {
            case id, version, name, category, availability, archived
            case priceGrosz = "price_grosz"
        }
        func validate() throws {
            guard version > 0 else { throw APIClientError.invalidResponse }
            do {
                try GarmentFields(name: name, category: category, priceGrosz: priceGrosz,
                                  availability: availability).validate()
            } catch { throw APIClientError.invalidResponse }
        }
    }
    /// Create this ONCE per user intent. Persist it with the outbox (T012).
    /// A timeout must never cause the caller to generate a new operation ID.
    struct SaveGarment: Codable, Sendable {
        let operationID: UUID
        let garmentID: UUID
        let baseVersion: Int64?
        let garment: GarmentFields
        enum CodingKeys: String, CodingKey {
            case operationID = "operation_id", garmentID = "garment_id"
            case baseVersion = "base_version", garment
        }
        func validate() throws {
            guard baseVersion.map({ $0 > 0 }) ?? true else { throw APIClientError.invalidRequest }
            try garment.validate()
        }
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(operationID, forKey: .operationID)
            try c.encode(garmentID, forKey: .garmentID)
            try c.encode(baseVersion, forKey: .baseVersion)
            try c.encode(garment, forKey: .garment)
        }
    }
    struct PageRequest: Encodable, Sendable {
        let limit: Int
        let cursor: UUID?
        enum CodingKeys: String, CodingKey { case limit, cursor }
        func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(limit, forKey: .limit)
            try c.encode(cursor, forKey: .cursor)
        }
    }
    struct GarmentPage: Decodable, Sendable {
        let items: [GarmentDTO]
        let nextCursor: UUID?
        enum CodingKeys: String, CodingKey { case items; case nextCursor = "next_cursor" }
    }
    enum JobStatus: String, Decodable, Sendable {
        case queued, running, succeeded, failed, cancelled
        case deadLetter = "dead_letter"
    }
    enum JobKind: String, Decodable, Sendable {
        case imageAnalysis = "image_analysis", outfitGeneration = "outfit_generation"
        case replacement, trip, purchaseFit = "purchase_fit"
    }
    struct JobDTO: Decodable, Sendable {
        let id: UUID
        let kind: JobKind
        let status: JobStatus
        let attempts: Int
        let errorCode: String?
        enum CodingKeys: String, CodingKey {
            case id, kind, status, attempts
            case errorCode = "error_code"
        }
    }
    struct JobPage: Decodable, Sendable {
        let items: [JobDTO]
        let nextCursor: UUID?
        enum CodingKeys: String, CodingKey { case items; case nextCursor = "next_cursor" }
    }
    struct Failure: Decodable, Error, Sendable, Equatable {
        let code: String
        let message: String
        let requestID: UUID
        enum CodingKeys: String, CodingKey { case code, message; case requestID = "request_id" }
    }
    struct Success<Value: Decodable & Sendable>: Decodable, Sendable {
        let data: Value
        let requestID: UUID
        enum CodingKeys: String, CodingKey { case data; case requestID = "request_id" }
    }
}

enum APIClientError: Error, Equatable {
    case invalidConfiguration, invalidRequest, invalidResponse
    // Gateway/auth failures may not follow the application error envelope.
    case http(status: Int, requestID: String?)
}

protocol APITransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

struct URLSessionTransport: APITransport {
    let session: URLSession

    static func gateway() -> URLSessionTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSessionTransport(session: URLSession(configuration: configuration,
            delegate: GatewayRedirectPolicy(), delegateQueue: nil))
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIClientError.invalidResponse }
        return (data, http)
    }
}

/// Never forward an OTP, opaque session token or private request to a redirect.
final class GatewayRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Supabase/PostgREST RPC transport. No tokens, response bodies or URLs are logged.
/// No automatic retry: ambiguous writes are retried explicitly with SaveGarment.
struct APIClient: Sendable {
    private let baseURL: URL
    private let publicAPIKey: String?
    private let transport: any APITransport
    private let accessToken: @Sendable () async throws -> String
    private let unauthorized: @Sendable (String) async -> Void

    init(baseURL: URL, transport: any APITransport, publicAPIKey: String? = nil,
         unauthorized: @escaping @Sendable (String) async -> Void = { _ in },
         accessToken: @escaping @Sendable () async throws -> String) throws {
        guard baseURL.scheme == "https", baseURL.host != nil,
              baseURL.user == nil, baseURL.password == nil,
              baseURL.query == nil, baseURL.fragment == nil else {
            throw APIClientError.invalidConfiguration
        }
        if let key = publicAPIKey, key.isEmpty || key.contains("\r") || key.contains("\n") {
            throw APIClientError.invalidConfiguration
        }
        self.publicAPIKey = publicAPIKey
        self.baseURL = baseURL
        self.transport = transport
        self.accessToken = accessToken
        self.unauthorized = unauthorized
    }

    func saveGarment(_ operation: APIv1.SaveGarment) async throws -> APIv1.Success<APIv1.GarmentDTO> {
        try operation.validate()
        let result: APIv1.Success<APIv1.GarmentDTO> = try await call("api_v1_save_garment", operation)
        try result.data.validate()
        guard result.data.id == operation.garmentID else { throw APIClientError.invalidResponse }
        return result
    }

    func garments(limit: Int = 50, cursor: UUID? = nil) async throws -> APIv1.Success<APIv1.GarmentPage> {
        guard (1...100).contains(limit) else { throw APIClientError.invalidRequest }
        let result: APIv1.Success<APIv1.GarmentPage> = try await call(
            "api_v1_list_garments", APIv1.PageRequest(limit: limit, cursor: cursor))
        let page = result.data
        guard page.items.count <= limit, Set(page.items.map(\.id)).count == page.items.count,
              page.nextCursor == nil || (page.items.count == limit && page.nextCursor == page.items.last?.id),
              page.nextCursor == nil || page.nextCursor != cursor else { throw APIClientError.invalidResponse }
        for item in page.items { try item.validate() }
        return result
    }

    /// Start with a nil cursor on every relaunch/refresh; status lives on the
    /// server and does not depend on retaining a job ID in process memory.
    func jobs(limit: Int = 50, cursor: UUID? = nil) async throws -> APIv1.Success<APIv1.JobPage> {
        guard (1...100).contains(limit) else { throw APIClientError.invalidRequest }
        let result: APIv1.Success<APIv1.JobPage> = try await call(
            "api_v1_list_jobs", APIv1.PageRequest(limit: limit, cursor: cursor))
        let page = result.data
        guard page.items.count <= limit, Set(page.items.map(\.id)).count == page.items.count,
              page.items.allSatisfy({ $0.attempts >= 0 }),
              page.nextCursor == nil || (page.items.count == limit && page.nextCursor == page.items.last?.id),
              page.nextCursor == nil || page.nextCursor != cursor else { throw APIClientError.invalidResponse }
        return result
    }

    private struct Arguments<Value: Encodable>: Encodable { let request: Value }
    private struct ErrorEnvelope: Decodable { let error: APIv1.Failure }

    func call<Input: Encodable, Output: Decodable & Sendable>(
        _ method: String, _ input: Input
    ) async throws -> APIv1.Success<Output> {
        try Task.checkCancellation()
        var request = URLRequest(url: baseURL.appendingPathComponent("rest/v1/rpc").appendingPathComponent(method))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("app", forHTTPHeaderField: "Content-Profile")
        if let publicAPIKey { request.setValue(publicAPIKey, forHTTPHeaderField: "apikey") }
        let token = try await accessToken()
        guard !token.isEmpty, !token.contains("\r"), !token.contains("\n") else { throw APIClientError.invalidConfiguration }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        request.httpBody = try encoder.encode(Arguments(request: input))
        let (data, response) = try await transport.send(request)
        try Task.checkCancellation()
        if response.statusCode == 401 { await unauthorized(token) }
        let decoder = JSONDecoder()
        if let error = try? decoder.decode(ErrorEnvelope.self, from: data) { throw error.error }
        guard (200...299).contains(response.statusCode) else {
            throw APIClientError.http(status: response.statusCode, requestID: response.value(forHTTPHeaderField: "X-Request-ID"))
        }
        do { return try decoder.decode(APIv1.Success<Output>.self, from: data) }
        catch { throw APIClientError.invalidResponse }
    }
}

actor APIWardrobeRepository: WardrobeRepository {
    let client: APIClient
    private var pages: [Data: WardrobePage] = [:]
    private var details: [UUID: GarmentDetail] = [:]

    init(client: APIClient) { self.client = client }

    private func isOffline(_ error: any Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.notConnectedToInternet, .networkConnectionLost].contains(error.code)
    }
    func page(query: WardrobeQuery, offset: Int, limit: Int) async throws -> WardrobePage {
        struct Request: Encodable { let query: WardrobeQuery; let offset: Int; let limit: Int }
        guard offset >= 0, (1...100).contains(limit), query.search.count <= 200 else { throw APIClientError.invalidRequest }
        let request = Request(query: query, offset: offset, limit: limit)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let key = try encoder.encode(request)
        let page: WardrobePage
        do {
            let result: APIv1.Success<WardrobePage> = try await client.call("api_v1_browse_wardrobe", request)
            page = result.data
        } catch {
            // In-memory, account-scoped metadata only. Auth/deletion errors must
            // never be converted into a cached success.
            if isOffline(error), var saved = pages[key] { saved.cached = true; return saved }
            pages.removeAll(); details.removeAll()
            throw error
        }
        guard page.items.count <= limit, Set(page.items.map(\.id)).count == page.items.count,
              page.nextOffset == nil || (page.items.count == limit && page.nextOffset == offset + limit)
        else { throw APIClientError.invalidResponse }
        if pages.count >= 128 { pages.removeAll() }
        pages[key] = page
        return page
    }

    func detail(id: UUID) async throws -> GarmentDetail {
        struct Request: Encodable { let id: UUID }
        do {
            let result: APIv1.Success<GarmentDetail> = try await client.call("api_v1_garment_detail", Request(id: id))
            guard result.data.garment.id == id else { throw APIClientError.invalidResponse }
            if details.count >= 40 { details.removeAll() }
            details[id] = result.data
            return result.data
        } catch {
            if isOffline(error), var saved = details[id] { saved.cached = true; return saved }
            pages.removeAll(); details.removeAll()
            throw error
        }
    }

    func thumbnail(imageID: UUID) async throws -> Data { try await client.wardrobeThumbnail(imageID: imageID) }
    func original(imageID: UUID) async throws -> Data { try await client.wardrobeImage(imageID: imageID, original: true) }

    func garments() async throws -> [Garment] {
        var result: [Garment] = []
        var cursor: UUID?
        var seen = Set<UUID>()
        repeat {
            let page = try await client.garments(cursor: cursor).data
            for dto in page.items {
                guard seen.insert(dto.id).inserted else { throw APIClientError.invalidResponse }
                result.append(Garment(id: dto.id, name: dto.name))
            }
            cursor = page.nextCursor
        } while cursor != nil
        return result
    }
}

// Construct from the same validated HTTPS origin and current-session provider.
extension APIClient {
    var dataExports: DataExportClient {
        DataExportClient(baseURL: baseURL, publicAPIKey: publicAPIKey,
                         accessToken: accessToken, unauthorized: unauthorized)
    }
}

// The image gateway requires authentication even on signed URLs. Use only its
// same-origin relative URL, and never persist tokens or image response bytes.
extension APIClient {
    func wardrobeThumbnail(imageID: UUID) async throws -> Data {
        try await wardrobeImage(imageID: imageID, original: false)
    }

    func wardrobeImage(imageID: UUID, original: Bool) async throws -> Data {
        let variant = original ? "original" : "thumbnail"
        let path = "/v1/images/\(imageID.uuidString.lowercased())/\(variant)"
        let token = try await accessToken()
        guard !token.isEmpty, !token.contains("\r"), !token.contains("\n") else { throw APIClientError.invalidConfiguration }
        func request(_ url: URL, method: String) -> URLRequest {
            var value = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            value.httpMethod = method
            value.timeoutInterval = 30
            value.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return value
        }
        let origin = URL(string: "https://\(baseURL.host!)\(baseURL.port.map { ":\($0)" } ?? "")")!
        let (data, response) = try await transport.send(request(origin.appendingPathComponent(path + "/url"), method: "POST"))
        if response.statusCode == 401 { await unauthorized(token) }
        guard response.statusCode == 200 else { throw APIClientError.http(status: response.statusCode, requestID: nil) }
        struct Link: Decodable { let url: String }
        let link = try JSONDecoder().decode(Link.self, from: data)
        guard let components = URLComponents(string: link.url), components.scheme == nil, components.host == nil,
              components.path == path, components.fragment == nil,
              let url = URL(string: link.url, relativeTo: origin)?.absoluteURL else { throw APIClientError.invalidResponse }
        let (bytes, imageResponse) = try await transport.send(request(url, method: "GET"))
        if imageResponse.statusCode == 401 { await unauthorized(token) }
        guard imageResponse.statusCode == 200, imageResponse.mimeType == "image/jpeg", bytes.count <= (original ? 12 * 1_048_576 : 1_048_576)
        else { throw APIClientError.invalidResponse }
        try Task.checkCancellation()
        return bytes
    }
}
