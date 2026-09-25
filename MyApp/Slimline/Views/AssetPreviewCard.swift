import SwiftUI

/// A large look at one asset, for the long-press peek.
///
/// The whole point of this app is asking someone to decide whether a photo is worth keeping, and
/// a 100pt thumbnail is not enough to answer that — particularly for near-identical shots, where
/// the difference is a blink or a shifted focus. So a long press shows the photo big, at its real
/// aspect ratio, with the facts that inform the decision underneath.
struct AssetPreviewCard: View {
    let record: AssetRecord

    /// Wide enough to judge a photo on, narrow enough that the system peek doesn't clip it.
    private let width: CGFloat = 320

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .aspectRatio(aspectRatio, contentMode: .fit)
                .overlay {
                    // Fitted rather than filled: a preview that crops the edges off can't answer
                    // "is anything important cut out of this one?"
                    AssetThumbnail(
                        assetID: record.id,
                        targetPixels: 900,
                        cornerRadius: 0,
                        fills: false
                    )
                }

            details
        }
        .frame(width: width)
        .background(Theme.surface)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if record.isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.destructive)
                }
                Text(record.byteSize.map { ByteFormatting.string($0) } ?? "Size unknown")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                Spacer()
                Text("\(record.pixelWidth) × \(record.pixelHeight)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }

            if let caption {
                Text(caption)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }

    private var caption: String? {
        var parts: [String] = []
        if let date = record.creationDate {
            parts.append(date.formatted(date: .abbreviated, time: .shortened))
        }
        if record.hasAdjustments { parts.append("Edited") }
        if record.isVideo {
            parts.append(Duration.seconds(record.duration).formatted(.time(pattern: .minuteSecond)))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The asset's real shape, falling back to portrait if PhotoKit reported nothing usable.
    private var aspectRatio: CGFloat {
        guard record.pixelWidth > 0, record.pixelHeight > 0 else { return 3 / 4 }
        return CGFloat(record.pixelWidth) / CGFloat(record.pixelHeight)
    }
}

/// Adds the long-press peek, plus the same select action the tap performs.
///
/// The menu repeats the tap action deliberately: once a peek is open, the natural next move is to
/// act on what you just looked at, and closing the preview to go and tap the thumbnail is a step
/// that shouldn't be needed.
struct AssetPreviewMenu: ViewModifier {
    let record: AssetRecord
    let isSelected: Bool
    /// `nil` where selecting isn't permitted — the keeper of a group — so the menu offers the
    /// preview without a control that would be refused.
    let onToggle: (() -> Void)?
    /// `nil` for the current keeper and for ungrouped assets, which have nothing to promote.
    let onMakeKeeper: (() -> Void)?

    func body(content: Content) -> some View {
        content.contextMenu {
            // Promotion comes first: on a group where the scan picked the wrong frame, this is
            // the action the user is reaching for, and it has to be reachable before the
            // destructive one.
            if let onMakeKeeper {
                Button(action: onMakeKeeper) {
                    Label("Keep this one instead", systemImage: "star")
                }
            }

            if let onToggle {
                Button(role: isSelected ? nil : .destructive, action: onToggle) {
                    Label(
                        isSelected ? "Don't delete this" : "Select for deletion",
                        systemImage: isSelected ? "arrow.uturn.backward" : "trash"
                    )
                }
            } else if onMakeKeeper == nil {
                Label("Kept as the best shot", systemImage: "lock.fill")
            }
        } preview: {
            AssetPreviewCard(record: record)
        }
    }
}

extension View {
    /// Long-press to see the asset full size, and to act on it.
    func assetPreview(
        _ record: AssetRecord,
        isSelected: Bool,
        onToggle: (() -> Void)? = nil,
        onMakeKeeper: (() -> Void)? = nil
    ) -> some View {
        modifier(
            AssetPreviewMenu(
                record: record,
                isSelected: isSelected,
                onToggle: onToggle,
                onMakeKeeper: onMakeKeeper
            )
        )
    }
}
