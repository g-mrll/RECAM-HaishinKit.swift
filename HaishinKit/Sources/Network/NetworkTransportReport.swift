import Foundation

/// A structure that represents a network transport bitRate statics.
package struct NetworkTransportReport: Sendable {
    /// The statistics of outgoing queue bytes per second.
    package let queueBytesOut: Int
    /// The statistics of incoming bytes per second.
    package let totalBytesIn: Int
    /// The statistics of outgoing bytes per second.
    package let totalBytesOut: Int
    /// Round-trip time in ms (SRT end-to-end; 0 if the transport doesn't report it).
    package let roundTripTimeMs: Double
    /// Packets sent this interval (SRT).
    package let packetsSent: Int
    /// Packets retransmitted this interval (SRT).
    package let packetsRetransmitted: Int
    /// Packets dropped on send this interval — SRT TLPKTDROP (link can't keep up).
    package let packetsSendDropped: Int

    /// Creates a new instance.
    package init(queueBytesOut: Int, totalBytesIn: Int, totalBytesOut: Int,
                 roundTripTimeMs: Double = 0, packetsSent: Int = 0,
                 packetsRetransmitted: Int = 0, packetsSendDropped: Int = 0) {
        self.queueBytesOut = queueBytesOut
        self.totalBytesIn = totalBytesIn
        self.totalBytesOut = totalBytesOut
        self.roundTripTimeMs = roundTripTimeMs
        self.packetsSent = packetsSent
        self.packetsRetransmitted = packetsRetransmitted
        self.packetsSendDropped = packetsSendDropped
    }
}
