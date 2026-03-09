import Foundation

class ProxyManager: ObservableObject {
    static let shared = ProxyManager()

    @Published var best: ProxyEntry?             = nil
    @Published var status: String                = "⏳ Starting…"
    @Published var isReady: Bool                 = false
    @Published var testedCount: Int              = 0
    @Published var workingCount: Int             = 0
    @Published var selectedCountry: String       = "ALL"
    @Published var customServers: [CustomServer] = []
    @Published var proxyCountry: String          = ""
    @Published var isCycling: Bool               = false

    var activeWebProxyIndex: Int       = 0
    var workingWebProxyIndices: [Int]  = []
    var currentCycleIndex: Int         = 0
    private var cycleTimer: Timer?

    let silentAuth = SilentAuthDelegate()

    let webProxies: [WebProxy] = [
        WebProxy(name: "corsproxy.io",  baseURL: "https://corsproxy.io/?",               country: "🇺🇸 USA"),
        WebProxy(name: "allorigins",    baseURL: "https://api.allorigins.win/raw?url=",   country: "🇪🇺 Europe"),
        WebProxy(name: "codetabs",      baseURL: "https://api.codetabs.com/v1/proxy?quest=", country: "🇺🇸 USA"),
        WebProxy(name: "corsproxy.org", baseURL: "https://corsproxy.org/?",              country: "🇪🇺 Europe"),
    ]

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
        }
        if let custom = customServers.first {
            testSingleProxy(proxy: ProxyEntry(ip: custom.ip, port: custom.port), label: custom.name)
            return
        }
        let testTarget = "https://httpbin.org/get"
        var results: [(index: Int, time: TimeInterval)] = []
        let lock = NSLock()
        let group = DispatchGroup()

        for (i, wp) in webProxies.enumerated() {
            guard let encoded = testTarget.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: wp.baseURL + encoded) else { continue }
            group.enter()
            let start = Date()
            var req = URLRequest(url: url)
            req.timeoutInterval = 10
            URLSession.shared.dataTask(with: req) { [weak self] (data: Data?, response: URLResponse?, error: Error?) in
                defer { group.leave() }
                guard let self else { return }
                let elapsed = Date().timeIntervalSince(start)
                DispatchQueue.main.async { self.testedCount += 1 }
                if error != nil {
                    if let err = error { print("❌ \(wp.name): \(err.localizedDescription)") }
                    return
                }
                guard let http = response as? HTTPURLResponse,
                      http.statusCode >= 200 && http.statusCode < 400 else {
                    print("❌ \(wp.name): bad status")
                    return
                }
                print("✅ \(wp.name) \(String(format: "%.2f", elapsed))s")
                lock.lock(); results.append((i, elapsed)); lock.unlock()
                DispatchQueue.main.async { self.workingCount += 1 }
            }.resume()
        }

        group.notify(queue: .global(qos: .userInitiated)) { [weak self] in
            guard let self else { return }
            let sorted = results.sorted { $0.time < $1.time }
            let indices = sorted.map { $0.index }
            DispatchQueue.main.async {
                self.workingWebProxyIndices = indices
                if let first = indices.first {
                    self.activeWebProxyIndex = first
                    self.proxyCountry        = self.webProxies[first].country
                    self.status              = "🛡 \(self.webProxies[first].name) · \(indices.count)/\(self.webProxies.count) working"
                    self.isReady             = true
                } else {
                    self.status  = "❌ No proxy services reachable. Tap 🔄 to retry."
                    self.isReady = false
                }
            }
        }
    }

    // MARK: - Build proxied URL
    func proxiedURL(for realURL: String) -> String {
        let base = webProxies[activeWebProxyIndex].baseURL
        let encoded = realURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? realURL
        return base + encoded
    }

    // MARK: - Cycle through working web proxies
    func cycleToNextProxy() {
        guard !workingWebProxyIndices.isEmpty else { findBestProxy(); return }
        currentCycleIndex += 1
        if currentCycleIndex >= workingWebProxyIndices.count { currentCycleIndex = 0 }
        let next = workingWebProxyIndices[currentCycleIndex]
        DispatchQueue.main.async {
            self.activeWebProxyIndex = next
            self.proxyCountry        = self.webProxies[next].country
            self.isReady             = true
            self.status              = "🔄 Trying \(self.webProxies[next].name) (\(self.currentCycleIndex + 1)/\(self.workingWebProxyIndices.count))"
            print("🔄 Cycled to \(self.webProxies[next].name)")
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

    // MARK: - Custom Servers (uses connectionProxyDictionary)
    func testSingleProxy(proxy: ProxyEntry, label: String) {
        DispatchQueue.main.async { self.status = "⏳ Testing \(label)…"; self.isReady = false }
        let start = Date()
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = proxyDictionary(ip: proxy.ip, port: proxy.port)
        config.timeoutIntervalForRequest  = 12
        config.timeoutIntervalForResource = 12
        let session = URLSession(configuration: config, delegate: silentAuth, delegateQueue: nil)
        var req = URLRequest(url: URL(string: "https://www.google.com/generate_204")!)
        req.timeoutInterval = 12
        session.dataTask(with: req) { [weak self] (data: Data?, response: URLResponse?, error: Error?) in
            let elapsed = Date().timeIntervalSince(start)
            defer { session.invalidateAndCancel() }
            guard let self else { return }
            let success: Bool
            if error != nil {
                success = false
            } else if let http = response as? HTTPURLResponse {
                success = http.statusCode >= 200 && http.statusCode < 400 && http.statusCode != 407 && http.statusCode != 403
            } else {
                success = false
            }
            DispatchQueue.main.async {
                if success {
                    self.best     = proxy
                    self.isReady  = true
                    let t         = String(format: "%.1f", elapsed)
                    self.status   = "🛡 \(label) · \(t)s"
                    self.proxyCountry = ""
                } else {
                    self.status  = "❌ Could not connect to \(label)"
                    self.isReady = false
                }
            }
        }.resume()
    }

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

// MARK: - Web Proxy Service
struct WebProxy {
    let name: String
    let baseURL: String
    let country: String
}
