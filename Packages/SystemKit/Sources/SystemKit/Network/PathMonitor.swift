import Foundation
import Network
import Synchronization

public enum NetworkInterfaceType: String, Sendable {
    case wifi, wired, cellular, other
}

/// What `NWPathMonitor` last said, reduced to value types.
public struct PathState: Sendable, Equatable {
    public enum Status: Sendable { case satisfied, unsatisfied, requiresConnection }

    public struct Interface: Sendable, Equatable {
        public var name: String
        public var type: NetworkInterfaceType
        public init(name: String, type: NetworkInterfaceType) {
            self.name = name
            self.type = type
        }
    }

    public var status: Status
    /// Interfaces the system could use, in its order of preference.
    public var interfaces: [Interface]
    /// The one carrying the default route: the first preferred interface the path uses.
    public var primary: Interface?
    public var isExpensive: Bool
    public var isConstrained: Bool
    public var supportsIPv4: Bool
    public var supportsIPv6: Bool

    public var isConnected: Bool { status == .satisfied }

    public init(status: Status, interfaces: [Interface] = [], primary: Interface? = nil, isExpensive: Bool = false,
                isConstrained: Bool = false, supportsIPv4: Bool = true, supportsIPv6: Bool = true) {
        self.status = status
        self.interfaces = interfaces
        self.primary = primary
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.supportsIPv4 = supportsIPv4
        self.supportsIPv6 = supportsIPv6
    }
}

/// One entry of the in-memory connection history.
public struct ConnectionEvent: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable { case connected, disconnected, interfaceChanged }

    public var id: Int
    public var date: Date
    public var kind: Kind
    /// The interface in use after the event, if any.
    public var interface: PathState.Interface?

    public init(id: Int, date: Date, kind: Kind, interface: PathState.Interface?) {
        self.id = id
        self.date = date
        self.kind = kind
        self.interface = interface
    }

    /// Events implied by a path update. Cost-flag flips (expensive, constrained) and
    /// address changes on the same interface are not events.
    static func events(from old: PathState?, to new: PathState, at date: Date, nextID: inout Int) -> [ConnectionEvent] {
        func make(_ kind: Kind) -> ConnectionEvent {
            defer { nextID += 1 }
            return ConnectionEvent(id: nextID, date: date, kind: kind, interface: new.primary)
        }
        guard let old else { return [make(new.isConnected ? .connected : .disconnected)] }
        if old.isConnected != new.isConnected { return [make(new.isConnected ? .connected : .disconnected)] }
        if new.isConnected, old.primary != new.primary { return [make(.interfaceChanged)] }
        return []
    }
}

/// Watches connectivity with `NWPathMonitor`: the kernel tells us when the path
/// changes, so there is no polling and no timer, and an idle monitor costs nothing.
///
/// Thread-safe. Callbacks and ``state`` come from a private utility queue.
public final class NetworkPathMonitor: Sendable {
    private struct Shared {
        var state: PathState?
        var nextEventID = 0
    }

    private let shared = Mutex(Shared())
    private let queue = DispatchQueue(label: "sistem.path", qos: .utility)
    private let monitor = Mutex<NWPathMonitor?>(nil)

    /// Called on the monitor queue after each update, with the new state and any
    /// events it produced.
    public init() {}

    public var state: PathState? { shared.withLock { $0.state } }

    /// The interface carrying the default route, for the throughput reader.
    public var primaryInterfaceName: String? { shared.withLock { $0.state?.primary?.name } }

    public var isRunning: Bool { monitor.withLock { $0 != nil } }

    /// Starts watching; no effect when already running. `handler` gets the state and
    /// the events of every update, starting with the current state.
    public func start(_ handler: @escaping @Sendable (PathState, [ConnectionEvent]) -> Void) {
        monitor.withLock { monitor in
            guard monitor == nil else { return }
            let new = NWPathMonitor()
            new.pathUpdateHandler = { [self] path in
                let state = Self.state(of: path)
                let events = shared.withLock { shared in
                    let events = ConnectionEvent.events(from: shared.state, to: state, at: Date(), nextID: &shared.nextEventID)
                    shared.state = state
                    return events
                }
                handler(state, events)
            }
            new.start(queue: queue)
            monitor = new
        }
    }

    public func stop() {
        monitor.withLock { monitor in
            monitor?.cancel()
            monitor = nil
        }
    }

    deinit { monitor.withLock { $0?.cancel() } }

    static func state(of path: NWPath) -> PathState {
        let status: PathState.Status = switch path.status {
        case .satisfied: .satisfied
        case .requiresConnection: .requiresConnection
        default: .unsatisfied
        }
        let interfaces = path.availableInterfaces.map { PathState.Interface(name: $0.name, type: type(of: $0.type)) }
        let primary = path.availableInterfaces.first { path.usesInterfaceType($0.type) }
            .map { PathState.Interface(name: $0.name, type: type(of: $0.type)) }
        return PathState(status: status, interfaces: interfaces, primary: status == .satisfied ? primary : nil,
                         isExpensive: path.isExpensive, isConstrained: path.isConstrained,
                         supportsIPv4: path.supportsIPv4, supportsIPv6: path.supportsIPv6)
    }

    static func type(of type: NWInterface.InterfaceType) -> NetworkInterfaceType {
        switch type {
        case .wifi: .wifi
        case .wiredEthernet: .wired
        case .cellular: .cellular
        default: .other
        }
    }
}
