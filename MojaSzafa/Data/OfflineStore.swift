import Foundation
import SQLite3

/// A single account snapshot and its outbox share one SQLite transaction. Open per
/// transaction so the Sendable value never transfers a SQLite handle across actors.
struct OfflineDatabase: Sendable {
    let url: URL

    func read() throws -> Data? {
        try access { db in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT payload FROM state WHERE id = 1", -1, &statement, nil) == SQLITE_OK else {
                throw OfflineError.storage
            }
            defer { sqlite3_finalize(statement) }
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW, let bytes = sqlite3_column_blob(statement, 0) else { throw OfflineError.storage }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
        }
    }

    func write(_ data: Data) throws {
        try access { db in
            guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw OfflineError.storage }
            defer { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO state VALUES (1, ?)", -1, &statement, nil) == SQLITE_OK else {
                throw OfflineError.storage
            }
            defer { sqlite3_finalize(statement) }
            let result = data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, 1, bytes.baseAddress, Int32(bytes.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            guard result == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE,
                  sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw OfflineError.storage }
        }
    }

    private func access<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let db = handle else {
            if let handle { sqlite3_close(handle) }
            throw OfflineError.storage
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5_000)
        guard sqlite3_exec(db, "PRAGMA synchronous=FULL; PRAGMA secure_delete=ON; CREATE TABLE IF NOT EXISTS state (id INTEGER PRIMARY KEY CHECK(id=1), payload BLOB NOT NULL)", nil, nil, nil) == SQLITE_OK else {
            throw OfflineError.storage
        }
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
        var resourceURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try resourceURL.setResourceValues(values)
        return try body(db)
    }
}

enum OfflineError: Error, Equatable {
    case storage, accountMismatch, accountDeleted, invalidState, pendingChange, conflict
}

struct SyncGarment: Codable, Sendable {
    let id: UUID
    let version: Int64
    let deleted: Bool
    let fields: APIv1.GarmentFields
    var metadata: Garment? = nil

    var display: Garment {
        Garment(id: id, name: fields.name, category: fields.category,
                availability: fields.availability, priceGrosz: fields.priceGrosz,
                imageID: metadata?.imageID, brand: metadata?.brand,
                colors: metadata?.colors ?? [], seasons: metadata?.seasons ?? [],
                archived: fields.archived ?? metadata?.archived ?? false, initialWearHistory: metadata?.initialWearHistory)
    }
}

struct SyncWear: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let version: Int64
    let deleted: Bool
    let wornOn: String
    let timezone: String
    let garmentIDs: [UUID]

    func validate(now: Date = Date()) throws {
        guard version >= 0, !deleted, let zone = TimeZone(identifier: timezone), !garmentIDs.isEmpty,
              garmentIDs.count <= 100, Set(garmentIDs).count == garmentIDs.count else { throw APIClientError.invalidRequest }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let day = formatter.date(from: wornOn), formatter.string(from: day) == wornOn,
              wornOn <= formatter.string(from: now) else { throw APIClientError.invalidRequest }
    }
}

struct SyncSnapshot: Codable, Sendable {
    let accountID: UUID
    let garments: [SyncGarment]
    let wears: [SyncWear]
}

struct SaveWear: Codable, Sendable {
    let operationID: UUID
    let wear: SyncWear
}

struct WearVisibility: Codable, Sendable {
    let operationID: UUID
    let id: UUID
    let baseVersion: Int64
    let action: String
}

struct SaveInitialHistory: Codable, Sendable {
    let operationID: UUID
    let id: UUID
    let baseVersion: Int64
    let history: InitialWearHistory?
    let confirmOverlap: Bool
    enum CodingKeys: String, CodingKey { case operationID, id, baseVersion, history, confirmOverlap }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(operationID, forKey: .operationID)
        try c.encode(id, forKey: .id)
        try c.encode(baseVersion, forKey: .baseVersion)
        try c.encode(history, forKey: .history)
        try c.encode(confirmOverlap, forKey: .confirmOverlap)
    }
}

