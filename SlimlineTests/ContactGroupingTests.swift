import Foundation
import Testing

@testable import MyApp

/// Tests for duplicate-contact matching.
///
/// This is the part of the feature that can lose real data: a false positive offers two different
/// people as the same person, and if the user trusts it, a phone number is gone for good with no
/// Recently Deleted to fall back on. So the negative cases matter at least as much as the
/// positive ones.
@Suite("Contact grouping")
struct ContactGroupingTests {

    // MARK: - Normalisation

    @Test("The same number written different ways normalises the same")
    func phoneNormalisationIgnoresFormatting() {
        let forms = [
            "+91 98765 43210",
            "098765 43210",
            "9876543210",
            "(987) 654-3210",
            "+91-98765-43210",
        ]

        let normalized = Set(forms.compactMap(ContactGrouping.normalizedPhone))

        #expect(normalized.count == 1)
        #expect(normalized.first == "9876543210")
    }

    @Test("Numbers too short to identify anyone are ignored")
    func shortNumbersAreRejected() {
        // Extensions and short codes would otherwise collide huge numbers of unrelated contacts.
        #expect(ContactGrouping.normalizedPhone("123") == nil)
        #expect(ContactGrouping.normalizedPhone("4567") == nil)
        #expect(ContactGrouping.normalizedPhone("") == nil)
        #expect(ContactGrouping.normalizedPhone("1234567") != nil)
    }

    @Test("Email comparison ignores case and surrounding space")
    func emailNormalisation() {
        #expect(ContactGrouping.normalizedEmail("  Ada@Example.COM ") == "ada@example.com")
        #expect(ContactGrouping.normalizedEmail("   ") == nil)
    }

    @Test("Name comparison ignores case, accents, punctuation and field order")
    func nameNormalisation() {
        let plain = ContactRecord(id: "1", givenName: "Ada", familyName: "Lovelace")
        let shouty = ContactRecord(id: "2", givenName: "ADA", familyName: "LOVELACE")
        let accented = ContactRecord(id: "3", givenName: "Áda", familyName: "Lovelace")
        let punctuated = ContactRecord(id: "4", givenName: "Ada.", familyName: "Love-lace")
        // The same person filed with the names in the wrong fields.
        let swapped = ContactRecord(id: "5", givenName: "Lovelace", familyName: "Ada")

        let keys = [plain, shouty, accented, punctuated, swapped]
            .compactMap(ContactGrouping.normalizedName)

        #expect(Set(keys).count == 1)
    }

    @Test("A name too short to be evidence produces no key")
    func shortNamesHaveNoKey() {
        // Matching every single-letter name together would be worse than not matching at all.
        #expect(ContactGrouping.normalizedName(ContactRecord(id: "1", givenName: "A")) == nil)
        #expect(ContactGrouping.normalizedName(ContactRecord(id: "2")) == nil)
        #expect(ContactGrouping.normalizedName(ContactRecord(id: "3", givenName: "Ada")) != nil)
    }

    // MARK: - Matching

    @Test("A shared phone number is conclusive even with different names")
    func sharedPhoneMatches() {
        let work = ContactRecord(
            id: "1",
            givenName: "Ada",
            phoneNumbers: ["+91 98765 43210"]
        )
        let home = ContactRecord(
            id: "2",
            givenName: "Ada",
            familyName: "Lovelace",
            phoneNumbers: ["098765 43210"]
        )

        #expect(ContactGrouping.isDuplicate(work, home))
    }

    @Test("A shared email is conclusive")
    func sharedEmailMatches() {
        let a = ContactRecord(id: "1", givenName: "Ada", emailAddresses: ["ada@example.com"])
        let b = ContactRecord(id: "2", organization: "Analytical Engines", emailAddresses: ["ADA@example.com"])

        #expect(ContactGrouping.isDuplicate(a, b))
    }

    @Test("A half-filled card matches its complete twin by name")
    func nameOnlyMatchWhenNothingContradicts() {
        // The classic duplicate: one card has everything, the other is just a name.
        let full = ContactRecord(
            id: "1",
            givenName: "Ada",
            familyName: "Lovelace",
            phoneNumbers: ["9876543210"]
        )
        let bare = ContactRecord(id: "2", givenName: "Ada", familyName: "Lovelace")

        #expect(ContactGrouping.isDuplicate(full, bare))
    }

    @Test("Two people with the same name but different phones are not duplicates")
    func conflictingPhonesBlockNameMatch() {
        // The mistake that costs real data: two distinct colleagues who happen to share a name.
        let first = ContactRecord(
            id: "1",
            givenName: "John",
            familyName: "Smith",
            phoneNumbers: ["9000000001"]
        )
        let second = ContactRecord(
            id: "2",
            givenName: "John",
            familyName: "Smith",
            phoneNumbers: ["9000000002"]
        )

        #expect(ContactGrouping.isDuplicate(first, second) == false)
    }

