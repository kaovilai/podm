import Testing

@testable import pacmand

/// Tests for `ContainerCreateRoute.resolveHealthcheck` — Docker's healthcheck
/// precedence on container create, now that the image's Dockerfile
/// `HEALTHCHECK` is readable (`ImageHealthcheckExtractor`) and can act as the
/// fallback when the create request carries no healthcheck of its own.
///
/// The full precedence matrix, per Docker semantics:
/// - request healthcheck present → wins, whatever the image says;
/// - request carries `{"Test":["NONE"]}` → the disable sentinel wins over the
///   image's HEALTHCHECK (it must suppress it, not fall through to it —
///   `HealthCheckManager.parseTest` maps `NONE` to "no runnable probe");
/// - request carries none → the image's Dockerfile HEALTHCHECK applies;
/// - neither side has one → no healthcheck at all.
@Suite("ContainerCreateRoute — healthcheck precedence")
struct ContainerCreateHealthcheckFallbackTests {

    private let imageHealthcheck = HealthcheckConfig(
        Test: ["CMD-SHELL", "curl -f http://localhost/ || exit 1"],
        Interval: 30_000_000_000,
        Timeout: 5_000_000_000,
        Retries: 3,
        StartPeriod: 10_000_000_000
    )

    @Test("no request healthcheck → the image's Dockerfile HEALTHCHECK is used")
    func imageHealthcheckFillsAbsentRequest() {
        let resolved = ContainerCreateRoute.resolveHealthcheck(requested: nil, image: imageHealthcheck)
        #expect(resolved?.Test == imageHealthcheck.Test)
        #expect(resolved?.Interval == 30_000_000_000)
        #expect(resolved?.Retries == 3)
    }

    @Test("a request healthcheck overrides the image's")
    func requestHealthcheckWins() {
        let requested = HealthcheckConfig(
            Test: ["CMD", "/bin/true"],
            Interval: 1_000_000_000,
            Timeout: nil,
            Retries: 1,
            StartPeriod: nil
        )
        let resolved = ContainerCreateRoute.resolveHealthcheck(requested: requested, image: imageHealthcheck)
        #expect(resolved?.Test == ["CMD", "/bin/true"])
        #expect(resolved?.Interval == 1_000_000_000)
        #expect(resolved?.Retries == 1)
    }

    @Test("an explicit NONE in the request suppresses the image's HEALTHCHECK")
    func requestNoneSuppressesImage() {
        let resolved = ContainerCreateRoute.resolveHealthcheck(
            requested: HealthcheckConfig(Test: ["NONE"], Interval: nil, Timeout: nil, Retries: nil, StartPeriod: nil),
            image: imageHealthcheck
        )
        // The sentinel itself is persisted (same as the pre-image-fallback
        // behavior for request-carried healthchecks); the start route's
        // HealthCheckManager.parseTest turns it into "no runnable probe".
        #expect(resolved?.Test == ["NONE"])
        #expect(HealthCheckManager.parseTest(resolved?.Test) == nil)
    }

    @Test("neither request nor image carries a healthcheck → none at all")
    func noHealthcheckAnywhere() {
        #expect(ContainerCreateRoute.resolveHealthcheck(requested: nil, image: nil) == nil)
    }

    @Test("a request healthcheck applies even when the image has none")
    func requestHealthcheckWithNoImageHealthcheck() {
        let requested = HealthcheckConfig(
            Test: ["CMD", "/bin/true"],
            Interval: nil,
            Timeout: nil,
            Retries: nil,
            StartPeriod: nil
        )
        let resolved = ContainerCreateRoute.resolveHealthcheck(requested: requested, image: nil)
        #expect(resolved?.Test == ["CMD", "/bin/true"])
    }

    @Test("an image NONE sentinel is persisted as-is when the request is silent")
    func imageNoneSentinelPassesThrough() {
        // An image built with `HEALTHCHECK NONE` bakes the sentinel into its
        // config; falling back to it must surface the sentinel (→ no probe),
        // not skip the label entirely.
        let resolved = ContainerCreateRoute.resolveHealthcheck(
            requested: nil,
            image: HealthcheckConfig(Test: ["NONE"], Interval: nil, Timeout: nil, Retries: nil, StartPeriod: nil)
        )
        #expect(resolved?.Test == ["NONE"])
        #expect(HealthCheckManager.parseTest(resolved?.Test) == nil)
    }
}
