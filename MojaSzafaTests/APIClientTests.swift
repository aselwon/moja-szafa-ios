import XCTest
@testable import MojaSzafa

final class APIClientTests: XCTestCase {
    func testRecognitionUploadUsesPrivateDraftEndpointAndRejectsForeignAcknowledgement() async throws {
        let draft = UUID(), image = UUID(), bytes = Data([1, 2, 3])
        for mode in ["success", "foreign-url", "wrong-ack"] {
            let transport = ImportPhotoTransport(garmentID: draft, imageID: image, bytes: bytes, mode: mode, recognition: true)
            do {
                try await client(transport).uploadRecognitionPhoto(draftID: draft, imageID: image, data: bytes)
                XCTAssertEqual(mode, "success")
            } catch { XCTAssertNotEqual(mode, "success"); XCTAssertEqual(error as? APIClientError, .invalidResponse) }
            let puts = await transport.putCount
            XCTAssertEqual(puts, mode == "foreign-url" ? 0 : 1)
        }
    }

    func testRecognitionResultRejectsForeignBindingAndInvalidState() async throws {
        let draft = UUID(), image = UUID(), job = UUID()
        let valid: [String: Any] = ["draft_id": draft.uuidString, "image_id": image.uuidString,
                                   "job_id": job.uuidString, "status": "running"]
        for key in ["valid", "draft_id", "image_id", "job_id", "status", "result"] {
            var payload = valid
            if key == "status" { payload[key] = "invented" }
            else if key == "result" { payload["status"] = "succeeded"; payload[key] = ["unexpected": "metadata"] }
            else if key != "valid" { payload[key] = UUID().uuidString }
            let body = try JSONSerialization.data(withJSONObject: ["request_id": UUID().uuidString, "data": payload])
            do {
                _ = try await client(FixedTransport(body: body, status: 200)).recognitionResult(draftID: draft, imageID: image, jobID: job)
                XCTAssertEqual(key, "valid")
            } catch { XCTAssertNotEqual(key, "valid") }
        }
    }

    func testRecognitionCleanupAcceptsOnlyConfirmedDiscardOrCanonicalAbsence() async throws {
        let requestID = UUID().uuidString
        let success = Data("{\"request_id\":\"\(requestID)\",\"data\":{\"discarded\":true}}".utf8)
        try await client(FixedTransport(body: success, status: 200)).discardRecognition(draftID: UUID())
        for code in ["not_found", "unauthorized", "internal_error"] {
            let body = Data("{\"error\":{\"code\":\"\(code)\",\"message\":\"Synthetic failure\",\"request_id\":\"\(requestID)\"}}".utf8)
            do {
                try await client(FixedTransport(body: body, status: 200)).discardRecognition(draftID: UUID())
                XCTAssertEqual(code, "not_found")
            } catch let error as APIv1.Failure {
                XCTAssertNotEqual(code, "not_found"); XCTAssertEqual(error.code, code)
            }
        }
        for status in [401, 404, 503] {
            do {
                try await client(FixedTransport(body: Data(), status: status)).discardRecognition(draftID: UUID())
                XCTFail("Unconfirmed remote absence must retain cleanup")
            } catch { XCTAssertTrue(error is APIClientError) }
        }
    }

    func testOnlyExplicitExpiredPrepareResponseRotatesPhotoIdentity() async throws {
        for (status, code) in [(409, "image_upload_expired"), (409, "other_conflict"), (403, "image_upload_expired")] {
            let body = try JSONEncoder().encode(["code": code])
            do {
                try await client(FixedTransport(body: body, status: status)).uploadGarmentPhoto(garmentID: UUID(), imageID: UUID(), data: Data([1]))
                XCTFail("Failure response accepted")
            } catch {
                if status == 409 && code == "image_upload_expired" { XCTAssertEqual(error as? PhotoUploadError, .expired) }
                else { XCTAssertEqual(error as? APIClientError, .http(status: status, requestID: nil)) }
            }
        }
    }

    func testPairedUploadAndCleanedFetchUseExplicitBoundedContracts() async throws {
        let garmentID = UUID(), imageID = UUID()
        let photos = try GarmentPhotos(original: Data([255,216,1]), cleaned: Data([137,80,78,71]))
        let expected = Data([0,0,0,3,255,216,1,137,80,78,71])
        XCTAssertEqual(photos.uploadData, expected)
        let transport = ImportPhotoTransport(garmentID: garmentID, imageID: imageID, bytes: expected, mode: "paired")
        try await client(transport).uploadGarmentPhotos(garmentID: garmentID, imageID: imageID, photos: photos)
        let count = await transport.putCount; XCTAssertEqual(count, 1)
        for mime in ["image/png", "image/jpeg"] {
            do {
                let bytes = try await client(CleanedPhotoTransport(id: imageID, mime: mime)).cleanedImage(id: imageID)
                XCTAssertEqual(mime, "image/png"); XCTAssertEqual(bytes, Data([137,80,78,71]))
            } catch {
                XCTAssertEqual(mime, "image/jpeg"); XCTAssertEqual(error as? APIClientError, .invalidResponse)
            }
        }
    }