struct DeleteGarment: Codable, Sendable {
    let operationID: UUID
    let garmentID: UUID
}

protocol OfflineRemote: Sendable {
    func visibility(_ operation: WearVisibility) async throws -> SyncWear
    func initialHistory(_ operation: SaveInitialHistory) async throws -> SyncGarment
    func delete(_ operation: DeleteGarment) async throws
    func snapshot() async throws -> SyncSnapshot
    func save(_ operation: APIv1.SaveGarment) async throws -> APIv1.GarmentDTO
    func save(_ operation: SaveWear) async throws -> SyncWear
    func image(id: UUID, original: Bool) async throws -> Data
}

extension OfflineRemote {
    func visibility(_ operation: WearVisibility) async throws -> SyncWear { throw RepositoryError.backendNotConfigured }
    func initialHistory(_ operation: SaveInitialHistory) async throws -> SyncGarment { throw RepositoryError.backendNotConfigured }
    func delete(_ operation: DeleteGarment) async throws { throw RepositoryError.backendNotConfigured }
    func image(id: UUID, original: Bool) async throws -> Data { throw RepositoryError.backendNotConfigured }
}

extension APIClient: OfflineRemote {
    func visibility(_ operation: WearVisibility) async throws -> SyncWear {
        let result: APIv1.Success<SyncWear> = try await call("api_v1_wear_visibility", operation)
        guard result.data.id == operation.id, result.data.version > operation.baseVersion,
              result.data.deleted == (operation.action == "remove") else { throw APIClientError.invalidResponse }
        return result.data
    }

    func initialHistory(_ operation: SaveInitialHistory) async throws -> SyncGarment {
        let result: APIv1.Success<SyncGarment> = try await call("api_v1_initial_wear_history", operation)
        guard result.data.id == operation.id, result.data.version > operation.baseVersion,
              !result.data.deleted, result.data.metadata?.initialWearHistory == operation.history else { throw APIClientError.invalidResponse }
        return result.data
    }
    func delete(_ operation: DeleteGarment) async throws {
        let result: APIv1.Success<Bool> = try await call("api_v1_delete_garment", operation)
        guard result.data else { throw APIClientError.invalidResponse }
    }
    func image(id: UUID, original: Bool) async throws -> Data {
        try await wardrobeImage(imageID: id, original: original)
    }
    func snapshot() async throws -> SyncSnapshot {
        struct Empty: Encodable {}
        let result: APIv1.Success<SyncSnapshot> = try await call("api_v1_sync_snapshot", Empty())
        return result.data
    }
    func save(_ operation: APIv1.SaveGarment) async throws -> APIv1.GarmentDTO {
        try await saveGarment(operation).data
    }
    func save(_ operation: SaveWear) async throws -> SyncWear {
        try operation.wear.validate()
        let result: APIv1.Success<SyncWear> = try await call("api_v1_save_wear", operation)
        guard result.data.id == operation.wear.id, result.data.version > operation.wear.version else { throw APIClientError.invalidResponse }
        return result.data
    }
}

