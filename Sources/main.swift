import AppKit
import UniformTypeIdentifiers
import ServiceManagement
import OSLog

private let logger = Logger(subsystem: "com.screenpeers.app", category: "lifecycle")

@_silgen_name("screenpeers_connections")
func nativeConnections() -> UnsafeMutablePointer<CChar>?

struct DNSObservation: Decodable {
    let hostname: String
    let address: String?
    let publishedAddress: String?
    let sync: String
    let verified: Double?
    let legacyLoaded: Bool
    let error: String?
}

struct Observation: Decodable {
    var peers: [String]?
    let interfaces: [NetworkAddress]
    let dns: DNSObservation?
    var error: String?
}

enum ConnectionReader {
    static func read() -> [String]? {
        guard let buffer = nativeConnections() else { return nil }
        defer { free(buffer) }
        return Set(String(cString: buffer).split(separator: "\n").map {
            $0.hasPrefix("::ffff:") ? String($0.dropFirst(7)) : String($0)
        }).sorted()
    }

    static func parse(_ text: String) -> [String]? {
        guard text.contains("Local Address"), text.contains("Foreign Address") else { return nil }
        let peers = text.split(separator: "\n").compactMap { line -> String? in
            let columns = line.split(whereSeparator: \.isWhitespace)
            guard columns.count >= 6, columns[0].hasPrefix("tcp"),
                  columns[3].hasSuffix(".5900"), columns[5] == "ESTABLISHED",
                  let separator = columns[4].lastIndex(of: ".") else { return nil }
            let address = String(columns[4][..<separator])
            return address.hasPrefix("::ffff:") ? String(address.dropFirst(7)) : address
        }
        return Set(peers).sorted()
    }
}

struct SyncResult: Decodable {
    let success: Bool
    let message: String
}

final class Store {
    var observation: Observation?
    var lastRead: Date?
    var readError: String?
    var syncing = false
    var syncError: String?
    var notes: [String: String] = UserDefaults.standard.dictionary(forKey: "peerNames") as? [String: String] ?? [:]
    var configPath = UserDefaults.standard.string(forKey: "configPath") ?? ""
    var autoSync = UserDefaults.standard.bool(forKey: "autoSync")
    var loginEnabled = SMAppService.mainApp.status == .enabled
    var settingsMessage: String?
    private var timer: Timer?
    private let network = NetworkState()
    private var wakeObserver: NSObjectProtocol?
    private var reconciliationTimer: Timer?
    private var retryWork: DispatchWorkItem?
    private var retryDelay: Double = 15
    private var pendingSync = false
    var configuration: DNSConfiguration?
    var selectedAddress: String?
    private var addresses: [NetworkAddress] = []
    private var publishedAddress: String?
    private var verified: Double?
    var saving = false
    private var reading = false
    private var networkRefresh: DispatchWorkItem?
    private var reconcileOnRefresh = false
    var onUpdate: (() -> Void)?

    var peers: [String]? { readError == nil ? observation?.peers : nil }
    var dns: DNSObservation? { observation?.dns }
    var configured: Bool { configuration != nil }

    init() {
        if !UserDefaults.standard.bool(forKey: "importedNotes") {
            if let suite = UserDefaults.standard.string(forKey: "legacyNotesSuite"),
               let old = UserDefaults(suiteName: suite)?.dictionary(forKey: "VNCPeerNames") as? [String: String] {
                notes.merge(old) { current, _ in current }
                UserDefaults.standard.set(notes, forKey: "peerNames")
            }
            UserDefaults.standard.set(true, forKey: "importedNotes")
        }
    }

