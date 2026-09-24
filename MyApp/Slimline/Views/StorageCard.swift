import SwiftUI

/// Device storage, as reported by the filesystem.
///
/// Shows only what iOS actually tells us: total capacity and free space. There is no
/// "junk files" or "other apps" figure here, because iOS exposes no such number and the brief
/// forbids promising it.
struct StorageCard: View {
    let snapshot: StorageSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("iPhone Storage")
                .font(.headline)

            if snapshot.totalCapacity > 0 {
                bar

                HStack {
                    Label(ByteFormatting.string(snapshot.usedCapacity), systemImage: "circle.fill")
                        .foregroundStyle(Theme.accent)
                    Spacer()
                    Text("\(ByteFormatting.string(snapshot.availableCapacity)) free")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
                .labelStyle(.titleAndIcon)
                .imageScale(.small)
            } else {
                Text("Couldn't read device storage.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .card()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var bar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: geometry.size.width * snapshot.usedFraction)
            }
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }

    private var accessibilityDescription: String {
        guard snapshot.totalCapacity > 0 else { return "Device storage unavailable" }
        return "\(ByteFormatting.string(snapshot.usedCapacity)) of \(ByteFormatting.string(snapshot.totalCapacity)) used, \(ByteFormatting.string(snapshot.availableCapacity)) free"
    }
}

#Preview {
    StorageCard(snapshot: StorageSnapshot(totalCapacity: 256_000_000_000, availableCapacity: 42_000_000_000))
        .padding()
}
