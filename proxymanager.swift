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
    
    init() { loadCustomServers() }
    
    func findBestProxy() {
        DispatchQueue.main.async {
            self.status       = "⏳ Fetching proxies…"
            self.isReady      = false
            self.best         = nil
            self.testedCount  = 0
            self.workingCount = 0
            self.allProxies   = []
        }
        if let custom = customServers.first {
            testSingleProxy(proxy: ProxyEntry(ip: custom.ip, port: custom.port), label: custom.name)
            return
        }
        fetchProxies()
    }
    
    // MARK: - Fetch proxy lists
    private func fetchProxies() {
        let sources = [
            "https://raw.githubusercontent.com/TheSpeedX/PROXY-List/master/http.txt",
            "https://raw.githubusercontent.com/clarketm/proxy-list/master/proxy-list-raw.txt",
            "https://raw.githubusercontent.com/monosans/proxy-list/main/proxies/http.txt",
            "https://raw.githubusercontent.com/ShiftyTR/Proxy-List/master/http.txt"
        ]
        
        let group   = DispatchGroup()
        var all     = [ProxyEntry]()
        let lock    = NSLock()
        var fetched = 0
        
        DispatchQueue.main.async { self.status = "⏳ Fetching proxy lists…" }
        
        for urlStr in sources {
            guard let url = URL(string: urlStr) else { continue }
            group.enter()
            var req = URLRequest(url: url)
            req.timeoutInterval = 12
            URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
                defer { group.leave() }
                guard let self else { return }
                if let error { print("❌ \(url.host ?? "?"): \(error.localizedDescription)"); return }
                guard let data else { return }
                let parsed = self.parseTextList(data: data)
                print("📡 \(url.host ?? "?"): \(parsed.count) proxies")
                lock.lock(); all.append(contentsOf: parsed); fetched += parsed.count; lock.unlock()
                DispatchQueue.main.async { self.status = "⏳ Collected \(fetched) proxies…" }
            }.resume()
        }
        
        group.notify(queue: .global(qos: .userInitiated)) { [weak self] in
            guard let self else { return }
            var seen   = Set<String>()
            var unique = [ProxyEntry]()
            for p in all where !seen.contains(p.label) { seen.insert(p.label); unique.append(p) }
            print("🔢 Unique: \(unique.count)")
            if unique.isEmpty {
                DispatchQueue.main.async {
                    self.status  = "❌ No proxies fetched."
                    self.isReady = false
                }
                return
            }
            let capped = Array(unique.shuffled().prefix(80))
            DispatchQueue.main.async {
                self.allProxies   = capped
                self.status       = "⚡ Testing \(capped.count) proxies…"
                self.testedCount  = 0
                self.workingCount = 0
            }
            self.speedTest(proxies: capped)
        }
    }
    
    // MARK: - Parse text list
    private func parseTextList(data: Data) -> [ProxyEntry] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.components(separatedBy: .newlines).compactMap { line -> ProxyEntry? in
            let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: " ").first ?? ""
            let parts = clean.split(separator: ":")
            guard parts.count == 2,
                  let port = Int(parts[1]),
                  port > 0, port < 65536,
                  String(parts[0]).split(separator: ".").count == 4
            else { return nil }
            return ProxyEntry(ip: String(parts[0]), port: port)
        }
    }
    
    // MARK: - Test single proxy (HTTPS test URL — fixes ATS blocking)
    func testSingleProxy(proxy: ProxyEntry, label: String) {
        DispatchQueue.main.async { self.status = "⏳ Testing \(label)…"; self.isReady = false }
        
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: 1,
            kCFNetworkProxiesHTTPProxy  as String: proxy.ip,
            kCFNetworkProxiesHTTPPort   as String: proxy.port
        ]
        config.timeoutIntervalForRequest  = 10
        config.timeoutIntervalForResource = 15
        
        // Use HTTPS so ATS does not block it
        let testURL = URL(string: "https://www.google.com")!
        let session = URLSession(configuration: config)
        var req = URLRequest(url: testURL)
        req.timeoutInterval = 10
        
        session.dataTask(with: req) { [weak self] _, response, error in
            guard let self else { return }
            DispatchQueue.main.async {
                if let error {
                    self.status  = "❌ Could not connect to \(label)"
                    self.isReady = false
                    print("❌ \(proxy.label): \(error.localizedDescription)")
                } else if let http = response as? HTTPURLResponse {
                    self.best    = proxy
                    self.isReady = true
                    self.status  = "🛡 \(label) · HTTP \(http.statusCode)"
                    print("✅ \(proxy.label) ready HTTP \(http.statusCode)")
                }
            }
            session.invalidateAndCancel()
        }.resume()
    }
    
    // MARK: - Speed test (HTTPS test URL — fixes ATS blocking)
    private func speedTest(proxies: [ProxyEntry]) {
        var results = [(proxy: ProxyEntry, time: TimeInterval)]()
        let lock    = NSLock()
        let group   = DispatchGroup()
        
        // HTTPS so ATS allows it
        let testURL = URL(string: "https://www.google.com")!
        let batches = stride(from: 0, to: proxies.count, by: 10).map {
            Array(proxies[$0..<min($0 + 10, proxies.count)])
        }
        
        for (bi, batch) in batches.enumerated() {
            let bg = DispatchGroup()
            for proxy in batch {
                bg.enter(); group.enter()
                let start  = Date()
                let config = URLSessionConfiguration.ephemeral
                config.connectionProxyDictionary = [
                    kCFNetworkProxiesHTTPEnable as String: 1,
                    kCFNetworkProxiesHTTPProxy  as String: proxy.ip,
                    kCFNetworkProxiesHTTPPort   as String: proxy.port
                ]
                config.timeoutIntervalForRequest  = 10
                config.timeoutIntervalForResource = 10
                let session = URLSession(configuration: config)
                var req = URLRequest(url: testURL)
                req.timeoutInterval = 10
                session.dataTask(with: req) { [weak self] _, response, error in
                    defer { bg.leave(); group.leave(); session.invalidateAndCancel() }
                    guard let self else { return }
                    DispatchQueue.main.async { self.testedCount += 1 }
                    if let e = error { print("❌ \(proxy.label): \(e.localizedDescription)"); return }
                    guard let http = response as? HTTPURLResponse else { return }
                    let elapsed = Date().timeIntervalSince(start)
                    print("✅ \(proxy.label) HTTP \(http.statusCode) \(String(format: "%.2f", elapsed))s")
                    lock.lock(); results.append((proxy, elapsed)); lock.unlock()
                    DispatchQueue.main.async {
                        self.workingCount += 1
                        self.status = "⚡ \(self.workingCount) working · \(self.testedCount)/\(proxies.count) tested…"
                    }
                }.resume()
            }
            bg.wait()
            print("📦 Batch \(bi + 1)/\(batches.count) — \(results.count) working")
            lock.lock(); let c = results.count; lock.unlock()
            if c >= 5 { break }
        }
        
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if results.isEmpty {
                self.status  = "❌ No working proxies found. Tap 🔄 to retry."
                self.isReady = false
            } else {
                let sorted   = results.sorted { $0.time < $1.time }
                self.best    = sorted.first?.proxy
                self.isReady = true
                let t        = String(format: "%.1f", sorted.first!.time)
                self.status  = "🛡 \(self.best!.label) · \(t)s · \(sorted.count) working"
            }
        }
    }
    
    // MARK: - Custom Servers
    func addCustomServer(name: String, ip: String, port: Int) {
        customServers.append(CustomServer(id: UUID(), name: name, ip: ip, port: port))
        saveCustomServers()
    }
    
    func removeCustomServer(_ s: CustomServer) {
        customServers.removeAll { $0.id == s.id }
        saveCustomServers()
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
           let s = try? JSONDecoder().decode([CustomServer].self, from: d) {
            customServers = s
        }
    }
}
