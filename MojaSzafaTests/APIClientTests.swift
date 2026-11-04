import XCTest
@testable import MojaSzafa

final class APIClientTests: XCTestCase {
    func testGarmentDeletionUsesCanonicalGatewayRPCPath() async throws {
        let operation = DeleteGarment(operationID: UUID(), garmentID: UUID())
        try await client(DeletionTransport(operation: operation)).delete(operation)
    }
    private func operation(price: Int64? = nil, version: Int64? = nil) -> APIv1.SaveGarment {
        APIv1.SaveGarment(operationID: UUID(), garmentID: UUID(), baseVersion: version,
            garment: .init(name: "Koszula", category: .top, priceGrosz: price, availability: .available))
    }
    private func client(_ transport: any APITransport) throws -> APIClient {
        try APIClient(baseURL: XCTUnwrap(URL(string: "https://example.invalid")),
                      transport: transport, accessToken: { "test-only-token" })
    }

    func testNewClientRecoversJobStatusWithoutRememberedJobID() async throws {
        let id = UUID()
        let transport = JobStatusTransport(id: id)
        let beforeRestart = try await client(transport).jobs()
        XCTAssertEqual(beforeRestart.data.items.first?.status, .running)
        // A new client has no retained job IDs, polling cursor or running task.
        let afterRestart = try await client(transport).jobs()
        XCTAssertEqual(afterRestart.data.items.first?.id, id)
        XCTAssertEqual(afterRestart.data.items.first?.status, .succeeded)
        XCTAssertNil(afterRestart.data.nextCursor)
    }

    func testJobsRejectInvalidStatusAndNegativeAttempts() async throws {
        for (status, attempts) in [("invented", 1), ("running", -1)] {
            let item: [String: Any] = ["id": UUID().uuidString, "kind": "image_analysis",
                                       "status": status, "attempts": attempts, "error_code": NSNull()]
            let page: [String: Any] = ["items": [item], "next_cursor": NSNull()]
            let envelope: [String: Any] = [
                "request_id": UUID().uuidString,
                "data": page
            ]
            let body = try JSONSerialization.data(withJSONObject: envelope)
            do {
                _ = try await client(FixedTransport(body: body, status: 200)).jobs()
                XCTFail("Malformed job response accepted")
            } catch let error as APIClientError { XCTAssertEqual(error, .invalidResponse) }
        }
    }

    func testTimeoutRetryPreservesOperationAndSerializedBody() async throws {
        let operation = operation(price: 80000)
        let transport = CommittedThenTimedOutTransport()
        let client = try client(transport)
        do {
            _ = try await client.saveGarment(operation)
            XCTFail("First committed response must time out")
        } catch let error as URLError { XCTAssertEqual(error.code, .timedOut) }
        // Roundtrip models restoring the same operation from a future outbox.
        let restored = try JSONDecoder().decode(APIv1.SaveGarment.self, from: JSONEncoder().encode(operation))
        let result = try await client.saveGarment(restored)
        XCTAssertEqual(result.data.id, operation.garmentID)
        XCTAssertEqual(result.data.version, 1)
        let state = await transport.snapshot()
        XCTAssertEqual(state.bodies.count, 2)
        XCTAssertEqual(state.bodies.first, state.bodies.last)
        XCTAssertEqual(state.records, 1)
    }

    func testNullPriceAndCreateVersionAreExplicitJSONNull() throws {
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(operation())) as? [String: Any])
        XCTAssertTrue(value["base_version"] is NSNull)
        XCTAssertTrue((value["garment"] as? [String: Any])?["price_grosz"] is NSNull)
    }

    func testInvalidInputDoesNotReachTransport() async throws {
        let transport = FixedTransport(body: Data(), status: 200)
        let client = try client(transport)
        for invalid in [operation(price: -1), operation(version: 0)] {
            do { _ = try await client.saveGarment(invalid); XCTFail("Invalid mutation") }
            catch let error as APIClientError { XCTAssertEqual(error, .invalidRequest) }
        }
        for limit in [0, 101] {
            do { _ = try await client.garments(limit: limit); XCTFail("Invalid limit") }
            catch let error as APIClientError { XCTAssertEqual(error, .invalidRequest) }
        }
        let calls = await transport.calls
        XCTAssertEqual(calls, 0)
    }

    func testServerErrorPreservesRequestIDAndCode() async throws {
        let id = UUID()
        let body = Data("{\"error\":{\"code\":\"idempotency_conflict\",\"message\":\"Conflict\",\"request_id\":\"\(id)\"}}".utf8)
        do { _ = try await client(FixedTransport(body: body, status: 200)).saveGarment(operation()); XCTFail("Expected error") }
        catch let error as APIv1.Failure {
            XCTAssertEqual(error.requestID, id)
            XCTAssertEqual(error.code, "idempotency_conflict")
        }
    }

    func testMalformedSuccessAndGatewayFailureAreDistinct() async throws {
        do { _ = try await client(FixedTransport(body: Data("{}".utf8), status: 200)).garments(); XCTFail("Malformed success") }
        catch let error as APIClientError { XCTAssertEqual(error, .invalidResponse) }
        do { _ = try await client(FixedTransport(body: Data(), status: 401)).garments(); XCTFail("Expired token") }
        catch let error as APIClientError { XCTAssertEqual(error, .http(status: 401, requestID: "gateway-test")) }
    }

    func testPaginationAggregatesAndUsesCursor() async throws {
        let first = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let second = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        // API client validates a full non-final page. Test limit=1 directly.
        let transport = PagingTransport(first: first, second: second)
        let client = try client(transport)
        let page = try await client.garments(limit: 1)
        XCTAssertEqual(page.data.nextCursor, first)
        let last = try await client.garments(limit: 1, cursor: page.data.nextCursor)
        XCTAssertNil(last.data.nextCursor)
        XCTAssertEqual(last.data.items.map(\.id), [second])
        let requests = await transport.requests
        XCTAssertEqual(requests, 2)
    }

    func testCancellationIsPropagated() async throws {
        let client = try client(FixedTransport(body: Data(), status: 200, cancelled: true))
        do { _ = try await client.garments(); XCTFail("Expected cancellation") }
        catch is CancellationError { }
    }

    func testRejectsInsecureConfiguration() throws {
        XCTAssertThrowsError(try APIClient(baseURL: XCTUnwrap(URL(string: "http://example.invalid")),
            transport: FixedTransport(body: Data(), status: 200), accessToken: { "test" }))
    }
}

