import Foundation

class ProxyManager: ObservableObject {
    static let shared = ProxyManager()
    
    @Published var status: String           = "🌐 Web Proxy"
    @Published var isReady: Bool            = true
    @Published var isDirectMode: Bool       = false
    @Published var best: ProxyEntry?        = nil
    @Published var testedCount: Int         = 0
    @Published var workingCount: Int        = 0
    @Published var customServers: [CustomServer] = []
    @Published var proxyCountry: String     = ""
    @Published var isCycling: Bool          = false
    
    var workingProxies: [ProxyEntry] = []
    var currentProxyIndex: Int = 0
    private var cycleTimer: Timer?
    private var webProxyRetryAttempt: Int = 0
    private var pendingWebProxyRetry: DispatchWorkItem?
    private let activeWebProxyIndexKey = "orion_active_web_proxy_index"
    private let maxWebProxyRetryAttempts = 3
    private let webProxyRetryBaseDelaySeconds = 0.8
    private let maxWebProxyRetryDelaySeconds = 3.0
    
    let silentAuth = SilentAuthDelegate()
    
    // MARK: - Web Proxy Services
    let webProxies: [WebProxy] = [
        WebProxy(name: "corsproxy.io",  baseURL: "https://corsproxy.io/?",                  country: "🌐"),
        WebProxy(name: "allorigins",    baseURL: "https://api.allorigins.win/raw?url=",       country: "🌐"),
        WebProxy(name: "codetabs",      baseURL: "https://api.codetabs.com/v1/proxy?quest=",  country: "🌐"),
        WebProxy(name: "corsproxy.org", baseURL: "https://corsproxy.org/?",                  country: "🌐"),
    ]
    @Published var activeWebProxyIndex: Int = 0
    private let webProxyQueryAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=?+#")
        return set
    }()
    
    private func clampedWebProxyIndex(_ index: Int) -> Int {
        guard !webProxies.isEmpty else { return 0 }
        if index < 0 { return 0 }
        if index >= webProxies.count { return webProxies.count - 1 }
        return index
    }
    
    private func persistActiveWebProxyIndex() {
        UserDefaults.standard.set(activeWebProxyIndex, forKey: activeWebProxyIndexKey)
    }
    
    var activeWebProxy: WebProxy {
        webProxies[clampedWebProxyIndex(activeWebProxyIndex)]
    }
    
    func proxiedURL(for urlString: String) -> String {
        let encoded = urlString.addingPercentEncoding(withAllowedCharacters: webProxyQueryAllowed) ?? urlString
        return activeWebProxy.baseURL + encoded
    }
    
    var activeWebProxyName: String {
        webProxies.isEmpty ? "web proxy" : activeWebProxy.name
    }
    
    init() {
        loadCustomServers()
        activeWebProxyIndex = clampedWebProxyIndex(UserDefaults.standard.integer(forKey: activeWebProxyIndexKey))
        // Always default to web proxy mode — never direct
        isDirectMode = false
        status = "🌐 \(activeWebProxyName)"
        isReady = true
    }
    
    // MARK: - Direct Mode
    func enableDirectMode() {
        stopCycling()
        resetWebProxyRetries()
        DispatchQueue.main.async {
            self.isDirectMode = true
            self.isReady = true
            self.best = nil
            self.status = "📡 Direct"
            self.proxyCountry = ""
            UserDefaults.standard.set(true, forKey: "orion_direct_mode")
        }
    }
    
    // MARK: - Find best proxy (custom servers only)
    func findBestProxy() {
        if customServers.isEmpty {
            // No custom servers — use web proxy mode instead of direct
            resetWebProxyRetries()
            DispatchQueue.main.async {
                self.isDirectMode = false
                self.isReady = true
                self.best = nil
                self.status = "🌐 \(self.activeWebProxyName)"
                UserDefaults.standard.set(false, forKey: "orion_direct_mode")
            }
            return
        }
        resetWebProxyRetries()
        stopCycling()
        DispatchQueue.main.async {
            self.isDirectMode = false
            self.status       = "⏳ Testing proxy…"
            self.isReady      = false
            self.best         = nil
            self.testedCount  = 0
            self.workingCount = 0
            self.proxyCountry = ""
            self.workingProxies = []
            self.currentProxyIndex = 0
            UserDefaults.standard.set(false, forKey: "orion_direct_mode")
        }
        if let custom = customServers.first {
            testSingleProxy(proxy: ProxyEntry(ip: custom.ip, port: custom.port), label: custom.name)
        }
    }
    
    func cycleToNextProxy() {
        guard !workingProxies.isEmpty else { enableDirectMode(); return }
        currentProxyIndex += 1
        if currentProxyIndex >= workingProxies.count { currentProxyIndex = 0 }
        let next = workingProxies[currentProxyIndex]
        DispatchQueue.main.async {
            self.best    = next
            self.isReady = true
            self.status  = "🔄 Trying \(next.label) (\(self.currentProxyIndex + 1)/\(self.workingProxies.count))"
            print("🔄 Cycled to proxy \(self.currentProxyIndex + 1)/\(self.workingProxies.count): \(next.label)")
        }
        lookupCountry(ip: next.ip)
    }
    
    func startCycling(reloadAction: @escaping () -> Void) {
        guard !isCycling else { return }
        guard workingProxies.count > 1 else { return }
        DispatchQueue.main.async { self.isCycling = true }
        cycleToNextProxy()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { reloadAction() }
        DispatchQueue.main.async {
            self.cycleTimer?.invalidate()
            self.cycleTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: true) { [weak self] _ in
                guard let self, self.isCycling else { return }
                self.cycleToNextProxy()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { reloadAction() }
            }
        }
    }
    
    func stopCycling() {
        DispatchQueue.main.async {
            self.isCycling = false
            self.cycleTimer?.invalidate()
            self.cycleTimer = nil
        }
    }
    
    private func resetWebProxyRetries() {
        webProxyRetryAttempt = 0
        pendingWebProxyRetry?.cancel()
        pendingWebProxyRetry = nil
    }
    
    private var isWebProxyRetryAllowed: Bool {
        !isDirectMode && best == nil && webProxies.count > 1
    }
    
    @discardableResult
    func switchToNextWebProxy(manual: Bool, completion: (() -> Void)? = nil) -> Bool {
        guard webProxies.count > 1 else {
            DispatchQueue.main.async {
                self.isReady = false
                self.status = "❌ No alternate web proxy available"
            }
            return false
        }
        let applySwitch = {
            self.stopCycling()
            self.isDirectMode = false
            self.best = nil
            self.isReady = true
            self.activeWebProxyIndex = (self.activeWebProxyIndex + 1) % self.webProxies.count
            self.persistActiveWebProxyIndex()
            self.status = manual ? "🔀 Switched to \(self.activeWebProxyName)" : "🔄 Trying \(self.activeWebProxyName)…"
            UserDefaults.standard.set(false, forKey: "orion_direct_mode")
            completion?()
        }
        if Thread.isMainThread {
            applySwitch()
        } else {
            DispatchQueue.main.async(execute: applySwitch)
        }
        return true
    }
    
    @discardableResult
    func scheduleWebProxyRetry(reloadAction: @escaping () -> Void, onScheduled: ((String) -> Void)? = nil) -> Bool {
        guard isWebProxyRetryAllowed else { return false }
        // Retry at most one pass across alternates, excluding the current proxy.
        let maxAttempts = min(maxWebProxyRetryAttempts, webProxies.count - 1)
        guard maxAttempts > 0 else { return false }
        let nextAttempt = webProxyRetryAttempt + 1
        guard nextAttempt <= maxAttempts else {
            resetWebProxyRetries()
            DispatchQueue.main.async {
                self.status = "❌ \(self.activeWebProxyName) failed"
            }
            return false
        }
        
        pendingWebProxyRetry?.cancel()
        webProxyRetryAttempt = nextAttempt
        let backoffMultiplier = pow(2.0, Double(nextAttempt - 1))
        let delay = min(backoffMultiplier * webProxyRetryBaseDelaySeconds, maxWebProxyRetryDelaySeconds)
        
        DispatchQueue.main.async {
            self.isReady = false
            self.status = "🔄 \(self.activeWebProxyName) failed — retrying (\(nextAttempt)/\(maxAttempts))"
            onScheduled?("🔄 \(self.activeWebProxyName) failed — switching web proxy…")
        }
        
        let retryWork = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let switched = self.switchToNextWebProxy(manual: false) {
                reloadAction()
            }
            if !switched {
                DispatchQueue.main.async {
                    self.status = "❌ No alternate web proxy available"
                    self.isReady = false
                }
            }
        }
        pendingWebProxyRetry = retryWork
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: retryWork)
        return true
    }
    
    func markWebProxySuccess() {
        guard !isDirectMode, best == nil else { return }
        resetWebProxyRetries()
        DispatchQueue.main.async {
            self.isReady = true
            self.status = "🌐 \(self.activeWebProxyName)"
        }
    }
    
    func lookupCountry(ip: String) {
        // ip-api.com free tier requires HTTP; HTTPS needs a paid key.
        // This lookup is purely cosmetic (country flag display) and the IP
        // is already known to the proxy server being connected to.
        guard let url = URL(string: "http://ip-api.com/json/\(ip)?fields=country,countryCode,city") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] (data: Data?, response: URLResponse?, error: Error?) in
            guard let self, let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let country = json["country"] as? String,
                  let code = json["countryCode"] as? String else { return }
            let city = json["city"] as? String ?? ""
            let flag = self.flagEmoji(code)
            DispatchQueue.main.async {
                self.proxyCountry = city.isEmpty ? "\(flag) \(country)" : "\(flag) \(city), \(country)"
            }
        }.resume()
    }
    
    private func flagEmoji(_ code: String) -> String {
        let base: UInt32 = 127397
        var emoji = ""
        for scalar in code.uppercased().unicodeScalars {
            if let flag = Unicode.Scalar(base + scalar.value) {
                emoji.append(String(flag))
            }
        }
        return emoji
    }
    
    // MARK: - Test single proxy (for custom servers)
    func testSingleProxy(proxy: ProxyEntry, label: String) {
        resetWebProxyRetries()
        DispatchQueue.main.async { self.status = "⏳ Testing \(label)…"; self.isReady = false }
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = proxyDictionary(ip: proxy.ip, port: proxy.port)
        config.timeoutIntervalForRequest = 12
        config.timeoutIntervalForResource = 12
        let session = URLSession(configuration: config, delegate: silentAuth, delegateQueue: nil)
        var req = URLRequest(url: URL(string: "https://www.google.com/generate_204")!)
        req.timeoutInterval = 12
        let start = Date()
        session.dataTask(with: req) { [weak self] (data: Data?, response: URLResponse?, error: Error?) in
            let elapsed = Date().timeIntervalSince(start)
            defer { session.invalidateAndCancel() }
            guard let self else { return }
            DispatchQueue.main.async {
                self.isDirectMode = false
                UserDefaults.standard.set(false, forKey: "orion_direct_mode")
                if error == nil, let http = response as? HTTPURLResponse,
                   http.statusCode >= 200 && http.statusCode < 400 {
                    self.best = proxy; self.isReady = true
                    self.workingProxies = [proxy]; self.currentProxyIndex = 0
                    self.testedCount = 1; self.workingCount = 1
                    let t = String(format: "%.1f", elapsed)
                    self.status = "🛡 \(label) · \(t)s"
                    self.lookupCountry(ip: proxy.ip)
                } else {
                    self.status = "❌ Could not connect to \(label)"
                    self.isReady = false
                }
            }
        }.resume()
    }
    
    // MARK: - Custom Servers
    func addCustomServer(name: String, ip: String, port: Int) {
        customServers.append(CustomServer(id: UUID(), name: name, ip: ip, port: port)); saveCustomServers()
    }
    func removeCustomServer(_ s: CustomServer) {
        customServers.removeAll { $0.id == s.id }; saveCustomServers()
        findBestProxy()
    }
    func useCustomServer(_ s: CustomServer) {
        testSingleProxy(proxy: ProxyEntry(ip: s.ip, port: s.port), label: s.name)
    }
    private func saveCustomServers() {
        if let d = try? JSONEncoder().encode(customServers) {
            UserDefaults.standard.set(d, forKey: "orion_custom_servers")
        }
    }
    private func loadCustomServers() {
        if let d = UserDefaults.standard.data(forKey: "orion_custom_servers"),
           let s = try? JSONDecoder().decode([CustomServer].self, from: d) { customServers = s }
    }
}
