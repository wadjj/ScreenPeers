import AppKit

final class DNSSettingsEditor: NSObject, NSWindowDelegate {
    let store: Store
    var onClose: (() -> Void)?
    private var window: NSWindow!
    private let provider = NSPopUpButton()
    private let domain = NSTextField()
    private let host = NSTextField()
    private let record = NSTextField()
    private let accessID = NSTextField()
    private let secret = NSSecureTextField()
    private let executable = NSTextField()
    private let fallback = NSPopUpButton()
    private let message = NSTextField(wrappingLabelWithString: "")
    private var login: NSButton!
    private var automatic: NSButton!
    private var save: NSButton!
    private var sync: NSButton!
    private var credentialRows: [NSView] = []
    private var adapterRow: NSView!
    private var accountHint = NSTextField(wrappingLabelWithString: "")
    private var loaded: DNSConfiguration?

    init(store: Store) {
        self.store = store
        super.init()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 530, height: 595),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "ScreenPeers 设置"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 22)])
        func heading(_ title: String) {
            let label = NSTextField(labelWithString: title)
            label.font = .boldSystemFont(ofSize: 13)
            stack.addArrangedSubview(label)
        }
        @discardableResult func row(_ title: String, _ control: NSView) -> NSView {
            let label = NSTextField(labelWithString: title)
            label.widthAnchor.constraint(equalToConstant: 100).isActive = true
            let row = NSStackView(views: [label, control])
            row.orientation = .horizontal; row.spacing = 10; row.alignment = .centerY
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            control.setContentHuggingPriority(.defaultLow, for: .horizontal)
            if let field = control as? NSTextField { field.setAccessibilityLabel(title) }
            control.setAccessibilityLabel(title)
            return row
        }
        heading("通用")
        login = NSButton(checkboxWithTitle: "登录时启动", target: self, action: #selector(toggleLogin))
        stack.addArrangedSubview(login)
        heading("域名更新")
        provider.addItems(withTitles: ["腾讯云 DNSPod", "阿里云 DNS", "自定义"])
        provider.target = self; provider.action = #selector(providerChanged)
        row("服务商", provider)
        domain.placeholderString = "example.com"
        host.placeholderString = "mac 或 @"
        record.placeholderString = "自动识别；多条同名记录时填写"
        row("域名", domain); row("主机记录", host); row("记录 ID", record)
        accessID.placeholderString = "SecretId / AccessKey ID"
        secret.placeholderString = "SecretKey / AccessKey Secret"
        credentialRows = [row("账户 ID", accessID), row("账户密钥", secret)]
        accountHint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(accountHint)
        executable.placeholderString = "选择本地可执行文件"
        let choose = NSButton(title: "选择…", target: self, action: #selector(chooseAdapter))
        let adapter = NSStackView(views: [executable, choose])
        adapter.orientation = .horizontal
        adapterRow = row("适配器", adapter)
        fallback.addItems(withTitles: ["以太网优先，其次 Wi-Fi", "Wi-Fi 优先，其次以太网"])
        row("备用规则", fallback)
        let detail = NSTextField(wrappingLabelWithString: "默认跟随系统主网络，仅在无法确定时使用备用规则。\nIP 变化后自动更新，每小时核对一次域名记录。")
        detail.textColor = .secondaryLabelColor
        stack.addArrangedSubview(detail)
        detail.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        automatic = NSButton(checkboxWithTitle: "自动更新域名", target: self, action: #selector(toggleAutomatic))
        stack.addArrangedSubview(automatic)
        save = NSButton(title: "测试并保存", target: self, action: #selector(saveConfiguration))
        sync = NSButton(title: "立即更新", target: self, action: #selector(syncNow))
        let tutorial = NSButton(title: "接入指南", target: self, action: #selector(openGuide))
        let actions = NSStackView(views: [save, sync, tutorial])
        actions.orientation = .horizontal; actions.spacing = 10
        stack.addArrangedSubview(actions)
        message.textColor = .secondaryLabelColor
        stack.addArrangedSubview(message)
        message.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        window.center()
        load()
    }

    private func load() {
        loaded = store.configuration
        let cfg = loaded ?? DNSConfiguration()
        provider.selectItem(at: ["dnspod", "aliyun", "custom"].firstIndex(of: cfg.provider) ?? 0)
        domain.stringValue = cfg.domain
        host.stringValue = cfg.subdomain
        record.stringValue = cfg.record_id
        executable.stringValue = cfg.executable
        fallback.selectItem(at: cfg.fallback == "wifi" ? 1 : 0)
        accessID.stringValue = ""; secret.stringValue = ""
        providerChanged()
    }

    @objc private func providerChanged() {
        let custom = provider.indexOfSelectedItem == 2
        credentialRows.forEach { $0.isHidden = custom }
        adapterRow.isHidden = !custom
        accountHint.stringValue = custom ? "由适配器管理服务商账户，协议与示例见接入指南。" :
            (loaded?.provider == providerID && (loaded?.profile != nil || loaded?.credential_id.isEmpty == false)
             ? "已保存账户；密钥留空可继续使用，填写两项可更换。" : "账户密钥仅保存在本机钥匙串。")
    }
    private var providerID: String { ["dnspod", "aliyun", "custom"][provider.indexOfSelectedItem] }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    func show() {
        updateStatus()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func updateStatus() {
        login.state = store.loginEnabled ? .on : .off
        automatic.state = store.autoSync ? .on : .off
        automatic.isEnabled = store.configured && !store.saving
        save.isEnabled = !store.syncing && !store.saving
        sync.isEnabled = store.configured && !store.syncing && !store.saving
        if store.saving { message.stringValue = "正在测试账户和记录…" }
        else if store.syncing { message.stringValue = "正在更新…" }
        else if let error = store.syncError { message.stringValue = error }
        else if message.stringValue.isEmpty || message.stringValue == "正在更新…" {
            if store.dns?.sync == "synced" {
                let time = store.dns?.verified.map { Date(timeIntervalSince1970: $0).formatted(date: .omitted, time: .shortened) } ?? ""
                message.stringValue = "已更新 · " + time
            } else { message.stringValue = store.configured ? "等待网络更新" : "填写后测试并保存" }
        }
    }
    @objc private func toggleLogin() { store.setLogin(login.state == .on); updateStatus() }
    @objc private func toggleAutomatic() { store.setAutoSync(automatic.state == .on); updateStatus() }
    @objc private func syncNow() { store.synchronize(force: true) }
    @objc private func chooseAdapter() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.title = "选择自定义 DNS 适配器"
        if panel.runModal() == .OK, let url = panel.url { executable.stringValue = url.path }
    }
    @objc private func openGuide() {
        if let url = Bundle.main.url(forResource: "DNS-SETUP", withExtension: "md") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc private func saveConfiguration() {
        var cfg = DNSConfiguration()
        cfg.provider = providerID
        cfg.domain = domain.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        cfg.subdomain = host.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        cfg.record_id = record.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        cfg.executable = executable.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        cfg.fallback = fallback.indexOfSelectedItem == 1 ? "wifi" : "ethernet"
        var credentials: [String: String]?
        if cfg.provider != "custom" {
            if !accessID.stringValue.isEmpty && !secret.stringValue.isEmpty {
                credentials = ["access_id": accessID.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                               "secret": secret.stringValue]
            } else if accessID.stringValue.isEmpty && secret.stringValue.isEmpty && loaded?.provider == cfg.provider {
                cfg.credential_id = loaded?.credential_id ?? ""
                cfg.profile = loaded?.profile; cfg.tccli = loaded?.tccli
            } else { message.stringValue = "请填写账户 ID 和密钥"; return }
        } else { credentials = [:] }
        store.saveConfiguration(cfg, credentials: credentials) { [weak self] error in
            guard let self else { return }
            if let error { self.message.stringValue = error }
            else { self.load(); self.message.stringValue = "已保存 · " + cfg.hostname }
        }
    }
}
