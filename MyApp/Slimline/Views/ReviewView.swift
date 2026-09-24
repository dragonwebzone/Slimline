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
                LabeledContent("Photos and videos", value: "\(plan.totalAssetCount)")
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
            } header: {
                Text("About to remove")
            } footer: {
                if sizesAreEstimated {
                    Text("Photo sizes are approximate on this version of iOS, so the total is an estimate. Video sizes are exact.")
                }
            }

            Section {
                if plan.totalAssetCount > 0 {
                    Label {
                        Text("Deleted photos go to **Recently Deleted** in Photos, where iOS keeps them for 30 days. Your storage won't actually drop until you empty that album.")
                    } icon: {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(Theme.reclaimable)
                    }
                    .font(.subheadline)

                    Button("Open Photos to empty it") {
                        openRecentlyDeleted()
                    }
                }

                // Contacts have no undo of any kind, unlike photos. Saying so is the difference
                // between an informed approval and a surprise.
                if plan.totalContactsRemoved > 0 {
                    Label {
                        Text("Contact changes are **permanent** — there's no Recently Deleted for contacts. Merging keeps every phone number and email on the card it keeps.")
                    } icon: {
                        Image(systemName: "person.crop.circle.badge.exclamationmark")
                            .foregroundStyle(Theme.reclaimable)
                    }
                    .font(.subheadline)
                }
            } header: {
                Text("What happens next")
            }

            Section {
                Button(role: .destructive) {
                    showConfirmation = true
                } label: {
                    HStack {
                        Spacer()
                        if isDeleting {
                            ProgressView()
                        } else {
                            Text("Remove \(totalItems) items")
                                .fontWeight(.semibold)
                        }
                        Spacer()
                    }
                }
                .disabled(plan.isEmpty || isDeleting)
            }
        }
        .navigationTitle("Review")
        .confirmationDialog(
            "Remove \(totalItems) items?",
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
    }

    private var totalItems: Int {
        plan.totalAssetCount + plan.totalContactsRemoved
    }

    /// Photos get a second, system-level confirmation from PhotoKit; contacts don't. Promising two
    /// approvals when only one is coming would be a lie the user notices at the worst moment.
    private var confirmationMessage: String {
        if plan.totalAssetCount > 0 {
            return "iOS will ask you to confirm the photos as well. Contact changes apply straight away and can't be undone."
        }
        return "Contact changes apply straight away and can't be undone."
    }

    /// Photos exposes no public deep link to a specific album, so this opens the app itself and
    /// the copy above tells the user where to go. Better than a link that silently does nothing.
    private func openRecentlyDeleted() {
        guard let url = URL(string: "photos-redirect://") else { return }
        UIApplication.shared.open(url)
    }
}
