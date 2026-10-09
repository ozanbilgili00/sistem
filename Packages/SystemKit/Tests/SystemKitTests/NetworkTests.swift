import Darwin
import Foundation
import Synchronization
import Testing
@testable import SystemKit

// MARK: Counters

@Test func thirtyTwoBitCounterWrapIsSummedNotLost() {
    #expect(NetworkReader.delta(from: 100, to: 600) == 500)
    #expect(NetworkReader.delta(from: 5, to: 5) == 0)
    // The counter passed 2^32 between two readings: 1000 bytes up to the wrap, 499 after.
    #expect(NetworkReader.delta(from: UInt32.max - 999, to: 499) == 1_499)
    #expect(NetworkReader.delta(from: UInt32.max, to: 0) == 1)
}

@Test func counterResetIsNotMistakenForAHugeWrap() {
    // An interface that restarted: 1 GB before, 40 KB now. A wrap would imply 3.3 GB in one
    // interval; the new value is taken as the traffic since the reset instead.
    #expect(NetworkReader.delta(from: 1_000_000_000, to: 40_000) == 40_000)
    // 0.5 GB across the wrap is still believable.
    #expect(NetworkReader.delta(from: UInt32.max - 250_000_000, to: 250_000_000) == 500_000_001)
}

@Test func onlyRealUpInterfacesAreCounted() {
    let up = UInt32(IFF_UP | IFF_RUNNING)
    #expect(NetworkReader.isCounted(flags: up, name: "en0"))
    #expect(NetworkReader.isCounted(flags: up, name: "pdp_ip0"))
    #expect(!NetworkReader.isCounted(flags: up | UInt32(IFF_LOOPBACK), name: "lo0"))
    for name in ["utun3", "awdl0", "llw0", "bridge0", "ap1", "anpi0", "gif0", "stf0"] {
        #expect(!NetworkReader.isCounted(flags: up, name: name), "\(name) must not be counted twice")
    }
    #expect(!NetworkReader.isCounted(flags: UInt32(IFF_RUNNING), name: "en5"), "down interfaces are skipped")
}

// MARK: Live reader

@Test func networkReaderPrimesThenReportsNonNegativeRates() throws {
    let reader = NetworkReader()
    let first = try #require(reader.sample())
    #expect(first.down == 0 && first.up == 0, "first sample has no baseline")
    Thread.sleep(forTimeInterval: 0.3)
    let second = try #require(reader.sample())
    #expect(second.down >= 0 && second.up >= 0)
    #expect(!second.interfaces.contains { $0.name.hasPrefix("lo") || $0.name.hasPrefix("utun") })
    reader.reset()
    #expect(try #require(reader.sample()).down == 0)
}

