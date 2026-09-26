import SwiftUI

/// Similar-photo groups, one card per group.
///
/// The suggested best shot is badged and "select extras" leaves it behind, but any photo — or a
/// whole set — can be selected. Review warns before an entire set is deleted.
struct SimilarPhotosView: View {
    let groups: [SimilarPhotoGroup]
    let sizesAreEstimated: Bool
    let plan: CleanPlan
    /// Photos both blur signals agree on. Not a group: each stands alone.
    var blurryPhotos: [AssetRecord] = []
    /// Non-`nil` while the blur pass is still measuring new photos.
    var blurProgress: Double?

    /// Owned by the root view so the Overview's Blurry tile can land on the right segment.
    @Binding var filter: Filter

    /// Splits groups by how alike they are. Worth separating because the two mean different
    /// things to the user: a duplicate is safe to clear without looking, while a burst needs a
    /// glance to decide which frame to keep.
    ///
    /// Blurry lives here as a third view rather than a sixth tab: iOS folds anything past five
    /// tabs into a "More" menu, and blur is a property of photos, so this is where it's looked for.
    enum Filter: Hashable {
        case similar, duplicates, blurry
    }

    private let blurColumns = [GridItem(.adaptive(minimum: 100), spacing: 8)]
    @State private var isSwipingBlurry = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: Theme.sectionSpacing) {
                summaryCard

                if filter == .blurry {
                    blurryGrid
                } else {
                    ForEach(visibleGroups) { group in
                        GroupCard(group: group, plan: plan)
                    }
                }
            }
            .padding(Theme.screenInset)
        }
        .pageBackground()
        .fullScreenCover(isPresented: $isSwipingBlurry) {
            SwipeReviewView(title: "Blurry Photos", records: visibleBlurry, plan: plan)
        }
        .overlay {
            if filter == .blurry {
                if visibleBlurry.isEmpty && blurProgress == nil {
                    ContentUnavailableView(
                        "No blurry photos",
                        systemImage: "camera.aperture",
                        description: Text("Nothing in your library looks out of focus.")
                    )
                }
            } else if groups.isEmpty {
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
                        Text(ByteFormatting.string(headlineBytes))
                            .font(.system(size: 34, weight: .bold))
                            .foregroundStyle(Theme.primaryText)
                            .contentTransition(.numericText())
                        Text("recoverable")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                Spacer()
                Chip(text: filter == .blurry ? "\(visibleBlurry.count) photos" : "\(visibleGroups.count) sets")
            }

            Text(
                filter == .blurry
                    ? "Photos where nothing is in focus. Long-press to check before selecting."
                    : "Select extras leaves the best shot, or select all to keep or clear a whole set. Tap any photo to change it."
            )
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)

            if sizesAreEstimated {
                Text("Photo sizes are approximate on this version of iOS.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.warning)
            }

            segmentedControl

            if filter == .blurry, !visibleBlurry.isEmpty {
                SwipeLaunchButton(count: visibleBlurry.count) { isSwipingBlurry = true }
            }
        }
        .card()
    }

    private var segmentedControl: some View {
        HStack(spacing: 2) {
            segment("Similar Sets", count: similarGroups.count, value: .similar)
            segment("Duplicates", count: duplicateGroups.count, value: .duplicates)
            segment("Blurry", count: visibleBlurry.count, value: .blurry)
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
                        RoundedRectangle(cornerRadius: Theme.controlCorner - 2)
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

    /// What the segment on screen would free.
    ///
    /// Each segment reports its own figure. This used to total every group regardless of the
    /// segment, so Similar Sets and Duplicates showed the same number — which read as if the two
    /// were the same photos, when they're disjoint halves of one list.
    private var headlineBytes: Int64 {
        switch filter {
        case .similar, .duplicates:
            visibleGroups.reduce(0) { $0 + $1.reclaimableBytes }
        case .blurry:
            visibleBlurry.compactMap(\.byteSize).reduce(0, +)
        }
    }

    /// Blurry photos that can actually be selected.
    ///
    /// Blurry photos, less any set's best shot.
    ///
    /// The best shot is the one its set suggests keeping; listing it here as well would give the
    /// same photo two contradictory verdicts on neighbouring tabs.
    private var visibleBlurry: [AssetRecord] {
        let keepers = Set(groups.map(\.bestAssetID))
        return blurryPhotos.filter { !keepers.contains($0.id) }
    }

    @ViewBuilder
    private var blurryGrid: some View {
        if let blurProgress {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking photos for blur…")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.primaryText)
                }
                ProgressView(value: blurProgress).tint(Theme.accent)
            }
            .card(padding: 12)
        }

        LazyVGrid(columns: blurColumns, spacing: 8) {
            ForEach(visibleBlurry) { record in
                GridPhotoCell(record: record, isSelected: plan.isSelected(record.id)) {
                    plan.toggle(record)
                }
            }
        }
    }
}

/// One group of similar photos.
private struct GroupCard: View {
    let group: SimilarPhotoGroup
    let plan: CleanPlan