    @Test("Same name but different emails is also not a duplicate")
    func conflictingEmailsBlockNameMatch() {
        let first = ContactRecord(
            id: "1",
            givenName: "John",
            familyName: "Smith",
            emailAddresses: ["john@one.example"]
        )
        let second = ContactRecord(
            id: "2",
            givenName: "John",
            familyName: "Smith",
            emailAddresses: ["john@two.example"]
        )

        #expect(ContactGrouping.isDuplicate(first, second) == false)
    }

    @Test("A shared phone still wins over a conflicting email")
    func sharedPhoneBeatsEmailConflict() {
        // One card has an old address and the other a new one, but it's the same phone: the same
        // person who changed email, not two people.
        let old = ContactRecord(
            id: "1",
            givenName: "Ada",
            familyName: "Lovelace",
            phoneNumbers: ["9876543210"],
            emailAddresses: ["ada@old.example"]
        )
        let new = ContactRecord(
            id: "2",
            givenName: "Ada",
            familyName: "Lovelace",
            phoneNumbers: ["9876543210"],
            emailAddresses: ["ada@new.example"]
        )

        #expect(ContactGrouping.isDuplicate(old, new))
    }

    @Test("Unrelated contacts don't match")
    func unrelatedContactsDoNotMatch() {
        let a = ContactRecord(
            id: "1",
            givenName: "Ada",
            familyName: "Lovelace",
            phoneNumbers: ["9000000001"]
        )
        let b = ContactRecord(
            id: "2",
            givenName: "Grace",
            familyName: "Hopper",
            phoneNumbers: ["9000000002"]
        )

        #expect(ContactGrouping.isDuplicate(a, b) == false)
    }

    @Test("An empty card never matches anything")
    func emptyCardsNeverMatch() {
        let empty = ContactRecord(id: "1")
        let real = ContactRecord(id: "2", givenName: "Ada", familyName: "Lovelace")

        #expect(ContactGrouping.isDuplicate(empty, real) == false)
        #expect(ContactGrouping.isDuplicate(empty, ContactRecord(id: "3")) == false)
    }

    // MARK: - Bucketing

    @Test("Only contacts sharing a key are ever compared")
    func bucketingSkipsHopelessPairs() {
        let records = [
            ContactRecord(id: "1", givenName: "Ada", familyName: "Lovelace", phoneNumbers: ["9000000001"]),
            ContactRecord(id: "2", givenName: "Ada", familyName: "Lovelace", phoneNumbers: ["9000000002"]),
            ContactRecord(id: "3", givenName: "Grace", familyName: "Hopper", phoneNumbers: ["9000000003"]),
        ]

        let buckets = ContactGrouping.candidateBuckets(for: records)

        // The two Adas share a name key and so get compared; Grace shares nothing with anyone and
        // is never placed in a bucket at all.
        #expect(buckets.count == 1)
        #expect(Set(buckets[0].map(\.id)) == ["1", "2"])
    }

    // MARK: - Groups

    @Test("Chained matches land in one group")
    func transitiveMatchesFormOneGroup() {
        // A shares a phone with B; B shares an email with C. All three are one person, and
        // comparing pairs alone would leave A and C apart — this is what union-find is for.
        let a = ContactRecord(id: "a", givenName: "Ada", familyName: "Lovelace", phoneNumbers: ["9876543210"])
        let b = ContactRecord(
            id: "b",
            givenName: "Ada",
            familyName: "Lovelace",
            phoneNumbers: ["9876543210"],
            emailAddresses: ["ada@example.com"]
        )
        let c = ContactRecord(id: "c", organization: "Analytical Engines", emailAddresses: ["ada@example.com"])

        let groups = ContactGrouping.groups(in: [a, b, c])

        #expect(groups.count == 1)
        #expect(Set(groups[0].contacts.map(\.id)) == ["a", "b", "c"])
    }

    @Test("An address book with no duplicates produces no groups")
    func cleanAddressBookProducesNothing() {
        let records = (0..<20).map {
            ContactRecord(
                id: "\($0)",
                givenName: "Person\($0)",
                familyName: "Surname\($0)",
                phoneNumbers: ["90000000\(String(format: "%02d", $0))"]
            )
        }

        #expect(ContactGrouping.groups(in: records).isEmpty)
    }