/// 8 MB sent to 127.0.0.1 must not show up as network traffic.
@Test func loopbackTrafficIsIgnored() throws {
    let reader = NetworkReader()
    _ = reader.sample()
    let socketFD = socket(AF_INET, SOCK_DGRAM, 0)
    defer { close(socketFD) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = UInt16(40_000).bigEndian
    address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
    let payload = [UInt8](repeating: 1, count: 8_000)
    for _ in 0..<1_000 {
        _ = payload.withUnsafeBytes { buffer in
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(socketFD, buffer.baseAddress, buffer.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }
    let sample = try #require(reader.sample())
    #expect(sample.totalUp + sample.totalDown < 4_000_000, "counted \(sample.totalUp + sample.totalDown) bytes")
}

@Test func localAddressesAreValidAndSkipLinkLocal() throws {
    let addresses = NetworkReader.localAddresses()
    for address in addresses {
        var v4 = in_addr(), v6 = in6_addr()
        let valid = address.isIPv6 ? inet_pton(AF_INET6, address.address, &v6) == 1 : inet_pton(AF_INET, address.address, &v4) == 1
        #expect(valid, "\(address.address)")
        #expect(!address.address.lowercased().hasPrefix("fe80"))
        #expect(address.address != "127.0.0.1")
    }
}

@Test func networkReaderDoesNotLeak() throws {
    let reader = NetworkReader()
    for _ in 0..<500 { _ = reader.sample() }
    _ = try footprintStaysFlat(margin: 3 * 1024 * 1024) {
        for _ in 0..<10_000 { _ = reader.sample() }
    }
}

@Test func localAddressListDoesNotLeak() throws {
    for _ in 0..<200 { _ = NetworkReader.localAddresses() }
    _ = try footprintStaysFlat(margin: 3 * 1024 * 1024) {
        for _ in 0..<5_000 { _ = NetworkReader.localAddresses() }
    }
}

// MARK: Wi-Fi

@Test func wifiReaderReportsPlausibleValuesAndDoesNotLeak() throws {
    let reader = WiFiReader()
    guard reader.isAvailable else { return }  // a Mac without Wi-Fi has nothing to read
    let sample = try #require(reader.sample())
    if sample.isAssociated {
        let rssi = try #require(sample.rssi)
        #expect((-110...0).contains(rssi))
        #expect((-120...(-40)).contains(try #require(sample.noise)))
        #expect((try #require(sample.transmitRate)) > 0)
        #expect(sample.quality != nil)
        #expect(sample.channel.map { (1...233).contains($0) } ?? true)
    } else {
        #expect(sample.rssi == nil && sample.transmitRate == nil && sample.ssid == nil)
    }
    for _ in 0..<50 { _ = reader.sample() }
    _ = try footprintStaysFlat(margin: 3 * 1024 * 1024) {
        for _ in 0..<500 { _ = reader.sample() }
    }
}

@Test func wifiQualityThresholds() {
    func quality(_ rssi: Int) -> WiFiSample.Quality? { WiFiSample(isAssociated: true, rssi: rssi).quality }
    #expect(quality(-45) == .excellent && quality(-50) == .excellent)
    #expect(quality(-55) == .good && quality(-65) == .fair && quality(-80) == .poor)
    #expect(WiFiSample().quality == nil)
    #expect(WiFiSample(isAssociated: true, rssi: -50, noise: -90).signalToNoise == 40)
}

@Test func locationStateMapping() {
    #expect(LocationAccess.state(for: .notDetermined) == .notDetermined)
    #expect(LocationAccess.state(for: .authorizedAlways) == .authorized)
    #expect(LocationAccess.state(for: .denied) == .denied)
    #expect(LocationAccess.state(for: .restricted) == .denied)
}

// MARK: Connection history

private func path(_ status: PathState.Status, _ primary: PathState.Interface?, expensive: Bool = false) -> PathState {
    PathState(status: status, interfaces: primary.map { [$0] } ?? [], primary: primary, isExpensive: expensive)
}

private let wifi = PathState.Interface(name: "en0", type: .wifi)
private let ethernet = PathState.Interface(name: "en5", type: .wired)

@Test func connectionEventsFollowPathChanges() {
    var id = 0
    let now = Date()
    // First report: one event for the starting state.
    let initial = ConnectionEvent.events(from: nil, to: path(.satisfied, wifi), at: now, nextID: &id)
    #expect(initial.map(\.kind) == [.connected] && initial.first?.interface == wifi)
    // Same interface, only a cost flag flipped: nothing to record.
    #expect(ConnectionEvent.events(from: path(.satisfied, wifi), to: path(.satisfied, wifi, expensive: true), at: now, nextID: &id).isEmpty)
    // Cable plugged in while on Wi-Fi: the default route moves.
    let moved = ConnectionEvent.events(from: path(.satisfied, wifi), to: path(.satisfied, ethernet), at: now, nextID: &id)
    #expect(moved.map(\.kind) == [.interfaceChanged] && moved.first?.interface == ethernet)
    let lost = ConnectionEvent.events(from: path(.satisfied, ethernet), to: path(.unsatisfied, nil), at: now, nextID: &id)
    #expect(lost.map(\.kind) == [.disconnected])
    let back = ConnectionEvent.events(from: path(.unsatisfied, nil), to: path(.satisfied, wifi), at: now, nextID: &id)
    #expect(back.map(\.kind) == [.connected])
    #expect(id == 4, "ids are unique and increasing")
}

@MainActor @Test func storeKeepsNewestEventsFirstAndCapsThem() {
    let store = MetricStore()
    for index in 0..<(MetricStore.connectionEventLimit + 10) {
        store.ingest(Snapshot(connectionEvents: [ConnectionEvent(id: index, date: .now, kind: .connected, interface: nil)]))
    }
    #expect(store.connectionEvents.count == MetricStore.connectionEventLimit)
    #expect(store.connectionEvents.first?.id == MetricStore.connectionEventLimit + 9)
}

@Test func pathMonitorReportsCurrentPathAndStopsCleanly() async throws {
    let monitor = NetworkPathMonitor()
    let received = Mutex<PathState?>(nil)
    monitor.start { state, _ in received.withLock { $0 = state } }
    #expect(monitor.isRunning)
    for _ in 0..<40 where received.withLock({ $0 }) == nil { try await Task.sleep(for: .milliseconds(100)) }
    let state = try #require(received.withLock { $0 })
    #expect(monitor.state == state)
    if state.isConnected { #expect(monitor.primaryInterfaceName == state.primary?.name) }
    monitor.stop()
    #expect(!monitor.isRunning)
    monitor.stop()  // idempotent
}

// MARK: Optional lookups — off by default

@Test func publicIPResponsesAreValidated() throws {
    func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: PublicIPClient.endpoint, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
    #expect(PublicIPClient.parse(data: Data("203.0.113.7\n".utf8), response: response(200)) == "203.0.113.7")
    #expect(PublicIPClient.parse(data: Data("2001:db8::1".utf8), response: response(200)) == "2001:db8::1")
    #expect(PublicIPClient.parse(data: Data("203.0.113.7".utf8), response: response(500)) == nil)
    #expect(PublicIPClient.parse(data: Data("<html>captive portal</html>".utf8), response: response(200)) == nil)
    #expect(PublicIPClient.parse(data: Data("999.1.1.1".utf8), response: response(200)) == nil)
    #expect(PublicIPClient.parse(data: Data(repeating: 49, count: 500), response: response(200)) == nil)
    #expect(PublicIPClient.parse(data: Data("1.2.3.4".utf8), response: URLResponse()) == nil)
}

@Test func everyRequestHasAnExplicitShortTimeout() {
    let configuration = PublicIPClient.configuration()
    #expect(configuration.timeoutIntervalForRequest > 0 && configuration.timeoutIntervalForRequest <= 5)
    #expect(configuration.timeoutIntervalForResource > 0 && configuration.timeoutIntervalForResource <= 5)
    #expect(!configuration.waitsForConnectivity)
    #expect(configuration.urlCache == nil && configuration.httpCookieStorage == nil)
    #expect(PublicIPClient.request().timeoutInterval <= 5)
    #expect(LatencyProbe.timeout <= 5)
    #expect(PublicIPClient.endpoint.scheme == "https")
}

/// Serves a canned answer so the client can be exercised without leaving the process.
private final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var body = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test func publicIPClientAgainstAStub() async {
    let configuration = PublicIPClient.configuration()
    configuration.protocolClasses = [StubProtocol.self]
    let session = URLSession(configuration: configuration)
    StubProtocol.status = 200
    StubProtocol.body = Data("198.51.100.4".utf8)
    #expect(await PublicIPClient().fetch(session: session) == "198.51.100.4")
    StubProtocol.status = 503
    #expect(await PublicIPClient().fetch(session: session) == nil)
}

/// With default settings the service must not call either lookup, however much the
/// network changes: the closures are the only code that reaches the network.
@MainActor @Test func defaultSettingsMakeNoOutboundRequests() async throws {
    let calls = Mutex(0)
    let store = MetricStore()
    let service = NetworkService(store: store,
                                 fetchAddress: { calls.withLock { $0 += 1 }; return "203.0.113.9" },
                                 measureRoundTrip: { calls.withLock { $0 += 1 }; return 12 })
    #expect(!service.publicIPEnabled && !service.latencyEnabled)
    service.update(demanded: true, onBattery: false, paused: false)
    for _ in 0..<30 where store.path == nil { try await Task.sleep(for: .milliseconds(100)) }
    #expect(store.path != nil, "the path monitor did start")
    try await Task.sleep(for: .milliseconds(500))
    #expect(calls.withLock { $0 } == 0)
    #expect(store.publicIP == .off && store.latency == .off)
}

@MainActor @Test func publicIPIsLookedUpOnEnableAndOnChangeOnly() async throws {
    let calls = Mutex(0)
    let store = MetricStore()
    let service = NetworkService(store: store, fetchAddress: { calls.withLock { $0 += 1 }; return "203.0.113.9" },
                                 measureRoundTrip: { nil })
    service.update(demanded: true, onBattery: false, paused: false)
    for _ in 0..<30 where store.path == nil { try await Task.sleep(for: .milliseconds(100)) }
    guard store.path?.isConnected == true else { return }  // offline: nothing to look up
    service.publicIPEnabled = true
    for _ in 0..<30 where store.publicIP == .fetching || store.publicIP == .off { try await Task.sleep(for: .milliseconds(100)) }
    #expect(store.publicIP == .address("203.0.113.9", { if case .address(_, let date) = store.publicIP { date } else { .now } }()))
    let afterEnable = calls.withLock { $0 }
    #expect(afterEnable >= 1)
    // No timer: a quiet network means no further lookups.
    try await Task.sleep(for: .milliseconds(1_500))
    #expect(calls.withLock { $0 } == afterEnable)
    service.publicIPEnabled = false
    #expect(store.publicIP == .off)
}

@MainActor @Test func latencyNeverRunsOnBatteryOrWhenHidden() async throws {
    let calls = Mutex(0)
    let store = MetricStore()
    let service = NetworkService(store: store, fetchAddress: { nil }, measureRoundTrip: { calls.withLock { $0 += 1 }; return 9 })
    service.latencyEnabled = true
    service.update(demanded: false, onBattery: false, paused: false)
    try await Task.sleep(for: .milliseconds(300))
    #expect(calls.withLock { $0 } == 0, "nothing on screen")
    service.update(demanded: true, onBattery: true, paused: false)
    try await Task.sleep(for: .milliseconds(300))
    #expect(calls.withLock { $0 } == 0, "on battery")
    service.update(demanded: true, onBattery: false, paused: true)
    try await Task.sleep(for: .milliseconds(300))
    #expect(calls.withLock { $0 } == 0, "asleep")
    service.update(demanded: true, onBattery: false, paused: false)
    for _ in 0..<30 where calls.withLock({ $0 }) == 0 { try await Task.sleep(for: .milliseconds(100)) }
    #expect(calls.withLock { $0 } >= 1)
    service.latencyEnabled = false
    #expect(store.latency == .off)
}

// MARK: Sampler and store wiring

@Test func samplerReadsNetworkAndDiskAndSlowMetricsRightAway() async throws {
    let seen = Mutex((network: 0, disk: 0, info: 0))
    let sampler = SamplerActor { snapshot in
        seen.withLock {
            if snapshot.network != nil { $0.network += 1 }
            if snapshot.disk != nil { $0.disk += 1 }
            if snapshot.networkInfo != nil { $0.info += 1 }
        }
    }
    // Two ticks only: networkInfo (every 5th) must still arrive on the first one, or a
    // page would sit empty for 10 s. (Not diskHealth: SMART is exclusive and has its own test.)
    sampler.send(SamplerConfig(interval: 0.1, metrics: [.network, .disk, .networkInfo], paused: false))
    try await Task.sleep(for: .milliseconds(320))
    sampler.send(SamplerConfig(interval: 0.1, metrics: [], paused: false))
    let counts = seen.withLock { $0 }
    #expect(counts.network >= 2 && counts.disk >= 2)
    #expect(counts.info >= 1, "networkInfo (every 5th tick) arrived on the first one")
}

@MainActor @Test func storeKeepsCapacityBetweenRefreshes() {
    let store = MetricStore()
    let volume = DiskVolume(name: "A", mountPoint: "/", total: 100, available: 40, kind: .internalDisk, isBoot: true)
    store.ingest(Snapshot(disk: DiskSample(readRate: 5, writeRate: 7, readOps: 1, writeOps: 1, devices: [], volumes: [volume])))
    store.ingest(Snapshot(disk: DiskSample(readRate: 1, writeRate: 2, readOps: 1, writeOps: 1, devices: [], volumes: nil)))
    #expect(store.diskVolumes == [volume])
    #expect(store.diskRead.values() == [5, 1] && store.diskWrite.values() == [7, 2])
}
