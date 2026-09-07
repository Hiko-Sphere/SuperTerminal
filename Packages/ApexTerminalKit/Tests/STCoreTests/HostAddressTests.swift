import Testing
@testable import STCore

/// The hostname field takes what people actually paste (D-024).
@Suite("Host address parsing")
struct HostAddressTests {
    @Test("A bare host, with and without a port")
    func bareHost() {
        #expect(HostAddress.parse("ssh.example.com") == HostAddress(host: "ssh.example.com"))
        #expect(HostAddress.parse("  ssh.example.com  ") == HostAddress(host: "ssh.example.com"))
        #expect(HostAddress.parse("ssh.example.com:443") == HostAddress(host: "ssh.example.com", port: 443))
        #expect(HostAddress.parse("10.0.0.5:2222") == HostAddress(host: "10.0.0.5", port: 2222))
    }

    @Test("A pasted URL keeps the host, the port and the user; never a password, a path or a query")
    func pastedURL() {
        #expect(HostAddress.parse("https://ssh.example.com:443/") == HostAddress(host: "ssh.example.com", port: 443))
        #expect(HostAddress.parse("ssh://deploy@build.example.com:2222/var/www?x=1#top") == HostAddress(host: "build.example.com", port: 2222, user: "deploy"))
        #expect(HostAddress.parse("ssh://deploy:hunter2@build.example.com") == HostAddress(host: "build.example.com", port: nil, user: "deploy"))
        #expect(HostAddress.parse("deploy@build.example.com") == HostAddress(host: "build.example.com", user: "deploy"))
    }

    @Test("IPv6 literals keep their colons")
    func ipv6() {
        #expect(HostAddress.parse("[2001:db8::1]") == HostAddress(host: "2001:db8::1"))
        #expect(HostAddress.parse("[2001:db8::1]:22") == HostAddress(host: "2001:db8::1", port: 22))
        #expect(HostAddress.parse("2001:db8::1") == HostAddress(host: "2001:db8::1"))
        #expect(HostAddress.parse("fe80::1%en0") == HostAddress(host: "fe80::1%en0"), "a zone identifier is part of the address")
        #expect(HostAddress.parse("[2001:db8::1") == nil, "a bracket that never closes")
        #expect(HostAddress.parse("[2001:db8::1]x") == nil)
    }

    @Test("What is not an address")
    func rejected() {
        #expect(HostAddress.parse("") == nil)
        #expect(HostAddress.parse("   ") == nil)
        #expect(HostAddress.parse("host:") == nil)
        #expect(HostAddress.parse(":443") == nil)
        #expect(HostAddress.parse("host:70000") == nil)
        #expect(HostAddress.parse("host:abc") == nil)
        #expect(HostAddress.parse("a:b:c") == nil, "three hex groups are not an address, however hexadecimal they look")
        #expect(HostAddress.parse("2001:db8::1::2") == nil, "two elisions are not an address")
        #expect(HostAddress.parse("https://") == nil)
        #expect(HostAddress.parse("@host") == HostAddress(host: "host"), "an empty user name is no user name")
    }
}
