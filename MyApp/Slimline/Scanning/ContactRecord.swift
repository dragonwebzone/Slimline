import Contacts

/// A small, `Sendable` snapshot of one contact.
///
/// Mirrors `AssetRecord`: the pipeline works on these and re-fetches the real `CNContact` by
/// identifier only at the moment of merge or delete, so a stale record can never cause the wrong
/// contact to be changed. `nonisolated` because this target sets
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, which would otherwise make even a `Sendable`
/// struct's members unreadable from the scanner actor.
nonisolated struct ContactRecord: Sendable, Identifiable, Hashable {
    /// The contact's `CNContact.identifier`.
    let id: String
    let givenName: String
    let familyName: String
    let organization: String
    /// Phone numbers as the user entered them, paired with a comparable form.
    let phoneNumbers: [String]
    let emailAddresses: [String]
    let hasImage: Bool

    var displayName: String {
        let full = [givenName, familyName]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !full.isEmpty { return full }
        if !organization.isEmpty { return organization }
        if let phone = phoneNumbers.first { return phone }
        if let email = emailAddresses.first { return email }
        return "No name"
    }

    /// A one-line summary of what this card actually holds, so the user can tell two near-identical
    /// entries apart before choosing which to keep.
    var detail: String {
        var parts: [String] = []
        if !organization.isEmpty { parts.append(organization) }
        parts.append(contentsOf: phoneNumbers)
        parts.append(contentsOf: emailAddresses)
        return parts.isEmpty ? "No phone or email" : parts.joined(separator: " · ")
    }

    /// How much information this card carries. Used to pick the one worth keeping.
    var fieldCount: Int {
        phoneNumbers.count
            + emailAddresses.count
            + (organization.isEmpty ? 0 : 1)
            + (givenName.isEmpty ? 0 : 1)
            + (familyName.isEmpty ? 0 : 1)
            + (hasImage ? 1 : 0)
    }

    /// Nothing to show and nothing to match on. Not worth offering as a duplicate.
    var isEmpty: Bool {
        givenName.isEmpty
            && familyName.isEmpty
            && organization.isEmpty
            && phoneNumbers.isEmpty
            && emailAddresses.isEmpty
    }

    /// Memberwise init, used by tests to build records without a contact store.
    init(
        id: String,
        givenName: String = "",
        familyName: String = "",
        organization: String = "",
        phoneNumbers: [String] = [],
        emailAddresses: [String] = [],
        hasImage: Bool = false
    ) {
        self.id = id
        self.givenName = givenName
        self.familyName = familyName
        self.organization = organization
        self.phoneNumbers = phoneNumbers
        self.emailAddresses = emailAddresses
        self.hasImage = hasImage
    }

    init(_ contact: CNContact) {
        id = contact.identifier
        givenName = contact.givenName
        familyName = contact.familyName
        organization = contact.organizationName
        phoneNumbers = contact.phoneNumbers.map(\.value.stringValue)
        emailAddresses = contact.emailAddresses.map { $0.value as String }
        hasImage = contact.imageDataAvailable
    }

    /// The keys `init(_:)` needs. Kept next to the initialiser so the two can't drift apart — a
    /// missing key here is a crash when the property is read, not a compile error.
    static var fetchKeys: [CNKeyDescriptor] {
        [
            CNContactIdentifierKey,
            CNContactGivenNameKey,
            CNContactFamilyNameKey,
            CNContactOrganizationNameKey,
            CNContactPhoneNumbersKey,
            CNContactEmailAddressesKey,
            CNContactImageDataAvailableKey,
        ].map { $0 as CNKeyDescriptor }
    }
}
