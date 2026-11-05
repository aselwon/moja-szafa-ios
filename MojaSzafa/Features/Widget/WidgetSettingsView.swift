import SwiftUI

struct WidgetSettingsView: View {
    @ObservedObject var model: WardrobeWidgetModel
    var body: some View {
        Form {
            Section {
                Text("widget.privacy")
                Toggle("widget.enable", isOn: Binding(get: { model.enabled }, set: { value in Task { await model.setEnabled(value) } }))
                    .disabled(!model.available || (model.busy && !model.enabled))
                if !model.available { Text("widget.unavailable") }
                if let count = model.plannedCount { Text("widget.planned \(count)") }
            }
            Section {
                Text("widget.refreshExplanation")
                Text("widget.confirmExplanation")
                if model.busy { ProgressView() }
                if let key = model.errorKey { Text(LocalizedStringKey(key)) }
                Button("widget.refresh") { Task { await model.refresh() } }.disabled(model.busy || !model.enabled)
            }
        }.navigationTitle("widget.settingsTitle")
    }
}
