import Foundation
import Observation
import SwiftUI

struct DataExportTicket: Decodable, Sendable {
    let id: UUID
    let expires_at: Date
}

protocol DataExportService: Sendable {
    func request(id: UUID) async throws -> DataExportTicket
    func download(_ ticket: DataExportTicket) async throws -> URL
}

// Never forward an account token to a redirect destination; no response cache.
private final class ExportSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct DataExportClient: DataExportService {
    let baseURL: URL
    let publicAPIKey: String?
    let accessToken: @Sendable () async throws -> String
    let unauthorized: @Sendable (String) async -> Void
    private let session: URLSession

    init(baseURL: URL, publicAPIKey: String?, accessToken: @escaping @Sendable () async throws -> String,
         unauthorized: @escaping @Sendable (String) async -> Void) {
        self.baseURL = baseURL
        self.publicAPIKey = publicAPIKey
        self.accessToken = accessToken
        self.unauthorized = unauthorized
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForResource = 900
        session = URLSession(configuration: configuration, delegate: ExportSessionDelegate(), delegateQueue: nil)
    }

    static var temporaryDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("DataExports", isDirectory: true)
    }

    // Called once on launch, before any download. Removes crash-left copies.
    static func clearPreviousDownloads() {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    private func requestURL(_ id: UUID, archive: Bool) async throws -> (URLRequest, String) {
        let token = try await accessToken()
        guard !token.isEmpty, !token.contains("\r"), !token.contains("\n") else { throw AuthError.expired }
        var url = baseURL.appendingPathComponent("v1/exports").appendingPathComponent(id.uuidString.lowercased())
        if archive { url.appendPathComponent("archive") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpMethod = archive ? "GET" : "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let publicAPIKey { request.setValue(publicAPIKey, forHTTPHeaderField: "apikey") }
        return (request, token)
    }

    private func validate(_ response: URLResponse, token: String) async throws {
        guard let http = response as? HTTPURLResponse else { throw APIClientError.invalidResponse }
        if http.statusCode == 401 { await unauthorized(token) }
        guard http.statusCode == 200 else { throw APIClientError.http(status: http.statusCode, requestID: nil) }
    }

    func request(id: UUID) async throws -> DataExportTicket {
        let (request, token) = try await requestURL(id, archive: false)
        let (data, response) = try await session.data(for: request)
        try await validate(response, token: token)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: value) else { throw APIClientError.invalidResponse }
            return date
        }
        let ticket = try decoder.decode(DataExportTicket.self, from: data)
        guard ticket.id == id, ticket.expires_at > Date() else { throw APIClientError.invalidResponse }
        return ticket
    }

    func download(_ ticket: DataExportTicket) async throws -> URL {
        guard ticket.expires_at > Date() else { throw APIClientError.invalidRequest }
        let (request, token) = try await requestURL(ticket.id, archive: true)
        let (temporary, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await validate(response, token: token)
        guard response.mimeType == "application/x-tar", ticket.expires_at > Date() else { throw APIClientError.invalidResponse }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: Self.temporaryDirectory, withIntermediateDirectories: true,
                                               attributes: [.protectionKey: FileProtectionType.complete])
        let destination = Self.temporaryDirectory.appendingPathComponent("export-\(ticket.id).tar")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        do {
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: destination.path)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return destination
    }
}

@MainActor @Observable
final class DataExportModel {
    private(set) var busy = false
    private(set) var ticket: DataExportTicket?
    private(set) var file: URL?
    private(set) var message: String?
    private(set) var operationID = UUID()
    private let service: (any DataExportService)?
    private var generation = UUID()

    init(service: (any DataExportService)?) { self.service = service }

    func prepare() async {
        guard !busy else { return }
        guard let service else { message = "export.unconfigured"; return }
        busy = true
        let current = generation
        defer { if generation == current { busy = false } }
        do {
            let result = try await service.request(id: operationID)
            guard generation == current, !Task.isCancelled else { return }
            ticket = result
            message = nil
        } catch {
            if generation == current { message = "export.error" }
        }
    }

    func download() async {
        guard !busy, let ticket, let service else { return }
        busy = true
        let current = generation
        defer { if generation == current { busy = false } }
        do {
            let result = try await service.download(ticket)
            guard generation == current, !Task.isCancelled else {
                try? FileManager.default.removeItem(at: result)
                return
            }
            file = result
            message = nil
        } catch {
            if generation == current { message = "export.error" }
        }
    }

    func clear() {
        generation = UUID()
        if let file { try? FileManager.default.removeItem(at: file) }
        file = nil
        busy = false
    }

    func expire() {
        clear()
        message = "export.expired"
    }

    func startAgain() {
        clear()
        ticket = nil
        operationID = UUID()
        message = nil
    }
}

struct DataExportView: View {
    @State private var model: DataExportModel
    @State private var operation: Task<Void, Never>?

    init(service: (any DataExportService)?) {
        _model = State(initialValue: DataExportModel(service: service))
    }

    var body: some View {
        Form {
            Section { Text("export.description"); Text("export.synced"); Text("export.copies") }
            if let ticket = model.ticket {
                Section {
                    LabeledContent("export.expires") { Text(ticket.expires_at, style: .time) }
                    if let file = model.file {
                        ShareLink("export.save", item: file)
                    } else {
                        Button("export.download") { operation = Task { await model.download() } }
                            .disabled(model.busy || ticket.expires_at <= Date())
                    }
                }
            } else {
                Button("export.request") { operation = Task { await model.prepare() } }.disabled(model.busy)
            }
            if model.busy { ProgressView() }
            if let message = model.message { Text(LocalizedStringKey(message)) }
            Button("export.new") { model.startAgain() }.disabled(model.busy)
        }
        .navigationTitle("export.title")
        .onDisappear { operation?.cancel(); model.clear() }
        .task(id: model.ticket?.id) {
            guard let ticket = model.ticket else { return }
            let delay = max(0, ticket.expires_at.timeIntervalSinceNow)
            do {
                try await Task.sleep(for: .seconds(delay))
                operation?.cancel()
                model.expire()
            } catch { /* Navigation cancelled the expiry timer. */ }
        }
    }
}
