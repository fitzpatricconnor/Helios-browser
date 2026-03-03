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
    
    init() { loadCustomServers() }
    
    func findBestProxy() {
        stopCycling()
        DispatchQueue.main.async {
            self.status         = "⏳ Fetching proxies…"
            self.isReady        = false
            self.best           = nil
            self.testedCount    = 0
            self.workingCount   = 0
            self.allProxies     = []
            self.proxyCountry   = ""
            self.workingProxies = []
            self.currentProxyIndex = 0
        }
        if let custom = customServers.first {
            testSingleProxy(proxy: ProxyEntry(ip: custom.ip, port: custom.port), label: custom.name)
            return
        }
        fetchProxies()
    }
    
    func cycleToNextProxy() {
        guard !workingProxies.isEmpty else { findBestProxy(); return }
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
        guard workingProxies.count > 1 else { findBestProxy(); return }
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
        guard let url = URL(string: "http://ip-api.com/json/\(ip)?fields=country,countryCode,city") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] (data: Data?, _: URLResponse?, _: Error?) in
            guard let self, let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            let country = json["country"] as? String ?? ""
            let city    = json["city"] as? String ?? ""
            let code    = json["countryCode"] as? String ?? ""
            let flag    = self.flagEmoji(code)
            DispatchQueue.main.async {
                if city.isEmpty {
                    self.proxyCountry = "\(flag) \(country)"
                } else {
                    self.proxyCountry = "\(flag) \(city), \(country)"
                }
            }
        }.resume()
    }
    
    private func flagEmoji(_ code: String) -> String {
        guard code.count == 2 else { return "🌍" }
        let base: UInt32 = 127397
        var flag = ""
        for scalar in code.uppercased().unicodeScalars {
            if let s = Unicode.Scalar(base + scalar.value) { flag.append(String(s)) }
        }
        return flag.isEmpty ? "🌍" : flag
    }
    
    // MARK: - Fetch proxy lists from MANY sources
    private func fetchProxies() {
        // These sources provide verified, recently-checked, HTTPS-capable proxies
        let sources: [(url: String, format: String)] = [
            // Proxifly — verified every 5 min, HTTPS only
            ("https://cdn.jsdelivr.net/gh/proxifly/free-proxy-list@main/proxies/protocols/https/data.txt", "text"),
            ("https://cdn.jsdelivr.net/gh/proxifly/free-proxy-list@main/proxies/protocols/http/data.txt", "text"),
            // ProxyScrape — real-time verified, SSL-capable
            ("https://api.proxyscrape.com/v2/?request=displayproxies&protocol=http&timeout=5000&country=all&ssl=yes&anonymity=all", "text"),
            // proxy-list.download — categorized, updated frequently
            ("https://www.proxy-list.download/api/v1/get?type=https", "text"),
            ("https://www.proxy-list.download/api/v1/get?type=http", "text"),
            // GeoNode API — verified anonymous/elite proxies (JSON)
            ("https://proxylist.geonode.com/api/proxy-list?limit=200&page=1&sort_by=lastChecked&sort_type=desc&protocols=http%2Chttps&anonymityLevel=anonymous%2Celite", "geonode"),
            // OpenProxy Space
            ("https://openproxylist.xyz/http.txt", "text"),
            // monosans — frequently updated GitHub list
            ("https://raw.githubusercontent.com/monosans/proxy-list/main/proxies/http.txt", "text"),
            // TheSpeedX — large list
            ("https://raw.githubusercontent.com/TheSpeedX/PROXY-List/master/http.txt", "text"),
            // hookzof — checked list
            ("https://raw.githubusercontent.com/hookzof/socks5_list/master/proxy.txt", "text"),
            // rdavydov — verified
            ("https://raw.githubusercontent.com/rdavydov/proxy-list/main/proxies/http.txt", "text"),
            ("https://raw.githubusercontent.com/rdavydov/proxy-list/main/proxies_anonymous/http.txt", "text"),
        ]
        
        let group   = DispatchGroup()
        var all     = [ProxyEntry]()
        let lock    = NSLock()
        var fetched = 0
        
        DispatchQueue.main.async { self.status = "⏳ Fetching from \(sources.count) sources…" }
        
        for source in sources {
            guard let url = URL(string: source.url) else { continue }
            group.enter()
            var req = URLRequest(url: url)
            req.timeoutInterval = 15
            URLSession.shared.dataTask(with: req) { [weak self] (data: Data?, _: URLResponse?, error: Error?) in
                defer { group.leave() }
                guard let self else { return }
                if error != nil { print("❌ \(url.host ?? "?"): fetch failed"); return }
                guard let data else { return }
                
                var parsed: [ProxyEntry] = []
                
                if source.format == "geonode" {
                    // Parse GeoNode JSON format
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let dataArray = json["data"] as? [[String: Any]] {
                        for item in dataArray {
                            if let ip = item["ip"] as? String,
                               let portStr = item["port"] as? String,
                               let port = Int(portStr) {
                                parsed.append(ProxyEntry(ip: ip, port: port))
                            }
                        }
                    }
                } else {
                    // Parse text format (ip:port per line)
                    parsed = self.parseTextList(data: data)
                }
                
                print("📡 \(url.host ?? "?"): \(parsed.count) proxies")
                lock.lock(); all.append(contentsOf: parsed); fetched += parsed.count; lock.unlock()
                DispatchQueue.main.async { self.status = "⏳ Collected \(fetched) proxies…" }
            }.resume()
        }
        
        group.notify(queue: .global(qos: .userInitiated)) { [weak self] in
            guard let self else { return }
            var seen = Set<String>(); var unique = [ProxyEntry]()
            for p in all where !seen.contains(p.label) { seen.insert(p.label); unique.append(p) }
            print("🔢 Total unique: \(unique.count)")
            if unique.isEmpty {
                DispatchQueue.main.async { self.status = "❌ No proxies fetched."; self.isReady = false }
                return
            }
            // Test more proxies to find working ones
            let capped = Array(unique.shuffled().prefix(200))
            DispatchQueue.main.async {
                self.allProxies = capped; self.status = "⚡ Testing \(capped.count) proxies…"
                self.testedCount = 0; self.workingCount = 0
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
            guard parts.count == 2, let port = Int(parts[1]),
                  port > 0, port < 65536,
                  String(parts[0]).split(separator: ".").count == 4
            else { return nil }
            return ProxyEntry(ip: String(parts[0]), port: port)
        }
    }
    
    // MARK: - HTTPS proxy test — tests the SAME way browsing uses it
    private func httpsTestProxy(proxy: ProxyEntry, timeout: TimeInterval = 8,
                                completion: @escaping (Bool, TimeInterval) -> Void) {
        let start = Date()
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = proxyDictionary(ip: proxy.ip, port: proxy.port)
        config.timeoutIntervalForRequest  = timeout
        config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config, delegate: silentAuth, delegateQueue: nil)
        var req = URLRequest(url: URL(string: "https://www.google.com/generate_204")!)
        req.timeoutInterval = timeout
        session.dataTask(with: req) { (_: Data?, response: URLResponse?, error: Error?) in
            let elapsed = Date().timeIntervalSince(start)
            defer { session.invalidateAndCancel() }
            if error != nil { completion(false, elapsed); return }
            guard let http = response as? HTTPURLResponse else { completion(false, elapsed); return }
            if http.statusCode == 407 || http.statusCode == 403 { completion(false, elapsed) }
            else if http.statusCode >= 200 && http.statusCode < 400 { completion(true, elapsed) }
            else { completion(false, elapsed) }
        }.resume()
    }
    
    func testSingleProxy(proxy: ProxyEntry, label: String) {
        DispatchQueue.main.async { self.status = "⏳ Testing \(label)…"; self.isReady = false }
        httpsTestProxy(proxy: proxy, timeout: 12) { [weak self] success, elapsed in
            guard let self else { return }
            DispatchQueue.main.async {
                if success {
                    self.best = proxy; self.isReady = true
                    self.workingProxies = [proxy]; self.currentProxyIndex = 0
                    let t = String(format: "%.1f", elapsed)
                    self.status = "🛡 \(label) · \(t)s"
                    self.lookupCountry(ip: proxy.ip)
                } else {
                    self.status = "❌ Could not connect to \(label)"; self.isReady = false
                }
            }
        }
    }
    
    // MARK: - Speed test — test in batches, stop early when enough found
    private func speedTest(proxies: [ProxyEntry]) {
        var results = [(proxy: ProxyEntry, time: TimeInterval)]()
        let lock = NSLock()
        let batches = stride(from: 0, to: proxies.count, by: 20).map {
            Array(proxies[$0..<min($0 + 20, proxies.count)])
        }
        for (bi, batch) in batches.enumerated() {
            let bg = DispatchGroup()
            for proxy in batch {
                bg.enter()
                httpsTestProxy(proxy: proxy, timeout: 8) { [weak self] success, elapsed in
                    defer { bg.leave() }
                    guard let self else { return }
                    DispatchQueue.main.async { self.testedCount += 1 }
                    if !success { return }
                    print("✅ \(proxy.label) \(String(format: "%.2f", elapsed))s")
                    lock.lock(); results.append((proxy, elapsed)); lock.unlock()
                    DispatchQueue.main.async {
                        self.workingCount += 1
                        self.status = "⚡ \(self.workingCount) working · \(self.testedCount)/\(proxies.count) tested…"
                    }
                }
            }
            bg.wait()
            print("📦 Batch \(bi + 1)/\(batches.count) — \(results.count) working so far")
            // Stop early if we have enough working proxies
            lock.lock(); let c = results.count; lock.unlock()
            if c >= 10 { break }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if results.isEmpty {
                self.status = "❌ No working proxies found. Tap 🔄 to retry."; self.isReady = false
            } else {
                let sorted = results.sorted { $0.time < $1.time }
                self.workingProxies = sorted.map { $0.proxy }
                self.currentProxyIndex = 0; self.best = sorted.first?.proxy; self.isReady = true
                let t = String(format: "%.1f", sorted.first!.time)
                self.status = "🛡 \(self.best!.label) · \(t)s · \(sorted.count) working"
                if let ip = self.best?.ip { self.lookupCountry(ip: ip) }
            }
        }
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
