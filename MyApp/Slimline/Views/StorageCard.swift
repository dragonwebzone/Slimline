import SwiftUI

/// Device storage, as reported by the filesystem.
///
/// Shows only what iOS actually tells us: total capacity and free space. There is no
/// "junk files" or "other apps" figure here, because iOS exposes no such number and the brief
/// forbids promising it.
struct StorageCard: View {
    let snapshot: StorageSnapshot
    /// What the current scan found that could be freed. Drawn as a distinct band inside the used
    /// portion, because it is a subset of what's used rather than an extra category.
    var reclaimableBytes: Int64 = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if snapshot.totalCapacity > 0 {
                header
                bar
                legend
            } else {
                SectionHeading("iPhone Storage")
                Text("Couldn't read device storage.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .card()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                SectionHeading(reclaimableBytes > 0 ? "Potential Recovery" : "iPhone Storage")
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(ByteFormatting.string(headlineBytes))
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(Theme.primaryText)
                        .contentTransition(.numericText())
                    Text(reclaimableBytes > 0 ? "recoverable" : "used")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            Spacer()
            Chip(text: "\(ByteFormatting.string(snapshot.availableCapacity)) free", tint: Theme.accent)
        }
    }

    /// The figure the user came for. Once a scan has found something, that's the recoverable
    /// amount; before then it's what the device is using, because a big "Zero KB recoverable"
    /// would be a strange way to open the app.
    private var headlineBytes: Int64 {
        reclaimableBytes > 0 ? reclaimableBytes : snapshot.usedCapacity
    }

    private var bar: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let used = width * snapshot.usedFraction

            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surfaceDim)
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: max(0, used))
                // Sits at the trailing edge of the used portion: the part of "used" that would
                // come back.
                Capsule()
                    .fill(Theme.warning)
                    .frame(width: max(0, min(used, width * reclaimableFraction)))
                    .offset(x: max(0, used - min(used, width * reclaimableFraction)))
            }
        }
        .frame(height: 8)
        .animation(.snappy, value: snapshot.usedFraction)
        .animation(.snappy, value: reclaimableBytes)
        .accessibilityHidden(true)
    }

    private var legend: some View {
        HStack(spacing: 14) {
            LegendDot(
                color: Theme.accent,
                label: "\(ByteFormatting.string(snapshot.usedCapacity)) used"
            )
            if reclaimableBytes > 0 {
                LegendDot(color: Theme.warning, label: "Can be freed")
            }
            Spacer()
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.secondaryText)
    }

    private var reclaimableFraction: Double {
        guard snapshot.totalCapacity > 0, reclaimableBytes > 0 else { return 0 }
        return Double(reclaimableBytes) / Double(snapshot.totalCapacity)
    }

    private var accessibilityDescription: String {
        guard snapshot.totalCapacity > 0 else { return "Device storage unavailable" }
        var description = "\(ByteFormatting.string(snapshot.usedCapacity)) of \(ByteFormatting.string(snapshot.totalCapacity)) used, \(ByteFormatting.string(snapshot.availableCapacity)) free"
        if reclaimableBytes > 0 {
            description += ", \(ByteFormatting.string(reclaimableBytes)) can be freed"
        }
        return description
    }
}

/// A colour swatch and its meaning.
struct LegendDot: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
        }
    }
}

#Preview("With reclaimable") {
    VStack {
        StorageCard(
            snapshot: StorageSnapshot(totalCapacity: 256_000_000_000, availableCapacity: 42_000_000_000),
            reclaimableBytes: 4_820_000_000
        )
    }
    .padding()
    .frame(maxHeight: .infinity)
    .pageBackground()
}
