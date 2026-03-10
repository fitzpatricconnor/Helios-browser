import Foundation

class ProxyManager: ObservableObject {
    static let shared = ProxyManager()
    
    @Published var best: ProxyEntry?        = nil
    @Published var status: String           = "⏳ Starting…"
    @Published var isReady: Bool            = false
    @Published var allProxies: [ProxyEntry] = []
    @Published var testedCount: Int         = 0
    @Published var workingCount: Int        = 0
    @Published var selectedCountry: String  = "ALL"
    @Published var customServers: [CustomServer] = []
    @Published var proxyCountry: String     = ""
    @Published var isCycling: Bool          = false
    
    var workingProxies: [ProxyEntry] = []
    var currentProxyIndex: Int = 0
    private var cycleTimer: Timer?
    
    let silentAuth = SilentAuthDelegate()
    
    // Web proxy services — these are HTTPS APIs that fetch pages for us
    var webProxies: [WebProxy] = [
        WebProxy(name: "corsproxy.io", baseURL: "https://corsproxy.io/?", country: "🇺🇸 USA"),
        WebProxy(name: "allorigins", baseURL: "https://api.allorigins.win/raw?url=", country: "🇪🇺 Europe"),
        WebProxy(name: "codetabs", baseURL: "https://api.codetabs.com/v1/proxy?quest=", country: "🇺🇸 USA"),
        WebProxy(name: "corsproxy.org", baseURL: "https://corsproxy.org/?", country: "🇪🇺 Europe"),
    ]
    var activeWebProxyIndex: Int = 0
    private var workingWebProxyIndices: [Int] = []
    
    init() { loadCustomServers() }
    
    // MARK: - Find best web proxy
    func findBestProxy() {
        stopCycling()
        DispatchQueue.main.async {
            self.status       = "⏳ Testing proxy services…"
            self.isReady      = false
            self.best         = nil
            self.testedCount  = 0
            self.workingCount = 0
            self.proxyCountry = ""
            self.workingProxies = []
            self.workingWebProxyIndices = []
            self.currentProxyIndex = 0
        }
        
        if let custom = customServers.first {
            testSingleProxy(proxy: ProxyEntry(ip: custom.ip, port: custom.port), label: custom.name)
            return
        }
        
        testWebProxies()
    }
    
    // MARK: - Test web proxy services
    private func testWebProxies() {
        let testURL = "https://httpbin.org/get"
        var results: [(index: Int, time: TimeInterval)] = []
        let lock = NSLock()
        let group = DispatchGroup()
        
        DispatchQueue.main.async {
            self.testedCount = 0
            self.workingCount = 0
        }
        
        for (i, wp) in webProxies.enumerated() {
            group.enter()
            let encoded = testURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? testURL
            let proxyURLString = wp.baseURL + encoded
            guard let url = URL(string: proxyURLString) else { group.leave(); continue }
            
            let start = Date()
            var req = URLRequest(url: url)
            req.timeoutInterval = 10
            req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
            
            URLSession.shared.dataTask(with: req) { [weak self] (data: Data?, response: URLResponse?, error: Error?) in
                defer { group.leave() }
                guard let self else { return }
                let elapsed = Date().timeIntervalSince(start)
                DispatchQueue.main.async { self.testedCount += 1 }
                
                if let error = error {
                    print("❌ \(wp.name): \(error.localizedDescription)")
                    return
                }
                if let http = response as? HTTPURLResponse,
                   http.statusCode >= 200 && http.statusCode < 400 {
                    print("✅ \(wp.name): \(String(format: "%.2f", elapsed))s")
                    lock.lock(); results.append((i, elapsed)); lock.unlock()
                    DispatchQueue.main.async { self.workingCount += 1 }
                } else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    print("❌ \(wp.name): HTTP \(code)")
                }
            }.resume()
        }
        
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            if results.isEmpty {
                self.status  = "❌ No proxy services available. Tap 🔄 to retry."
                self.isReady = false
            } else {
                let sorted = results.sorted { $0.time < $1.time }
                guard let best = sorted.first else { return }
                self.workingWebProxyIndices = sorted.map { $0.index }
                self.activeWebProxyIndex = best.index
                let wp = self.webProxies[self.activeWebProxyIndex]
                self.isReady = true
                self.proxyCountry = wp.country
                let t = String(format: "%.1f", best.time)
                self.status = "🛡 \(wp.name) · \(t)s · \(sorted.count)/\(self.webProxies.count) working"
                // Create dummy ProxyEntry for UI compatibility
                self.best = ProxyEntry(ip: wp.name, port: 0)
                self.workingProxies = sorted.compactMap { r in
                    guard r.index < self.webProxies.count else { return nil }
                    return ProxyEntry(ip: self.webProxies[r.index].name, port: 0)
                }
                self.currentProxyIndex = 0
                print("🛡 Best web proxy: \(wp.name) (\(t)s)")
            }
        }
    }
    
    // MARK: - Get the proxied URL for a given real URL
    func proxiedURL(for realURL: String) -> String {
        let wp = webProxies[activeWebProxyIndex]
        let encoded = realURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? realURL
        return wp.baseURL + encoded
    }
    
    // MARK: - Cycle to next working web proxy
    func cycleToNextProxy() {
        guard workingWebProxyIndices.count > 1 else { findBestProxy(); return }
        currentProxyIndex += 1
        if currentProxyIndex >= workingWebProxyIndices.count { currentProxyIndex = 0 }
        activeWebProxyIndex = workingWebProxyIndices[currentProxyIndex]
        let wp = webProxies[activeWebProxyIndex]
        DispatchQueue.main.async {
            self.best = ProxyEntry(ip: wp.name, port: 0)
            self.isReady = true
            self.proxyCountry = wp.country
            self.status = "🔄 Switched to \(wp.name) (\(self.currentProxyIndex + 1)/\(self.workingWebProxyIndices.count))"
            print("🔄 Cycled to \(wp.name)")
        }
    }
    
    func startCycling(reloadAction: @escaping () -> Void) {
        guard !isCycling else { return }
        guard workingWebProxyIndices.count > 1 else { findBestProxy(); return }
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
    
    // MARK: - Traditional proxy test (for custom servers only)
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
                if error == nil, let http = response as? HTTPURLResponse,
                   http.statusCode >= 200 && http.statusCode < 400 {
                    self.best = proxy; self.isReady = true
                    self.workingProxies = [proxy]; self.currentProxyIndex = 0
                    let t = String(format: "%.1f", elapsed)
                    self.status = "🛡 \(label) · \(t)s"
                } else {
                    self.status = "❌ Could not connect to \(label)"; self.isReady = false
                }
            }
        }.resume()
    }
    
    // MARK: - Custom Servers
    func addCustomServer(name: String, ip: String, port: Int) {
        customServers.append(CustomServer(id: UUID(), name: name, ip: ip, port: port)); saveCustomServers()
    }
    func removeCustomServer(_ s: CustomServer) {
        customServers.removeAll { $0.id == s.id }; saveCustomServers(); findBestProxy()
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

// MARK: - Web Proxy model
struct WebProxy {
    let name: String
    let baseURL: String
    let country: String
}