    func start() {
        configuration = DNSConfiguration.read(configPath)
        if let configuration, configPath != DNSConfiguration.url.path {
            do {
                try configuration.save()
                configPath = DNSConfiguration.url.path
                UserDefaults.standard.set(configPath, forKey: "configPath")
            } catch { syncError = "无法迁移本地配置，请在设置中保存" }
        }
        network.changed = { [weak self] in self?.scheduleNetworkRefresh() }
        network.start()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.scheduleNetworkRefresh(reconcile: true)
            }
        networkChanged(reconcile: true)
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
        reconciliationTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.networkChanged(reconcile: true)
        }
        reconciliationTimer?.tolerance = 60
    }

    func scheduleNetworkRefresh(reconcile: Bool = false) {
        reconcileOnRefresh = reconcileOnRefresh || reconcile
        networkRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let reconcile = self.reconcileOnRefresh
            self.reconcileOnRefresh = false
            self.networkChanged(reconcile: reconcile)
        }
        networkRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    func networkChanged(reconcile: Bool = false) {
        addresses = NetworkState.addresses()
        let next = NetworkState.selected(addresses, fallback: configuration?.fallback ?? "ethernet")?.address
        let changed = next != selectedAddress
        selectedAddress = next
        refresh()
        if changed || reconcile { synchronize(force: false) }
    }

    func refresh() {
        guard !reading else { return }
        reading = true
        DispatchQueue.global(qos: .utility).async {
            let peers = ConnectionReader.read()
            DispatchQueue.main.async {
                self.reading = false
                self.lastRead = Date()
                self.readError = peers == nil ? "无法读取连接；请尝试重新打开 App" : nil
                let dns = self.configuration.map { cfg in
                    DNSObservation(hostname: cfg.hostname, address: self.selectedAddress,
                        publishedAddress: self.publishedAddress,
                        sync: self.publishedAddress != nil && self.publishedAddress == self.selectedAddress ? "synced" : "pending",
                        verified: self.verified, legacyLoaded: false, error: self.syncError)
                }
                self.observation = Observation(peers: peers, interfaces: self.addresses, dns: dns, error: self.readError)
                self.onUpdate?()
                self.writeHealth()
            }
        }
    }

    func synchronize(force: Bool) {
        guard let cfg = configuration, let address = selectedAddress, force || autoSync, !saving else { return }
        if syncing { pendingSync = true; return }
        syncing = true
        syncError = nil
        retryWork?.cancel()
        onUpdate?()
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try ProviderBridge.run(cfg, operation: "sync", address: address) }
            DispatchQueue.main.async {
                self.syncing = false
                switch result {
                case .success(let value):
                    self.syncError = value.success ? nil : value.message
                    if value.success {
                        self.publishedAddress = value.address
                        self.verified = value.verified
                    }
                case .failure(let error): self.syncError = error.localizedDescription
                }
                self.refresh()
                self.writeHealth()
                if self.pendingSync {
                    self.pendingSync = false
                    self.synchronize(force: force)
                } else if self.syncError != nil && self.autoSync {
                    let retry = DispatchWorkItem { [weak target = self] in target?.synchronize(force: false) }
                    self.retryWork = retry
                    DispatchQueue.main.asyncAfter(deadline: .now() + self.retryDelay, execute: retry)
                    self.retryDelay = min(self.retryDelay * 2, 900)
                } else { self.retryDelay = 15 }
            }
        }
    }

    func saveConfiguration(_ draft: DNSConfiguration, credentials: [String: String]?, completion: @escaping (String?) -> Void) {
        guard !syncing, !saving else { completion("请等待当前更新完成"); return }
        saving = true
        onUpdate?()
        let oldID = configuration?.credential_id ?? ""
        DispatchQueue.global(qos: .utility).async {
            var cfg = draft
            var newID: String?
            let result = Result { () -> ProviderResult in
                let checked = try ProviderBridge.run(cfg, operation: "probe", address: nil, credential: credentials)
                guard checked.success, let id = checked.record_id else {
                    throw NSError(domain: "ScreenPeers", code: 1, userInfo: [NSLocalizedDescriptionKey: checked.message])
                }
                cfg.record_id = id
                if let credentials, !credentials.isEmpty {
                    let id = UUID().uuidString
                    try CredentialStore.save(credentials, id: id)
                    newID = id
                    cfg.credential_id = id
                    cfg.profile = nil; cfg.tccli = nil
                }
                try cfg.save()
                return checked
            }
            DispatchQueue.main.async {
                self.saving = false
                switch result {
                case .success(let value):
                    self.configuration = cfg
                    self.configPath = DNSConfiguration.url.path
                    UserDefaults.standard.set(self.configPath, forKey: "configPath")
                    if oldID != cfg.credential_id { CredentialStore.remove(oldID) }
                    self.publishedAddress = value.address
                    self.verified = value.verified
                    self.syncError = nil
                    self.networkChanged()
                    if self.autoSync { self.synchronize(force: false) }
                    completion(nil)
                case .failure(let error):
                    if let newID { CredentialStore.remove(newID) }
                    completion(error.localizedDescription)
                }
                self.onUpdate?()
            }
        }
    }

    private func writeHealth() {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/com.screenpeers.app")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let value: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier,
            "readAt": lastRead?.timeIntervalSince1970 ?? 0, "sourceCount": peers?.count ?? -1,
            "autoSync": autoSync, "syncing": syncing, "configured": configured,
            "dnsStatus": dns?.sync ?? "unconfigured", "verified": dns?.verified ?? 0,
            "legacyLoaded": dns?.legacyLoaded ?? false, "loginEnabled": loginEnabled,
            "readError": readError ?? "", "syncError": syncError ?? ""]
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("health.json"), options: .atomic)
        }
    }

    func setAutoSync(_ enabled: Bool) {
        autoSync = enabled
        UserDefaults.standard.set(enabled, forKey: "autoSync")
        if enabled { synchronize(force: false) }
        else { retryWork?.cancel(); pendingSync = false }
    }

    func chooseConfig() {
        let panel = NSOpenPanel()
        panel.title = "选择域名配置"
        panel.message = "选择已保存的域名配置文件。"
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            configPath = url.path
            UserDefaults.standard.set(configPath, forKey: "configPath")
            setAutoSync(false)
            configuration = DNSConfiguration.read(configPath)
            observation = nil
            syncError = nil
            networkChanged()
        }
    }

    func clearConfig() {
        setAutoSync(false)
        configPath = ""
        configuration = nil
        UserDefaults.standard.removeObject(forKey: "configPath")
        syncError = nil
        observation = nil
        refresh()
    }

    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            settingsMessage = SMAppService.mainApp.status == .requiresApproval ? "请在系统设置 → 登录项中允许 ScreenPeers。" : nil
        } catch { settingsMessage = "登录启动设置失败：\(error.localizedDescription)" }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func editNote(_ address: String) {
        let alert = NSAlert()
        alert.messageText = "备注连接来源"
        alert.informativeText = "\(address)\n留空保存即可清除备注。"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 290, height: 25))
        input.stringValue = notes[address] ?? ""
        input.placeholderString = "例如：工作笔记本"
        alert.accessoryView = input
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = input
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        notes[address] = value.isEmpty ? nil : value
        UserDefaults.standard.set(notes, forKey: "peerNames")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let store = Store()
    var item: NSStatusItem!
    private var editor: DNSSettingsEditor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("ScreenPeers launching")
        let mainMenu = NSMenu()
        let applicationMenu = NSMenu()
        applicationMenu.addItem(withTitle: "退出 ScreenPeers", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let applicationItem = mainMenu.addItem(withTitle: "ScreenPeers", action: nil, keyEquivalent: "")
        applicationItem.submenu = applicationMenu
        let editMenu = NSMenu(title: "编辑")
        for (title, selector, key) in [
            ("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"),
            ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: NSSelectorFromString(selector), keyEquivalent: key)
        }
        mainMenu.addItem(withTitle: "编辑", action: nil, keyEquivalent: "").submenu = editMenu
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        mainMenu.addItem(withTitle: "窗口", action: nil, keyEquivalent: "").submenu = windowMenu
        NSApp.mainMenu = mainMenu
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        store.onUpdate = { [weak self] in self?.updateStatus(); self?.updateSettings() }
        updateStatus()
        store.start()
        if CommandLine.arguments.contains("--enable-login") { store.setLogin(true) }
        if CommandLine.arguments.contains("--show-settings") { showSettings() }
    }

    func updateStatus() {
        guard let button = item.button else { return }
        let count = store.peers?.count ?? 0
        let symbol = store.peers == nil ? "exclamationmark.circle" : count > 0 ? "display.and.arrow.down" : "display"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "ScreenPeers")
        image?.size = NSSize(width: 21, height: 18)
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageLeading
        button.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        button.title = count > 0 ? String(count) : ""
        button.toolTip = store.peers.map { "ScreenPeers · \($0.count) 个 VNC 连接来源" } ?? "ScreenPeers · 连接状态未知"
        button.setAccessibilityLabel(button.toolTip ?? "ScreenPeers")
    }

    @discardableResult
    private func action(_ title: String, in menu: NSMenu, selector: Selector, value: String? = nil) -> NSMenuItem {
        let row = menu.addItem(withTitle: title, action: selector, keyEquivalent: "")
        row.target = self
        row.representedObject = value
        return row
    }

    private func copyRow(_ text: String, in menu: NSMenu) {
        let row = action(text, in: menu, selector: #selector(copyAddress(_:)), value: text)
        row.toolTip = "点击复制完整地址"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: "本机连接地址", action: nil, keyEquivalent: "")
        let address = store.dns?.address
            ?? store.observation?.interfaces.first(where: { $0.primary })?.address
            ?? store.observation?.interfaces.first?.address
        if let address { copyRow("\(address):5900", in: menu) }
        else { menu.addItem(withTitle: "暂时无法读取本机 IP", action: nil, keyEquivalent: "") }
        if let dns = store.dns, !dns.hostname.isEmpty { copyRow("\(dns.hostname):5900", in: menu) }

        if store.configured {
            if store.syncing {
                menu.addItem(withTitle: "域名正在更新…", action: nil, keyEquivalent: "")
            } else if store.dns?.legacyLoaded == true {
                menu.addItem(withTitle: "域名由旧后台维护", action: nil, keyEquivalent: "")
            } else if store.syncError != nil || store.dns?.error != nil {
                action("域名更新失败…", in: menu, selector: #selector(showSyncError))
            } else if store.dns?.sync == "synced" {
                let row = menu.addItem(withTitle: "域名已更新", action: nil, keyEquivalent: "")
                row.toolTip = store.dns?.verified.map { "上次确认：" + Date(timeIntervalSince1970: $0).formatted() }
            } else if store.dns?.address == nil {
                menu.addItem(withTitle: "域名等待网络连接", action: nil, keyEquivalent: "")
            } else {
                action("域名待更新 · 点击更新", in: menu, selector: #selector(syncNow))
            }
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: "VNC 连入设备", action: nil, keyEquivalent: "")
        if let peers = store.peers, !peers.isEmpty {
            for ip in peers {
                let title = store.notes[ip].map { "\($0)（\(ip)）" } ?? ip
                let row = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
                let actions = NSMenu()
                action("复制 IP 地址", in: actions, selector: #selector(copyAddress(_:)), value: ip)
                action(store.notes[ip] == nil ? "添加备注…" : "编辑备注…", in: actions,
                       selector: #selector(editNote(_:)), value: ip)
                row.submenu = actions
            }
        } else {
            menu.addItem(withTitle: store.peers == nil ? "暂时无法读取 VNC 连接" : "当前无 VNC 设备连入",
                         action: nil, keyEquivalent: "")
        }

        menu.addItem(.separator())
        action("设置…", in: menu, selector: #selector(showSettings))
        action("退出 ScreenPeers", in: menu, selector: #selector(quit))
    }

    @objc func copyAddress(_ sender: NSMenuItem) {
        if let text = sender.representedObject as? String { store.copy(text) }
    }
    @objc func editNote(_ sender: NSMenuItem) {
        if let ip = sender.representedObject as? String { store.editNote(ip) }
    }
    @objc func syncNow() { store.synchronize(force: true); updateSettings() }
    @objc func refresh() { store.refresh() }
    @objc func toggleAutoSync() { store.setAutoSync(!store.autoSync); updateSettings() }
    @objc func toggleLogin() {
        store.setLogin(!store.loginEnabled)
        updateSettings()
        if let message = store.settingsMessage { notice("登录时启动", message) }
    }
    @objc func chooseConfig() { NSApp.activate(ignoringOtherApps: true); store.chooseConfig(); updateSettings() }
    @objc func showSyncError() {
        notice("域名更新失败", store.syncError ?? store.dns?.error ?? "请重试。")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    @objc func showSettings() {
        if editor == nil {
            editor = DNSSettingsEditor(store: store)
            editor?.onClose = { [weak self] in self?.editor = nil }
        }
        editor?.show()
    }

    private func updateSettings() { editor?.updateStatus() }
    private func notice(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
    @objc func quit() { NSApp.terminate(nil) }
}

if CommandLine.arguments.contains("--parse-peers") {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let text = String(data: data, encoding: .utf8), let peers = ConnectionReader.parse(text) else { exit(1) }
    peers.forEach { print($0) }
    exit(0)
}

if CommandLine.arguments.contains("--list") {
    guard let peers = ConnectionReader.read() else { print("Connection state unavailable"); exit(1) }
    print("\(peers.count) source(s)")
    peers.forEach { print($0) }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
