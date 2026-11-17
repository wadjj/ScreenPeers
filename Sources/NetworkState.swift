import Foundation
import SystemConfiguration
import Darwin

struct NetworkAddress: Decodable, Identifiable {
    let id: String
    let interface: String
    let name: String
    let address: String
    let primary: Bool
    var displayName: String {
        if name == "Ethernet" { return "以太网" }
        return name
    }
}

final class NetworkState {
    private var dynamicStore: SCDynamicStore?
    private var wake: NSObjectProtocol?
    var changed: (() -> Void)?

    func start() {
        var context = SCDynamicStoreContext(version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        dynamicStore = SCDynamicStoreCreate(nil, "ScreenPeers" as CFString, { _, _, pointer in
            guard let pointer else { return }
            Unmanaged<NetworkState>.fromOpaque(pointer).takeUnretainedValue().changed?()
        }, &context)
        if let dynamicStore {
            SCDynamicStoreSetNotificationKeys(dynamicStore,
                ["State:/Network/Global/IPv4"] as CFArray,
                ["State:/Network/Interface/.*/IPv4", "State:/Network/Interface/.*/Link",
                 "State:/Network/Service/.*/IPv4"] as CFArray)
            SCDynamicStoreSetDispatchQueue(dynamicStore, .main)
        }
    }

    static func addresses() -> [NetworkAddress] {
        let store = SCDynamicStoreCreate(nil, "ScreenPeers.read" as CFString, nil, nil)
        let global = store.flatMap { SCDynamicStoreCopyValue($0, "State:/Network/Global/IPv4" as CFString) as? [String: Any] }
        let primary = global?["PrimaryInterface"] as? String
        var names: [String: String] = [:]
        if let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for interface in interfaces {
                if let bsd = SCNetworkInterfaceGetBSDName(interface) as String? {
                    names[bsd] = SCNetworkInterfaceGetInterfaceType(interface) as String?
                }
            }
        }
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var result: [NetworkAddress] = []
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            let value = entry.pointee
            guard let addr = value.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  value.ifa_flags & UInt32(IFF_UP) != 0,
                  value.ifa_flags & UInt32(IFF_RUNNING) != 0,
                  value.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let interface = String(cString: value.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            guard !ip.hasPrefix("169.254."), !ip.hasPrefix("127."), !ip.hasPrefix("0."),
                  let octet = Int(ip.split(separator: ".")[0]), octet < 224 else { continue }
            let type = names[interface] ?? interface
            result.append(NetworkAddress(id: interface + "/" + ip, interface: interface,
                name: type == "IEEE80211" ? "Wi-Fi" : type, address: ip, primary: interface == primary))
        }
        return result.sorted { $0.id < $1.id }
    }

    static func selected(_ addresses: [NetworkAddress], fallback: String) -> NetworkAddress? {
        let primary = addresses.filter { $0.primary }
        if primary.count == 1 { return primary[0] }
        // Ambiguous primary: prefer a physical active interface by the user's fallback order.
        let physical = addresses.filter { $0.name == "Ethernet" || $0.name == "Wi-Fi" }
        let preferred = fallback == "wifi" ? "Wi-Fi" : "Ethernet"
        return physical.sorted {
            if ($0.name == preferred) != ($1.name == preferred) { return $0.name == preferred }
            return $0.id < $1.id
        }.first
    }
}
