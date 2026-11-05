import SwiftUI
import WidgetKit

struct WardrobeWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WardrobeWidgetSnapshot?
}

struct WardrobeTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> WardrobeWidgetEntry { WardrobeWidgetEntry(date: Date(), snapshot: nil) }
    func getSnapshot(in context: Context, completion: @escaping (WardrobeWidgetEntry) -> Void) {
        completion(WardrobeWidgetEntry(date: Date(), snapshot: WidgetSnapshotStore.live().read()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<WardrobeWidgetEntry>) -> Void) {
        let now = Date()
        let snapshot = WidgetSnapshotStore.live().read(now: now)
        let expiration = snapshot?.expiresAt ?? now.addingTimeInterval(900)
        completion(Timeline(entries: [WardrobeWidgetEntry(date: now, snapshot: snapshot),
                                      WardrobeWidgetEntry(date: expiration, snapshot: nil)], policy: .after(expiration)))
    }
}

struct WardrobeWidgetView: View {
    let entry: WardrobeWidgetEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("widget.title", systemImage: "tshirt").font(.headline)
            if let snapshot = entry.snapshot {
                Text("widget.planned \(snapshot.plannedCount)").privacySensitive()
                Text(snapshot.generatedAt, style: .time).font(.caption).privacySensitive()
            } else { Text("widget.openToRefresh").font(.caption) }
            Button(intent: ConfirmWearIntent()) { Label("widget.confirm", systemImage: "checkmark.circle") }
                .buttonStyle(.bordered)
        }
        .containerBackground(for: .widget) { Color(.systemBackground) }
        .widgetURL(WardrobeWidgetIdentity.wearURL())
    }
}

struct WardrobeTodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: WardrobeWidgetIdentity.kind, provider: WardrobeTimelineProvider()) { WardrobeWidgetView(entry: $0) }
            .configurationDisplayName("widget.title")
            .description("widget.description")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct MojaSzafaWidgets: WidgetBundle {
    var body: some Widget { WardrobeTodayWidget() }
}
