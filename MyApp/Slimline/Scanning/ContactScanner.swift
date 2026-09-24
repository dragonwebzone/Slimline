import Contacts

/// Reads the address book and hands it to `ContactGrouping`.
///
/// An actor so the enumeration — which is synchronous and can take a moment on a large address
/// book — never runs on the main actor.
actor ContactScanner {
    enum ScanError: Error {
        case unreadable
    }

    func scan() async throws -> [DuplicateContactGroup] {
        let records = try fetchAll()
        try Task.checkCancellation()
        return ContactGrouping.groups(in: records)
    }

    private func fetchAll() throws -> [ContactRecord] {
        let store = CNContactStore()
        let request = CNContactFetchRequest(keysToFetch: ContactRecord.fetchKeys)
        // Unified contacts only: iOS already links the same person across iCloud, Gmail and the
        // local store, and offering those system-linked cards as our own duplicates would be both
        // wrong and impossible to act on.
        request.unifyResults = true

        var records: [ContactRecord] = []
        var cancelled = false

        do {
            try store.enumerateContacts(with: request) { contact, stop in
                if Task.isCancelled {
                    cancelled = true
                    stop.pointee = true
                    return
                }
                let record = ContactRecord(contact)
                if !record.isEmpty {
                    records.append(record)
                }
            }
        } catch {
            throw ScanError.unreadable
        }

        if cancelled { throw CancellationError() }

        return records
    }
}
