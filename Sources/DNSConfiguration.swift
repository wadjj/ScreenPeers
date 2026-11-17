import Foundation
import Security

struct DNSConfiguration: Codable {
    var version = 2
    var provider = "dnspod"
    var domain = ""
    var subdomain = ""
    var record_id = ""
    var credential_id = ""
    var executable = ""
    var fallback = "ethernet"
    var profile: String?
    var tccli: String?
    var hostname: String { subdomain == "@" ? domain : subdomain + "." + domain }

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/ScreenPeers")
    }
    static var url: URL { directory.appendingPathComponent("dns.json") }
    static func read(_ path: String) -> DNSConfiguration? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        if let cfg = try? JSONDecoder().decode(Self.self, from: data) { return cfg }
        // Import the original local installation without carrying its network bindings forward.
        guard let legacy = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let domain = legacy["domain"] as? String, let subdomain = legacy["subdomain"] as? String,
              let profile = legacy["profile"] as? String else { return nil }
        var cfg = Self()
        cfg.domain = domain; cfg.subdomain = subdomain; cfg.profile = profile
        cfg.tccli = legacy["tccli"] as? String
        if let runtime = legacy["runtime_dir"] as? String,
           let state = try? Data(contentsOf: URL(fileURLWithPath: runtime).appendingPathComponent("state.json")),
           let value = try? JSONSerialization.jsonObject(with: state) as? [String: Any],
           let id = value["record_id"] { cfg.record_id = String(describing: id) }
        return cfg
    }
    func save() throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(self)
        try data.write(to: Self.url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.url.path)
    }
}

enum CredentialStore {
    static func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.screenpeers.dns", kSecAttrAccount as String: id]
    }
    static func read(_ id: String) throws -> [String: String] {
        if id.isEmpty { return [:] }
        var request = query(id)
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let value = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw NSError(domain: "ScreenPeers", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "无法读取钥匙串账户，请在设置中重新保存密钥"])
        }
        return value
    }
    static func save(_ value: [String: String], id: String) throws {
        let data = try JSONSerialization.data(withJSONObject: value)
        var request = query(id)
        request[kSecValueData as String] = data
        request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(request as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: "ScreenPeers", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "无法保存账户到钥匙串"])
        }
    }
    static func remove(_ id: String) {
        if !id.isEmpty { SecItemDelete(query(id) as CFDictionary) }
    }
}

struct ProviderResult: Decodable {
    let success: Bool
    let message: String
    let record_id: String?
    let address: String?
    let verified: Double?
}

enum ProviderBridge {
    static func run(_ config: DNSConfiguration, operation: String, address: String?,
                    credential: [String: String]? = nil) throws -> ProviderResult {
        guard let script = Bundle.main.path(forResource: "providers", ofType: "py"),
              let python = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
                .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw NSError(domain: "ScreenPeers", code: 1, userInfo: [NSLocalizedDescriptionKey: "需要 Python 3.9 或更新版本"])
        }
        let configValue = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config))
        let credentials = try credential ?? CredentialStore.read(config.credential_id)
        var request: [String: Any] = ["config": configValue, "operation": operation, "credential": credentials]
        if let address { request["address"] = address }
        let input = Pipe(), output = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-B", script]
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: request))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return try JSONDecoder().decode(ProviderResult.self, from: data)
    }
}
