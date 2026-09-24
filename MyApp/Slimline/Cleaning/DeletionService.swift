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
        /// Contacts absorbed into another card by a merge. Counted separately from deletions
        /// because the user chose a different action, even though the card is gone either way.
        let contactsMerged: Int
        /// Bytes that will be reclaimed once Recently Deleted is emptied.
        let bytesPendingReclaim: Int64
        let failure: String?

        var didAnything: Bool { assetsDeleted > 0 || contactsDeleted > 0 || contactsMerged > 0 }

        /// Defaulted so each call site states only the fields it actually affects — a clean that
        /// touches no contacts shouldn't have to mention them.
        init(
            assetsRequested: Int = 0,
            assetsDeleted: Int = 0,
            contactsDeleted: Int = 0,
            contactsMerged: Int = 0,
            bytesPendingReclaim: Int64 = 0,
            failure: String? = nil
        ) {
            self.assetsRequested = assetsRequested
            self.assetsDeleted = assetsDeleted
            self.contactsDeleted = contactsDeleted
            self.contactsMerged = contactsMerged
            self.bytesPendingReclaim = bytesPendingReclaim
            self.failure = failure
        }

        /// Folds two stages of one clean into a single report.
        func combined(with other: Outcome) -> Outcome {
            Outcome(
                assetsRequested: assetsRequested + other.assetsRequested,
                assetsDeleted: assetsDeleted + other.assetsDeleted,
                contactsDeleted: contactsDeleted + other.contactsDeleted,
                contactsMerged: contactsMerged + other.contactsMerged,
                bytesPendingReclaim: bytesPendingReclaim + other.bytesPendingReclaim,
                // Keep the first failure: it's the one closest to what the user just approved,
                // and a later stage failing too doesn't make the message more useful.
                failure: failure ?? other.failure
            )
        }
    }

    /// Deletes photos and videos.
    ///
    /// PhotoKit shows its own confirmation alert for this change, which sits on top of our review
    /// screen — two independent approvals before anything goes. If the user declines the system
    /// alert, `performChanges` throws and nothing is removed.
    func deleteAssets(ids: [String], expectedBytes: Int64) async -> Outcome {
        guard !ids.isEmpty else { return Outcome() }

        // Re-fetch by identifier rather than trusting a captured PHAsset. Anything already gone
        // simply isn't in the result, so a stale selection can't delete the wrong thing.
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var assets: [PHAsset] = []
        fetched.enumerateObjects { asset, _, _ in assets.append(asset) }

        guard !assets.isEmpty else {
            return Outcome(
                assetsRequested: ids.count,
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
                bytesPendingReclaim: expectedBytes
            )
        } catch {
            // The commonest cause by far is the user tapping "Don't Allow" on the system alert,
            // which is a legitimate choice rather than an error to apologise for.
            return Outcome(
                assetsRequested: ids.count,
                failure: "Nothing was deleted."
            )
        }
    }

    /// Deletes contacts outright.
    ///
    /// Unlike photos, this is immediate and permanent — the Contacts framework has no equivalent
    /// of Recently Deleted, and iOS shows no confirmation of its own. Our review screen is
    /// therefore the only approval step, which is why it asks explicitly.
    func deleteContacts(ids: [String]) async -> Outcome {
        guard !ids.isEmpty else { return Outcome() }

        let store = CNContactStore()
        let keys = [CNContactIdentifierKey as CNKeyDescriptor]
        let request = CNSaveRequest()
        var queued = 0

        for id in ids {
            guard let contact = Self.fetch(id: id, keys: keys, from: store) else { continue }
            request.delete(contact.mutableCopy() as! CNMutableContact)
            queued += 1
        }

        guard queued > 0 else {
            return Outcome(failure: "Those contacts are no longer available.")
        }

        do {
            try store.execute(request)
            return Outcome(contactsDeleted: queued)
        } catch {
            return Outcome(failure: "Contacts couldn't be updated.")
        }
    }

    /// Merges each group into its primary card, then removes the cards it absorbed.
    ///
    /// Both halves go into one `CNSaveRequest` per group so the update and the deletions land
    /// together: if the save fails, the duplicates are still there and nothing has been lost. The
    /// alternative — delete first, then write — can drop data if the write fails.
    func mergeContacts(groups: [DuplicateContactGroup]) async -> Outcome {
        guard !groups.isEmpty else { return Outcome() }

        let store = CNContactStore()
        var merged = 0
        var failures = 0

        // Contacts requires that every key we intend to modify was fetched, or the save throws.
        let keys = ContactRecord.fetchKeys

        for group in groups {
            guard let primary = Self.fetch(id: group.primaryContactID, keys: keys, from: store),
                  let mutablePrimary = primary.mutableCopy() as? CNMutableContact
            else {
                failures += 1
                continue
            }

            let fields = ContactGrouping.mergedFields(for: group)
            apply(fields, to: mutablePrimary)

            let request = CNSaveRequest()
            request.update(mutablePrimary)

            var absorbed = 0
            for duplicate in group.duplicates {
                guard let contact = Self.fetch(id: duplicate.id, keys: keys, from: store),
                      let mutable = contact.mutableCopy() as? CNMutableContact
                else { continue }
                request.delete(mutable)
                absorbed += 1
            }

            do {
                try store.execute(request)
                merged += absorbed
            } catch {
                failures += 1
            }
        }

        guard failures == 0 else {
            return Outcome(
                contactsMerged: merged,
                failure: merged > 0
                    ? "Some contacts couldn't be merged and were left alone."
                    : "Those contacts couldn't be merged."
            )
        }

        return Outcome(contactsMerged: merged)
    }

    /// Writes the merged union onto the primary card.
    ///
    /// Labels are preserved from whichever card first supplied each value; a number the primary
    /// already has keeps its existing label rather than being relabelled by a duplicate.
    private func apply(_ fields: ContactGrouping.MergedFields, to contact: CNMutableContact) {
        if contact.givenName.isEmpty { contact.givenName = fields.givenName }
        if contact.familyName.isEmpty { contact.familyName = fields.familyName }
        if contact.organizationName.isEmpty { contact.organizationName = fields.organization }

        let existingPhones = Set(
            contact.phoneNumbers.compactMap { ContactGrouping.normalizedPhone($0.value.stringValue) }
        )
        for number in fields.phoneNumbers {
            guard let normalized = ContactGrouping.normalizedPhone(number),
                  !existingPhones.contains(normalized)
            else { continue }
            contact.phoneNumbers.append(
                CNLabeledValue(label: CNLabelOther, value: CNPhoneNumber(stringValue: number))
            )
        }

        let existingEmails = Set(
            contact.emailAddresses.compactMap { ContactGrouping.normalizedEmail($0.value as String) }
        )
        for email in fields.emailAddresses {
            guard let normalized = ContactGrouping.normalizedEmail(email),
                  !existingEmails.contains(normalized)
            else { continue }
            contact.emailAddresses.append(
                CNLabeledValue(label: CNLabelOther, value: email as NSString)
            )
        }
    }

    /// Re-fetches a contact by identifier, for the same reason assets are re-fetched: a stale
    /// record then can't cause the wrong card to be changed.
    private static func fetch(
        id: String,
        keys: [CNKeyDescriptor],
        from store: CNContactStore
    ) -> CNContact? {
        let predicate = CNContact.predicateForContacts(withIdentifiers: [id])
        return try? store.unifiedContacts(matching: predicate, keysToFetch: keys).first
    }
}
