import ContainerizationError
import Foundation
import Testing

@testable import podmd

/// A failing `RUN` step reported only
/// `Error: The operation couldn't be completed. (GRPCCore.RPCError error 1.)` —
/// no failing step, no exit code. BuildKit's real message lives in the error's
/// own description.
@Suite("BuildRoute — failure messages")
struct BuildFailureMessageTests {

    /// Stands in for GRPCCore's RPCError: an error with a rich description but
    /// no useful `localizedDescription`.
    private struct RPCLikeError: Error, CustomStringConvertible {
        var description: String {
            "unknown: \"failed to solve: process \\\"/bin/sh -c exit 42\\\" did not complete successfully: exit code: 42\""
        }
    }

    /// Stands in for any error whose only description is Foundation's generic
    /// bridge text.
    private struct OpaqueError: Error {}

    @Test("a BuildKit-style error keeps its failing step and exit code")
    func keepsRichDescription() {
        let message = BuildRoute.buildFailureMessage(for: RPCLikeError())
        #expect(message.contains("exit code: 42"))
        #expect(message.contains("/bin/sh -c exit 42"))
        #expect(!message.contains("The operation couldn’t be completed"))
    }

    @Test("a ContainerizationError keeps its structured description")
    func keepsContainerizationDescription() {
        let error = ContainerizationError(.invalidArgument, message: "builder rejected the Dockerfile")
        let message = BuildRoute.buildFailureMessage(for: error)
        #expect(message.contains("builder rejected the Dockerfile"))
    }

    @Test("an otherwise featureless error still yields a non-empty message")
    func opaqueErrorStillDescribes() {
        #expect(!BuildRoute.buildFailureMessage(for: OpaqueError()).isEmpty)
    }
}
