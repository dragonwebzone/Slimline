import AVKit
import Photos
import PhotosUI
import SwiftUI

/// The private vault: locked by default, and locked again whenever the app leaves the foreground.
struct VaultView: View {
    /// Told which library photos were removed after being moved in, so results stop offering them.
    let onOriginalsRemoved: (Set<String>) -> Void

    @Environment(\.scenePhase) private var scenePhase

    @State private var isUnlocked = false
    @State private var items: [VaultItem] = []
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var isAdding = false
    /// Moved in, but whose originals are still in the library — the user declined the system
    /// prompt. Until they're removed nothing has actually been hidden, so this is offered again.
    @State private var originalsLeft: [VaultItem] = []
    @State private var viewing: VaultItem?
    @State private var message: String?

    private let vault = PrivateVault()
    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 8)]

    var body: some View {
        Group {
            if isUnlocked {
                unlocked
            } else {
                locked
            }
        }
        .pageBackground()
        .navigationTitle("Private Vault")
        // Locks the moment the app isn't in front — including the app switcher, where the system
        // snapshot would otherwise show the vault's contents.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { isUnlocked = false }
        }
        .sheet(item: $viewing) { item in
            VaultItemViewer(item: item, vault: vault) {
                Task { await reload() }
            }
        }
    }

    // MARK: - Locked

    private var locked: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 48))
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)

            Text("Private Vault")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.primaryText)

            Text("Photos and videos you keep here are hidden from your library and locked behind \(VaultLock.methodName).")
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)

            PrimaryActionButton(title: "Unlock with \(VaultLock.methodName)", systemImage: "faceid") {
                Task {
                    if await VaultLock.unlock() {
                        await reload()
                        withAnimation(.snappy) { isUnlocked = true }
                    }
                }
            }
            .frame(maxWidth: 280)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Unlocked

    private var unlocked: some View {
        ScrollView {
            LazyVStack(spacing: Theme.sectionSpacing) {
                summaryCard

                if !originalsLeft.isEmpty {
                    removeOriginalsCard
                }

                if let message {
                    Label(message, systemImage: "info.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .card(padding: 12)
                }

                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(items) { item in
                        Button {
                            viewing = item
                        } label: {
                            VaultThumbnail(item: item, vault: vault)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(Theme.screenInset)
        }
        .overlay {
            if items.isEmpty && !isAdding {
                ContentUnavailableView(
                    "The vault is empty",
                    systemImage: "lock.rectangle.stack",
                    description: Text("Add photos to keep them out of your library.")
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Lock") { isUnlocked = false }
            }
        }
        .onChange(of: pickerItems) { _, selection in
            guard !selection.isEmpty else { return }
            Task { await add(selection) }
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    SectionHeading("In the vault")
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(items.count)")
                            .font(.system(size: 34, weight: .bold))
                            .foregroundStyle(Theme.primaryText)
                        Text(items.count == 1 ? "item" : "items")
                            .font(.system(size: 14))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                Spacer()
                Chip(text: ByteFormatting.string(items.reduce(0) { $0 + $1.bytes }))
            }

            // The single most important thing to know about this feature, stated where it can't
            // be missed rather than in a settings footnote.
            Label {
                Text("Vault items live **only in Slimline on this iPhone** — not in iCloud or your backups. Deleting Slimline deletes them. Restore anything you want to keep first.")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning)
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.secondaryText)

            PhotosPicker(
                selection: $pickerItems,
                matching: .any(of: [.images, .videos]),
                photoLibrary: .shared()
            ) {
                HStack(spacing: 8) {
                    if isAdding {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "plus")
                    }
                    Text(isAdding ? "Adding…" : "Add from library")
                        .font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Theme.accent, in: .capsule)
            }
            .disabled(isAdding)
        }
        .card()
    }

    /// Shown only when the originals couldn't be removed, usually because the user tapped
    /// "Don't Allow". The photos are in two places until this is done.
    private var removeOriginalsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(originalsLeft.count) still in your library")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
            Text("They're safely in the vault, but the originals weren't removed, so they're still visible in Photos.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
            HStack(spacing: 8) {
                Button("Not now") { originalsLeft = [] }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                Button("Remove from library") {
                    Task { await removeOriginals(originalsLeft) }
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.accent)
            }
        }
        .card(padding: 14)
    }

    // MARK: - Actions

    private func reload() async {
        items = await vault.all()
    }

    private func add(_ selection: [PhotosPickerItem]) async {
        isAdding = true
        message = nil
        var added: [VaultItem] = []
        var failed = 0

        for picked in selection {
            guard let id = picked.itemIdentifier else { failed += 1; continue }
            do {
                added.append(try await vault.add(assetID: id))
            } catch {
                failed += 1
            }
        }

        pickerItems = []
        await reload()
        isAdding = false

        // Moving means the photo leaves the library; a copy in both places hides nothing.
        await removeOriginals(added)

        if failed > 0 {
            message = "\(failed) item\(failed == 1 ? "" : "s") couldn't be added — probably stored in iCloud only. \(failed == 1 ? "It's" : "They're") still in your library."
        }
    }

    /// Deletes the library originals of items now in the vault, so they're only in the vault.
    ///
    /// Only originals whose vault copy was written in full are touched — an item that came back
    /// empty keeps its original, so a failed copy can never cost the user the photo. iOS asks for
    /// confirmation itself, and the originals go to Photos' Recently Deleted, not straight away.
    private func removeOriginals(_ moved: [VaultItem]) async {
        let ids = moved.filter { $0.bytes > 0 }.compactMap(\.sourceAssetID)
        guard !ids.isEmpty else { return }

        let outcome = await DeletionService().deleteAssets(ids: ids, expectedBytes: 0)
        if outcome.assetsDeleted > 0 {
            originalsLeft = []
            onOriginalsRemoved(Set(ids))
            message = "Moved to the vault. The originals are in Photos' Recently Deleted album for 30 days — empty it there to remove them sooner."
        } else {
            originalsLeft = moved
        }
    }
}

