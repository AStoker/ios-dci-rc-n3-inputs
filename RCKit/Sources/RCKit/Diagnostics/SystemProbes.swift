import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// One network interface address. Used to spot a USB-Ethernet-style interface appearing when the
/// remote is plugged in (another transport some DJI devices expose in PC mode).
public struct NetworkInterfaceInfo: Sendable, Hashable, Identifiable {
    public var id: String { "\(name)|\(family)|\(address)" }
    public let name: String
    public let family: String
    public let address: String
    public let isUp: Bool
    public let isRunning: Bool
    public let isLoopback: Bool

    public var logDescription: String {
        "\(name) \(family) \(address)\(isUp ? " UP" : "")\(isRunning ? " RUNNING" : "")"
    }
}

public enum NetworkInterfaces {
    public static func snapshot() -> [NetworkInterfaceInfo] {
        var result: [NetworkInterfaceInfo] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let name = String(cString: entry.ifa_name)
            let flags = Int32(entry.ifa_flags)
            guard let addr = entry.ifa_addr else { continue }
            let familyCode = Int32(addr.pointee.sa_family)
            let family: String
            var address = ""
            switch familyCode {
            case AF_INET, AF_INET6:
                family = familyCode == AF_INET ? "IPv4" : "IPv6"
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    address = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                }
            case AF_LINK:
                family = "link"
            default:
                continue
            }
            result.append(NetworkInterfaceInfo(
                name: name, family: family, address: address,
                isUp: flags & IFF_UP != 0, isRunning: flags & IFF_RUNNING != 0, isLoopback: flags & IFF_LOOPBACK != 0
            ))
        }
        return result.sorted { ($0.name, $0.family, $0.address) < ($1.name, $1.family, $1.address) }
    }
}

/// Facts about the phone and build, for log headers.
public struct ProbeEnvironment: Sendable {
    public var deviceModel: String
    public var osVersion: String
    public var appVersion: String
    public var appBuild: String
    public var bundleID: String
    public var declaredAccessoryProtocols: [String]

    public static func current(bundle: Bundle = .main) -> ProbeEnvironment {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafeBytes(of: &systemInfo.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        let info = bundle.infoDictionary ?? [:]
        return ProbeEnvironment(
            deviceModel: machine,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            appVersion: info["CFBundleShortVersionString"] as? String ?? "?",
            appBuild: info["CFBundleVersion"] as? String ?? "?",
            bundleID: bundle.bundleIdentifier ?? "?",
            declaredAccessoryProtocols: info["UISupportedExternalAccessoryProtocols"] as? [String] ?? []
        )
    }

    public var summary: String {
        """
        Device: \(deviceModel)  OS: \(osVersion)
        App: \(bundleID) \(appVersion) (\(appBuild))
        Declared EA protocols: \(declaredAccessoryProtocols.joined(separator: ", "))
        """
    }
}
