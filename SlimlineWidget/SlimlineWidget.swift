import SwiftUI
import WidgetKit

/// Device storage at a glance, on the Home Screen.
///
/// Reads capacity straight from the filesystem, the same call the app makes, so it needs no shared
/// container and no data handed over from the app. The trade-off is that it can only show what
/// iOS reports — used and free — and not what Slimline's last scan found. It says so rather than
/// showing a reclaimable figure that could be days stale.
struct StorageEntry: TimelineEntry {
    let date: Date
    let total: Int64
    let available: Int64

    var used: Int64 { max(0, total - available) }

    var usedFraction: Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(used) / Double(total)))
    }

    static let sample = StorageEntry(date: .now, total: 256_000_000_000, available: 42_000_000_000)

    static func current() -> StorageEntry {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ])
        return StorageEntry(
            date: .now,
            total: Int64(values?.volumeTotalCapacity ?? 0),
            available: values?.volumeAvailableCapacityForImportantUsage ?? 0
        )
    }
}

struct StorageProvider: TimelineProvider {
    func placeholder(in context: Context) -> StorageEntry { .sample }

    func getSnapshot(in context: Context, completion: @escaping (StorageEntry) -> Void) {
        completion(context.isPreview ? .sample : .current())
    }

    /// Hourly. Storage changes slowly, and a widget that refreshes more often only spends the
    /// budget iOS gives it without showing anything new.
    func getTimeline(in context: Context, completion: @escaping (Timeline<StorageEntry>) -> Void) {
        let entry = StorageEntry.current()
        let next = Calendar.current.date(byAdding: .hour, value: 1, to: entry.date) ?? entry.date
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

/// The app's palette, repeated here because a widget extension can't see the app's `Theme`.
private enum Palette {
    static let accent = Color(red: 0x1F / 255, green: 0x6F / 255, blue: 0x5C / 255)
    static let track = Color(red: 0xE4 / 255, green: 0xE0 / 255, blue: 0xD8 / 255)
    static let background = Color(red: 0xF6 / 255, green: 0xF4 / 255, blue: 0xEF / 255)
    static let primary = Color(red: 0x1C / 255, green: 0x1B / 255, blue: 0x19 / 255)
    static let secondary = Color(red: 0x6B / 255, green: 0x68 / 255, blue: 0x60 / 255)
}

struct StorageWidgetView: View {
    let entry: StorageEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .systemMedium: medium
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        default: small
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Storage", systemImage: "internaldrive")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.secondary)

            Spacer(minLength: 0)

            Text(format(entry.available))
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Palette.primary)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text("free")
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondary)

            bar
        }
    }

    private var medium: some View {
        HStack(spacing: 16) {
            ring
                .frame(width: 88, height: 88)

            VStack(alignment: .leading, spacing: 4) {
                Label("iPhone Storage", systemImage: "internaldrive")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.secondary)
                Text("\(format(entry.available)) free")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Palette.primary)
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                Text("\(format(entry.used)) of \(format(entry.total)) used")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondary)
                Spacer(minLength: 0)
                Text("Open Slimline to find what can be freed")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Palette.accent)
            }
            Spacer(minLength: 0)
        }
    }

    private var circular: some View {
        Gauge(value: entry.usedFraction) {
            Image(systemName: "internaldrive")
        } currentValueLabel: {
            Text("\(Int(entry.usedFraction * 100))%")
        }
        .gaugeStyle(.accessoryCircularCapacity)
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(format(entry.available)) free")
                .font(.headline)
            Gauge(value: entry.usedFraction) { EmptyView() }
                .gaugeStyle(.accessoryLinearCapacity)
        }
    }

    private var bar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                Capsule()
                    .fill(Palette.accent)
                    .frame(width: geometry.size.width * entry.usedFraction)
            }
        }
        .frame(height: 6)
    }

    private var ring: some View {
        ZStack {
            Circle().stroke(Palette.track, lineWidth: 10)
            Circle()
                .trim(from: 0, to: entry.usedFraction)
                .stroke(Palette.accent, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(Int(entry.usedFraction * 100))%")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Palette.primary)
                Text("used")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.secondary)
            }
        }
    }

    private func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

struct SlimlineWidget: Widget {
    let kind = "SlimlineStorage"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StorageProvider()) { entry in
            StorageWidgetView(entry: entry)
                .containerBackground(Palette.background, for: .widget)
        }
        .configurationDisplayName("Storage")
        .description("How much space is free on your iPhone.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

#Preview(as: .systemSmall) {
    SlimlineWidget()
} timeline: {
    StorageEntry.sample
}

#Preview(as: .systemMedium) {
    SlimlineWidget()
} timeline: {
    StorageEntry.sample
}
