import ContainerResource
import Foundation
import Logging

/// Apple Container bakes the container's native id — which doubles as the
/// Docker-visible name — into the VM configuration at create time, so a true
/// rename is impossible. `docker rename` therefore records an override here,
/// consulted wherever a Docker client should see the container's name.
/// Persisted so renames survive daemon restarts, like the native ids they
/// shadow.
///
/// Keyed by the instance-unique Docker hex id (native id + creation date),
/// never the reusable native name: a recreated container gets a fresh key, so
/// a stale entry can never rename the wrong instance — removal on delete is
/// hygiene, not correctness. Mirrors RestartPolicyOverrideStore.
actor ContainerNameOverrideStore {
    static let shared = ContainerNameOverrideStore()

    private var overrides: [String: String] = [:]
    private var fileURL: URL?
    private let log = Logger(label: "podm.container-name-overrides")

    func configure(storageDirectory: URL) {
        let url = storageDirectory.appendingPathComponent("podm-container-name-overrides.json")
        fileURL = url
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            overrides = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        } catch {
            log.error("could not load container-name overrides from \(url.path) — renames recorded by earlier runs are not applied: \(error)")
        }
    }

    func set(hexId: String, name: String) {
        overrides[hexId] = name
        persist()
    }

    func get(hexId: String) -> String? {
        overrides[hexId]
    }

    /// Deleted (pruned, removed, auto-removed) instance keys. A rename that
    /// read the container's override BEFORE the deletion suspended, and its
    /// claim arrives AFTER `remove` — the claim must fail, or it persists a
    /// name for a container that no longer exists and reserves it across
    /// restarts. Hex ids are instance-unique, so a tombstone can never name a
    /// future container; the set is bounded (drop-oldest) purely to cap memory.
    private var tombstones: [String] = []

    func remove(hexId: String) {
        overrides.removeValue(forKey: hexId)
        if !tombstones.contains(hexId) {
            tombstones.append(hexId)
            if tombstones.count > 4_096 { tombstones.removeFirst() }
        }
        persist()
    }

    /// In-memory pending-create reservations. NOT persisted: a create that
    /// dies with the daemon never completed, so its name is legitimately free
    /// again after a restart. Only live for the suspension window between a
    /// create's name check and Apple accepting (or rejecting) the container.
    private var pendingCreates: Set<String> = []

    /// Reserves `name` for an in-flight create — the atomic check-then-act
    /// path container CREATE consults (so a new native container cannot steal
    /// a renamed container's name, and a concurrent rename cannot steal a
    /// create's name during image preparation; the Apple store only rejects
    /// native-id duplicates and knows nothing about overrides). Returns false
    /// when the name is already taken (override or another pending create).
    func reserveForCreate(name: String) -> Bool {
        if overrides.values.contains(name) || pendingCreates.contains(name) {
            return false
        }
        pendingCreates.insert(name)
        return true
    }

    /// Releases a pending-create reservation (on success the container now
    /// exists — its native id is covered by every later rename's reserved
    /// set — and on failure the name must be free again).
    func releaseCreateReservation(name: String) {
        pendingCreates.remove(name)
    }

    /// Atomically claims `name` for `hexId`: fails when any container already
    /// holds `name` as its effective name, when `name` is in `reserved`
    /// (native ids, Docker hex ids — in raw AND sanitized form — and any
    /// other names the caller collected), when an in-flight create holds it,
    /// or when `hexId`'s CURRENT override no longer equals `expectedOverride`
    /// — the RAW override the caller read before building its request (nil
    /// for a first rename). A concurrent rename of the same container that
    /// won the race changed it, so the loser must fail rather than publish a
    /// stale old name in its event or leave an abandoned DNS alias. One
    /// non-suspending actor operation — none of these checks can interleave
    /// with a concurrent claim.
    ///
    /// The failure carries the name's owner WHEN THE ACTOR CAN SEE IT — a
    /// live override holding the name — resolved atomically with the check:
    /// a separate owner snapshot taken before the claim can race a
    /// concurrent winner (two renames snapshotting a free name both see no
    /// owner; the loser must still be able to quote the winner).
    func claim(hexId: String, name: String, expectedOverride: String?, reserved: Set<String>) -> ClaimOutcome {
        if reserved.contains(name) { return .conflict(owner: nil) }
        if let owner = overrides.first(where: { $0.value == name })?.key {
            return .conflict(owner: owner)
        }
        if pendingCreates.contains(name) { return .conflict(owner: nil) }
        if overrides[hexId] != expectedOverride { return .conflict(owner: nil) }
        if tombstones.contains(hexId) { return .conflict(owner: nil) }
        overrides[hexId] = name
        persist()
        return .claimed
    }

    /// The result of a `claim`: `.claimed` on success; `.conflict` on every
    /// failure, with the owning container's hex id when the actor observed
    /// one (see `claim`).
    enum ClaimOutcome: Equatable {
        case claimed
        case conflict(owner: String?)
    }

    /// A copy of every recorded override (hexId → name) for batch lookups —
    /// one actor hop instead of one per container.
    func snapshot() -> [String: String] {
        overrides
    }

    private func persist() {
        guard let fileURL else { return }
        do {
            try JSONEncoder().encode(overrides).write(to: fileURL, options: .atomic)
        } catch {
            log.error("could not persist container-name overrides to \(fileURL.path) — the rename is in effect but will not survive a daemon restart: \(error)")
        }
    }
}

extension ContainerNameOverrideStore {
    /// The Docker-visible name for one container: its recorded rename, else
    /// its native id (the name it was created under).
    static func effectiveName(for container: ContainerSnapshot) async -> String {
        await shared.get(hexId: DockerContainerID.hexId(for: container)) ?? container.id
    }

    /// Effective names for a batch, keyed by native id — a single actor hop
    /// for list/inspect/filter call sites that name every container.
    static func effectiveNames(for containers: [ContainerSnapshot]) async -> [String: String] {
        let recorded = await shared.snapshot()
        var names: [String: String] = [:]
        names.reserveCapacity(containers.count)
        for container in containers {
            names[container.id] = recorded[DockerContainerID.hexId(for: container)] ?? container.id
        }
        return names
    }
}
