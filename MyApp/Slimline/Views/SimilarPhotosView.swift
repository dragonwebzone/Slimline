import SwiftUI

/// Similar-photo groups, one card per group.
///
/// The keeper is badged and locked — it cannot be selected, so "select extras" always leaves
/// exactly one photo behind and no amount of tapping can empty a group.
struct SimilarPhotosView: View {
    let groups: [SimilarPhotoGroup]
    let sizesAreEstimated: Bool
    let plan: CleanPlan
    /// Promotes a photo to be the keeper of its group.
    let onMakeKeeper: (String, String) -> Void

    @State private var filter = Filter.similar

    /// Splits groups by how alike they are. Worth separating because the two mean different
    /// things to the user: a duplicate is safe to clear without looking, while a burst needs a
    /// glance to decide which frame to keep.
    enum Filter: Hashable {
        case similar, duplicates
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: Theme.sectionSpacing) {
                summaryCard

                ForEach(visibleGroups) { group in
                    GroupCard(group: group, plan: plan, onMakeKeeper: onMakeKeeper)
                }
            }
            .padding(Theme.screenInset)
        }
        .pageBackground()
        .overlay {
            if groups.isEmpty {
                ContentUnavailableView(
                    "No duplicates found",
                    systemImage: "checkmark.circle",
                    description: Text("Nothing in your library looks like a duplicate.")
                )
            } else if visibleGroups.isEmpty {
                ContentUnavailableView(
                    filter == .duplicates ? "No exact duplicates" : "No similar sets",
                    systemImage: "square.on.square",
                    description: Text(
                        filter == .duplicates
                            ? "Nothing here is an exact copy — check Similar Sets."
                            : "Everything found is an exact copy — check Duplicates."
                    )
                )
            }
        }
    }

    // MARK: - Summary

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    SectionHeading("Potential Recovery")
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(ByteFormatting.string(totalReclaimable))
                            .font(.system(size: 34, weight: .bold))
                            .foregroundStyle(Theme.primaryText)
                            .contentTransition(.numericText())
                        Text("recoverable")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                Spacer()
                Chip(text: "\(groups.count) sets")
            }

            Text("The starred shot is kept. Tap a photo's star to keep that one instead.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)

            if sizesAreEstimated {
                Text("Photo sizes are approximate on this version of iOS.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.warning)
            }

            segmentedControl
        }
        .card()
    }

    private var segmentedControl: some View {
        HStack(spacing: 2) {
            segment("Similar Sets", count: similarGroups.count, value: .similar)
            segment("Duplicates", count: duplicateGroups.count, value: .duplicates)
        }
        .padding(2)
        .background(Theme.background, in: .rect(cornerRadius: Theme.controlCorner))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.controlCorner)
                .strokeBorder(Theme.divider, lineWidth: 1)
        }
    }

    private func segment(_ title: String, count: Int, value: Filter) -> some View {
        let isSelected = filter == value

        return Button {
            withAnimation(.snappy(duration: 0.2)) { filter = value }
        } label: {
            Text("\(title) (\(count))")
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Theme.primaryText : Theme.secondaryText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Theme.surface)
                            .shadow(color: .black.opacity(0.06), radius: 1, y: 1)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    private var similarGroups: [SimilarPhotoGroup] {
        groups.filter { !$0.isDuplicate }
    }

    private var duplicateGroups: [SimilarPhotoGroup] {
        groups.filter(\.isDuplicate)
    }

    private var visibleGroups: [SimilarPhotoGroup] {
        filter == .duplicates ? duplicateGroups : similarGroups
    }

    private var totalReclaimable: Int64 {
        groups.reduce(0) { $0 + $1.reclaimableBytes }
    }
}

/// One group of similar photos.
private struct GroupCard: View {
    let group: SimilarPhotoGroup
    let plan: CleanPlan
    let onMakeKeeper: (String, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            // Two columns for small groups so each frame is big enough to judge; three once a
            // group gets long, to keep the card from dominating the scroll.
            let columns = group.assets.count > 4 ? 3 : 2
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columns),
                spacing: 8
            ) {
                ForEach(group.assets) { record in
                    PhotoCard(
                        record: record,
                        isKeeper: record.id == group.bestAssetID,
                        reason: reason(for: record),
                        isSelected: plan.isSelected(record.id),
                        canSelect: plan.canSelect(record.id),
                        onTap: { plan.toggle(record) },
                        onMakeKeeper: {
                            withAnimation(.snappy) { onMakeKeeper(record.id, group.id) }
                        }
                    )
                }
            }
        }
        .card(padding: 12)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                if let label = group.similarityLabel {
                    Chip(text: label)
                }
                Button(allExtrasSelected ? "Deselect" : "Select extras") {
                    if allExtrasSelected {
                        plan.deselectAll(in: group)
                    } else {
                        plan.selectExtras(in: group)
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.accent)
            }
        }
    }

    /// Named by when it was taken. A place name would need reverse geocoding, which is a network
    /// call, and nothing in this app is allowed to leave the device.
    private var title: String {
        guard let date = group.assets.compactMap(\.creationDate).min() else {
            return "\(group.assets.count) similar photos"
        }
        return date.formatted(.dateTime.month(.wide).day().year())
    }

    private var subtitle: String {
        var parts = ["\(group.assets.count) photos"]
        if group.reclaimableBytes > 0 {
            parts.append(ByteFormatting.string(group.reclaimableBytes))
        }
        if let date = group.assets.compactMap(\.creationDate).min() {
            parts.append(date.formatted(date: .omitted, time: .shortened))
        }
        return parts.joined(separator: " · ")
    }

    /// Why this photo is or isn't the keeper.
    ///
    /// Only ever states something actually computed — a favourite, a higher Vision quality score,
    /// more pixels. The app does not detect blur, exposure or obstruction, so it never claims to.
    private func reason(for record: AssetRecord) -> String {
        if record.id == group.bestAssetID {
            if record.isFavorite { return "Favourite" }
            return "Best quality"
        }

        let keeper = group.assets.first { $0.id == group.bestAssetID }
        if let keeper, record.pixelCount < keeper.pixelCount {
            return "Lower resolution"
        }
        if record.hasAdjustments { return "Edited" }
        return "Lower quality"
    }

    private var allExtrasSelected: Bool {
        !group.others.isEmpty && group.others.allSatisfy { plan.isSelected($0.id) }
    }
}

