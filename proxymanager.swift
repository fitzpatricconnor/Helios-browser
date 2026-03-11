import Foundation

class ProxyManager: ObservableObject {
    static let shared = ProxyManager()
    
    @Published var status: String           = "📡 Direct"
    @Published var isReady: Bool            = true
    @Published var isDirectMode: Bool       = true
    @Published var best: ProxyEntry?        = nil
    @Published var testedCount: Int         = 0
    @Published var workingCount: Int        = 0
    @Published var customServers: [CustomServer] = []
    @Published var proxyCountry: String     = ""
    @Published var isCycling: Bool          = false
    
    var workingProxies: [ProxyEntry] = []
    var currentProxyIndex: Int = 0
    private var cycleTimer: Timer?
    
    let silentAuth = SilentAuthDelegate()
    
    init() {
        loadCustomServers()
        isDirectMode = UserDefaults.standard.object(forKey: "orion_direct_mode") as? Bool ?? true
        if isDirectMode {
            status = "📡 Direct"
            isReady = true
        }
    }
    
    // MARK: - Direct Mode
    func enableDirectMode() {
        stopCycling()
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
            enableDirectMode()
            return
        }
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
        if customServers.isEmpty { enableDirectMode() } else { findBestProxy() }
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
