import Testing

@testable import podmd

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

extension ContainerCreateHealthcheckFallbackTests {
    @Test("a partial request merges field-by-field over the image — Interval-only keeps the image's Test")
    func partialRequestMergesOverImage() {
        let requested = HealthcheckConfig(
            Test: nil, Interval: 5_000_000_000, Timeout: nil, Retries: nil, StartPeriod: nil)
        let resolved = ContainerCreateRoute.resolveHealthcheck(requested: requested, image: imageHealthcheck)
        #expect(resolved?.Test == imageHealthcheck.Test, "image's Test survives an Interval-only request")
        #expect(resolved?.Interval == 5_000_000_000)
        #expect(resolved?.Retries == imageHealthcheck.Retries)
        #expect(resolved?.Timeout == imageHealthcheck.Timeout)
    }

    @Test("a Test-only request keeps the image's timing and retry settings")
    func testOnlyRequestKeepsImageTimings() {
        let requested = HealthcheckConfig(
            Test: ["CMD", "/bin/custom"], Interval: nil, Timeout: nil, Retries: nil, StartPeriod: nil)
        let resolved = ContainerCreateRoute.resolveHealthcheck(requested: requested, image: imageHealthcheck)
        #expect(resolved?.Test == ["CMD", "/bin/custom"])
        #expect(resolved?.Interval == imageHealthcheck.Interval)
        #expect(resolved?.Timeout == imageHealthcheck.Timeout)
        #expect(resolved?.Retries == imageHealthcheck.Retries)
    }

    @Test("explicit zeros count as unset — Docker defaults apply instead of 1s floors or 0 retries")
    func explicitZerosNormalizeToUnset() {
        let zeroed = HealthcheckConfig(
            Test: ["CMD", "true"], Interval: 0, Timeout: 0, Retries: 0, StartPeriod: 0)
        let resolved = ContainerCreateRoute.resolveHealthcheck(requested: zeroed, image: nil)
        #expect(resolved?.Test == ["CMD", "true"])
        #expect(resolved?.Interval == nil, "0 interval must not become the 1s loop floor")
        #expect(resolved?.Timeout == nil)
        #expect(resolved?.Retries == nil, "0 retries must not mean immediately-unhealthy")
        #expect(resolved?.StartPeriod == nil)

        // An image-encoded zero also normalizes, and a request 0 suppresses
        // the image's value so the default applies.
        let imageZero = HealthcheckConfig(
            Test: ["CMD", "true"], Interval: 2_000_000_000, Timeout: 0, Retries: 5, StartPeriod: nil)
        let suppressed = ContainerCreateRoute.resolveHealthcheck(
            requested: HealthcheckConfig(
                Test: nil, Interval: 0, Timeout: nil, Retries: nil, StartPeriod: nil),
            image: imageZero)
        #expect(suppressed?.Interval == nil, "request 0 overrides the image's interval back to default")
        #expect(suppressed?.Retries == 5)
    }

    @Test("a merged healthcheck with no runnable Test persists nothing")
    func mergedWithoutTestPersistsNothing() {
        let resolved = ContainerCreateRoute.resolveHealthcheck(
            requested: HealthcheckConfig(
                Test: nil, Interval: 5_000_000_000, Timeout: nil, Retries: nil, StartPeriod: nil),
            image: nil)
        #expect(resolved == nil)

        let emptyTest = ContainerCreateRoute.resolveHealthcheck(
            requested: HealthcheckConfig(
                Test: [], Interval: nil, Timeout: nil, Retries: nil, StartPeriod: nil),
            image: nil)
        #expect(emptyTest == nil)
    }
}