    func testImportedMetadataSurvivesDurableOperationEncoding() throws {
        var fields = APIv1.GarmentFields(name: "Blue shirt", category: .top, priceGrosz: 4500, availability: .available)
        fields.metadata = .init(colors: ["blue"], seasons: ["summer"], pattern: nil,
                                formality: 2, brand: "Example", purchasedOn: "2026-01-01")
        let original = APIv1.SaveGarment(operationID: UUID(), garmentID: UUID(), baseVersion: nil, garment: fields)
        let encoded = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(APIv1.SaveGarment.self, from: encoded)
        XCTAssertEqual(restored.operationID, original.operationID)
        XCTAssertEqual(restored.garment, original.garment)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let garment = try XCTUnwrap(object["garment"] as? [String: Any])
        let metadata = try XCTUnwrap(garment["metadata"] as? [String: Any])
        XCTAssertTrue(metadata["pattern"] is NSNull)
        XCTAssertEqual(metadata["purchased_on"] as? String, "2026-01-01")
    }

    func testWardrobeUploadUsesStableIdentityAndRejectsForeignURLOrAcknowledgement() async throws {
        let garmentID = UUID(), imageID = UUID()
        let bytes = Data([1, 2, 3])
        for mode in ["success", "foreign-url", "wrong-ack"] {
            let transport = ImportPhotoTransport(garmentID: garmentID, imageID: imageID, bytes: bytes, mode: mode)
            do {
                try await client(transport).uploadGarmentPhoto(garmentID: garmentID, imageID: imageID, data: bytes)
                XCTAssertEqual(mode, "success")
            } catch {
                XCTAssertNotEqual(mode, "success")
                XCTAssertEqual(error as? APIClientError, .invalidResponse)
            }
            let count = await transport.putCount
            XCTAssertEqual(count, mode == "foreign-url" ? 0 : 1)
        }
    }
    func testSubscriptionStatusPreservesServerStateAndRejectsForeignOrMalformedChains() async throws {
        let configuration = try XCTUnwrap(SubscriptionConfiguration(monthlyID: "test.monthly", yearlyID: "test.yearly"))
        let environment = Bundle.main.object(forInfoDictionaryKey: "AppEnvironment") as? String
        let item: [String: Any] = ["productID": "test.monthly", "originalTransactionID": "7",
            "environment": environment == "prod" ? "production" : "sandbox", "status": "revoked",
            "expiresAt": "2070-01-01T00:00:00.123+00:00", "graceExpiresAt": NSNull()]
        func body(_ items: [[String: Any]]) throws -> Data { try JSONSerialization.data(withJSONObject: ["entitlements": items]) }
        let data = try body([item])
        let values = try await client(SubscriptionStatusTransport(body: data)).entitlements(configuration: configuration)
        XCTAssertEqual(values.count, 1); XCTAssertEqual(values[0].status, .revoked, "Future expiry must not override the server's revocation")
        XCTAssertNil(values[0].graceExpiresAt)
        for (key, value) in [("productID", "foreign.product"), ("originalTransactionID", "007"),
                             ("environment", "Xcode"), ("status", "paid_unlimited"), ("expiresAt", "not-a-date"), ("graceExpiresAt", "not-a-date")] {
            var wrong = item; wrong[key] = value
            do { _ = try await client(FixedTransport(body: body([wrong]), status: 200)).entitlements(configuration: configuration); XCTFail("Invalid entitlement accepted") }
            catch { XCTAssertEqual(error as? APIClientError, .invalidResponse) }
        }
        do { _ = try await client(FixedTransport(body: body([item, item]), status: 200)).entitlements(configuration: configuration); XCTFail("Duplicate chain accepted") }
        catch { XCTAssertEqual(error as? APIClientError, .invalidResponse) }
    }
    func testSubscriptionPreflightRequiresMatchingServerCatalogAndBuildEnvironment() async throws {
        let configuration = try XCTUnwrap(SubscriptionConfiguration(monthlyID: "test.monthly", yearlyID: "test.yearly"))
        let environment = Bundle.main.object(forInfoDictionaryKey: "AppEnvironment") as? String
        let catalog: [String: Any] = ["available": true, "bundleID": try XCTUnwrap(Bundle.main.bundleIdentifier),
            "environment": environment == "prod" ? "production" : "sandbox", "monthlyProductID": "test.monthly", "yearlyProductID": "test.yearly"]
        try await client(FixedTransport(body: JSONSerialization.data(withJSONObject: catalog), status: 200)).preparePurchase(configuration: configuration)
        for (key, value) in [("available", false as Any), ("bundleID", "foreign.app" as Any),
                             ("environment", "Xcode" as Any), ("monthlyProductID", "foreign.product" as Any)] {
            var wrong = catalog; wrong[key] = value
            do {
                try await client(FixedTransport(body: JSONSerialization.data(withJSONObject: wrong), status: 200)).preparePurchase(configuration: configuration)
                XCTFail("Mismatched subscription catalog accepted")
            } catch { XCTAssertEqual(error as? SubscriptionError, .serverUnavailable) }
        }
    }
    func testSubscriptionReceiptUsesAuthenticatedBodyAndExactServerAcknowledgement() async throws {
        let transport = SubscriptionReceiptTransport()
        let receipt = VerifiedStoreTransaction(id: 7, originalID: 7, productID: "test.monthly", accountToken: UUID(), signedRepresentation: "synthetic-signed-receipt")
        let acknowledgement = try await client(transport).receive(receipt)
        XCTAssertEqual(acknowledgement.transactionID, 7)
        for id in ["8", "007", "-7", "18446744073709551616"] {
            let body = try JSONSerialization.data(withJSONObject: ["transactionID": id])
            do { _ = try await client(FixedTransport(body: body, status: 200)).receive(receipt); XCTFail("Wrong acknowledgement accepted") }
            catch { XCTAssertEqual(error as? SubscriptionError, .invalidAcknowledgement) }
        }
    }
    func testSubscriptionUnavailableBackendNeverAcknowledgesReceipt() async throws {
        let receipt = VerifiedStoreTransaction(id: 7, originalID: 7, productID: "test.monthly", accountToken: UUID(), signedRepresentation: "synthetic-signed-receipt")
        for status in [401, 403, 422, 503] {
            do { _ = try await client(FixedTransport(body: Data(), status: status)).receive(receipt); XCTFail("Rejected receipt acknowledged") }
            catch { XCTAssertEqual(error as? APIClientError, .http(status: status, requestID: nil)) }
        }
    }
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

private actor SubscriptionStatusTransport: APITransport {
    let body: Data
    init(body: Data) { self.body = body }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        XCTAssertEqual(request.url?.path, "/v1/subscriptions/status")
        XCTAssertEqual(request.httpMethod, "GET"); XCTAssertNil(request.httpBody); XCTAssertNil(request.url?.query)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-only-token")
        return (body, response(request))
    }
}

