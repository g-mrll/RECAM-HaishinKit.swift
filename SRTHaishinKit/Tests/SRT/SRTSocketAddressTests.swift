import Foundation
import Testing

import libsrt
@testable import SRTHaishinKit

@Suite struct SRTSocketAddressTests {
    private func literal(_ host: String, _ port: Int = 9000) throws -> SRTSocketAddress {
        try #require(SRTSocketAddress(literal: host, port: port))
    }

    private func url(_ string: String) throws -> SRTSocketURL {
        try #require(SRTSocketURL(URL(string: string)))
    }

    @Test func literals() throws {
        #expect(try literal("127.0.0.1").family == AF_INET)
        #expect(try literal("::1").family == AF_INET6)
        #expect(try literal("127.0.0.1").description == "127.0.0.1:9000")
        #expect(try literal("2001:db8::1").description == "[2001:db8::1]:9000")
        #expect(try literal("0.0.0.0").isWildcard)
        #expect(try literal("::").isWildcard)
        #expect(try !literal("::1").isWildcard)
        #expect(try !literal("127.0.0.1").isWildcard)
        #expect(SRTSocketAddress(literal: "relay.recam.live", port: 9000) == nil)
        #expect(SRTSocketAddress(literal: "127.0.0.1", port: 70000) == nil)
    }

    @Test func preferredTakesFirstIPv4ElseFirst() throws {
        let v6a = try literal("2001:db8::1")
        let v6b = try literal("2001:db8::2")
        let v4 = try literal("192.0.2.1")
        #expect(SRTSocketAddress.preferred([v6a, v4, v6b])?.description == v4.description)
        #expect(SRTSocketAddress.preferred([v6b, v6a])?.description == v6b.description)
        #expect(SRTSocketAddress.preferred([]) == nil)
    }

    @Test func resolve() {
        #expect(SRTSocketAddress.resolve(host: "127.0.0.1", port: 9000).map(\.description) == ["127.0.0.1:9000"])
        #expect(SRTSocketAddress.resolve(host: "::1", port: 9000).map(\.description) == ["[::1]:9000"])
        #expect(SRTSocketAddress.resolve(host: "2001:db8::1", port: 9000).map(\.description) == ["[2001:db8::1]:9000"])
        #expect(SRTSocketAddress.resolve(host: "host.invalid", port: 9000).isEmpty)
        #expect(SRTSocketAddress.resolve(host: "127.0.0.1", port: -1).isEmpty)
    }

    @Test func remoteParsesIPv6Literal() throws {
        let v6 = try url("srt://[2001:db8::1]:9000?mode=rendezvous&passphrase=0123456789")
        #expect(v6.mode == .rendezvous)
        #expect(v6.remote?.description == "[2001:db8::1]:9000")
        #expect(try self.url("srt://127.0.0.1:9000?mode=caller").remote?.description == "127.0.0.1:9000")
        #expect(try self.url("srt://host.invalid:9000?mode=caller").remote == nil)
    }

    @Test func localFollowsRemoteFamily() throws {
        let rendezvous = try url("srt://relay.example:20000?mode=rendezvous")
        #expect(rendezvous.local(family: AF_INET)?.description == "0.0.0.0:20000")
        #expect(rendezvous.local(family: AF_INET6)?.description == "[::]:20000")

        let withPort = try url("srt://relay.example:20000?mode=rendezvous&port=5000")
        #expect(withPort.local(family: AF_INET6)?.description == "[::]:5000")

        let v6Wildcard = try url("srt://relay.example:20000?adapter=::&port=5000")
        #expect(v6Wildcard.local(family: AF_INET)?.description == "0.0.0.0:5000")

        let v4Adapter = try url("srt://relay.example:20000?adapter=127.0.0.1&port=5000")
        #expect(v4Adapter.local(family: AF_INET)?.description == "127.0.0.1:5000")
        #expect(v4Adapter.local(family: AF_INET6) == nil)
    }

    @Test func listenerLocalStaysIPv4ByDefault() throws {
        #expect(try url("srt://0.0.0.0:9000?mode=listener").local()?.description == "0.0.0.0:9000")
        #expect(try url("srt://:9000?mode=listener&adapter=::").local()?.description == "[::]:9000")
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct SRTSocketDualStackLoopbackTests {
    // A finite rcvtimeo keeps a receiver blocked in srt_recvmsg from stalling teardown.
    private static let options = "passphrase=0123456789abcdef&transtype=live&latency=120&rcvtimeo=1000"

    init() {
        srt_startup()
    }

    @Test(arguments: [("127.0.0.1", 47_110), ("[::1]", 47_120)])
    func rendezvous(host: String, basePort: Int) async throws {
        let left = SRTSocket()
        let right = SRTSocket()
        let leftURL = try #require(SRTSocketURL(URL(string: "srt://\(host):\(basePort + 1)?mode=rendezvous&port=\(basePort)&\(Self.options)")))
        let rightURL = try #require(SRTSocketURL(URL(string: "srt://\(host):\(basePort)?mode=rendezvous&port=\(basePort + 1)&\(Self.options)")))
        async let leftOpen: Void = left.open(leftURL)
        async let rightOpen: Void = right.open(rightURL)
        _ = try await (leftOpen, rightOpen)
        #expect(await Self.exchange(from: left, to: right))
        await left.stopRunning()
        await right.stopRunning()
    }

    @Test(arguments: [("127.0.0.1", 47_130), ("[::1]", 47_140)])
    func callerToListener(host: String, port: Int) async throws {
        let adapter = host.hasPrefix("[") ? "::" : "0.0.0.0"
        let listener = SRTSocket()
        let listenerURL = try #require(SRTSocketURL(URL(string: "srt://:\(port)?mode=listener&adapter=\(adapter)&\(Self.options)")))
        try await listener.open(listenerURL)
        let caller = SRTSocket()
        async let accepted = listener.accept(listenerURL.options)
        try await caller.open(#require(SRTSocketURL(URL(string: "srt://\(host):\(port)?mode=caller&\(Self.options)"))))
        let server = try await accepted
        #expect(await Self.exchange(from: caller, to: server))
        await caller.stopRunning()
        await server.stopRunning()
        await listener.stopRunning()
    }

    /// Sends until the receiver yields one payload, or 5 s pass.
    private static func exchange(from sender: SRTSocket, to receiver: SRTSocket) async -> Bool {
        let payload = Data("recam-dual-stack".utf8)
        let sending = Task {
            while !Task.isCancelled {
                try? await sender.send(payload)
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        defer {
            sending.cancel()
        }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await data in await receiver.inputs {
                    return data == payload
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }
}
