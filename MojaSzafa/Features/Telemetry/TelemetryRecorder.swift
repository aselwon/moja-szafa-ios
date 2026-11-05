import Foundation

/// One instance belongs to one authenticated account AND one gateway. It is
/// invalidated on logout; references captured by older requests then do nothing.
actor TelemetryRecorder {
    private struct Journal: Codable {
        var preferences = TelemetryPreferences.disabled
        var pending: TelemetryChoice?
        var consentBegan: Date?
        var events: [TelemetryEvent] = []
    }
    private let repository: any TelemetryRepository
    private let journalURL: URL
    private var journal: Journal
    private var active = true
    private var verified = false
    private var busy = false
    private var sending = false
    private var epoch = 0
    private var sessionRecorded = false

    init(repository: any TelemetryRepository, journalURL: URL) throws {
        self.repository = repository
        self.journalURL = journalURL
        if FileManager.default.fileExists(atPath: journalURL.path) {
            let size = try journalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= 2_000_000 else { throw APIClientError.invalidResponse }
            journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL))
            guard journal.events.count <= 100, journal.preferences.version >= 0 else { throw APIClientError.invalidResponse }
        } else { journal = Journal() }
    }

    func preferences() -> TelemetryPreferences { journal.preferences }
    func hasPendingChoice() -> Bool { journal.pending != nil }
    func diagnosticWindow() -> Date? {
        active && verified && journal.pending == nil && journal.preferences.diagnostics ? journal.consentBegan : nil
    }

    /// Always fetch after an idempotent preference acknowledgement: replaying an
    /// old response is not evidence that consent still exists on the server.
    func refresh() async throws {
        guard active, !busy else { return }
        busy = true
        verified = false
        let generation = epoch
        defer { busy = false }
        if let pending = journal.pending {
            do { _ = try await repository.telemetryChoose(pending) }
            catch let failure as APIv1.Failure where failure.code == "version_conflict" {
                guard active, epoch == generation else { return }
                journal.pending = nil
                try persist()
                // The user's requested choice was not applied. Do not silently
                // turn collection back on after another device changed consent.
                throw failure
            }
            guard active, epoch == generation else { return }
            journal.pending = nil
            try persist()
        }
        let value = try await repository.telemetryPreferences()
        guard active, epoch == generation else { return }
        let previous = journal.preferences
        if previous.version != value.version {
            journal.events.removeAll()
            // A newer consent revision could include an intervening withdrawal.
            journal.consentBegan = nil
        }
        journal.preferences = value
        if value.diagnostics {
            if journal.consentBegan == nil { journal.consentBegan = Date() }
        } else {
            journal.consentBegan = nil
            journal.events.removeAll()
        }
        try persist()
        verified = true
        if value.diagnostics && !sessionRecorded {
            sessionRecorded = true
            await record(.session())
        }
    }

    func choose(diagnostics: Bool, product: Bool) async throws {
        guard active, !busy, journal.pending == nil else { throw APIClientError.invalidRequest }
        // Suspend both categories before any await, including an offline revoke.
        epoch += 1
        verified = false
        journal.events.removeAll()
        journal.consentBegan = nil
        journal.pending = TelemetryChoice(operationID: UUID(), baseVersion: journal.preferences.version,
                                          diagnostics: diagnostics, product: product)
        try persist()
        try await refresh()
    }

    func record(_ event: TelemetryEvent) async {
        guard active, verified, journal.pending == nil, journal.preferences.diagnostics else { return }
        guard journal.events.count < 100, !journal.events.contains(where: { $0.id == event.id }) else { return }
        journal.events.append(event)
        do { try persist() }
        catch { verified = false; journal.events.removeAll() }
    }

    /// Periodic foreground flush; no telemetry request recursively records itself.
    /// Failed batches keep stable IDs. Unknown outcomes never manufacture success.
    func flush() async {
        guard active, verified, journal.pending == nil, !sending,
              journal.preferences.diagnostics || journal.preferences.product else { return }
        sending = true
        defer { sending = false }
        let generation = epoch
        let version = journal.preferences.version
        var batch: [TelemetryEvent] = []
        for event in journal.events.prefix(20) {
            let candidate = batch + [event]
            guard let data = try? JSONEncoder().encode(candidate), data.count <= 23_000 else { break }
            batch = candidate
        }
        let ids = Set(batch.map(\.id))
        do {
            try await repository.telemetryIngest(version: version, events: batch, probeActivation: journal.preferences.product)
            guard active, generation == epoch else { return }
            journal.events.removeAll { ids.contains($0.id) }
            try persist()
        } catch let failure as APIv1.Failure where ["version_conflict", "telemetry_disabled", "account_unavailable"].contains(failure.code) {
            guard active, generation == epoch else { return }
            verified = false
            journal.events.removeAll()
            journal.consentBegan = nil
            try? persist()
        } catch { /* Bounded queue retries on the next foreground tick. */ }
    }

    func invalidate() throws {
        active = false
        verified = false
        epoch += 1
        journal = Journal()
        if FileManager.default.fileExists(atPath: journalURL.path) { try FileManager.default.removeItem(at: journalURL) }
    }

    private func persist() throws {
        let folder = journalURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(journal)
        #if os(iOS)
        try data.write(to: journalURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: journalURL, options: .atomic)
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
        var url = journalURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}