private actor SubscriptionReceiptTransport: APITransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        XCTAssertEqual(request.url?.path, "/v1/subscriptions/transactions")
        XCTAssertNil(request.url?.query)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-only-token")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
        XCTAssertEqual(body, ["signedTransaction": "synthetic-signed-receipt"])
        return (Data("{\"transactionID\":\"7\"}".utf8), response(request))
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

private actor ImportPhotoTransport: APITransport {
    let garmentID: UUID
    let imageID: UUID
    let bytes: Data
    let mode: String
    let recognition: Bool
    private(set) var putCount = 0
    init(garmentID: UUID, imageID: UUID, bytes: Data, mode: String, recognition: Bool = false) {
        self.garmentID = garmentID; self.imageID = imageID; self.bytes = bytes; self.mode = mode
        self.recognition = recognition
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        XCTAssertEqual(request.url?.host, "example.invalid")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-only-token")
        let body: [String: String]
        let prefix = recognition ? "/v1/recognition-images/uploads" : "/v1/images/uploads"
        if request.httpMethod == "POST" {
            XCTAssertEqual(request.url?.path, prefix)
            let input = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            let parent = input[recognition ? "draft_id" : "garment_id"] as? String
            let operation = input["operation_id"] as? String
            let hasCleaned = input["has_cleaned"] as? Bool
            XCTAssertEqual(parent, garmentID.uuidString.lowercased())
            if recognition {
                let hasGarment = input.keys.contains("garment_id")
                let hasCandidate = input.keys.contains("candidate_id")
                XCTAssertFalse(hasGarment); XCTAssertFalse(hasCandidate)
            }
            XCTAssertEqual(operation, imageID.uuidString.lowercased())
            XCTAssertEqual(hasCleaned, mode == "paired" ? true : nil)
            let path = "\(prefix)/\(imageID.uuidString.lowercased())?token=test-upload"
            body = ["image_id": imageID.uuidString, "upload_url": mode == "foreign-url" ? "https://foreign.invalid" + path : path]
        } else {
            putCount += 1
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.path, "\(prefix)/\(imageID.uuidString.lowercased())")
            XCTAssertEqual(request.httpBody, bytes)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), mode == "paired" ? "application/vnd.szafa.image-pair" : "application/octet-stream")
            body = ["image_id": (mode == "wrong-ack" ? UUID() : imageID).uuidString]
        }
        return (try JSONEncoder().encode(body), try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)))
    }
}

private struct CleanedPhotoTransport: APITransport {
    let id: UUID
    let mime: String
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = "/v1/images/\(id.uuidString.lowercased())/cleaned"
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-only-token")
        XCTAssertEqual(request.url?.host, "example.invalid")
        let body: Data
        if request.httpMethod == "POST" {
            XCTAssertEqual(request.url?.path, path + "/url")
            body = try JSONEncoder().encode(["url": path + "?token=fixture"])
        } else {
            XCTAssertEqual(request.url?.path, path)
            body = Data([137,80,78,71])
        }
        return (body, try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": request.httpMethod == "POST" ? "application/json" : mime])))
    }
}
