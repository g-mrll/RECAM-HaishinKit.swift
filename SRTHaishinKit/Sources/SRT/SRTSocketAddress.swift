import Foundation

/// An IPv4 or IPv6 socket address for the libsrt C API.
struct SRTSocketAddress {
    let family: Int32
    private let storage: sockaddr_storage
    private let length: socklen_t

    /// Resolves a host name or IP literal with getaddrinfo, in its result order.
    ///
    /// The default flags (AI_DEFAULT) let iOS synthesize NAT64 addresses on IPv6-only networks,
    /// for names and IPv4 literals alike.
    static func resolve(host: String, port: Int, flags: Int32 = AI_DEFAULT) -> [SRTSocketAddress] {
        guard UInt16(exactly: port) != nil else {
            return []
        }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_flags = flags | AI_NUMERICSERV
        var head: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &head)
        guard status == 0 else {
            logger.error("getaddrinfo(\(host)): \(String(cString: gai_strerror(status)))")
            return []
        }
        defer {
            freeaddrinfo(head)
        }
        var addresses: [SRTSocketAddress] = []
        var cursor = head
        while let info = cursor {
            if let address = info.pointee.ai_addr.flatMap({ SRTSocketAddress($0, length: info.pointee.ai_addrlen) }) {
                addresses.append(address)
            }
            cursor = info.pointee.ai_next
        }
        return addresses
    }

    /// The first IPv4 address, else the first one: IPv4 networks keep dialing IPv4 as before.
    static func preferred(_ addresses: [SRTSocketAddress]) -> SRTSocketAddress? {
        addresses.first { $0.family == AF_INET } ?? addresses.first
    }

    /// `0.0.0.0` or `::` on `port`.
    static func wildcard(family: Int32, port: Int) -> SRTSocketAddress? {
        SRTSocketAddress(literal: family == AF_INET6 ? "::" : "0.0.0.0", port: port)
    }

    /// Parses a numeric IPv4 or IPv6 literal without resolving it (no NAT64 synthesis).
    init?(literal host: String, port: Int) {
        guard let port = UInt16(exactly: port) else {
            return nil
        }
        var v4 = sockaddr_in()
        if inet_pton(AF_INET, host, &v4.sin_addr) == 1 {
            v4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            v4.sin_family = sa_family_t(AF_INET)
            v4.sin_port = port.bigEndian
            self.init(v4, family: AF_INET)
            return
        }
        var v6 = sockaddr_in6()
        if inet_pton(AF_INET6, host, &v6.sin6_addr) == 1 {
            v6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            v6.sin6_family = sa_family_t(AF_INET6)
            v6.sin6_port = port.bigEndian
            self.init(v6, family: AF_INET6)
            return
        }
        return nil
    }

    init?(_ address: UnsafePointer<sockaddr>, length: socklen_t) {
        let family = Int32(address.pointee.sa_family)
        guard family == AF_INET || family == AF_INET6, Int(length) <= MemoryLayout<sockaddr_storage>.size else {
            return nil
        }
        var storage = sockaddr_storage()
        withUnsafeMutableBytes(of: &storage) {
            $0.copyMemory(from: UnsafeRawBufferPointer(start: address, count: Int(length)))
        }
        self.family = family
        self.storage = storage
        self.length = length
    }

    private init<T>(_ address: T, family: Int32) {
        var storage = sockaddr_storage()
        withUnsafeMutableBytes(of: &storage) { storage in
            withUnsafeBytes(of: address) { storage.copyMemory(from: $0) }
        }
        self.family = family
        self.storage = storage
        self.length = socklen_t(MemoryLayout<T>.size)
    }

    /// True for `0.0.0.0` and `::`.
    var isWildcard: Bool {
        withSockaddr { address, _ in
            switch family {
            case AF_INET:
                return address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr == 0 }
            case AF_INET6:
                return address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    withUnsafeBytes(of: $0.pointee.sin6_addr) { $0.allSatisfy { $0 == 0 } }
                }
            default:
                return false
            }
        }
    }

    func withSockaddr<R>(_ body: (UnsafePointer<sockaddr>, Int32) throws -> R) rethrows -> R {
        try withUnsafePointer(to: storage) {
            try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                try body($0, Int32(length))
            }
        }
    }
}

extension SRTSocketAddress: CustomStringConvertible {
    // MARK: CustomStringConvertible
    var description: String {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        var port = [CChar](repeating: 0, count: Int(NI_MAXSERV))
        let status = withSockaddr { address, length in
            getnameinfo(address, socklen_t(length), &host, socklen_t(host.count), &port, socklen_t(port.count), NI_NUMERICHOST | NI_NUMERICSERV)
        }
        guard status == 0 else {
            return "<unprintable address>"
        }
        let hostString = Self.string(host)
        return family == AF_INET6 ? "[\(hostString)]:\(Self.string(port))" : "\(hostString):\(Self.string(port))"
    }

    private static func string(_ buffer: [CChar]) -> String {
        buffer.withUnsafeBufferPointer { $0.baseAddress.map { String(cString: $0) } ?? "" }
    }
}
