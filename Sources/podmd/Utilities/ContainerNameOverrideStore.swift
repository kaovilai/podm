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

    func remove(hexId: String) {
        guard overrides.removeValue(forKey: hexId) != nil else { return }
        persist()
    }

    /// In-memory pending-create reservations. NOT persisted: a create that
    /// dies with the daemon never completed, so its name is legitimately free
    /// again after a restart. Only live for the suspension window between a
    /// create's name check and Apple accepting (or rejecting) the container.
    private var pendingCreates: Set<String> = []

    /// True when `name` is held as some container's effective (renamed) name
    /// or by an in-flight create — consulted by container CREATE so a new
    /// native container cannot steal a renamed container's name, and by the
    /// pending reservation so a concurrent RENAME cannot steal a create's
    /// name during image preparation (the Apple store only rejects native-id
    /// duplicates and knows nothing about overrides).
    func isTaken(name: String) -> Bool {
        overrides.values.contains(name) || pendingCreates.contains(name)
    }

    /// Reserves `name` for an in-flight create. Returns false when the name
    /// is already taken (override or another pending create).
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
    func claim(hexId: String, name: String, expectedOverride: String?, reserved: Set<String>) -> Bool {
        if reserved.contains(name) { return false }
        if overrides.values.contains(name) { return false }
        if pendingCreates.contains(name) { return false }
        if overrides[hexId] != expectedOverride { return false }
        overrides[hexId] = name
        persist()
        return true
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
