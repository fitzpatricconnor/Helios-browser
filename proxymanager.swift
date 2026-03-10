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
    @Published var isDirectMode: Bool       = false

    var workingProxies: [ProxyEntry] = []
    var currentProxyIndex: Int = 0
    private var cycleTimer: Timer?

    let silentAuth = SilentAuthDelegate()

    init() {
        let direct = UserDefaults.standard.bool(forKey: "orion_direct_mode")
        isDirectMode = direct
        if direct {
            isReady = true
            status  = "📡 Direct Mode"
        }
        loadCustomServers()
    }

    // MARK: - Direct Mode toggle
    func setDirectMode(_ value: Bool) {
        isDirectMode = value
        UserDefaults.standard.set(value, forKey: "orion_direct_mode")
        findBestProxy()
    }

    // MARK: - Find best proxy
    func findBestProxy() {
        stopCycling()

        if isDirectMode {
            DispatchQueue.main.async {
                self.status  = "📡 Direct Mode"
                self.isReady = true
                self.best    = nil
            }
            return
        }

        DispatchQueue.main.async {
            self.status         = "⏳ Searching for proxies…"
            self.isReady        = false
            self.best           = nil
            self.testedCount    = 0
            self.workingCount   = 0
            self.proxyCountry   = ""
            self.workingProxies = []
            self.currentProxyIndex = 0
        }

        if let custom = customServers.first {
            testSingleProxy(proxy: ProxyEntry(ip: custom.ip, port: custom.port), label: custom.name)
            return
        }

        fetchAndTestProxies()
    }

    // MARK: - Fetch proxies from reliable sources
    private func fetchAndTestProxies() {
        let sources = [
            // Elite+anonymous HTTPS proxies (most restrictive / highest quality)
            "https://api.proxyscrape.com/v3/free-proxy-list/get?request=displayproxies&protocol=https&timeout=5000&country=all&ssl=yes&anonymity=elite,anonymous",
            // All HTTPS proxies (broader list, includes transparent)
            "https://api.proxyscrape.com/v3/free-proxy-list/get?request=displayproxies&protocol=https&timeout=5000&country=all&ssl=yes",
            "https://proxylist.geonode.com/api/proxy-list?limit=100&page=1&sort_by=lastChecked&sort_type=desc&protocols=https&filterUpTime=70",
        ]

        var collected: [ProxyEntry] = []
        let lock  = NSLock()
        let group = DispatchGroup()

        for source in sources {
            guard let url = URL(string: source) else { continue }
            group.enter()
            var req = URLRequest(url: url)
            req.timeoutInterval = 15
            URLSession.shared.dataTask(with: req) { (data: Data?, response: URLResponse?, error: Error?) in
                defer { group.leave() }
                guard let data = data, error == nil else { return }
                if source.contains("geonode") {
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let arr  = json["data"] as? [[String: Any]] {
                        lock.lock()
                        for item in arr {
                            if let ip      = item["ip"]   as? String,
                               let portStr = item["port"] as? String,
                               let port    = Int(portStr) {
                                collected.append(ProxyEntry(ip: ip, port: port))
                            }
                        }
                        lock.unlock()
                    }
                } else {
                    let text  = String(data: data, encoding: .utf8) ?? ""
                    let lines = text.components(separatedBy: .newlines)
                    lock.lock()
                    for line in lines {
                        let parts = line.trimmingCharacters(in: .whitespaces).components(separatedBy: ":")
                        if parts.count == 2, let port = Int(parts[1]) {
                            collected.append(ProxyEntry(ip: parts[0], port: port))
                        }
                    }
                    lock.unlock()
                }
            }.resume()
        }

        group.notify(queue: .global()) { [weak self] in
            guard let self else { return }
            var seen   = Set<String>()
            var unique: [ProxyEntry] = []
            for p in collected {
                if seen.insert(p.label).inserted { unique.append(p) }
            }
            let limited = Array(unique.prefix(300)) // cap at 300 to balance coverage vs. test time
            DispatchQueue.main.async { self.status = "⏳ Testing \(limited.count) proxies…" }
            self.testProxiesConcurrently(limited)
        }
    }

    // MARK: - Test proxies concurrently
    private func testProxiesConcurrently(_ proxies: [ProxyEntry]) {
        let group = DispatchGroup()
        let lock  = NSLock()
        var found: (proxy: ProxyEntry, time: TimeInterval)? = nil
        var working: [ProxyEntry] = []
        var tested = 0

        DispatchQueue.main.async { self.testedCount = 0; self.workingCount = 0 }

        for proxy in proxies {
            group.enter()
            let config = URLSessionConfiguration.ephemeral
            config.connectionProxyDictionary = proxyDictionary(ip: proxy.ip, port: proxy.port)
            config.timeoutIntervalForRequest  = 5
            config.timeoutIntervalForResource = 5
            let session = URLSession(configuration: config, delegate: silentAuth, delegateQueue: nil)
            var req = URLRequest(url: URL(string: "https://www.google.com/generate_204")!)
            req.timeoutInterval = 5
            let start = Date()
            session.dataTask(with: req) { [weak self] (data: Data?, response: URLResponse?, error: Error?) in
                defer { session.invalidateAndCancel(); group.leave() }
                guard let self else { return }
                let elapsed = Date().timeIntervalSince(start)
                lock.lock(); tested += 1; let t = tested; lock.unlock()
                DispatchQueue.main.async { self.testedCount = t }

                if error == nil, let http = response as? HTTPURLResponse,
                   http.statusCode >= 200 && http.statusCode < 400 {
                    lock.lock()
                    let isFirst = found == nil
                    if isFirst { found = (proxy, elapsed) }
                    working.append(proxy)
                    lock.unlock()
                    DispatchQueue.main.async {
                        self.workingCount += 1
                        if isFirst {
                            self.best          = proxy
                            self.isReady       = true
                            self.workingProxies = [proxy]
                            self.currentProxyIndex = 0
                            let s = String(format: "%.1f", elapsed)
                            self.status = "🛡 \(proxy.label) · \(s)s"
                        }
                    }
                }
            }.resume()
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            if self.workingProxies.count < working.count {
                self.workingProxies = working
            }
            if found == nil {
                self.status  = "❌ No working proxies found. Tap 🔄 to retry."
                self.isReady = false
            } else {
                let s = String(format: "%.1f", found!.time)
                self.status = "🛡 \(found!.proxy.label) · \(s)s · \(self.workingCount) working"
            }
        }
    }

    // MARK: - Cycle to next working proxy
    func cycleToNextProxy() {
        guard workingProxies.count > 1 else { findBestProxy(); return }
        currentProxyIndex += 1
        if currentProxyIndex >= workingProxies.count { currentProxyIndex = 0 }
        let proxy = workingProxies[currentProxyIndex]
        DispatchQueue.main.async {
            self.best    = proxy
            self.isReady = true
            self.status  = "🔄 Switched to \(proxy.label) (\(self.currentProxyIndex + 1)/\(self.workingProxies.count))"
        }
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

    // MARK: - Traditional proxy test (for custom servers)
    func testSingleProxy(proxy: ProxyEntry, label: String) {
        DispatchQueue.main.async { self.status = "⏳ Testing \(label)…"; self.isReady = false }
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = proxyDictionary(ip: proxy.ip, port: proxy.port)
        config.timeoutIntervalForRequest  = 12
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
