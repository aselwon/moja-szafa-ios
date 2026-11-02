import Foundation

/// Wire contracts are versioned independently from domain/view models.
enum APIv1 {
    enum Category: String, Codable, Sendable, CaseIterable {
        case top, bottom, shoes, dress, jumpsuit, outerwear, accessory, other
    }
    enum Availability: String, Codable, Sendable { case available, laundry, unavailable }

    struct GarmentFields: Codable, Sendable, Equatable {
        let name: String
        let category: Category
        let priceGrosz: Int64?
        let availability: Availability

        enum CodingKeys: String, CodingKey {
            case name, category, availability
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
        }
    }
    struct GarmentDTO: Decodable, Sendable, Equatable {
        let id: UUID
        let version: Int64
        let name: String
        let category: Category
        let priceGrosz: Int64?
        let availability: Availability
        enum CodingKeys: String, CodingKey {
            case id, version, name, category, availability
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
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIClientError.invalidResponse }
        return (data, http)
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

struct APIWardrobeRepository: WardrobeRepository {
    let client: APIClient
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