    @Environment(\.keepForGood) private var keepForGood

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
                        isSuggested: record.id == group.bestAssetID,
                        reason: reason(for: record),
                        isSelected: plan.isSelected(record.id),
                        canSelect: plan.canSelect(record.id),
                        onTap: { plan.toggle(record) }
                    )
                }
            }

            // For sets that aren't really duplicates — two different moments that happen to look
            // alike. Keeping them all is the honest answer, and the set shouldn't come back.
            if let keepForGood {
                Button {
                    withAnimation(.snappy) { keepForGood(group.assets.map(\.id)) }
                } label: {
                    Label("Keep all \(group.assets.count) and don't show again", systemImage: "eye.slash")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
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
                HStack(spacing: 6) {
                    // The whole set: to keep it all from the review bar, or to clear it all.
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            if allSelected {
                                plan.deselectAll(in: group)
                            } else {
                                plan.selectAll(in: group)
                            }
                        }
                    } label: {
                        Text(allSelected ? "Deselect" : "All \(group.assets.count)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .overlay { Capsule().strokeBorder(Theme.accent.opacity(0.35), lineWidth: 1) }
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(allSelected ? "Deselect all \(group.assets.count)" : "Select all \(group.assets.count) photos")

                    SelectExtrasButton(
                        count: group.others.count,
                        isSelected: allExtrasSelected
                    ) {
                        withAnimation(.snappy(duration: 0.2)) {
                            if allExtrasSelected {
                                plan.deselectAll(in: group)
                            } else {
                                plan.selectExtras(in: group)
                            }
                        }
                    }
                }
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

    /// Exactly the extras — the best shot left out. Selecting everything is its own state.
    private var allExtrasSelected: Bool {
        !group.others.isEmpty && group.others.allSatisfy { plan.isSelected($0.id) }
            && !plan.isSelected(group.bestAssetID)
    }

    private var allSelected: Bool {
        group.assets.allSatisfy { plan.isSelected($0.id) }
    }
}

/// One tappable photo with its selection state and a one-word verdict.
///
/// Every photo can be selected, including the suggested best shot — the suggestion is advice,
/// not a lock.
private struct PhotoCard: View {
    let record: AssetRecord
    /// The scan's pick, which "select extras" leaves behind.
    let isSuggested: Bool
    let reason: String
    let isSelected: Bool
    let canSelect: Bool
    let onTap: () -> Void

    private var isAvailable: Bool { canSelect || isSelected }

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
        .disabled(!isAvailable)
        .opacity(isAvailable ? 1 : 0.4)
        // Long press peeks at the photo. A thumbnail this size can't settle "which of these two
        // near-identical shots is the better one", which is the decision the screen is asking for.
        .assetPreview(record, isSelected: isSelected, onToggle: isAvailable ? onTap : nil)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var thumbnail: some View {
        AssetThumbnail.Filling(assetID: record.id, ratio: 4 / 5, targetPixels: 260)
            .overlay(alignment: .topLeading) {
                if isSuggested { bestBadge }
            }
            .overlay(alignment: .topTrailing) { marker }
            .overlay(alignment: .bottomLeading) {
                if let bytes = record.byteSize {
                    Text(ByteFormatting.string(bytes))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.primaryText)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Theme.surface.opacity(0.92), in: .capsule)
                        .padding(6)
                }
            }
    }

    /// A label, not a control: it marks the scan's suggestion without asking to be tapped.
    private var bestBadge: some View {
        Text("Best")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Theme.accent, in: .capsule)
            .padding(6)
    }

    private var marker: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(isSelected ? .white : .clear)
            .frame(width: 22, height: 22)
            .background(isSelected ? Theme.accent : Theme.surface, in: .circle)
            .overlay(
                Circle().strokeBorder(isSelected ? Theme.accent : Theme.divider, lineWidth: 1)
            )
            .padding(6)
    }

    private var footer: some View {
        HStack(spacing: 4) {
            Text(reason)
                .font(.system(size: 11))
                .foregroundStyle(isSuggested ? Theme.accent : Theme.secondaryText)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text(isSelected ? "Delete" : (isAvailable ? "Review" : "Last one"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSelected ? Theme.destructive : Theme.secondaryText)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(Theme.surface)
    }

    private var accessibilityLabel: String {
        let size = record.byteSize.map { ByteFormatting.string($0) } ?? "size unknown"
        let kind = isSuggested ? "Suggested best shot" : "Photo"
        if isSelected { return "\(kind), selected for deletion, \(reason), \(size)" }
        if !isAvailable { return "\(kind), the last one left in this set, \(reason), \(size)" }
        return "\(kind), \(reason), \(size)"
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

/// The group-level "select everything but the best shot" control.
///
/// Styled as an unmistakable button — icon, fill, capsule — because it was plain accent-coloured
/// text sitting beside a similarity chip, and read as a caption rather than something to press.
/// It also says how many photos it will select, so the tap has a predictable result, and it
/// changes state visibly once pressed rather than only swapping its label.
private struct SelectExtrasButton: View {
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "checkmark.circle")
                    .font(.system(size: 13, weight: .semibold))
                Text(isSelected ? "Selected" : "Select \(count)")
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(isSelected ? .white : Theme.accent)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                isSelected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.accent.opacity(0.12)),
                in: .capsule
            )
            .overlay {
                Capsule().strokeBorder(Theme.accent.opacity(isSelected ? 0 : 0.35), lineWidth: 1)
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            isSelected
                ? "All \(count) extras selected. Double-tap to deselect."
                : "Select the \(count) extras, keeping the best shot"
        )
    }
}
