import SwiftUI

/// Similar-photo groups, one section per group.
///
/// The keeper is badged and cannot be selected — the user has to actively deselect it as keeper
/// by choosing a different photo, rather than being able to sweep the whole group away by
/// accident. "Select extras" therefore always leaves exactly one photo behind.
struct SimilarPhotosView: View {
    let groups: [SimilarPhotoGroup]
    let sizesAreEstimated: Bool
    let plan: CleanPlan

    private let columns = [GridItem(.adaptive(minimum: 88), spacing: 8)]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if sizesAreEstimated {
                    EstimatedSizeNotice()
                }

                ForEach(groups) { group in
                    section(for: group)
                }
            }
            .padding(16)
        }
        .navigationTitle("Similar Photos")
        .overlay {
            if groups.isEmpty {
                ContentUnavailableView(
                    "No duplicates found",
                    systemImage: "checkmark.circle",
                    description: Text("Nothing in your library looks like a duplicate.")
                )
            }
        }
    }

    private func section(for group: SimilarPhotoGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(group.assets.count) similar")
                        .font(.headline)
                    Text("Frees \(ByteFormatting.string(group.reclaimableBytes))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(allExtrasSelected(in: group) ? "Deselect" : "Select extras") {
                    if allExtrasSelected(in: group) {
                        plan.deselectAll(in: group)
                    } else {
                        plan.selectExtras(in: group)
                    }
                }
                .font(.subheadline)
            }

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(group.assets) { record in
                    SelectableAsset(
                        record: record,
                        isKeeper: record.id == group.bestAssetID,
                        isSelected: plan.isSelected(record.id),
                        canSelect: plan.canSelect(record.id)
                    ) {
                        plan.toggle(record)
                    }
                }
            }
        }
    }

    private func allExtrasSelected(in group: SimilarPhotoGroup) -> Bool {
        !group.others.isEmpty && group.others.allSatisfy { plan.isSelected($0.id) }
    }
}

/// One tappable thumbnail with selection and keeper state.
struct SelectableAsset: View {
    let record: AssetRecord
    let isKeeper: Bool
    let isSelected: Bool
    let canSelect: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            AssetThumbnail(assetID: record.id, side: 88)
                .overlay(alignment: .topTrailing) { marker }
                .overlay(alignment: .bottomLeading) { keeperBadge }
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isSelected ? Theme.accent : .clear, lineWidth: 3)
                }
                .opacity(isKeeper ? 1 : (canSelect || isSelected ? 1 : 0.4))
        }
        .buttonStyle(.plain)
        .disabled(isKeeper || (!canSelect && !isSelected))
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var marker: some View {
        if isSelected {
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Theme.accent)
                .padding(4)
        }
    }

    @ViewBuilder
    private var keeperBadge: some View {
        if isKeeper {
            Text("Keep")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.thinMaterial, in: .capsule)
                .padding(4)
        }
    }

    private var accessibilityLabel: String {
        let size = record.byteSize.map { ByteFormatting.string($0) } ?? "size unknown"
        if isKeeper { return "Best shot, kept, \(size)" }
        return isSelected ? "Selected for deletion, \(size)" : "Photo, \(size)"
    }
}

/// Shown wherever photo sizes are pixel-based estimates rather than measurements.
struct EstimatedSizeNotice: View {
    var body: some View {
        Label(
            "Photo sizes are approximate on this version of iOS. Video sizes are exact.",
            systemImage: "info.circle"
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
