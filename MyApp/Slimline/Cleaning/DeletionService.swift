import Contacts
import Photos

/// Carries out an approved clean, and reports what actually happened.
///
/// Note on what "freed" means: `deleteAssets` moves photos to Recently Deleted, where iOS keeps
/// them for 30 days. Disk space is not reclaimed until that album is emptied. This type therefore
/// reports bytes as *pending* rather than freed, and the UI is responsible for saying so. Claiming
/// an immediate saving would be straightforwardly untrue.
actor DeletionService {
    nonisolated struct Outcome: Sendable {
        let assetsRequested: Int
        let assetsDeleted: Int
        let contactsDeleted: Int
        /// Bytes that will be reclaimed once Recently Deleted is emptied.
        let bytesPendingReclaim: Int64
        let failure: String?

        var didAnything: Bool { assetsDeleted > 0 || contactsDeleted > 0 }
    }

    /// Deletes photos and videos.
    ///
    /// PhotoKit shows its own confirmation alert for this change, which sits on top of our review
    /// screen — two independent approvals before anything goes. If the user declines the system
    /// alert, `performChanges` throws and nothing is removed.
    func deleteAssets(ids: [String], expectedBytes: Int64) async -> Outcome {
        guard !ids.isEmpty else {
            return Outcome(
                assetsRequested: 0,
                assetsDeleted: 0,
                contactsDeleted: 0,
                bytesPendingReclaim: 0,
                failure: nil
            )
        }

        // Re-fetch by identifier rather than trusting a captured PHAsset. Anything already gone
        // simply isn't in the result, so a stale selection can't delete the wrong thing.
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var assets: [PHAsset] = []
        fetched.enumerateObjects { asset, _, _ in assets.append(asset) }

        guard !assets.isEmpty else {
            return Outcome(
                assetsRequested: ids.count,
                assetsDeleted: 0,
                contactsDeleted: 0,
                bytesPendingReclaim: 0,
                failure: "Those photos are no longer in your library."
            )
        }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets as NSArray)
            }
            return Outcome(
                assetsRequested: ids.count,
                assetsDeleted: assets.count,
                contactsDeleted: 0,
                bytesPendingReclaim: expectedBytes,
                failure: nil
            )
        } catch {
            // The commonest cause by far is the user tapping "Don't Allow" on the system alert,
            // which is a legitimate choice rather than an error to apologise for.
            return Outcome(
                assetsRequested: ids.count,
                assetsDeleted: 0,
                contactsDeleted: 0,
                bytesPendingReclaim: 0,
                failure: "Nothing was deleted."
            )
        }
    }

    /// Deletes contacts outright.
    func deleteContacts(ids: [String]) async -> Outcome {
        guard !ids.isEmpty else {
            return Outcome(
                assetsRequested: 0,
                assetsDeleted: 0,
                contactsDeleted: 0,
                bytesPendingReclaim: 0,
                failure: nil
            )
        }

        let store = CNContactStore()
        let keys = [CNContactIdentifierKey as CNKeyDescriptor]
        let request = CNSaveRequest()
        var queued = 0

        for id in ids {
            let predicate = CNContact.predicateForContacts(withIdentifiers: [id])
            guard let contact = try? store.unifiedContacts(matching: predicate, keysToFetch: keys).first else {
                continue
            }
            request.delete(contact.mutableCopy() as! CNMutableContact)
            queued += 1
        }

        guard queued > 0 else {
            return Outcome(
                assetsRequested: 0,
                assetsDeleted: 0,
                contactsDeleted: 0,
                bytesPendingReclaim: 0,
                failure: "Those contacts are no longer available."
            )
        }

        do {
            try store.execute(request)
            return Outcome(
                assetsRequested: 0,
                assetsDeleted: 0,
                contactsDeleted: queued,
                bytesPendingReclaim: 0,
                failure: nil
            )
        } catch {
            return Outcome(
                assetsRequested: 0,
                assetsDeleted: 0,
                contactsDeleted: 0,
                bytesPendingReclaim: 0,
                failure: "Contacts couldn't be updated."
            )
        }
    }
}
