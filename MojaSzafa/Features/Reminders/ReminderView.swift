import SwiftUI

struct ReminderView: View {
    @ObservedObject var model: ReminderModel
    @State private var draft = ReminderSettings()
    var body: some View {
        Form {
            Section {
                Text("reminders.explanation")
                Toggle("reminders.plans", isOn: $draft.plans)
                hour("reminders.planHour", selection: $draft.planHour)
                Toggle("reminders.wear", isOn: $draft.wear)
                hour("reminders.wearHour", selection: $draft.wearHour)
            }
            Section("reminders.quiet") {
                hour("reminders.quietStart", selection: $draft.quietStart)
                hour("reminders.quietEnd", selection: $draft.quietEnd)
                if !draft.valid { Text("reminders.invalidQuiet") }
                Text(verbatim: TimeZone.current.identifier).font(.caption)
                Text("reminders.timezones").font(.caption)
            }
            Section {
                Text("reminders.horizon")
                Text("reminders.scheduled \(model.scheduledCount)")
                if let key = model.errorKey { Text(LocalizedStringKey(key)) }
                if model.busy { ProgressView() }
                Button("reminders.save") { Task { await model.apply(draft) } }
                    .disabled(model.busy || !draft.valid)
                Button("reminders.refresh") { Task { await model.refresh() } }.disabled(model.busy)
                Link("reminders.systemSettings", destination: URL(string: UIApplication.openSettingsURLString)!)
            }
        }
        .navigationTitle("reminders.title")
        .onAppear { draft = model.settings }
    }
    private func hour(_ label: LocalizedStringKey, selection: Binding<Int>) -> some View {
        Picker(selection: selection) {
            ForEach(0..<24, id: \.self) { Text(verbatim: String(format: "%02d:00", $0)).tag($0) }
        } label: { Text(label) }
    }
}
