import Foundation

/// A point-in-time reading of device storage.
///
/// `nonisolated` so the actor below can build and inspect one; see `AssetRecord` for why this
/// target needs the annotation on its value types.
nonisolated struct StorageSnapshot: Sendable, Equatable {
    let totalCapacity: Int64
    let availableCapacity: Int64

    var usedCapacity: Int64 { max(0, totalCapacity - availableCapacity) }

    var usedFraction: Double {
        guard totalCapacity > 0 else { return 0 }
        return min(1, max(0, Double(usedCapacity) / Double(totalCapacity)))
    }

    static let unknown = StorageSnapshot(totalCapacity: 0, availableCapacity: 0)
}

/// Reads real device capacity from the filesystem.
///
/// This is the only storage figure iOS actually gives us. There is no public API for per-app
/// usage or for other apps' caches and junk files, so the dashboard shows this device-wide
/// number alongside per-category totals that come from our own scans — and invents nothing in
/// between.
///
/// An `actor` so the blocking filesystem read never lands on the main thread. This target
/// compiles with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so a plain type would be
/// main-actor-isolated by default.
actor StorageReporter {
    func snapshot() throws -> StorageSnapshot {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ])

        // `forImportantUsage` is the right key here: it reflects space iOS would actually make
        // available for user-initiated work, rather than the raw free-block count.
        let total = Int64(values.volumeTotalCapacity ?? 0)
        let available = values.volumeAvailableCapacityForImportantUsage ?? 0

        return StorageSnapshot(totalCapacity: total, availableCapacity: available)
    }
}
