import AVFoundation
import SwiftUI
import UIKit

/// One-at-a-time review: swipe left to mark for deletion, right to keep for good.
///
/// A photo swiped right is never suggested again — that's the point of saying "keep" to it. The
/// kept photos are handed over when the screen closes rather than one by one, so undo stays a
/// local step and the list being reviewed doesn't shift underneath the user.
///
/// A swipe marks; it never deletes. Everything swiped left lands in the same `CleanPlan` the grid
/// selections do, and still goes through the review screen and PhotoKit's own confirmation. That
/// matters more here than anywhere else in the app, because swiping is fast by design — fast
/// enough that a mistaken flick must be cheap to recover from. Hence the undo, too.
struct SwipeReviewView: View {
    let title: String
    let plan: CleanPlan

    @Environment(\.dismiss) private var dismiss
    @Environment(\.keepForGood) private var keepForGood

    /// A copy taken on arrival. The source list changes as photos are kept or deleted elsewhere,
    /// and indexing into a moving list would skip or repeat cards.
    @State private var records: [AssetRecord]
    /// Swiped right this session, committed on close.
    @State private var keptIDs: Set<String> = []

    @State private var index = 0
    @State private var drag: CGSize = .zero
    /// What each swipe did, so undo can put the plan back exactly as it was — including leaving a
    /// photo selected if it was selected before the user swiped it.
    @State private var history: [(record: AssetRecord, wasSelected: Bool, decision: Decision)] = []
    @State private var refusedID: String?

    /// How far a card has to travel before letting go commits it.
    private let commitDistance: CGFloat = 110

    init(title: String, records: [AssetRecord], plan: CleanPlan) {
        self.title = title
        self.plan = plan
        _records = State(initialValue: records)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                progressHeader

                ZStack {
                    if let record = current {
                        card(for: record)
                            .id(record.id)
                            .transition(.asymmetric(insertion: .scale(scale: 0.94).combined(with: .opacity), removal: .opacity))
                    } else {
                        finished
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                controls
            }
            .padding(Theme.screenInset)
            .pageBackground()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
            .sensoryFeedback(.selection, trigger: index)
        }
        .onDisappear {
            keepForGood?(Array(keptIDs))
        }
    }

    private var current: AssetRecord? {
        records.indices.contains(index) ? records[index] : nil
    }

    // MARK: - Header

