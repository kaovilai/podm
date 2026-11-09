// SPDX-License-Identifier: Apache-2.0
import Testing

@testable import podmd

@Test("upstream spec: bare IPv4 defaults to port 53")
func upstreamBareIP() {
    let parsed = PodmDNSServer.parseUpstream("9.9.9.9")
    #expect(parsed?.ip == "9.9.9.9")
    #expect(parsed?.port == 53)
}

@Test("upstream spec: ip:port honored")
func upstreamIPPort() {
    let parsed = PodmDNSServer.parseUpstream("192.168.1.1:5353")
    #expect(parsed?.ip == "192.168.1.1")
    #expect(parsed?.port == 5353)
}

@Test("upstream spec: invalid IPv4 rejected")
func upstreamInvalidIP() {
    #expect(PodmDNSServer.parseUpstream("not-an-ip") == nil)
    #expect(PodmDNSServer.parseUpstream("::1") == nil)  // IPv6 not supported
    #expect(PodmDNSServer.parseUpstream("dns.example.com") == nil)  // hostnames not supported
    #expect(PodmDNSServer.parseUpstream("") == nil)
}

@Test("upstream spec: port bounds and garbage rejected")
func upstreamInvalidPort() {
    #expect(PodmDNSServer.parseUpstream("1.1.1.1:0") == nil)
    #expect(PodmDNSServer.parseUpstream("1.1.1.1:65536") == nil)
    #expect(PodmDNSServer.parseUpstream("1.1.1.1:53.5") == nil)
    #expect(PodmDNSServer.parseUpstream("1.1.1.1:abc") == nil)
    #expect(PodmDNSServer.parseUpstream("1.1.1.1:-1") == nil)
    #expect(PodmDNSServer.parseUpstream("1.1.1.1:53:54") == nil)
}
