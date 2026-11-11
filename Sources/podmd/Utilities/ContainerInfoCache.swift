import Foundation

actor ContainerInfoCache {
    static let shared = ContainerInfoCache()

    struct Info {
        let hexId: String
        let nativeId: String
        let image: String
        let labels: [String: String]
        /// IP on the container's primary network, stored at /start so DNS cleanup in the
        /// --rm paths can perform the same ownership check as ContainerDeleteRoute.
        let ip: String?
    }

    private var store: [String: Info] = [:]

    /// Maps each id of a `--rm` container (both hex and native) to its sibling id, so a
    /// consume by either id can atomically clear both. Kept separate from `store` so the
    /// routine `set()` at /start can't clobber it, and self-contained so the pairing does not
    /// depend on a `store` entry existing at consume time.
    private var autoRemoveSibling: [String: String] = [:]

    func set(hexId: String, nativeId: String, image: String, labels: [String: String], ip: String? = nil) {
        let info = Info(hexId: hexId, nativeId: nativeId, image: image, labels: labels, ip: ip)
        store[hexId] = info
        store[nativeId] = info
    }

    func get(id: String) -> Info? {
        store[id]
    }

    func remove(id: String) {
        if let info = store[id] {
            store.removeValue(forKey: info.hexId)
            store.removeValue(forKey: info.nativeId)
        }
        // Clear any lingering --rm mark so a stale observer that reaches consumeAutoRemove
        // after this container was already deleted can't fire a second destroy event.
        if let sibling = autoRemoveSibling[id] {
            autoRemoveSibling.removeValue(forKey: id)
            autoRemoveSibling.removeValue(forKey: sibling)
        }
    }

    /// Instance-scoped `remove` for cleanup that may run AFTER the
    /// container was deleted: drops this instance's hex key unconditionally
    /// (a hex id is unique to the instance — it derives from the bundle's
    /// on-disk creation date) but the native-id key only while it still
    /// maps to THIS instance. Native ids are reusable names
    /// (`Utility.createContainerID(name:)` passes the container name
    /// through), so a same-name replacement may already own the native key
    /// — its entries must survive this container's cleanup.
    ///
    /// `hexId` should be the instance's 64-char Docker id (or, in the
    /// no-identity fallback, whatever id the caller had — then this behaves
    /// like `remove(id:)`).
    func removeInstance(hexId: String, nativeId: String?) {
        store.removeValue(forKey: hexId)
        if let nativeId, store[nativeId]?.hexId == hexId {
            store.removeValue(forKey: nativeId)
        }
        // --rm marks die with the instance, same dedup as remove(id:).
        var keys = [hexId]
        if let nativeId { keys.append(nativeId) }
        for key in keys {
            if let sibling = autoRemoveSibling[key] {
                autoRemoveSibling.removeValue(forKey: key)
                autoRemoveSibling.removeValue(forKey: sibling)
            }
        }
    }

    /// Records that a container was created with `--rm`, keyed by both ids so either the
    /// hex (attach route) or native (die observer) lookup finds it.
    func markAutoRemove(hexId: String, nativeId: String) {
        autoRemoveSibling[hexId] = nativeId
        autoRemoveSibling[nativeId] = hexId
    }

    /// Atomically returns `true` exactly once if the container (by either id) was marked
    /// `--rm`, clearing the mark. This is both the auto-remove gate and the destroy dedup:
    /// whichever path (foreground attach or detached die observer) reaches it first emits the
    /// `destroy` event; the other sees `false` and skips — so exactly one destroy fires, matching
    /// moby's single post-`die` destroy for `--rm` containers.
    func consumeAutoRemove(id: String) -> Bool {
        guard let sibling = autoRemoveSibling[id] else { return false }
        autoRemoveSibling.removeValue(forKey: id)
        autoRemoveSibling.removeValue(forKey: sibling)
        return true
    }
}