/// A vault item's thumbnail, decoded straight from its protected file.
private struct VaultThumbnail: View {
    let item: VaultItem
    let vault: PrivateVault

    @State private var image: UIImage?

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Theme.surfaceDim
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if item.isVideo {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                        .padding(6)
                }
            }
            .clipShape(.rect(cornerRadius: Theme.innerCorner))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.innerCorner).strokeBorder(Theme.divider, lineWidth: 1)
            }
            .task(id: item.id) {
                let url = await vault.url(for: item)
                image = await vault.thumbnail(for: item, url: url, maxPixel: 300)
            }
            .accessibilityLabel(item.isVideo ? "Vault video" : "Vault photo")
    }
}

/// One vault item, full size, with the ways out of the vault.
private struct VaultItemViewer: View {
    let item: VaultItem
    let vault: PrivateVault
    let onChange: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var confirmDelete = false
    @State private var status: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if item.isVideo {
                    VaultVideoPlayer(item: item, vault: vault)
                } else if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    ProgressView().tint(.white)
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if let status {
                        Text(status)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    HStack(spacing: 12) {
                        Button {
                            Task {
                                do {
                                    try await vault.restore(item)
                                    status = "Restored to your library. The vault copy is still here."
                                } catch {
                                    status = "Couldn't restore to your library."
                                }
                            }
                        } label: {
                            Label("Restore to Library", systemImage: "arrow.uturn.backward")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)

                        Button(role: .destructive) {
                            confirmDelete = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(Theme.destructive)
                        .confirmationDialog(
                            "Delete from the vault?",
                            isPresented: $confirmDelete,
                            titleVisibility: .visible
                        ) {
                            Button("Delete permanently", role: .destructive) {
                                Task {
                                    try? await vault.remove(item)
                                    onChange()
                                    dismiss()
                                }
                            }
                        } message: {
                            // No Recently Deleted here either: the vault is outside Photos.
                            Text("This can't be undone. Restore it to your library first if you might want it.")
                        }
                    }
                }
                .padding(Theme.screenInset)
                .background(.black.opacity(0.6))
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
            .task {
                guard !item.isVideo else { return }
                let url = await vault.url(for: item)
                image = await vault.thumbnail(for: item, url: url, maxPixel: 2400)
            }
        }
    }
}

private struct VaultVideoPlayer: View {
    let item: VaultItem
    let vault: PrivateVault
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
            } else {
                ProgressView().tint(.white)
            }
        }
        .task {
            let made = AVPlayer(url: await vault.url(for: item))
            player = made
            made.play()
        }
        .onDisappear { player?.pause() }
    }
}
