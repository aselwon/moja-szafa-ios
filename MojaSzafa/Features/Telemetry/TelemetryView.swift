import SwiftUI

struct TelemetryView: View {
    let recorder: TelemetryRecorder?
    @State private var preferences = TelemetryPreferences.disabled
    @State private var busy = false
    @State private var failed = false
    @State private var pending = false

    var body: some View {
        Form {
            Section { Text("telemetry.explanation"); Text("telemetry.retention") }
            if recorder != nil {
                Toggle("telemetry.diagnostics", isOn: Binding(get: { preferences.diagnostics }, set: {
                    value in Task { await choose(diagnostics: value, product: preferences.product) }
                })).disabled(busy || pending)
                Toggle("telemetry.product", isOn: Binding(get: { preferences.product }, set: {
                    value in Task { await choose(diagnostics: preferences.diagnostics, product: value) }
                })).disabled(busy || pending)
                if busy { ProgressView() }
                if pending { Text("telemetry.pending") }
                if failed { Text("telemetry.error") }
                Button("profile.retry") { Task { await refresh() } }.disabled(busy)
            } else { Text("telemetry.unavailable") }
        }.navigationTitle("telemetry.title").task { await refresh() }
    }

    private func refresh() async {
        guard let recorder else { return }
        busy = true; failed = false
        do { try await recorder.refresh() } catch { failed = true }
        preferences = await recorder.preferences()
        pending = await recorder.hasPendingChoice()
        busy = false
    }
    private func choose(diagnostics: Bool, product: Bool) async {
        guard let recorder else { return }
        busy = true; failed = false
        do { try await recorder.choose(diagnostics: diagnostics, product: product) }
        catch { failed = true }
        preferences = await recorder.preferences()
        pending = await recorder.hasPendingChoice()
        busy = false
    }
}
