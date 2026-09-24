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
                if !plan.selectedContactIDs.isEmpty {
                    LabeledContent("Contacts", value: "\(plan.selectedContactIDs.count)")
                }
            } header: {
                Text("About to remove")
            } footer: {
                if sizesAreEstimated {
                    Text("Photo sizes are approximate on this version of iOS, so the total is an estimate. Video sizes are exact.")
                }
            }

            Section {
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
                            Text("Remove \(plan.totalAssetCount) items")
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
            "Remove \(plan.totalAssetCount) items?",
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
            Text("iOS will ask you to confirm as well. Nothing is removed until you approve both.")
        }
    }

    /// Photos exposes no public deep link to a specific album, so this opens the app itself and
    /// the copy above tells the user where to go. Better than a link that silently does nothing.
    private func openRecentlyDeleted() {
        guard let url = URL(string: "photos-redirect://") else { return }
        UIApplication.shared.open(url)
    }
}
