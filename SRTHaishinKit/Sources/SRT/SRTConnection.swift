import Combine
import Foundation
import HaishinKit
import libsrt

/// An actor that provides the interface to control a SRT connection.
///
/// Supports a one-to-one connection. Multiple connections cannot be established.
public actor SRTConnection: NetworkConnection {
    /// The error domain codes.
    public enum Error: Swift.Error {
        /// An invalid internal stare.
        case invalidState
        /// The uri isn’t supported.
        case unsupportedUri(_ uri: URL?)
        /// The failed to connect.
        case failedToConnect(_ reason: SRTRejectReason)
    }

    /// The SRT Library version.
    public static let version: String = SRT_VERSION_STRING
    /// The URI passed to the `connect()` method.
    public private(set) var uri: URL?
    /// This instance connect to server(true) or not(false)
    @Published public private(set) var connected = false
    /// The performance data.
    public var performanceData: SRTPerformanceData? {
        get async {
            return await socket?.performanceData
        }
    }

    private var socket: SRTSocket?
    private var streams: [SRTStream] = []
    private var listener: SRTSocket?
    private var networkMonitor: NetworkMonitor?

    /// Process-singleton SRT library init. libsrt refcounts srt_startup/srt_cleanup, so the old
    /// per-instance pairing (startup in init, cleanup in deinit) hit ZERO whenever no SRTConnection
    /// was momentarily alive — a stream stop, a mode bounce, the gap between teardown and the next
    /// session. srt_cleanup then closed ALL sockets and stopped SRT's GC thread, and the in-process
    /// re-init left `srt_create_socket` failing ("Operation not supported: Invalid socket ID") on
    /// every subsequent dial until an app relaunch. Initialize once, never cleanup (the OS reclaims
    /// everything at process death) — the standard production SRT lifecycle.
    private static let srtStartup: Void = {
        srt_startup()
    }()

    /// Creates an object.
    public init() {
        _ = Self.srtStartup
        socket = SRTSocket()
    }

    deinit {
        streams.removeAll()
    }

    /// Gets a SRTSocketOption.
    public func getSocketOption(_ name: SRTSocketOption.Name) async throws -> SRTSocketOption? {
        try await socket?.getSocketOption(name)
    }

    /// Sets a SRTSocketOption.
    public func setSocketOption(_ option: SRTSocketOption) async throws {
        if connected {
            guard option.name.restriction == .post else {
                throw Error.invalidState
            }
            try await socket?.setSocketOption(option)
        } else {
            guard option.name.restriction == .pre else {
                throw Error.invalidState
            }
            try await socket?.setSocketOption(option)
        }
    }

    /// Creates a connection to the server or waits for an incoming connection.
    ///
    /// - Parameters:
    ///   - uri: You can specify connection options in the URL. This follows the standard SRT format.
    ///
    /// - srt://192.168.1.1:9000?mode=caller
    ///   - Connect to the specified server.
    /// - srt://:9000?mode=listener
    ///   - Wait for connections as a server.
    public func connect(_ uri: URL?) async throws {
        guard let url = SRTSocketURL(uri) else {
            throw Error.unsupportedUri(uri)
        }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
                Task {
                    do {
                        try await socket?.open(url)
                        self.uri = uri
                        switch url.mode {
                        case .caller:
                            break
                        case .listener:
                            listener = socket
                            socket = try await listener?.accept(url.options)
                            await listener?.stopRunning()
                            listener = nil
                        case .rendezvous:
                            break
                        }
                        connected = await socket?.status == .connected
                        continuation.resume()
                    } catch {
                        // Close the failed socket before replacing it — a bound-but-failed dial
                        // otherwise holds its local port forever (see SRTSocket.stopRunning).
                        await socket?.stopRunning()
                        socket = SRTSocket()
                        continuation.resume(throwing: error)
                    }
                }
            }
            Task {
                guard let socket else {
                    return
                }
                let networkMonitor = await socket.makeNetworkMonitor()
                self.networkMonitor = networkMonitor
                await networkMonitor.startRunning()
                for await event in await networkMonitor.event {
                    for stream in streams {
                        await stream.dispatch(event)
                    }
                }
            }
        } catch let error as SRTSocket.Error {
            switch error {
            case .rejected(let reason):
                throw Error.failedToConnect(reason)
            default:
                // Rethrow as-is: `.illegalState(message)` carries the actual srt error string
                // (bind failure, unreachable, …) — flattening it to `.invalidState` left route
                // failures undiagnosable from the app's logs.
                throw error
            }
        }
    }

    /// Closes a connection. Idempotent and unconditional: it tears down the socket, listener,
    /// and network monitor even when `uri` is nil — i.e. when a connect hasn't COMPLETED yet
    /// (a listener blocked in `accept()` awaiting a peer, or a rendezvous mid-dial). The old
    /// `guard uri != nil` bailed out in exactly those states, leaking the bound socket/listener
    /// across an SRT mode switch (rendezvous <-> listener) so nothing was "restarted from 0".
    public func close() async {
        await networkMonitor?.stopRunning()
        networkMonitor = nil
        for stream in streams {
            await stream.close()
        }
        await socket?.stopRunning()
        socket = nil
        await listener?.stopRunning()
        listener = nil
        uri = nil
        connected = false
        socket = SRTSocket()
    }

    func send(_ data: Data) async {
        do {
            try await socket?.send(data)
        } catch {
            await close()
        }
    }

    func recv() {
        Task {
            guard let socket else {
                return
            }
            for await data in await socket.inputs {
                await streams.first?.doInput(data)
            }
            await close()
        }
    }

    func addStream(_ stream: SRTStream) {
        guard !streams.contains(where: { $0 === stream }) else {
            return
        }
        streams.append(stream)
    }

    func removeStream(_ stream: SRTStream) {
        if let index = streams.firstIndex(where: { $0 === stream }) {
            streams.remove(at: index)
        }
    }
}
