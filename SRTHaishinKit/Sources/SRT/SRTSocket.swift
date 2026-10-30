import Foundation
import HaishinKit
import libsrt
import Logboard

final actor SRTSocket {
    static let payloadSize: Int = 1316

    enum Error: Swift.Error {
        case notConnected
        case rejected(_ reason: SRTRejectReason)
        case illegalState(_ message: String)
    }

    enum Status: Int, CustomDebugStringConvertible {
        case unknown
        case `init`
        case opened
        case listening
        case connecting
        case connected
        case broken
        case closing
        case closed
        case nonexist

        var debugDescription: String {
            switch self {
            case .unknown:
                return "unknown"
            case .`init`:
                return "init"
            case .opened:
                return "opened"
            case .listening:
                return "listening"
            case .connecting:
                return "connecting"
            case .connected:
                return "connected"
            case .broken:
                return "broken"
            case .closing:
                return "closing"
            case .closed:
                return "closed"
            case .nonexist:
                return "nonexist"
            }
        }

        init?(_ status: SRT_SOCKSTATUS) {
            self.init(rawValue: Int(status.rawValue))
            defer {
                logger.trace(debugDescription)
            }
        }
    }

    /// Received payloads. The blocking `srt_recvmsg` runs on its own thread, off this actor, so
    /// `stopRunning()` is never queued behind it: its `srt_close` wakes the read at once.
    var inputs: AsyncStream<Data> {
        let socket = self.socket
        let capacity = windowSizeC
        return AsyncStream<Data> { continuation in
            let thread = Thread {
                Self.receiveLoop(socket, capacity: capacity, into: continuation)
                Task { await self.stopRunning() }
            }
            thread.name = "SRTSocket.recv"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    var performanceData: SRTPerformanceData {
        .init(mon: perf)
    }

    var status: Status {
        .init(srt_getsockstate(socket)) ?? .unknown
    }

    private(set) var isRunning = false
    private var perf: CBytePerfMon = .init()
    private var socket: SRTSOCKET = SRT_INVALID_SOCK
    private var outputs: AsyncStream<Data>.Continuation? {
        didSet {
            oldValue?.finish()
        }
    }
    private var connected: Bool {
        status == .connected
    }
    private var windowSizeC: Int32 = 1024 * 4

    init() {
        socket = srt_create_socket()
    }

    init(socket: SRTSOCKET, options: [SRTSocketOption]) async throws {
        self.socket = socket
        guard configure(options, restriction: .post) else {
            throw makeSocketError()
        }
    }

    func getSocketOption(_ name: SRTSocketOption.Name) throws -> SRTSocketOption {
        return try SRTSocketOption(name: name, socket: socket)
    }

    func setSocketOption(_ option: SRTSocketOption) throws {
        try option.setSockflag(socket)
    }

    func open(_ url: SRTSocketURL) async throws {
        if socket == SRT_INVALID_SOCK {
            throw makeSocketError()
        }
        guard configure(url.options, restriction: .pre) else {
            throw makeSocketError()
        }
        let status: Int32 = try {
            switch url.mode {
            case .caller:
                guard let remote = url.remote else {
                    logger.error("caller: cannot resolve remote host \(url.url.host ?? "")")
                    return SRT_ERROR
                }
                logger.info("caller -> \(remote)")
                return remote.withSockaddr { srt_connect(socket, $0, $1) }
            case .listener:
                guard let local = url.local() else {
                    logger.error("listener: cannot resolve the adapter address")
                    return SRT_ERROR
                }
                logger.info("listener on \(local)")
                guard prepareBind(local, options: url.options),
                      local.withSockaddr({ srt_bind(socket, $0, $1) }) != SRT_ERROR else {
                    throw makeSocketError()
                }
                return srt_listen(socket, 1)
            case .rendezvous:
                guard let remote = url.remote else {
                    logger.error("rendezvous: cannot resolve remote host \(url.url.host ?? "")")
                    return SRT_ERROR
                }
                guard let local = url.local(family: remote.family) else {
                    logger.error("rendezvous: adapter does not resolve to the remote's family (\(remote))")
                    return SRT_ERROR
                }
                logger.info("rendezvous \(local) -> \(remote)")
                guard prepareBind(local, options: url.options) else {
                    throw makeSocketError()
                }
                return local.withSockaddr { localaddr, locallen in
                    remote.withSockaddr { srt_rendezvous(socket, localaddr, locallen, $0, $1) }
                }
            }
        }()
        guard status != SRT_ERROR else {
            let reason = SRTRejectReason(socket: socket) ?? .unknown
            // A failed dial must not leak its (possibly already-bound) socket — see stopRunning.
            // Read the reject reason BEFORE closing; srt_close invalidates it.
            srt_close(socket)
            socket = SRT_INVALID_SOCK
            throw Error.rejected(reason)
        }
        switch url.mode {
        case .listener:
            break
        default:
            guard configure(url.options, restriction: .post) else {
                throw makeSocketError()
            }
        }
        await startRunning()
    }

    func accept(_ options: [SRTSocketOption]) async throws -> SRTSocket {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SRTSocket, Swift.Error>) in
            Task.detached { [self] in
                do {
                    let accept = srt_accept(await socket, nil, nil)
                    guard -1 < accept else {
                        throw await makeSocketError()
                    }
                    let socket = try await SRTSocket(socket: accept, options: options)
                    await socket.startRunning()
                    continuation.resume(returning: socket)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func send(_ data: Data) throws {
        guard connected else {
            throw Error.notConnected
        }
        for data in data.chunk(Self.payloadSize) {
            outputs?.yield(data)
        }
    }

    private func configure(_ options: [SRTSocketOption], restriction: SRTSocketOption.Restriction) -> Bool {
        var failures: [String] = []
        for option in options where option.name.restriction == restriction {
            do {
                try option.setSockflag(socket)
            } catch {
                failures.append(option.name.rawValue)
            }
        }
        guard failures.isEmpty else {
            logger.error(failures)
            return false
        }
        return true
    }

    /// libsrt refuses to bind `::` until SRTO_IPV6ONLY is set: use the URL's `ipv6only`, else 1.
    /// A listener with `adapter=::&ipv6only=0` accepts both families.
    private func prepareBind(_ local: SRTSocketAddress, options: [SRTSocketOption]) -> Bool {
        guard local.family == AF_INET6, local.isWildcard else {
            return true
        }
        do {
            let option = try options.first { $0.name.rawValue == SRTSocketOption.Name.ipv6only.rawValue }
                ?? SRTSocketOption(name: .ipv6only, value: 1)
            try option.setSockflag(socket)
            return true
        } catch {
            logger.error(error)
            return false
        }
    }

    private func bstats() -> Int32 {
        guard socket != SRT_INVALID_SOCK else {
            return SRT_ERROR
        }
        return srt_bstats(socket, &perf, 1)
    }

    private func makeSocketError() -> Error {
        let error_message = String(cString: srt_getlasterror_str())
        defer {
            logger.error(error_message)
        }
        if socket != SRT_INVALID_SOCK {
            srt_close(socket)
            socket = SRT_INVALID_SOCK
        }
        return .illegalState(error_message)
    }

    @inline(__always)
    private static func sendmsg(_ socket: SRTSOCKET, _ data: Data) -> Int32 {
        return data.withUnsafeBytes { pointer in
            guard let buffer = pointer.baseAddress?.assumingMemoryBound(to: CChar.self) else {
                return SRT_ERROR
            }
            return srt_sendmsg(socket, buffer, Int32(data.count), -1, 0)
        }
    }

    /// Reads until `srt_recvmsg` fails: a broken link, or `srt_close` from another thread.
    private static func receiveLoop(
        _ socket: SRTSOCKET,
        capacity: Int32,
        into continuation: AsyncStream<Data>.Continuation
    ) {
        var buffer = [CChar](repeating: 0, count: Int(capacity))
        while true {
            let result = buffer.withUnsafeMutableBufferPointer { srt_recvmsg(socket, $0.baseAddress, capacity) }
            guard 0 <= result else {
                // A finite `rcvtimeo` expiring is an idle link, not a broken one.
                if srt_getlasterror(nil) == Int32(SRT_ETIMEOUT.rawValue) {
                    continue
                }
                break
            }
            continuation.yield(buffer.withUnsafeBytes { Data($0.prefix(Int(result))) })
        }
        continuation.finish()
    }
}

extension SRTSocket: AsyncRunner {
    // MARK: AsyncRunner
    func startRunning() async {
        guard !isRunning else {
            return
        }
        let stream = AsyncStream<Data> { continuation in
            self.outputs = continuation
        }
        // Off the actor, like the receive loop: a blocked `srt_sendmsg` must not hold back `srt_close`.
        let socket = self.socket
        Task.detached(priority: Task.currentPriority) {
            for await data in stream {
                if Self.sendmsg(socket, data) == SRT_ERROR {
                    await self.stopRunning()
                    break
                }
            }
        }
        isRunning = true
    }

    func stopRunning() async {
        // Close unconditionally (guard only against double-close): `isRunning` is set only AFTER a
        // successful connect, so guarding on it left every mid-dial or failed-dial socket — which
        // srt_bind may have ALREADY BOUND to a local port (rendezvous binds 0.0.0.0/:: :<port> before
        // connecting) — open forever. The leaked bound socket then makes every re-dial of the same
        // port fail instantly (EADDRINUSE / poisoned muxer): the "route switch needs an app kill"
        // 2 s insta-fail loop. Sibling of the SRTConnection.close() `uri != nil` guard removal.
        guard socket != SRT_INVALID_SOCK else {
            return
        }
        srt_close(socket)
        socket = SRT_INVALID_SOCK
        outputs = nil
        isRunning = false
    }
}

extension SRTSocket: NetworkTransportReporter {
    // MARK: NetworkTransportReporter
    func makeNetworkTransportReport() -> NetworkTransportReport {
        _ = bstats()
        let performanceData = self.performanceData
        return .init(
            queueBytesOut: Int(performanceData.byteSndBuf),
            totalBytesIn: Int(performanceData.byteRecvTotal),
            totalBytesOut: Int(performanceData.byteSentTotal),
            roundTripTimeMs: performanceData.msRTT,
            packetsSent: Int(performanceData.pktSent),
            packetsRetransmitted: Int(performanceData.pktRetrans),
            packetsSendDropped: Int(performanceData.pktSndDrop)
        )
    }

    func makeNetworkMonitor() -> NetworkMonitor {
        return .init(self)
    }
}
