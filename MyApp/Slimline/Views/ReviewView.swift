import SwiftUI
import UIKit

/// The last stop before anything is removed.
///
/// Shows exactly what will go and what it frees. Two properties matter here: the numbers come
/// from the same `CleanPlan` that drives the deletion, so they can't disagree; and the copy is
/// explicit that space returns only after Recently Deleted is emptied.
struct ReviewView: View {
    let plan: CleanPlan
    let sizesAreEstimated: Bool
    let onConfirm: () async -> Void

    @State private var isDeleting = false
    @State private var showConfirmation = false

    var body: some View {
        List {
            Section {
                // Opens the photos themselves, not just a count: this is the moment to see
                // exactly what's about to go.
                if plan.totalAssetCount > 0 {
                    NavigationLink {
                        SelectedAssetsView(plan: plan)
                    } label: {
                        VStack(alignment: .leading, spacing: 10) {
                            LabeledContent("Photos and videos", value: "\(plan.totalAssetCount)")
                            SelectedAssetsStrip(plan: plan)
                        }
                    }
                } else {
                    LabeledContent("Photos and videos", value: "0")
                }
                LabeledContent("Space freed", value: ByteFormatting.string(plan.totalBytes))
                if !plan.mergingGroupIDs.isEmpty {
                    LabeledContent(
                        "Contacts merged",
                        value: "\(plan.mergingGroupIDs.count) into one each"
                    )
                }
                if !plan.selectedContactIDs.isEmpty {
                    LabeledContent("Contacts deleted", value: "\(plan.selectedContactIDs.count)")
                }
                if !plan.selectedEventIDs.isEmpty {
                    LabeledContent("Calendar events deleted", value: "\(plan.selectedEventIDs.count)")
                }
            } header: {
                Text("About to remove")
            } footer: {
                if sizesAreEstimated {
                    Text("Photo sizes are approximate on this version of iOS, so the total is an estimate. Video sizes are exact.")
                }
            }

            // Only rendered when there's something to say. An empty section still draws its
            // header, which reads as content that failed to load.
            if plan.totalAssetCount > 0 || plan.totalContactsRemoved > 0 || !plan.selectedEventIDs.isEmpty {
                Section {
                    // Whole sets can be selected now, so say so rather than let a set vanish
                    // without the user having noticed nothing of it is being kept.
                    if plan.fullySelectedGroupCount > 0 {
                        let count = plan.fullySelectedGroupCount
                        Label {
                            Text("**\(count) \(count == 1 ? "set is" : "sets are") fully selected**, so no photo from \(count == 1 ? "it" : "them") will be kept. To keep a set instead, go back and tap Keep.")
                        } icon: {
                            Image(systemName: "square.stack.3d.up.slash")
                                .foregroundStyle(Theme.destructive)
                        }
                        .font(.subheadline)
                    }

                    if plan.totalAssetCount > 0 {
                        Label {
                            Text("Deleted photos go to **Recently Deleted** in Photos, where iOS keeps them for 30 days. Your storage won't actually drop until you empty that album.")
                        } icon: {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(Theme.warning)
                        }
                        .font(.subheadline)

                        Button("Open Photos to empty it") {
                            openRecentlyDeleted()
                        }
                    }

                    // Contacts have no undo of any kind, unlike photos. Saying so is the
                    // difference between an informed approval and a surprise.
                    if plan.totalContactsRemoved > 0 {
                        Label {
                            Text("Contact changes are **permanent** — there's no Recently Deleted for contacts. Merging keeps every phone number and email on the card it keeps.")
                        } icon: {
                            Image(systemName: "person.crop.circle.badge.exclamationmark")
                                .foregroundStyle(Theme.warning)
                        }
                        .font(.subheadline)
                    }

                    // Same reason as contacts, and it syncs: an event removed here is removed
                    // from every device on the account.
                    if !plan.selectedEventIDs.isEmpty {
                        Label {
                            Text("Calendar deletions are **permanent** and sync to all your devices. Only past, one-off events are ever offered.")
                        } icon: {
                            Image(systemName: "calendar.badge.exclamationmark")
                                .foregroundStyle(Theme.warning)
                        }
                        .font(.subheadline)
                    }
                } header: {
                    Text("What happens next")
                }
            }
        }
        .navigationTitle("Review")
        .scrollContentBackground(.hidden)
        .pageBackground()
        .safeAreaInset(edge: .bottom) {
            confirmButton
        }
    }

