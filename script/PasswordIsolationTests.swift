import Foundation
import Security

final class ObservedStore: PasswordStore {
    var result: PasswordLookup = .missing
    var reads = 0
    var writes = 0
    var removals = 0
    var synchronizable = false
    func lookup(for accountID: UUID) -> PasswordLookup { reads += 1; return result }
    func setPassword(_ password: String, for accountID: UUID) throws { writes += 1; result = .found(password) }
    func removePassword(for accountID: UUID) { removals += 1; result = .missing }
}
@main
struct PasswordIsolationTests {
    static func main() throws {
        let id = UUID(), primary = ObservedStore(), original = ObservedStore()
        original.result = .found("synthetic-original")
        let store = ReadThroughPasswordStore(primary: primary, original: original)
        precondition(store.lookup(for: id) == .found("synthetic-original"))
        precondition(original.reads == 1 && original.writes == 0)
        try store.setPassword("synthetic-updated", for: id)
        precondition(store.lookup(for: id) == .found("synthetic-updated"))
        precondition(original.reads == 1 && original.writes == 0)
        primary.result = .denied(errSecAuthFailed)
        precondition(store.lookup(for: id) == .denied(errSecAuthFailed))
        precondition(original.reads == 1)
        store.synchronizable = true
        precondition(!original.synchronizable && primary.synchronizable)
        store.removePassword(for: id)
        precondition(primary.removals == 1 && original.removals == 0)
        precondition(original.result == .found("synthetic-original"))
        print("Password isolation passed: existing credential read-through, local edits, denial propagation, no original writes/deletes or sync changes")
    }
}
