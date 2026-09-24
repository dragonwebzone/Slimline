import Foundation

/// A set of contacts that look like the same person.
nonisolated struct DuplicateContactGroup: Sendable, Identifiable, Hashable {
    let id: String
    let contacts: [ContactRecord]
    /// The card we suggest keeping, and the one a merge folds everything into. Never pre-selected
    /// for deletion.
    let primaryContactID: String

    var primary: ContactRecord {
        contacts.first { $0.id == primaryContactID } ?? contacts[0]
    }

    var duplicates: [ContactRecord] {
        contacts.filter { $0.id != primaryContactID }
    }

    /// Why these were matched, in the user's words. Shown per group so the suggestion is never a
    /// black box the user has to trust blindly.
    var reason: String {
        let others = duplicates
        if others.contains(where: { !ContactGrouping.sharedPhones(primary, $0).isEmpty }) {
            return "Same phone number"
        }
        if others.contains(where: { !ContactGrouping.sharedEmails(primary, $0).isEmpty }) {
            return "Same email address"
        }
        return "Same name"
    }
}

/// The pure, testable half of duplicate-contact detection.
///
/// Free of the Contacts framework on purpose, exactly like `PhotoGrouping`: the matching rules are
/// the part that can be wrong in a way that costs the user real data, so they need coverage that
/// doesn't depend on whatever happens to be in the address book of the test device.
nonisolated enum ContactGrouping {

    // MARK: - Normalisation

    /// Digits only, reduced to the last 10.
    ///
    /// The same number is routinely stored as "+91 98765 43210", "098765 43210" and "9876543210".
    /// Comparing raw strings would miss all of those. Ten digits is the sweet spot: it survives
    /// country codes and trunk prefixes without colliding the way a shorter suffix would.
    static func normalizedPhone(_ raw: String) -> String? {
        let digits = raw.filter(\.isNumber)
        guard digits.count >= 7 else { return nil }
        return String(digits.suffix(10))
    }

    static func normalizedEmail(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Case-, accent- and punctuation-insensitive name key.
    ///
    /// Returns `nil` for names too short to be evidence of anything — matching every "A" in the
    /// address book together would be worse than useless.
    static func normalizedName(_ record: ContactRecord) -> String? {
        let combined = "\(record.givenName) \(record.familyName)"
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            // Split on whitespace only, then strip punctuation *within* each part. Splitting on
            // punctuation instead would turn "Love-lace" into two parts and stop it matching
            // "Lovelace", which is the same surname spelled two ways.
            .components(separatedBy: .whitespacesAndNewlines)
            .map { part in String(part.filter { $0.isLetter || $0.isNumber }) }
            .filter { !$0.isEmpty }
            .sorted()  // "Ada Lovelace" and "Lovelace Ada" are the same person filed two ways.
            .joined(separator: " ")

        return combined.count >= 3 ? combined : nil
    }

    static func sharedPhones(_ lhs: ContactRecord, _ rhs: ContactRecord) -> Set<String> {
        Set(lhs.phoneNumbers.compactMap(normalizedPhone))
            .intersection(rhs.phoneNumbers.compactMap(normalizedPhone))
    }

    static func sharedEmails(_ lhs: ContactRecord, _ rhs: ContactRecord) -> Set<String> {
        Set(lhs.emailAddresses.compactMap(normalizedEmail))
            .intersection(rhs.emailAddresses.compactMap(normalizedEmail))
    }

    // MARK: - Matching

    /// Whether two cards look like the same person.
    ///
    /// A shared phone number or email address is treated as conclusive. A shared name alone is
    /// weaker — two different people really can be called the same thing — so it only counts when
    /// neither card carries contact details that actively contradict the other. Without that
    /// guard, two colleagues with the same common name and different phones would be offered as
    /// duplicates, which is the one mistake in this feature that loses data.
    static func isDuplicate(_ lhs: ContactRecord, _ rhs: ContactRecord) -> Bool {
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }

        if !sharedPhones(lhs, rhs).isEmpty { return true }
        if !sharedEmails(lhs, rhs).isEmpty { return true }

        guard let lhsName = normalizedName(lhs),
              let rhsName = normalizedName(rhs),
              lhsName == rhsName
        else { return false }

        return !hasConflictingDetails(lhs, rhs)
    }

    /// True when both cards carry details of the same kind and none of them agree.
    ///
    /// One card having a phone and the other having none is not a conflict — that's the classic
    /// half-filled duplicate this feature exists to clean up.
    private static func hasConflictingDetails(
        _ lhs: ContactRecord,
        _ rhs: ContactRecord
    ) -> Bool {
        let lhsPhones = Set(lhs.phoneNumbers.compactMap(normalizedPhone))
        let rhsPhones = Set(rhs.phoneNumbers.compactMap(normalizedPhone))
        if !lhsPhones.isEmpty, !rhsPhones.isEmpty, lhsPhones.isDisjoint(with: rhsPhones) {
            return true
        }

        let lhsEmails = Set(lhs.emailAddresses.compactMap(normalizedEmail))
        let rhsEmails = Set(rhs.emailAddresses.compactMap(normalizedEmail))
        if !lhsEmails.isEmpty, !rhsEmails.isEmpty, lhsEmails.isDisjoint(with: rhsEmails) {
            return true
        }

        return false
    }

    // MARK: - Grouping

    /// Buckets contacts so that only plausibly-matching pairs are ever compared.
    ///
    /// Same reasoning as the photo scan: comparing every contact against every other is O(n²).
    /// An address book is far smaller than a photo library, but a blind sweep over 5,000 contacts
    /// is still 12 million comparisons on the main path. Every match rule requires a shared key —
    /// a phone, an email, or a name — so contacts are indexed by those keys and only cards that
    /// collide on at least one are compared directly.
    static func candidateBuckets(for records: [ContactRecord]) -> [[ContactRecord]] {
        var byKey: [String: [Int]] = [:]

        for (index, record) in records.enumerated() where !record.isEmpty {
            for phone in record.phoneNumbers.compactMap(normalizedPhone) {
                byKey["p:\(phone)", default: []].append(index)
            }
            for email in record.emailAddresses.compactMap(normalizedEmail) {
                byKey["e:\(email)", default: []].append(index)
            }
            if let name = normalizedName(record) {
                byKey["n:\(name)", default: []].append(index)
            }
        }

        return byKey.values
            .filter { $0.count > 1 }
            .map { indices in indices.map { records[$0] } }
    }

    /// Finds every duplicate group in an address book.
    static func groups(in records: [ContactRecord]) -> [DuplicateContactGroup] {
        var indexByID: [String: Int] = [:]
        for (index, record) in records.enumerated() {
            indexByID[record.id] = index
        }

        var unionFind = UnionFind(count: records.count)
        var didMatch = false

        for bucket in candidateBuckets(for: records) {
            for i in bucket.indices {
                for j in bucket.index(after: i)..<bucket.endIndex {
                    guard isDuplicate(bucket[i], bucket[j]) else { continue }
                    guard let left = indexByID[bucket[i].id],
                          let right = indexByID[bucket[j].id]
                    else { continue }
                    unionFind.union(left, right)
                    didMatch = true
                }
            }
        }

        guard didMatch else { return [] }

        return unionFind.clusters()
            .map { indices in
                let members = indices.map { records[$0] }
                let primary = primaryContactID(in: members)
                return DuplicateContactGroup(
                    id: primary,
                    contacts: members.sorted { $0.fieldCount > $1.fieldCount },
                    primaryContactID: primary
                )
            }
            .sorted { $0.duplicates.count > $1.duplicates.count }
    }

    /// Picks the card to keep: the most complete one.
    ///
    /// Completeness first because a merge folds the others into this card, so starting from the
    /// richest entry loses the least if anything goes wrong. Then a photo, then the longer name,
    /// then identifier order purely so the choice is stable between scans — a keeper that moves
    /// on every rescan would keep clearing the user's selections.
    static func primaryContactID(in group: [ContactRecord]) -> String {
        precondition(!group.isEmpty, "A duplicate-contact group is never empty")

        let best = group.max { lhs, rhs in
            if lhs.fieldCount != rhs.fieldCount { return lhs.fieldCount < rhs.fieldCount }
            if lhs.hasImage != rhs.hasImage { return rhs.hasImage }

            let lhsNameLength = lhs.displayName.count
            let rhsNameLength = rhs.displayName.count
            if lhsNameLength != rhsNameLength { return lhsNameLength < rhsNameLength }

            return lhs.id > rhs.id
        }

        return best?.id ?? group[0].id
    }

    /// The union of every field across a group, as it would look after a merge.
    ///
    /// Drives the merge preview and the merge itself, so what the user is shown is by construction
    /// what gets written.
    static func mergedFields(for group: DuplicateContactGroup) -> MergedFields {
        let ordered = [group.primary] + group.duplicates

        return MergedFields(
            givenName: ordered.first { !$0.givenName.isEmpty }?.givenName ?? "",
            familyName: ordered.first { !$0.familyName.isEmpty }?.familyName ?? "",
            organization: ordered.first { !$0.organization.isEmpty }?.organization ?? "",
            phoneNumbers: dedupe(ordered.flatMap(\.phoneNumbers), by: normalizedPhone),
            emailAddresses: dedupe(ordered.flatMap(\.emailAddresses), by: normalizedEmail)
        )
    }

    /// Keeps the first spelling of each distinct value, so the merged card reads the way the user
    /// wrote it rather than in some normalised form.
    private static func dedupe(
        _ values: [String],
        by key: (String) -> String?
    ) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values {
            guard let normalized = key(value) else { continue }
            guard seen.insert(normalized).inserted else { continue }
            result.append(value)
        }
        return result
    }

    nonisolated struct MergedFields: Sendable, Equatable {
        let givenName: String
        let familyName: String
        let organization: String
        let phoneNumbers: [String]
        let emailAddresses: [String]
    }
}
