#if os(iOS)
import ExternalAccessory
import Foundation

/// Watches External Accessory connections and owns one `AccessoryStreamSession` per
/// (accessory, protocol) pair.
///
/// External Accessory is Apple's API for MFi hardware that speaks iAP2. An app can only see
/// accessories whose protocol strings it declares in Info.plist (`UISupportedExternalAccessoryProtocols`).
/// That's roughly the native version of a web page needing permission for a device, except the
/// allow-list is baked into the app at build time.
@MainActor
public final class ExternalAccessoryProbe {
    public private(set) var accessories: [AccessoryInfo] = []
    public private(set) var sessions: [String: AccessoryStreamSession] = [:]
    /// Open a session automatically for every declared protocol a connected accessory advertises.
    public var autoOpenSessions = true
    public let declaredProtocols: [String]

    private let log: ProbeLog
    private let io = RunLoopThread(name: "RCKit.EA-IO")
    private var liveAccessories: [Int: EAAccessory] = [:]
    private var observers: [NSObjectProtocol] = []
    private var started = false

    public init(log: ProbeLog, declaredProtocols: [String]) {
        self.log = log
        self.declaredProtocols = declaredProtocols
    }

    public func start() {
        guard !started else { return }
        started = true
        EAAccessoryManager.shared().registerForLocalNotifications()
        let center = NotificationCenter.default
        for (name, label) in [(Notification.Name.EAAccessoryDidConnect, "connect"),
                              (Notification.Name.EAAccessoryDidDisconnect, "disconnect")] {
            // queue: .main means the closure runs on the main thread, so asserting main-actor
            // isolation is correct. (A mismatch here is what crashed the previous attempt.)
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.log.log(.ea, "Notification: EAAccessoryDid\(label.capitalized)")
                    self?.refresh()
                }
            })
        }
        log.log(.ea, "External Accessory probe started. Declared protocols: \(declaredProtocols.joined(separator: ", "))")
        refresh()
    }

    /// Re-reads `connectedAccessories`, logs differences and (optionally) opens sessions.
    public func refresh() {
        let current = EAAccessoryManager.shared().connectedAccessories
        let currentIDs = Set(current.map(\.connectionID))
        let previousIDs = Set(liveAccessories.keys)

        for accessory in current where !previousIDs.contains(accessory.connectionID) {
            log.log(.ea, "Accessory CONNECTED: \(AccessoryInfo(accessory).logDescription)")
            let undeclared = accessory.protocolStrings.filter { !declaredProtocols.contains($0) }
            if !undeclared.isEmpty {
                log.log(.ea, "Accessory advertises protocols NOT declared in Info.plist (can't open these yet): "
                    + undeclared.joined(separator: ", "))
            }
        }
        for id in previousIDs.subtracting(currentIDs) {
            log.log(.ea, "Accessory DISCONNECTED: connectionID=\(id)")
            for session in sessions.values where session.accessoryID == id && session.state.isLive {
                session.close(reason: "accessory disconnected")
            }
        }
        if current.isEmpty, previousIDs.isEmpty {
            log.log(.ea, "connectedAccessories is empty")
        }

        liveAccessories = Dictionary(uniqueKeysWithValues: current.map { ($0.connectionID, $0) })
        accessories = current.map(AccessoryInfo.init).sorted { $0.connectionID < $1.connectionID }

        if autoOpenSessions {
            for accessory in current {
                for proto in accessory.protocolStrings where declaredProtocols.contains(proto) {
                    if let existing = sessions["\(accessory.connectionID)|\(proto)"], existing.state.isLive { continue }
                    openSession(accessoryID: accessory.connectionID, protocolString: proto)
                }
            }
        }
    }

    public func openSession(accessoryID: Int, protocolString: String) {
        guard let accessory = liveAccessories[accessoryID] else {
            log.log(.ea, "Can't open \(protocolString): accessory \(accessoryID) is gone")
            return
        }
        let key = "\(accessoryID)|\(protocolString)"
        if let existing = sessions[key], existing.state.isLive { return }
        let session = AccessoryStreamSession(accessory: accessory, protocolString: protocolString, io: io, log: log)
        sessions[key] = session
        session.open(accessory: accessory)
    }

    public func closeSession(id: String, reason: String = "closed by user") {
        sessions[id]?.close(reason: reason)
    }

    public func closeAll(reason: String) {
        for session in sessions.values where session.state.isLive { session.close(reason: reason) }
    }

    /// Sessions that are open, in a stable order.
    public var liveSessions: [AccessoryStreamSession] {
        sessions.values.filter { $0.state == .open }.sorted { $0.id < $1.id }
    }

    public var allSessions: [AccessoryStreamSession] {
        sessions.values.sorted { $0.id < $1.id }
    }

    public func removeClosedSessions() {
        sessions = sessions.filter { $0.value.state.isLive }
    }
}
#endif