    private var progressHeader: some View {
        VStack(spacing: 6) {
            HStack {
                Text(current == nil ? "All reviewed" : "\(index + 1) of \(records.count)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
                    .contentTransition(.numericText())
                Spacer()
                Text("\(markedCount) marked")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(markedCount > 0 ? Theme.destructive : Theme.secondaryText)
                    .contentTransition(.numericText())
            }
            ProgressView(value: Double(min(index, records.count)), total: Double(max(records.count, 1)))
                .tint(Theme.accent)
        }
    }

    // MARK: - Card

    private func card(for record: AssetRecord) -> some View {
        let lean = drag.width / commitDistance

        return VStack(spacing: 0) {
            Color.clear
                .overlay {
                    if record.isVideo {
                        SwipeVideo(record: record)
                    } else {
                        AssetThumbnail(assetID: record.id, targetPixels: 900, cornerRadius: 0, fills: false)
                    }
                }
                .background(record.isVideo ? Color.black : Theme.surfaceDim)
                .clipped()

            HStack {
                Text(record.byteSize.map { ByteFormatting.string($0) } ?? "Size unknown")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                Spacer()
                if record.isVideo {
                    Label(
                        Duration.seconds(record.duration).formatted(.time(pattern: .minuteSecond)),
                        systemImage: "video.fill"
                    )
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.trailing, 6)
                }
                if let date = record.creationDate {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            .padding(12)
            .background(Theme.surface)
        }
        .clipShape(.rect(cornerRadius: Theme.cardCorner))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardCorner)
                .strokeBorder(Theme.divider, lineWidth: 1)
        }
        .overlay(alignment: .topLeading) {
            stamp("KEEP", color: Theme.accent)
                .opacity(Double(max(0, lean)))
                .rotationEffect(.degrees(-12))
                .padding(20)
        }
        .overlay(alignment: .topTrailing) {
            stamp("DELETE", color: Theme.destructive)
                .opacity(Double(max(0, -lean)))
                .rotationEffect(.degrees(12))
                .padding(20)
        }
        .overlay(alignment: .bottom) {
            if refusedID == record.id {
                Text("This is the last photo left in its set, so it can't be deleted.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.7), in: .capsule)
                    .padding(.bottom, 60)
                    .transition(.opacity)
            }
        }
        .offset(x: drag.width, y: drag.height * 0.2)
        .rotationEffect(.degrees(Double(drag.width / 18)))
        .gesture(
            DragGesture()
                .onChanged { drag = $0.translation }
                .onEnded { value in
                    if value.translation.width > commitDistance {
                        decide(.keep)
                    } else if value.translation.width < -commitDistance {
                        decide(.delete)
                    } else {
                        withAnimation(.snappy) { drag = .zero }
                    }
                }
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Photo \(index + 1) of \(records.count)")
        .accessibilityAction(named: "Keep") { decide(.keep) }
        .accessibilityAction(named: "Mark for deletion") { decide(.delete) }
    }

    private func stamp(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 26, weight: .heavy))
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .overlay {
                RoundedRectangle(cornerRadius: 10).strokeBorder(color, lineWidth: 3)
            }
            .background(Theme.surface.opacity(0.85), in: .rect(cornerRadius: 10))
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 28) {
            circleButton("xmark", color: Theme.destructive, label: "Mark for deletion") {
                decide(.delete)
            }
            .disabled(current == nil)

            circleButton("arrow.uturn.backward", color: Theme.secondaryText, label: "Undo", small: true) {
                undo()
            }
            .disabled(history.isEmpty)

            circleButton("heart.fill", color: Theme.accent, label: "Keep and don't show again") {
                decide(.keep)
            }
            .disabled(current == nil)
        }
        .padding(.bottom, 8)
    }

    private func circleButton(
        _ symbol: String,
        color: Color,
        label: String,
        small: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: small ? 17 : 24, weight: .bold))
                .foregroundStyle(color)
                .frame(width: small ? 48 : 64, height: small ? 48 : 64)
                .background(Theme.surface, in: .circle)
                .overlay(Circle().strokeBorder(Theme.divider, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var finished: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52))
                .foregroundStyle(Theme.accent)
            Text("All \(records.count) reviewed")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
            Text(finishedSummary)
            .font(.system(size: 14))
            .foregroundStyle(Theme.secondaryText)
            .multilineTextAlignment(.center)

            PrimaryActionButton(title: markedCount > 0 ? "Back to review" : "Done") { dismiss() }
                .frame(maxWidth: 240)
                .padding(.top, 6)
        }
        .padding(24)
    }

    // MARK: - Decisions

    private enum Decision { case keep, delete }

    private var finishedSummary: String {
        var lines: [String] = []
        lines.append(
            markedCount > 0
                ? "\(markedCount) marked for deletion. Nothing is removed until you review and confirm."
                : "Nothing marked for deletion."
        )
        if !keptIDs.isEmpty {
            lines.append("\(keptIDs.count) kept — they won't be suggested again.")
        }
        return lines.joined(separator: "\n")
    }

    private var markedCount: Int {
        records.filter { plan.isSelected($0.id) }.count
    }

    private func decide(_ decision: Decision) {
        guard let record = current else { return }
        let wasSelected = plan.isSelected(record.id)

        switch decision {
        case .keep:
            plan.deselect(record.id)
            keptIDs.insert(record.id)
        case .delete:
            // The plan has the final word. A photo it refuses — the last one in a set — bounces back
            // with the reason, rather than appearing to be marked when it isn't.
            guard wasSelected || plan.select(record) else {
                withAnimation(.snappy) {
                    drag = .zero
                    refusedID = record.id
                }
                return
            }
        }

        history.append((record, wasSelected, decision))
        refusedID = nil

        let exit: CGFloat = decision == .keep ? 600 : -600
        withAnimation(.easeIn(duration: 0.18)) { drag = CGSize(width: exit, height: 0) }
        Task {
            try? await Task.sleep(for: .milliseconds(180))
            drag = .zero
            withAnimation(.snappy) { index += 1 }
        }
    }

    private func undo() {
        guard let last = history.popLast() else { return }

        if last.decision == .keep {
            keptIDs.remove(last.record.id)
        }

        if last.wasSelected {
            plan.select(last.record)
        } else {
            plan.deselect(last.record.id)
        }

        refusedID = nil
        withAnimation(.snappy) { index = max(0, index - 1) }
    }
}

