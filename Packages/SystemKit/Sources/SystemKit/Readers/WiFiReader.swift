import CoreWLAN
import Foundation

public struct WiFiSample: Sendable, Equatable {
    public enum Band: String, Sendable { case ghz2_4, ghz5, ghz6 }

    public var interfaceName: String?
    /// False when Wi-Fi is switched off or the Mac isn't joined to a network.
    public var isAssociated: Bool
    public var isPoweredOn: Bool
    /// dBm, negative; nil when not associated.
    public var rssi: Int?
    /// dBm; nil when not associated.
    public var noise: Int?
    public var channel: Int?
    public var band: Band?
    /// Mbit/s negotiated with the access point.
    public var transmitRate: Double?
    /// nil unless Location Services allow this app to see network names.
    public var ssid: String?

    public var signalToNoise: Int? {
        guard let rssi, let noise else { return nil }
        return rssi - noise
    }

    public init(interfaceName: String? = nil, isAssociated: Bool = false, isPoweredOn: Bool = true, rssi: Int? = nil,
                noise: Int? = nil, channel: Int? = nil, band: Band? = nil, transmitRate: Double? = nil, ssid: String? = nil) {
        self.interfaceName = interfaceName
        self.isAssociated = isAssociated
        self.isPoweredOn = isPoweredOn
        self.rssi = rssi
        self.noise = noise
        self.channel = channel
        self.band = band
        self.transmitRate = transmitRate
        self.ssid = ssid
    }

    /// Four steps for a signal bar: thresholds follow the usual rule of thumb
    /// (−50 excellent, −60 good, −70 fair).
    public enum Quality: Int, Sendable { case poor, fair, good, excellent }

    public var quality: Quality? {
        guard let rssi else { return nil }
        switch rssi {
        case (-50)...: return .excellent
        case (-60)...: return .good
        case (-70)...: return .fair
        default: return .poor
        }
    }
}

/// Wi-Fi link details from CoreWLAN. RSSI, noise, channel and rate need no
/// permission; the network name does (Location Services) and comes back nil without it.
///
/// The interface object is fetched once; every read is a few property getters
/// answered by `airportd`. Returns nil on a Mac without a Wi-Fi interface.
public final class WiFiReader {
    private let interface: CWInterface?

    public init() {
        interface = CWWiFiClient.shared().interface()
    }

    public var isAvailable: Bool { interface != nil }

    public func sample() -> WiFiSample? {
        guard let interface else { return nil }
        let powered = interface.powerOn()
        let rssi = interface.rssiValue()
        let rate = interface.transmitRate()
        // CoreWLAN reports 0 for RSSI and rate when there is no link.
        let associated = powered && rssi != 0 && rate > 0
        guard associated else {
            return WiFiSample(interfaceName: interface.interfaceName, isAssociated: false, isPoweredOn: powered)
        }
        let channel = interface.wlanChannel()
        return WiFiSample(
            interfaceName: interface.interfaceName, isAssociated: true, isPoweredOn: true,
            rssi: rssi, noise: interface.noiseMeasurement(),
            channel: channel?.channelNumber, band: channel.flatMap { Self.band($0.channelBand) },
            transmitRate: rate, ssid: interface.ssid())
    }

    static func band(_ band: CWChannelBand) -> WiFiSample.Band? {
        switch band {
        case .band2GHz: .ghz2_4
        case .band5GHz: .ghz5
        case .band6GHz: .ghz6
        default: nil
        }
    }
}