    /// The commit action, pinned to the bottom of the screen.
    ///
    /// Previously the last section of the list, which meant it sat wherever the content happened
    /// to end — halfway up the screen on a short review. The one irreversible action in the app
    /// should be in the same place every time, and be reachable by thumb.
    private var confirmButton: some View {
        Button(role: .destructive) {
            showConfirmation = true
        } label: {
            HStack(spacing: 8) {
                Spacer()
                if isDeleting {
                    ProgressView().tint(.white)
                    Text("Removing…")
                        .font(.body.weight(.semibold))
                } else {
                    Text("Remove \(itemsPhrase)")
                        .font(.body.weight(.semibold))
                }
                Spacer()
            }
            .foregroundStyle(.white)
            .frame(height: 50)
            .background(Theme.destructive, in: .capsule)
            .opacity(plan.isEmpty || isDeleting ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .disabled(plan.isEmpty || isDeleting)
        // Attached to the button rather than to the list: on iOS 26 a confirmation dialog anchors
        // itself to the view it's modifying, so hanging it off the list pinned the popover to the
        // top of the screen with its tail pointing at nothing.
        .confirmationDialog(
            "Remove \(itemsPhrase)?",
            isPresented: $showConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                Task {
                    isDeleting = true
                    await onConfirm()
                    isDeleting = false
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
        .padding(.horizontal, Theme.screenInset)
        .padding(.top, 10)
        .padding(.bottom, 8)
        // An opaque bar so list rows scrolling underneath never collide with the action.
        .background {
            Theme.surface
                .overlay(alignment: .top) { Theme.divider.frame(height: 1) }
                .ignoresSafeArea()
        }
    }

    private var totalItems: Int {
        plan.totalItemCount
    }

    /// "1 item" rather than "1 items". The button is the last thing read before an irreversible
    /// action, which is a poor place to look careless.
    private var itemsPhrase: String {
        "\(totalItems) item\(totalItems == 1 ? "" : "s")"
    }

    /// Photos get a second, system-level confirmation from PhotoKit; contacts don't. Promising two
    /// approvals when only one is coming would be a lie the user notices at the worst moment.
    private var confirmationMessage: String {
        // Named precisely, so the message never warns about contacts on a photos-only clean or
        // forgets the calendar on a mixed one.
        var permanent: [String] = []
        if plan.totalContactsRemoved > 0 { permanent.append("Contact") }
        if !plan.selectedEventIDs.isEmpty { permanent.append("calendar") }

        let permanentNote = permanent.isEmpty
            ? nil
            : "\(permanent.joined(separator: " and ")) changes apply straight away and can't be undone."

        if plan.totalAssetCount > 0 {
            return ["iOS will ask you to confirm the photos as well.", permanentNote]
                .compactMap { $0 }
                .joined(separator: " ")
        }
        return permanentNote ?? "This can't be undone."
    }

    /// Photos exposes no public deep link to a specific album, so this opens the app itself and
    /// the copy above tells the user where to go. Better than a link that silently does nothing.
    private func openRecentlyDeleted() {
        guard let url = URL(string: "photos-redirect://") else { return }
        UIApplication.shared.open(url)
    }
}

#Preview("Short review") {
    let plan = CleanPlan()
    return NavigationStack {
        ReviewView(plan: plan, sizesAreEstimated: true, onConfirm: {})
    }
}
