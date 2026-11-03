import XCTest
@testable import MojaSzafa

private actor ExportStub: DataExportService {
    var ids: [UUID] = []
    let file: URL
    var holdDownload = false
    var continuation: CheckedContinuation<Void, Never>?
    func hold() { holdDownload = true }
    func waiting() -> Bool { continuation != nil }
    func release() { continuation?.resume(); continuation = nil }
    init(file: URL) { self.file = file }
    func request(id: UUID) async throws -> DataExportTicket {
        ids.append(id)
        if ids.count == 1 { throw URLError(.timedOut) }
        return DataExportTicket(id: id, expires_at: Date().addingTimeInterval(900))
    }
    func download(_ ticket: DataExportTicket) async throws -> URL {
        try Data("archive".utf8).write(to: file)
        if holdDownload { await withCheckedContinuation { continuation = $0 } }
        return file
    }
    func requestedIDs() -> [UUID] { ids }
}

@MainActor
final class DataExportTests: XCTestCase {
    func testTimeoutRetainsOperationAndCleanupRemovesPrivateFile() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let service = ExportStub(file: file)
        let model = DataExportModel(service: service)
        await model.prepare()
        XCTAssertNil(model.ticket)
        XCTAssertNotNil(model.message)
        await model.prepare()
        let ids = await service.requestedIDs()
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(ids[0], ids[1])
        XCTAssertNotNil(model.ticket)
        await model.download()
        XCTAssertEqual(model.file, file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        model.clear()
        XCTAssertNil(model.file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let previous = model.operationID
        model.startAgain()
        XCTAssertNotEqual(model.operationID, previous)
        XCTAssertNil(model.ticket)
    }

    func testLateDownloadAfterNavigationIsErased() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let service = ExportStub(file: file)
        let model = DataExportModel(service: service)
        await model.prepare()
        await model.prepare()
        await service.hold()
        let download = Task { await model.download() }
        while !(await service.waiting()) { await Task.yield() }
        model.clear()
        await service.release()
        await download.value
        XCTAssertNil(model.file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertFalse(model.busy)
    }

    func testUnconfiguredServiceNeverReportsSuccess() async {
        let model = DataExportModel(service: nil)
        await model.prepare()
        XCTAssertNil(model.ticket)
        XCTAssertEqual(model.message, "export.unconfigured")
        XCTAssertFalse(model.busy)
    }
}
