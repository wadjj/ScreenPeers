import Foundation

@main enum NetworkTests {
    static func main() {
        func address(_ name: String, _ ip: String, _ primary: Bool, _ type: String) -> NetworkAddress {
            NetworkAddress(id: name + "/" + ip, interface: name, name: type, address: ip, primary: primary)
        }
        let wired = address("en0", "192.168.1.2", false, "Ethernet")
        let wifi = address("en1", "192.168.2.2", false, "Wi-Fi")
        let primaryWiFi = address("en1", "192.168.2.2", true, "Wi-Fi")
        let tunnel = address("utun5", "10.0.0.2", true, "utun5")
        assert(NetworkState.selected([wired, primaryWiFi], fallback: "ethernet")?.interface == "en1")
        assert(NetworkState.selected([wired, wifi], fallback: "wifi")?.interface == "en1")
        assert(NetworkState.selected([wired, wifi], fallback: "ethernet")?.interface == "en0")
        assert(NetworkState.selected([wired, tunnel], fallback: "ethernet")?.interface == "utun5")
        assert(NetworkState.selected([], fallback: "ethernet") == nil)
        assert(NetworkState.selected([address("utun5", "10.0.0.2", false, "utun5")], fallback: "ethernet") == nil)
        print("Network selection: 6 scenarios passed")
        let live = NetworkState.addresses()
        print("Live network interfaces: \(live.count); selected: \(NetworkState.selected(live, fallback: "ethernet")?.interface ?? "none")")
    }
}