/// One tappable photo with its selection state and a one-word verdict.
private struct PhotoCard: View {
    let record: AssetRecord
    let isKeeper: Bool
    let reason: String
    let isSelected: Bool
    let canSelect: Bool
    let onTap: () -> Void
    let onMakeKeeper: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 0) {
                thumbnail
                footer
            }
            .background(Theme.surfaceDim, in: .rect(cornerRadius: Theme.innerCorner))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.innerCorner)
                    .strokeBorder(isSelected ? Theme.accent : Theme.divider, lineWidth: isSelected ? 2 : 1)
            }
            .clipShape(.rect(cornerRadius: Theme.innerCorner))
        }
        .buttonStyle(.plain)
        .disabled(isKeeper || (!canSelect && !isSelected))
        .opacity(isKeeper || canSelect || isSelected ? 1 : 0.4)
        // Long press peeks at the photo. A thumbnail this size can't settle "which of these two
        // near-identical shots is the better one", which is the decision the screen is asking for.
        .assetPreview(
            record,
            isSelected: isSelected,
            onToggle: isKeeper || (!canSelect && !isSelected) ? nil : onTap,
            onMakeKeeper: isKeeper ? nil : onMakeKeeper
        )
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var thumbnail: some View {
        AssetThumbnail.Filling(assetID: record.id, ratio: 4 / 5, targetPixels: 260)
            .overlay(alignment: .topLeading) { keeperStar }
            .overlay(alignment: .topTrailing) { marker }
            .overlay(alignment: .bottomLeading) {
                if let bytes = record.byteSize {
                    Text(ByteFormatting.string(bytes))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.primaryText)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Theme.surface.opacity(0.92), in: .rect(cornerRadius: 4))
                        .padding(6)
                }
            }
    }

    /// The keeper control: filled star on the one being kept, hollow star on the rest.
    ///
    /// Tappable on every photo, which is the whole point — the scan's pick is a default, and a
    /// visible control says so far better than a padlock did. The padlock was accurate about the
    /// rule and wrong about the intent: it read as "this decision is not yours".
    private var keeperStar: some View {
        Button(action: onMakeKeeper) {
            Image(systemName: isKeeper ? "star.fill" : "star")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isKeeper ? .white : Theme.primaryText)
                .frame(width: 22, height: 22)
                .background(isKeeper ? Theme.accent : Theme.surface.opacity(0.92), in: .circle)
                .overlay(
                    Circle().strokeBorder(isKeeper ? Theme.accent : Theme.divider, lineWidth: 1)
                )
                .frame(width: 38, height: 38)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(isKeeper)
        .accessibilityLabel(isKeeper ? "Kept" : "Keep this one instead")
    }

    /// A blank disc on the keeper — it can't be selected — and a checkbox on everything else.
    private var marker: some View {
        Group {
            if isKeeper {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.clear)
                    .frame(width: 22, height: 22)
                    .background(Theme.surface.opacity(0.5), in: .circle)
                    .overlay(Circle().strokeBorder(Theme.divider, lineWidth: 1))
            } else {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(isSelected ? .white : .clear)
                    .frame(width: 22, height: 22)
                    .background(isSelected ? Theme.accent : Theme.surface, in: .circle)
                    .overlay(
                        Circle().strokeBorder(isSelected ? Theme.accent : Theme.divider, lineWidth: 1)
                    )
            }
        }
        .padding(6)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Text(reason)
                .font(.system(size: 11))
                .foregroundStyle(isKeeper ? Theme.accent : Theme.secondaryText)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(isKeeper ? "Keep" : (isSelected ? "Delete" : "Review"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(
                    isKeeper ? Theme.secondaryText : (isSelected ? Theme.destructive : Theme.secondaryText)
                )
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(Theme.surface)
    }

    private var accessibilityLabel: String {
        let size = record.byteSize.map { ByteFormatting.string($0) } ?? "size unknown"
        if isKeeper { return "Best shot, kept, \(reason), \(size)" }
        return isSelected
            ? "Selected for deletion, \(reason), \(size)"
            : "Photo, \(reason), \(size)"
    }
}

/// Shown wherever photo sizes are pixel-based estimates rather than measurements.
struct EstimatedSizeNotice: View {
    var body: some View {
        Label(
            "Photo sizes are approximate on this version of iOS. Video sizes are exact.",
            systemImage: "info.circle"
        )
        .font(.system(size: 12))
        .foregroundStyle(Theme.secondaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
