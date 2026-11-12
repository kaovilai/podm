//===----------------------------------------------------------------------===//
// Copyright © 2026 the podm authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import ContainerizationError
import Foundation
import Testing

@testable import podmd

@Suite("ReconnectingContainerClient")
struct ReconnectingContainerClientTests {

    /// Stands in for a `ContainerClient` connection. Each value made by `makeClient`
    /// carries the next `generation`, so tests can tell whether an operation ran
    /// against the original client or a freshly reconnected one.
    struct FakeConnection: Sendable {
        let generation: Int
    }

    @Test("Reconnects once and recovers when the client reports a stale XPC connection")
    func retryRecoversOnceOnStaleConnection() async throws {
        let generations = Counter()
        let client = ReconnectingContainerClient<FakeConnection>(makeClient: {
            FakeConnection(generation: generations.nextSync())
        })

        let attempts = Counter()
        let result = try await client.withClient { connection -> Int in
            let attempt = attempts.nextSync()
            if attempt == 1 {
                // Mirrors apple/container's XPCClient.parseReply mapping
                // XPC_ERROR_CONNECTION_INVALID to ContainerizationError(.interrupted, ...).
                throw ContainerizationError(.interrupted, message: "XPC connection error: Connection invalid")
            }
            return connection.generation
        }

        #expect(result == 2, "the retried call should observe the freshly reconnected client (generation 2)")
        let reconnectCount = await client.reconnectCount
        #expect(reconnectCount == 1)
    }

    @Test("Reconnects when the stale connection is buried inside ContainerClient's own error wrapping")
    func retryRecoversWhenStaleErrorIsWrapped() async throws {
        let generations = Counter()
        let client = ReconnectingContainerClient<FakeConnection>(makeClient: {
            FakeConnection(generation: generations.nextSync())
        })

        let attempts = Counter()
        let result = try await client.withClient { connection -> Int in
            let attempt = attempts.nextSync()
            if attempt == 1 {
                // Mirrors what ContainerClient's own methods actually throw: they catch
                // the raw XPC error and rewrap it as `.internalError` with the original
                // `.interrupted` error as `cause` (see e.g. ContainerClient.get/create/
                // bootstrap/kill/stop/delete/createProcess/dial). A naive check of only
                // the outer `error.code` would miss this and never reconnect.
                throw ContainerizationError(
                    .internalError,
                    message: "failed to get container",
                    cause: ContainerizationError(.interrupted, message: "XPC connection error: Connection invalid")
                )
            }
            return connection.generation
        }

        #expect(result == 2, "the retried call should observe the freshly reconnected client (generation 2)")
        let reconnectCount = await client.reconnectCount
        #expect(reconnectCount == 1)
    }

    @Test("Does not retry or reconnect for a non-stale error")
    func nonStaleErrorNotRetried() async throws {
        let generations = Counter()
        let client = ReconnectingContainerClient<FakeConnection>(makeClient: {
            FakeConnection(generation: generations.nextSync())
        })

        let attempts = Counter()
        await #expect(throws: ContainerizationError.self) {
            try await client.withClient { _ -> Int in
                attempts.nextSync()
                throw ContainerizationError(.notFound, message: "container not found")
            }
        }

        #expect(attempts.countSync() == 1, "a non-stale error must not be retried")
        let reconnectCount = await client.reconnectCount
        #expect(reconnectCount == 0)
    }

    // MARK: review round 2 — retry permit (reconnects after the final deadline)

    @Test("A refused retry permit rethrows the stale error without reconnecting")
    func expiredPermitRefusesRetry() async throws {
        // Regression (PR #51 review): after a delete was abandoned past its
        // recovery deadline, a stale-connection retry could re-issue the
        // delete against a recreated same-name container — native ids are
        // reusable names. The permit must switch the retry off.
        let generations = Counter()
        let client = ReconnectingContainerClient<FakeConnection>(makeClient: {
            FakeConnection(generation: generations.nextSync())
        })

        let attempts = Counter()
        do {
            _ = try await client.withClient(allowRetry: { false }) { _ -> Int in
                attempts.nextSync()
                throw ContainerizationError(.interrupted, message: "XPC connection error: Connection invalid")
            }
            Issue.record("expected the stale-connection error to be rethrown")
        } catch let error as ContainerizationError {
            #expect(error.code == .interrupted, "the original stale-connection error propagates as-is")
        }

        #expect(attempts.countSync() == 1, "the expired operation must not be re-issued")
        let reconnectCount = await client.reconnectCount
        #expect(reconnectCount == 0, "no reconnection for a refused retry")
    }

    @Test("A granted retry permit keeps the reconnect-and-retry behavior")
    func grantedPermitStillRetries() async throws {
        let generations = Counter()
        let client = ReconnectingContainerClient<FakeConnection>(makeClient: {
            FakeConnection(generation: generations.nextSync())
        })

        let attempts = Counter()
        let result = try await client.withClient(allowRetry: { true }) { connection -> Int in
            let attempt = attempts.nextSync()
            if attempt == 1 {
                throw ContainerizationError(.interrupted, message: "XPC connection error: Connection invalid")
            }
            return connection.generation
        }

        #expect(result == 2)
        let reconnectCount = await client.reconnectCount
        #expect(reconnectCount == 1)
    }

    // MARK: review round 6 — permit expiry during reconstruction

    @Test("A permit expiring while makeClient reconstructs the connection still refuses the retry")
    func permitExpiringDuringReconnectRefusesRetry() async throws {
        // RecoveryExpiry.expire() fires on the hang-recovery timer,
        // independently of this actor: it can land AFTER the permit check
        // passed but BEFORE the retry is dispatched — e.g. while makeClient()
        // constructs the fresh XPC connection. The permit must be re-checked
        // after reconstruction, or the retry is issued past the caller's
        // final deadline — against a possible same-name replacement.
        let expiry = ContainerRuntimeJobRecovery.RecoveryExpiry()
        let generations = Counter()
        let client = ReconnectingContainerClient<FakeConnection>(makeClient: {
            let generation = generations.nextSync()
            if generation == 2 {
                // The reconstruction is in flight when the deadline lands.
                expiry.expire()
            }
            return FakeConnection(generation: generation)
        })

        let attempts = Counter()
        do {
            _ = try await client.withClient(allowRetry: expiry.retryPermit) { _ -> Int in
                attempts.nextSync()
                throw ContainerizationError(.interrupted, message: "XPC connection error: Connection invalid")
            }
            Issue.record("expected the stale-connection error to be rethrown")
        } catch let error as ContainerizationError {
            #expect(error.code == .interrupted, "the original stale-connection error propagates as-is")
        }

        #expect(
            attempts.countSync() == 1,
            "the retry must not be dispatched once the permit expired mid-reconstruction")
        let reconnectCount = await client.reconnectCount
        #expect(
            reconnectCount == 1,
            "the reconnection itself still happened — only the retry dispatch is gated")
    }
}

/// A tiny thread-safe counter used to observe call/reconnect counts from
/// synchronous, non-isolated closures (e.g. the `makeClient` factory).
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    @discardableResult
    func nextSync() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    func countSync() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