private func response(_ request: URLRequest, status: Int = 200) -> HTTPURLResponse {
    HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                    headerFields: ["X-Request-ID": "gateway-test"])!
}
private actor DeletionTransport: APITransport {
    let operation: DeleteGarment
    init(operation: DeleteGarment) { self.operation = operation }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        XCTAssertEqual(request.url?.path, "/rest/v1/rpc/api_v1_delete_garment")
        XCTAssertEqual(request.httpMethod, "POST")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let payload = try XCTUnwrap(root["request"] as? [String: Any])
        XCTAssertEqual(Set(payload.keys), ["operationID", "garmentID"])
        XCTAssertEqual((payload["operationID"] as? String)?.lowercased(), operation.operationID.uuidString.lowercased())
        XCTAssertEqual((payload["garmentID"] as? String)?.lowercased(), operation.garmentID.uuidString.lowercased())
        return (try JSONSerialization.data(withJSONObject: ["data": true, "request_id": UUID().uuidString]), response(request))
    }
}
private func garment(_ id: UUID) -> [String: Any] {
    ["id": id.uuidString, "version": 1, "name": "Koszula", "category": "top",
     "price_grosz": NSNull(), "availability": "available"]
}

private actor FixedTransport: APITransport {
    let body: Data
    let status: Int
    let cancelled: Bool
    private(set) var calls = 0
    init(body: Data, status: Int, cancelled: Bool = false) {
        self.body = body; self.status = status; self.cancelled = cancelled
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        calls += 1
        if cancelled { throw CancellationError() }
        return (body, response(request, status: status))
    }
}

/// Client contract test only; the real SQL replay behavior is tested separately.
private actor CommittedThenTimedOutTransport: APITransport {
    var saved: [String: Data] = [:]
    var bodies: [Data] = []
    func snapshot() -> (bodies: [Data], records: Int) { (bodies, saved.count) }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        XCTAssertEqual(request.url?.path, "/rest/v1/rpc/api_v1_save_garment")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Profile"), "app")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-only-token")
        let body = try XCTUnwrap(request.httpBody)
        bodies.append(body)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let payload = try XCTUnwrap(root["request"] as? [String: Any])
        let key = try XCTUnwrap(payload["operation_id"] as? String)
        if let saved = saved[key] { return (saved, response(request)) }
        let id = try XCTUnwrap((payload["garment_id"] as? String).flatMap(UUID.init(uuidString:)))
        saved[key] = try JSONSerialization.data(withJSONObject: ["data": garment(id), "request_id": UUID().uuidString])
        throw URLError(.timedOut)
    }
}

private actor PagingTransport: APITransport {
    let first: UUID
    let second: UUID
    private(set) var requests = 0
    init(first: UUID, second: UUID) { self.first = first; self.second = second }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests += 1
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let args = try XCTUnwrap(root["request"] as? [String: Any])
        XCTAssertEqual(args["limit"] as? Int, 1)
        let isFirst = args["cursor"] is NSNull
        if !isFirst { XCTAssertEqual(args["cursor"] as? String, first.uuidString) }
        let page: [String: Any] = ["items": [garment(isFirst ? first : second)],
                                    "next_cursor": isFirst ? first.uuidString as Any : NSNull()]
        return (try JSONSerialization.data(withJSONObject: ["data": page, "request_id": UUID().uuidString]), response(request))
    }
}

private actor JobStatusTransport: APITransport {
    let id: UUID
    var requests = 0
    init(id: UUID) { self.id = id }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests += 1
        XCTAssertEqual(request.url?.path, "/rest/v1/rpc/api_v1_list_jobs")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let args = try XCTUnwrap(root["request"] as? [String: Any])
        XCTAssertTrue(args["cursor"] is NSNull)
        let page: [String: Any] = ["items": [["id": id.uuidString, "kind": "image_analysis",
            "status": requests == 1 ? "running" : "succeeded", "attempts": 2, "error_code": NSNull()]],
            "next_cursor": NSNull()]
        return (try JSONSerialization.data(withJSONObject: ["data": page, "request_id": UUID().uuidString]), response(request))
    }
}