/// A video on a swipe card: its poster frame until tapped, then playing in place.
///
/// Not SwiftUI's `VideoPlayer`: its scrubber and controls sit on the card and catch the very
/// drags that swipe it away. A bare player layer that ignores touches leaves the swipe working,
/// and a tap on the card plays or pauses. Playback is on-device only, like everywhere else.
private struct SwipeVideo: View {
    let record: AssetRecord

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var isLoading = false
    @State private var unavailable = false
    /// Playback position in seconds, driven by the player or by the scrubber.
    @State private var position: Double = 0
    @State private var isScrubbing = false
    @State private var wasPlayingBeforeScrub = false

    private var duration: Double { max(record.duration, 0.1) }

    var body: some View {
        ZStack {
            AssetThumbnail(assetID: record.id, targetPixels: 900, cornerRadius: 0, fills: false)
                .opacity(player != nil ? 0 : 1)

            if let player {
                PlayerLayerView(player: player)
                    .allowsHitTesting(false)
            }

            if !isPlaying && !isScrubbing {
                Group {
                    if isLoading {
                        ProgressView().tint(.white)
                    } else if unavailable {
                        Label("Stored in iCloud — can't play here", systemImage: "icloud.slash")
                            .font(.system(size: 13, weight: .medium))
                    } else {
                        Image(systemName: "play.fill")
                            .font(.system(size: 26, weight: .semibold))
                    }
                }
                .foregroundStyle(.white)
                .frame(minWidth: 68, minHeight: 68)
                .padding(.horizontal, unavailable ? 14 : 0)
                .background(.black.opacity(0.45), in: .capsule)
            }
        }
        .contentShape(.rect)
        .onTapGesture { Task { await toggle() } }
        // Outside the tap area, so touching the scrubber never also plays or pauses.
        .overlay(alignment: .bottom) {
            if !unavailable { scrubber }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Video")
        .accessibilityAddTraits(.startsMediaSession)
        .accessibilityAction(named: isPlaying ? "Pause" : "Play") { Task { await toggle() } }
        .onDisappear { player?.pause() }
        // Bring the play button back at the end, so one tap replays it.
        .task(id: player) {
            guard let item = player?.currentItem else { return }
            for await _ in NotificationCenter.default.notifications(
                named: AVPlayerItem.didPlayToEndTimeNotification,
                object: item
            ) {
                isPlaying = false
                position = duration
            }
        }
        // Follows playback while it runs. Polling a few times a second is plenty for a bar this
        // size, and avoids a time-observer token to manage.
        .task(id: isPlaying) {
            while isPlaying, !Task.isCancelled {
                if !isScrubbing, let seconds = player?.currentTime().seconds, seconds.isFinite {
                    position = min(seconds, duration)
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    // MARK: - Scrubber

    private var scrubber: some View {
        HStack(spacing: 10) {
            Text(Self.time(position))
            ScrubTrack(fraction: position / duration, isActive: isScrubbing) { fraction, phase in
                scrub(to: fraction, phase: phase)
            }
            Text("-" + Self.time(duration - position))
        }
        .font(.system(size: 11, weight: .semibold).monospacedDigit())
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.top, 18)
        .padding(.bottom, 10)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        )
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(Self.time(position)) of \(Self.time(duration))")
        .accessibilityAdjustableAction { direction in
            let step = duration / 10
            let target = direction == .increment ? position + step : position - step
            scrub(to: min(max(target, 0), duration) / duration, phase: .ended)
        }
    }

    private func scrub(to fraction: Double, phase: ScrubTrack.Phase) {
        switch phase {
        case .began:
            isScrubbing = true
            wasPlayingBeforeScrub = isPlaying
            player?.pause()
            isPlaying = false
        case .changed, .ended:
            break
        }

        position = fraction * duration
        let target = position
        Task {
            // Scrubbing before the first play loads the video, so the frame under the finger
            // appears straight away rather than only after tapping play.
            if player == nil, await load() == nil { return }
            await player?.seek(
                to: CMTime(seconds: target, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
        }

        if phase == .ended {
            isScrubbing = false
            if wasPlayingBeforeScrub {
                player?.play()
                isPlaying = true
            }
        }
    }

    private static func time(_ seconds: Double) -> String {
        Duration.seconds(max(0, seconds)).formatted(.time(pattern: .minuteSecond))
    }

    // MARK: - Playback

    private func toggle() async {
        if let player {
            if isPlaying {
                player.pause()
            } else {
                // Restart once finished, so a tap replays rather than doing nothing.
                if position >= duration - 0.1 {
                    await player.seek(to: .zero)
                    position = 0
                }
                player.play()
            }
            isPlaying.toggle()
            return
        }

        guard let made = await load() else { return }
        made.play()
        isPlaying = true
    }

    private func load() async -> AVPlayer? {
        if let player { return player }
        guard !isLoading, !unavailable else { return nil }
        isLoading = true
        let made = await VideoPreviewView.makePlayer(assetID: record.id)
        isLoading = false
        guard let made else {
            unavailable = true
            return nil
        }
        player = made
        return made
    }
}

/// A thin track with a knob, dragged directly.
///
/// Its own drag gesture rather than a `Slider`: a child view's gesture wins over the card's swipe
/// gesture, which is what lets the user scrub without flinging the card away.
private struct ScrubTrack: View {
    enum Phase { case began, changed, ended }

    let fraction: Double
    let isActive: Bool
    let onScrub: (Double, Phase) -> Void

    @State private var dragging = false

    var body: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            let clamped = min(max(fraction, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3))
                    .frame(height: isActive ? 6 : 4)
                Capsule().fill(.white)
                    .frame(width: width * clamped, height: isActive ? 6 : 4)
                Circle().fill(.white)
                    .frame(width: isActive ? 16 : 12, height: isActive ? 16 : 12)
                    .offset(x: width * clamped - (isActive ? 8 : 6))
                    .shadow(color: .black.opacity(0.3), radius: 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let next = min(max(value.location.x / width, 0), 1)
                        onScrub(next, dragging ? .changed : .began)
                        dragging = true
                    }
                    .onEnded { value in
                        dragging = false
                        onScrub(min(max(value.location.x / width, 0), 1), .ended)
                    }
            )
            .animation(.snappy(duration: 0.15), value: isActive)
        }
        // Taller than it looks, so it's easy to catch with a thumb.
        .frame(height: 28)
    }
}

/// An `AVPlayerLayer`, sized to its view, with no controls of its own.
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ view: PlayerUIView, context: Context) {
        view.playerLayer.player = player
    }

    final class PlayerUIView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

/// The button that opens swipe review, styled to sit beside "Select all".
struct SwipeLaunchButton: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Swipe", systemImage: "rectangle.stack")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Theme.background, in: .rect(cornerRadius: Theme.controlCorner))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.controlCorner)
                        .strokeBorder(Theme.divider, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .disabled(count == 0)
        .accessibilityHint("Review one at a time. Swipe right to keep for good, left to mark for deletion")
    }
}

#Preview("Swipe review") {
    let records = (0..<5).map { index in
        AssetRecord(
            id: "preview-swipe-\(index)",
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            modificationDate: nil,
            pixelWidth: 1170,
            pixelHeight: 2532,
            isVideo: false,
            isScreenshot: true,
            isScreenRecording: false,
            duration: 0,
            isFavorite: false,
            hasAdjustments: false,
            byteSize: 2_400_000
        )
    }
    return SwipeReviewView(title: "Screenshots", records: records, plan: CleanPlan())
}