    @Test("A group never contains a lone contact")
    func groupsAlwaysHaveTwoOrMore() {
        let records = [
            ContactRecord(id: "a", givenName: "Ada", familyName: "Lovelace", phoneNumbers: ["9876543210"]),
            ContactRecord(id: "b", givenName: "Ada", familyName: "Lovelace", phoneNumbers: ["9876543210"]),
            ContactRecord(id: "c", givenName: "Grace", familyName: "Hopper"),
        ]

        let groups = ContactGrouping.groups(in: records)

        #expect(groups.allSatisfy { $0.contacts.count > 1 })
        #expect(groups.flatMap { $0.contacts.map(\.id) }.contains("c") == false)
    }

    // MARK: - Primary selection

    @Test("The most complete card is the one kept")
    func primaryIsTheRichestCard() {
        let bare = ContactRecord(id: "bare", givenName: "Ada")
        let rich = ContactRecord(
            id: "rich",
            givenName: "Ada",
            familyName: "Lovelace",
            organization: "Analytical Engines",
            phoneNumbers: ["9876543210"],
            emailAddresses: ["ada@example.com"]
        )

        #expect(ContactGrouping.primaryContactID(in: [bare, rich]) == "rich")
        // Order of the input must not change the answer.
        #expect(ContactGrouping.primaryContactID(in: [rich, bare]) == "rich")
    }

    @Test("A photo breaks a tie between equally complete cards")
    func photoBreaksTie() {
        let plain = ContactRecord(id: "plain", givenName: "Ada", familyName: "Lovelace")
        let withPhoto = ContactRecord(
            id: "photo",
            givenName: "Ada",
            familyName: "Lovelace",
            hasImage: true
        )

        #expect(ContactGrouping.primaryContactID(in: [plain, withPhoto]) == "photo")
    }

    @Test("The keeper is stable across rescans")
    func primaryIsStable() {
        // A keeper that moved between scans would keep silently clearing the user's selections,
        // so identical input must always give the same answer regardless of ordering.
        let records = [
            ContactRecord(id: "a", givenName: "Ada", familyName: "Lovelace"),
            ContactRecord(id: "b", givenName: "Ada", familyName: "Lovelace"),
            ContactRecord(id: "c", givenName: "Ada", familyName: "Lovelace"),
        ]

        let first = ContactGrouping.primaryContactID(in: records)
        let reversed = ContactGrouping.primaryContactID(in: records.reversed())
        let shuffled = ContactGrouping.primaryContactID(in: [records[1], records[2], records[0]])

        #expect(first == reversed)
        #expect(first == shuffled)
    }

    // MARK: - Merge preview

    @Test("A merge keeps every distinct phone and email")
    func mergeUnionsAllDetails() {
        let primary = ContactRecord(
            id: "p",
            givenName: "Ada",
            phoneNumbers: ["9876543210"],
            emailAddresses: ["ada@example.com"]
        )
        let duplicate = ContactRecord(
            id: "d",
            familyName: "Lovelace",
            organization: "Analytical Engines",
            phoneNumbers: ["9000000001"],
            emailAddresses: ["ada@work.example"]
        )
        let group = DuplicateContactGroup(
            id: "p",
            contacts: [primary, duplicate],
            primaryContactID: "p"
        )

        let merged = ContactGrouping.mergedFields(for: group)

        // Nothing may be dropped: this is the guarantee that makes merge safer than delete.
        #expect(merged.givenName == "Ada")
        #expect(merged.familyName == "Lovelace")
        #expect(merged.organization == "Analytical Engines")
        #expect(merged.phoneNumbers.count == 2)
        #expect(merged.emailAddresses == ["ada@example.com", "ada@work.example"])
    }

    @Test("A merge doesn't duplicate the same number written two ways")
    func mergeDedupesEquivalentNumbers() {
        let primary = ContactRecord(id: "p", givenName: "Ada", phoneNumbers: ["+91 98765 43210"])
        let duplicate = ContactRecord(id: "d", givenName: "Ada", phoneNumbers: ["098765 43210"])
        let group = DuplicateContactGroup(
            id: "p",
            contacts: [primary, duplicate],
            primaryContactID: "p"
        )

        let merged = ContactGrouping.mergedFields(for: group)

        // One number, kept in the spelling the user actually typed on the card being kept.
        #expect(merged.phoneNumbers == ["+91 98765 43210"])
    }

    @Test("The primary card's own values win")
    func primaryValuesTakePrecedence() {
        let primary = ContactRecord(id: "p", givenName: "Ada", familyName: "Lovelace")
        let duplicate = ContactRecord(id: "d", givenName: "Augusta", familyName: "Byron")
        let group = DuplicateContactGroup(
            id: "p",
            contacts: [primary, duplicate],
            primaryContactID: "p"
        )

        let merged = ContactGrouping.mergedFields(for: group)

        #expect(merged.givenName == "Ada")
        #expect(merged.familyName == "Lovelace")
    }
}