/// One instance per signed-in account, retained by the composition root.
/// A pending write for a garment must be acknowledged/resolved before another
/// edit to that same garment: an ambiguous request's bytes must never change.
actor OfflineStore: WardrobeRepository {
    struct Pending: Codable, Sendable {
        let id: UUID
        let garment: APIv1.SaveGarment?
        let wear: SaveWear?
        var deletion: DeleteGarment? = nil
        var initialHistory: SaveInitialHistory? = nil
        var visibility: WearVisibility? = nil
        var sent = false
        var attempts = 0
        var retryAfter = Date.distantPast
        var failure: String?
    }
    struct State: Codable, Sendable {
        var format = 1
        let accountID: UUID
        var deleted = false
        var garments: [SyncGarment] = []
        var wears: [SyncWear] = []
        var outbox: [Pending] = []
        var lastRemovedWearID: UUID? = nil
    }
    private let database: OfflineDatabase
    private let remote: any OfflineRemote
    private let telemetry: TelemetryRecorder?
    private var state: State
    private var syncing = false

    init(accountID: UUID, database: OfflineDatabase, remote: any OfflineRemote, telemetry: TelemetryRecorder? = nil) throws {
        self.telemetry = telemetry
        self.database = database
        self.remote = remote
        if let data = try database.read() {
            state = try JSONDecoder().decode(State.self, from: data)
            guard state.format == 1 else { throw OfflineError.invalidState }
            guard state.accountID == accountID else { throw OfflineError.accountMismatch }
        } else {
            state = State(accountID: accountID)
            try database.write(JSONEncoder().encode(state))
        }
    }

    func status() -> State { state }

    func statisticsSnapshot() async throws -> StatisticsSnapshot {
        do { try await synchronize() }
        catch {
            if error is CancellationError || Task.isCancelled { throw error }
            try requireActive()
            if !(error is URLError) { throw error }
        }
        try requireActive()
        return StatisticsSnapshot(garments: state.garments.filter { !$0.deleted }.map(\.display),
            wears: state.wears, cached: true, pendingChanges: !state.outbox.isEmpty)
    }


    func garments() async throws -> [Garment] {
        do { try await synchronize() }
        catch {
            if error is CancellationError || Task.isCancelled { throw error }
            if error as? OfflineError == .storage { throw error }
            // Sync failures remain inspectable in status; local data stays readable.
        }
        try requireActive()
        return state.garments.filter { !$0.deleted }.map(\.display)
    }

    /// Refresh the durable metadata snapshot on the first page only. Subsequent
    /// pages never trigger another whole-account sync or any image downloads.
    func page(query: WardrobeQuery, offset: Int, limit: Int) async throws -> WardrobePage {
        try requireActive()
        guard offset >= 0, (1...100).contains(limit) else { throw APIClientError.invalidRequest }
        if offset == 0 {
            do { try await synchronize() }
            catch {
                if error is CancellationError || Task.isCancelled || error as? OfflineError == .storage { throw error }
                if !(error is URLError) { throw error }
            }
            try requireActive()
        }
        let items = state.garments.filter { !$0.deleted }.map(\.display)
        return query.page(items, offset: offset, limit: limit, cached: true)
    }

    func detail(id: UUID) async throws -> GarmentDetail {
        try requireActive()
        guard let item = state.garments.first(where: { $0.id == id && !$0.deleted }) else { throw OfflineError.invalidState }
        return GarmentDetail(garment: item.display,
            wornOn: Set(state.wears.filter { !$0.deleted && $0.garmentIDs.contains(id) }.map(\.wornOn)).sorted(by: >), cached: true)
    }

    func thumbnail(imageID: UUID) async throws -> Data {
        try await readImage(id: imageID, original: false)
    }
    func original(imageID: UUID) async throws -> Data {
        try await readImage(id: imageID, original: true)
    }
    private func readImage(id: UUID, original: Bool) async throws -> Data {
        try requireActive()
        let data = try await remote.image(id: id, original: original)
        try requireActive()
        return data
    }

    func setArchived(id: UUID, archived: Bool) async throws -> GarmentDetail {
        try requireActive()
        guard let item = state.garments.first(where: { $0.id == id && !$0.deleted }) else { throw OfflineError.invalidState }
        // Keep the latest availability in the same actor transaction; a stale
        // review row must not change a newer laundry/unavailable selection.
        try saveGarment(id: id, fields: APIv1.GarmentFields(name: item.fields.name,
            category: item.fields.category, priceGrosz: item.fields.priceGrosz,
            availability: item.fields.availability, archived: archived))
        return try await detail(id: id)
    }

    func setStatus(id: UUID, availability: APIv1.Availability, archived: Bool) async throws -> GarmentDetail {
        try requireActive()
        guard let item = state.garments.first(where: { $0.id == id && !$0.deleted }) else { throw OfflineError.invalidState }
        try saveGarment(id: id, fields: APIv1.GarmentFields(name: item.fields.name,
            category: item.fields.category, priceGrosz: item.fields.priceGrosz,
            availability: availability, archived: archived))
        return try await detail(id: id)
    }

    func deleteGarment(id: UUID) async throws {
        try requireActive()
        guard let item = state.garments.first(where: { $0.id == id }) else { throw OfflineError.invalidState }
        if item.deleted { return }
        var next = state
        next.garments.removeAll { $0.id == id }
        next.garments.append(SyncGarment(id: id, version: item.version, deleted: true,
            fields: APIv1.GarmentFields(name: "Deleted", category: .other, priceGrosz: nil, availability: .unavailable)))
        next.outbox.removeAll { $0.garment?.garmentID == id || $0.initialHistory?.id == id }
        let operation = DeleteGarment(operationID: UUID(), garmentID: id)
        next.outbox.insert(Pending(id: operation.operationID, garment: nil, wear: nil, deletion: operation), at: 0)
        scrubDeletedMembership(&next)
        try commit(next)
    }

    // Never change bytes of a previously sent wear. Block its replay for explicit
    // recovery; unaffected events and garments retain their original history.
    private func scrubDeletedMembership(_ next: inout State) {
        let deleted = Set(next.garments.filter(\.deleted).map(\.id))
        next.wears = next.wears.map { wear in
            SyncWear(id: wear.id, version: wear.version, deleted: wear.deleted,
                wornOn: wear.wornOn, timezone: wear.timezone,
                garmentIDs: wear.garmentIDs.filter { !deleted.contains($0) })
        }
        for index in next.outbox.indices {
            if let wear = next.outbox[index].wear, !deleted.isDisjoint(with: wear.wear.garmentIDs) {
                if next.outbox[index].sent {
                    next.outbox[index].failure = "version_conflict"
                } else {
                    let remaining = wear.wear.garmentIDs.filter { !deleted.contains($0) }
                    let replacement = SyncWear(id: wear.wear.id, version: wear.wear.version, deleted: false,
                        wornOn: wear.wear.wornOn, timezone: wear.wear.timezone, garmentIDs: remaining)
                    next.outbox[index] = Pending(id: wear.operationID, garment: nil,
                        wear: SaveWear(operationID: wear.operationID, wear: replacement))
                }
            }
        }
        next.outbox.removeAll { !$0.sent && $0.wear?.wear.garmentIDs.isEmpty == true }
    }

    func setInitialHistory(id: UUID, history: InitialWearHistory?, confirmOverlap: Bool) async throws -> GarmentDetail {
        try requireActive()
        try history?.validate()
        guard let old = state.garments.first(where: { $0.id == id && !$0.deleted }), old.version > 0 else { throw OfflineError.invalidState }
        guard !state.outbox.contains(where: { $0.garment?.garmentID == id || $0.initialHistory?.id == id }) else { throw OfflineError.pendingChange }
        if let history, old.metadata?.initialWearHistory?.startDate != history.startDate,
           state.wears.contains(where: { !$0.deleted && $0.garmentIDs.contains(id) && $0.wornOn < max(history.startDate, old.metadata?.initialWearHistory?.startDate ?? history.startDate) }), !confirmOverlap {
            throw APIClientError.invalidRequest
        }
        let operation = SaveInitialHistory(operationID: UUID(), id: id, baseVersion: old.version, history: history, confirmOverlap: confirmOverlap)
        var next = state
        var metadata = old.display
        metadata.initialWearHistory = history
        next.garments.removeAll { $0.id == id }
        next.garments.append(SyncGarment(id: id, version: old.version, deleted: false, fields: old.fields, metadata: metadata))
        next.outbox.append(Pending(id: operation.operationID, garment: nil, wear: nil, initialHistory: operation))
        try commit(next)
        return try await detail(id: id)
    }

    func discardInitialHistoryConflict(id: UUID) async throws {
        try requireActive()
        guard !syncing, let pending = state.outbox.first(where: { $0.initialHistory?.id == id }), pending.failure != nil else { throw OfflineError.pendingChange }
        syncing = true
        defer { syncing = false }
        let snapshot = try await remote.snapshot()
        try requireActive()
        guard snapshot.accountID == state.accountID else { throw OfflineError.accountMismatch }
        var next = state
        next.outbox.removeAll { $0.id == pending.id }
        try commit(next)
        try merge(snapshot)
    }

    @discardableResult
    func saveGarment(id: UUID = UUID(), fields: APIv1.GarmentFields) throws -> UUID {
        try requireActive()
        try fields.validate()
        guard !state.outbox.contains(where: { $0.initialHistory?.id == id }) else { throw OfflineError.pendingChange }
        let queued = state.outbox.first { $0.garment?.garmentID == id }
        guard queued?.sent != true else { throw OfflineError.pendingChange }
        let previous = state.garments.first { $0.id == id }
        guard previous?.deleted != true else { throw OfflineError.conflict }
        let base = queued != nil ? queued?.garment?.baseVersion : previous?.version
        let operation = APIv1.SaveGarment(operationID: queued?.id ?? UUID(), garmentID: id, baseVersion: base, garment: fields)
        var next = state
        next.garments.removeAll { $0.id == id }
        next.garments.append(SyncGarment(id: id, version: previous?.version ?? 0, deleted: false, fields: fields, metadata: previous?.metadata))
        next.outbox.removeAll { $0.id == operation.operationID }
        next.outbox.append(Pending(id: operation.operationID, garment: operation, wear: nil))
        try commit(next)
        return id
    }

    @discardableResult
    func recordWear(id: UUID = UUID(), wornOn: String, timezone: String, garmentIDs: [UUID]) throws -> UUID {
        try requireActive()
        if let existing = state.wears.first(where: { $0.id == id }) {
            guard !existing.deleted, existing.wornOn == wornOn, existing.timezone == timezone,
                  existing.garmentIDs == garmentIDs else { throw OfflineError.conflict }
            return id
        }
        try saveWear(SyncWear(id: id, version: 0, deleted: false, wornOn: wornOn, timezone: timezone, garmentIDs: garmentIDs))
        return id
    }

    /// The editor retains the version it opened, so a sync during editing cannot
    /// silently overwrite a newer event. An in-flight intent is immutable.
    func editWear(_ wear: SyncWear) throws {
        try requireActive()
        guard let old = state.wears.first(where: { $0.id == wear.id }),
              !old.deleted, old.version == wear.version else { throw OfflineError.conflict }
        try saveWear(wear)
    }

    /// Preserve an exact operation in the same durable outbox as normal edits.
    func setWearRemoved(id: UUID, version: Int64, removed: Bool) throws {
        try requireActive()
        guard let old = state.wears.first(where: { $0.id == id }), old.version == version,
              old.deleted != removed else { throw OfflineError.conflict }
        var next = state
        if let pending = state.outbox.first(where: { $0.visibility?.id == id }) {
            // An unsent removal can be undone entirely offline. Once sent, its
            // outcome is ambiguous until the identical operation is replayed.
            guard !pending.sent, pending.failure == nil else { throw OfflineError.pendingChange }
            next.outbox.removeAll { $0.id == pending.id }
            next.wears.removeAll { $0.id == id }
            next.wears.append(SyncWear(id: id, version: version, deleted: removed,
                wornOn: old.wornOn, timezone: old.timezone, garmentIDs: old.garmentIDs))
            next.lastRemovedWearID = removed ? id : nil
            try commit(next)
            return
        }
        guard !state.outbox.contains(where: { $0.wear?.wear.id == id }) else { throw OfflineError.pendingChange }
        if version == 0 {
            // A local-only event normally has a creation intent, checked above.
            throw OfflineError.pendingChange
        }
        let operation = WearVisibility(operationID: UUID(), id: id, baseVersion: version, action: removed ? "remove" : "restore")
        next.outbox.append(Pending(id: operation.operationID, garment: nil, wear: nil, visibility: operation))
        next.wears.removeAll { $0.id == id }
        next.wears.append(SyncWear(id: id, version: version, deleted: removed, wornOn: old.wornOn, timezone: old.timezone, garmentIDs: old.garmentIDs))
        next.lastRemovedWearID = removed ? id : nil
        try commit(next)
    }

    func discardVisibilityConflict(id: UUID) async throws {
        try requireActive()
        guard !syncing, let pending = state.outbox.first(where: { $0.visibility?.id == id }), pending.failure != nil else { throw OfflineError.pendingChange }
        syncing = true
        defer { syncing = false }
        let snapshot = try await remote.snapshot()
        try requireActive()
        guard snapshot.accountID == state.accountID else { throw OfflineError.accountMismatch }
        var next = state
        next.outbox.removeAll { $0.id == pending.id }
        next.lastRemovedWearID = nil
        try commit(next)
        try merge(snapshot)
    }

    private func saveWear(_ wear: SyncWear) throws {
        guard !state.outbox.contains(where: { $0.visibility?.id == wear.id }) else { throw OfflineError.pendingChange }
        try wear.validate()
        guard wear.garmentIDs.allSatisfy({ id in state.garments.contains { $0.id == id && !$0.deleted } }) else {
            throw APIClientError.invalidRequest
        }
        let queued = state.outbox.first { $0.wear?.wear.id == wear.id }
        guard queued?.sent != true else { throw OfflineError.pendingChange }
        let operation = SaveWear(operationID: queued?.id ?? UUID(), wear: wear)
        var next = state
        next.wears.removeAll { $0.id == wear.id }
        next.wears.append(wear)
        next.outbox.removeAll { $0.id == operation.operationID }
        next.outbox.append(Pending(id: operation.operationID, garment: nil, wear: operation))
        try commit(next)
    }

    /// Resolve only definitive conflicts, never discard an ambiguous timeout.
    func resolveWear(id: UUID, keepLocal: Bool) async throws {
        try requireActive()
        guard !syncing else { throw OfflineError.pendingChange }
        guard let pending = state.outbox.first(where: { $0.wear?.wear.id == id }),
              let failure = pending.failure, ["version_conflict", "validation_failed"].contains(failure),
              let local = pending.wear?.wear else { throw OfflineError.invalidState }
        guard !keepLocal || failure == "version_conflict" else { throw OfflineError.conflict }
        syncing = true
        defer { syncing = false }
        let snapshot: SyncSnapshot
        do { snapshot = try await remote.snapshot() }
        catch { try handleAccount(error); throw error }
        try requireActive()
        guard snapshot.accountID == state.accountID else { throw OfflineError.accountMismatch }
        let server = snapshot.wears.first(where: { $0.id == id })
        var next = state
        next.outbox.removeAll { $0.id == pending.id }
        next.wears.removeAll { $0.id == id }
        if keepLocal {
            guard let server, !server.deleted else { throw OfflineError.conflict }
            let replacement = SyncWear(id: id, version: server.version, deleted: false,
                wornOn: local.wornOn, timezone: local.timezone, garmentIDs: local.garmentIDs)
            try replacement.validate()
            let operation = SaveWear(operationID: UUID(), wear: replacement)
            next.wears.append(replacement)
            next.outbox.append(Pending(id: operation.operationID, garment: nil, wear: operation))
        } else if let server { next.wears.append(server) }
        try commit(next)
    }

    /// Count local calendar days, never events or current outfit membership.
    func wearDays(for garmentID: UUID) -> Int {
        Set(state.wears.filter { !$0.deleted && $0.garmentIDs.contains(garmentID) }.map(\.wornOn)).count
    }

    /// Called on local account deletion or account_unavailable. Persist the fence
    /// before returning; a response already in flight cannot repopulate this store.
    func invalidateAccount() throws {
        var next = State(accountID: state.accountID)
        next.deleted = true
        try commit(next)
    }

    /// Explicit conflict resolution. Retaining local fields creates a NEW intent
    /// against the fetched version; tombstones can only be accepted.
    func resolveGarment(id: UUID, keepLocal: Bool) async throws {
        try requireActive()
        guard !syncing else { throw OfflineError.pendingChange }
        guard let pending = state.outbox.first(where: { $0.garment?.garmentID == id }),
              pending.failure == "version_conflict", let operation = pending.garment else { throw OfflineError.invalidState }
        syncing = true
        defer { syncing = false }
        let snapshot: SyncSnapshot
        do { snapshot = try await remote.snapshot() }
        catch { try handleAccount(error); throw error }
        try requireActive()
        guard snapshot.accountID == state.accountID else { throw OfflineError.accountMismatch }
        guard let server = snapshot.garments.first(where: { $0.id == id }) else { throw OfflineError.conflict }
        guard !keepLocal || !server.deleted else { throw OfflineError.conflict }
        var next = state
        next.outbox.removeAll { $0.id == pending.id }
        next.garments.removeAll { $0.id == id }
        next.garments.append(server)
        if keepLocal {
            let replacement = APIv1.SaveGarment(operationID: UUID(), garmentID: id, baseVersion: server.version, garment: operation.garment)
            next.outbox.append(Pending(id: replacement.operationID, garment: replacement, wear: nil))
            next.garments.removeAll { $0.id == id }
            next.garments.append(SyncGarment(id: id, version: server.version, deleted: false, fields: operation.garment, metadata: server.metadata))
        }
        try commit(next)
    }

    /// Trigger on foreground/reconnect or explicit retry. Retry dates survive
    /// restart; no background timer or unbounded network loop is required.
    func synchronize(now: Date = Date()) async throws {
        try requireActive()
        guard !syncing else { return }
        syncing = true
        let started = ContinuousClock.now
        defer { syncing = false }
        do {
            // Pull first, including account fence and record tombstones.
            try merge(await remote.snapshot())
            // Process a bounded snapshot of IDs. Writes queued during await wait
            // for the next pass, and blocked records do not starve independent work.
            let ids = state.outbox.map(\.id)
            for id in ids {
                try requireActive()
                guard let pending = state.outbox.first(where: { $0.id == id }),
                      pending.failure == nil, pending.retryAfter <= now else { continue }
                if let wear = pending.wear, state.outbox.contains(where: {
                    $0.garment.map { wear.wear.garmentIDs.contains($0.garmentID) } ?? false
                }) { continue }
                var started = state
                if let index = started.outbox.firstIndex(where: { $0.id == id }) { started.outbox[index].sent = true }
                try commit(started)
                do {
                    if let operation = pending.visibility {
                        let wear = try await remote.visibility(operation)
                        try requireActive()
                        var next = state
                        next.wears.removeAll { $0.id == wear.id }
                        next.wears.append(wear)
                        next.outbox.removeAll { $0.id == id }
                        scrubDeletedMembership(&next)
                        try commit(next)
                    } else if let operation = pending.initialHistory {
                        let garment = try await remote.initialHistory(operation)
                        try requireActive()
                        var next = state
                        if next.garments.contains(where: { $0.id == garment.id && $0.deleted }) { continue }
                        next.garments.removeAll { $0.id == garment.id }
                        next.garments.append(garment)
                        next.outbox.removeAll { $0.id == id }
                        try commit(next)
                    } else if let operation = pending.deletion {
                        try await remote.delete(operation)
                        try requireActive()
                        var next = state
                        next.outbox.removeAll { $0.id == id }
                        try commit(next)
                    } else if let operation = pending.garment {
                        let dto = try await remote.save(operation)
                        try requireActive()
                        var next = state
                        if next.garments.contains(where: { $0.id == dto.id && $0.deleted }) { continue }
                        next.garments.removeAll { $0.id == dto.id }
                        next.garments.append(SyncGarment(id: dto.id, version: dto.version, deleted: false,
                            fields: APIv1.GarmentFields(name: dto.name, category: dto.category, priceGrosz: dto.priceGrosz, availability: dto.availability, archived: dto.archived ?? operation.garment.archived),
                            metadata: state.garments.first { $0.id == dto.id }?.metadata))
                        next.outbox.removeAll { $0.id == id }
                        try commit(next)
                    } else if let operation = pending.wear {
                        let wear = try await remote.save(operation)
                        try requireActive()
                        var next = state
                        next.wears.removeAll { $0.id == wear.id }
                        next.wears.append(wear)
                        scrubDeletedMembership(&next)
                        next.outbox.removeAll { $0.id == id }
                        try commit(next)
                    }
                } catch {
                    try handleAccount(error)
                    try requireActive()
                    var next = state
                    guard let index = next.outbox.firstIndex(where: { $0.id == id }) else { throw error }
                    if let failure = error as? APIv1.Failure, ["version_conflict", "validation_failed", "idempotency_conflict"].contains(failure.code) {
                        next.outbox[index].failure = failure.code
                    } else {
                        next.outbox[index].attempts = min(pending.attempts + 1, 16)
                        next.outbox[index].retryAfter = now.addingTimeInterval(min(3600, pow(2, Double(next.outbox[index].attempts))))
                    }
                    try commit(next)
                    throw error
                }
            }
            try merge(await remote.snapshot())
            await recordSynchronization(started: started, outcome: .success)
        } catch {
            await recordSynchronization(started: started, outcome: .classify(error))
            try handleAccount(error)
            throw error
        }
    }

    private func recordSynchronization(started: ContinuousClock.Instant, outcome: TelemetryOutcome) async {
        let elapsed = started.duration(to: .now).components
        let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        if let event = TelemetryEvent.latency(route: "sync_cycle", kind: "sync", outcome: outcome, seconds: seconds) {
            await telemetry?.record(event)
        }
    }

    private func merge(_ snapshot: SyncSnapshot) throws {
        try requireActive()
        guard snapshot.accountID == state.accountID else { throw OfflineError.accountMismatch }
        var next = state
        for garment in snapshot.garments {
            if !garment.deleted && next.garments.contains(where: { $0.id == garment.id && $0.deleted }) { continue }
            guard garment.version > 0 else { throw APIClientError.invalidResponse }
            if let pending = next.outbox.firstIndex(where: { $0.initialHistory?.id == garment.id }) {
                if garment.deleted { next.outbox[pending].failure = "version_conflict"; next.outbox[pending].sent = true }
                else { continue }
            }
            if let pending = next.outbox.firstIndex(where: { $0.garment?.garmentID == garment.id }) {
                // Preserve the local proposal for conflict review. A tombstone
                // hides it immediately and prevents any stale write being sent.
                if garment.deleted {
                    next.outbox[pending].failure = "version_conflict"
                    next.outbox[pending].sent = true
                } else { continue }
            }
            next.garments.removeAll { $0.id == garment.id }
            next.garments.append(garment)
        }
        for wear in snapshot.wears {
            guard wear.version > 0 else { throw APIClientError.invalidResponse }
            if next.outbox.contains(where: { $0.visibility?.id == wear.id }) {
                // A successful-but-unacknowledged operation must replay even if
                // the snapshot already includes its tombstone or restoration.
                continue
            }
            if let pending = next.outbox.firstIndex(where: { $0.wear?.wear.id == wear.id }) {
                if wear.deleted {
                    next.outbox[pending].failure = "version_conflict"
                    next.outbox[pending].sent = true
                } else { continue }
            }
            next.wears.removeAll { $0.id == wear.id }
            next.wears.append(wear)
        }
        scrubDeletedMembership(&next)
        try commit(next)
    }

    private func handleAccount(_ error: any Error) throws {
        if (error as? APIv1.Failure)?.code == "account_unavailable" { try invalidateAccount() }
    }
    private func requireActive() throws {
        guard !state.deleted else { throw OfflineError.accountDeleted }
    }
    private func commit(_ next: State) throws {
        try database.write(JSONEncoder().encode(next))
        state = next
    }
}
