import SwiftUI
import WebKit

// MARK: - JS Scripts
let pageFixJS = """
(function() {
    document.querySelectorAll('img[data-src]').forEach(i => i.src = i.dataset.src);
    document.querySelectorAll('img[data-lazy-src]').forEach(i => i.src = i.dataset.lazySrc);
    document.querySelectorAll('img[loading="lazy"]').forEach(i => {
        i.loading = 'eager';
        if (i.dataset.src) i.src = i.dataset.src;
    });
    window.dispatchEvent(new Event('scroll'));
    window.dispatchEvent(new Event('resize'));
    ['cookie','consent','gdpr','popup','modal','overlay','banner'].forEach(k => {
        document.querySelectorAll('[class*="'+k+'"],[id*="'+k+'"]')
                .forEach(el => el.style.display = 'none');
    });
    if (document.body) document.body.style.overflow = 'auto';
})();
"""

let darkModeJS = """
(function() {
    var el = document.getElementById('orion-dark');
    if (el) { el.remove(); return; }
    var s = document.createElement('style');
    s.id = 'orion-dark';
    s.innerHTML = 'html{filter:invert(1) hue-rotate(180deg)!important;}img,video,canvas,svg{filter:invert(1) hue-rotate(180deg)!important;}';
    document.head.appendChild(s);
})();
"""

let readerModeJS = """
(function() {
    var a = document.querySelector('article')||document.querySelector('main')||document.querySelector('.content')||document.body;
    var text=a?a.innerText:document.body.innerText;
    var title=document.title;
    document.open();
    document.write('<!DOCTYPE html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><title>'+title+'</title><style>body{font-family:Georgia,serif;max-width:680px;margin:40px auto;padding:0 20px;line-height:1.8;font-size:18px;background:#0f0f18;color:#e8e8f0;}h1{font-size:26px;margin-bottom:20px;color:#fff;}p{margin-bottom:16px;}</style></head><body><h1>'+title+'</h1><p>'+text.replace(/\\n\\n+/g,'</p><p>').replace(/\\n/g,'<br>')+'</p></body></html>');
    document.close();
})();
"""

func findOnPageJS(_ term: String) -> String {
    "(function(){window.getSelection().removeAllRanges();if(!'\(term)')return;document.body.innerHTML=document.body.innerHTML.replace(new RegExp('\(term)','gi'),'<mark style=\"background:#6b8eff;color:#fff;border-radius:3px;padding:1px 3px\">$&</mark>');var f=document.querySelector('mark');if(f)f.scrollIntoView({behavior:'smooth',block:'center'});})();"
}

// MARK: - Proxy dictionary helper
func proxyDictionary(ip: String, port: Int) -> [String: Any] {
    return [
        "HTTPEnable"  : 1,
        "HTTPProxy"   : ip,
        "HTTPPort"    : port,
        "HTTPSEnable" : 1,
        "HTTPSProxy"  : ip,
        "HTTPSPort"   : port
    ]
}

// MARK: - Silent auth delegate
class SilentAuthDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        if method == NSURLAuthenticationMethodHTTPBasic ||
            method == NSURLAuthenticationMethodHTTPDigest ||
            method == NSURLAuthenticationMethodNTLM {
            completionHandler(.cancelAuthenticationChallenge, nil)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

// MARK: - Scheme Handler
class ProxySchemeHandler: NSObject, WKURLSchemeHandler {
    let realScheme: String
    private var cancelledTasks = Set<ObjectIdentifier>()
    private let lock = NSLock()

    init(realScheme: String) { self.realScheme = realScheme }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let requestURL = task.request.url,
              var comps = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)
        else { sendError(task: task, msg: "Bad URL"); return }

        comps.scheme = realScheme
        guard let realURL = comps.url else { sendError(task: task, msg: "Bad URL"); return }

        let taskID = ObjectIdentifier(task)
        let pm = ProxyManager.shared
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest  = 30
        config.timeoutIntervalForResource = 60

        let fetchURL: URL
        let session: URLSession
        let useCustomProxy = !pm.customServers.isEmpty && pm.best != nil && pm.best!.port != 0

        if useCustomProxy, let p = pm.best {
            // Custom SOCKS/HTTP proxy server
            config.connectionProxyDictionary = proxyDictionary(ip: p.ip, port: p.port)
            fetchURL = realURL
            session = URLSession(configuration: config, delegate: pm.silentAuth, delegateQueue: nil)
            print("🔀 \(realURL.host ?? "?") via custom \(p.ip):\(p.port)")
        } else {
            // Web proxy API — route through the active web proxy service
            let proxied = pm.proxiedURL(for: realURL.absoluteString)
            guard let pURL = URL(string: proxied) else {
                sendError(task: task, msg: "Failed to build proxy URL")
                return
            }
            fetchURL = pURL
            session = URLSession(configuration: config)
            let wp = pm.activeWebProxy
            print("🔀 \(realURL.host ?? "?") via \(wp.name)")        }

        var req = URLRequest(url: fetchURL)
        req.httpMethod = task.request.httpMethod ?? "GET"
        req.httpBody   = task.request.httpBody
        task.request.allHTTPHeaderFields?.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        if req.value(forHTTPHeaderField: "User-Agent") == nil {
            req.setValue(
                "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
                forHTTPHeaderField: "User-Agent"
            )
        }

        session.dataTask(with: req) { [weak self] (data: Data?, response: URLResponse?, error: Error?) in
            guard let self else { return }
            defer { session.finishTasksAndInvalidate() }
            self.lock.lock(); let cancelled = self.cancelledTasks.contains(taskID); self.lock.unlock()
            if cancelled { return }

            if let error = error {
                print("❌ \(realURL.host ?? "?"): \(error.localizedDescription)")
                self.sendError(task: task, msg: error.localizedDescription)
                return
            }
            guard let data = data, !data.isEmpty, let response = response else {
                self.sendError(task: task, msg: "No data received")
                return
            }

            if let http = response as? HTTPURLResponse,
               (http.statusCode == 403 || http.statusCode == 407 || http.statusCode == 429) {
                self.sendError(task: task, msg: "Proxy blocked (HTTP \(http.statusCode))")
                return
            }

            self.lock.lock(); let c2 = self.cancelledTasks.contains(taskID); self.lock.unlock()
            if c2 { return }

            var statusCode = 200
            var headers: [String: String] = ["Access-Control-Allow-Origin": "*"]
            if let http = response as? HTTPURLResponse {
                statusCode = http.statusCode
                for (key, value) in http.allHeaderFields {
                    guard let headerKey = key as? String else { continue }
                    headers[headerKey] = (value as? String) ?? "\(value)"
                }
            }
            if headers["Content-Type"] == nil {
                headers["Content-Type"] = "text/html; charset=utf-8"
            }
            headers["Content-Length"] = "\(data.count)"
            guard let httpResponse = HTTPURLResponse(
                url: realURL,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            ) else {
                self.sendError(task: task, msg: "Failed to build response")
                return
            }

            task.didReceive(httpResponse)
            task.didReceive(data)
            task.didFinish()
            DispatchQueue.main.async {
                ProxyManager.shared.stopCycling()
                ProxyManager.shared.markWebProxySuccess()
            }
            print("✅ \(realURL.host ?? "?") \(data.count) bytes")
        }.resume()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        lock.lock(); cancelledTasks.insert(ObjectIdentifier(task)); lock.unlock()
    }

    private func sendError(task: WKURLSchemeTask, msg: String) {
        task.didFailWithError(NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCannotConnectToHost,
            userInfo: [NSLocalizedDescriptionKey: msg]
        ))
    }
}

// MARK: - Browser Store
class BrowserStore: ObservableObject {
    @Published var isLoading:    Bool          = false
    @Published var progress:     Double        = 0.0
    @Published var pageTitle:    String        = ""
    @Published var currentURL:   String        = ""
    @Published var errorMsg:     String?       = nil
    @Published var canGoBack:    Bool          = false
    @Published var canGoFwd:     Bool          = false
    @Published var isIncognito:  Bool          = false
    @Published var isDarkMode:   Bool          = false
    @Published var isReaderMode: Bool          = false
    @Published var bookmarks:    [Bookmark]    = []
    @Published var history:      [HistoryItem] = []
    @Published var tabs:         [BrowserTab]  = []
    @Published var activeTabIndex: Int         = 0
    
    let webView: WKWebView
    private var obs = [NSKeyValueObservation]()
    
    init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let pp = WKWebpagePreferences()
        pp.allowsContentJavaScript = true
        config.defaultWebpagePreferences = pp
        let prefs = WKPreferences()
        prefs.javaScriptCanOpenWindowsAutomatically = true
        config.preferences = prefs
        config.setURLSchemeHandler(ProxySchemeHandler(realScheme: "https"), forURLScheme: "proxy-https")
        let cc = WKUserContentController()
        cc.addUserScript(WKUserScript(source: pageFixJS, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        config.userContentController = cc
        
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        wv.allowsBackForwardNavigationGestures = true
        wv.scrollView.contentInsetAdjustmentBehavior = .always
        wv.backgroundColor = UIColor(Color.oBG)
        wv.isOpaque = false
        self.webView = wv
        
        obs.append(wv.observe(\.estimatedProgress) { [weak self] v, _ in DispatchQueue.main.async { self?.progress   = v.estimatedProgress        } })
        obs.append(wv.observe(\.title)             { [weak self] v, _ in DispatchQueue.main.async { self?.pageTitle  = v.title ?? ""               } })
        obs.append(wv.observe(\.url)               { [weak self] v, _ in DispatchQueue.main.async { self?.currentURL = v.url?.absoluteString ?? "" } })
        obs.append(wv.observe(\.canGoBack)         { [weak self] v, _ in DispatchQueue.main.async { self?.canGoBack  = v.canGoBack                 } })
        obs.append(wv.observe(\.canGoForward)      { [weak self] v, _ in DispatchQueue.main.async { self?.canGoFwd   = v.canGoForward              } })
        
        tabs = [BrowserTab(id: UUID(), title: "New Tab", url: "", isIncognito: false)]
        loadPersisted()
    }
    
    private func resolveURL(_ raw: String) -> String {
        var url = raw.trimmingCharacters(in: .whitespaces)
        if url.hasPrefix("http://") { url = "https://" + url.dropFirst(7) }
        if url.hasPrefix("https://") { return url }
        let looksLikeURL = url.contains(".") && !url.contains(" ") &&
            (url.first?.isLetter == true || url.first?.isNumber == true)
        if looksLikeURL {
            return "https://" + url
        } else {
            let encoded = url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? url
            return "https://duckduckgo.com/?q=" + encoded
        }
    }

    func load(_ raw: String) {
        let url = resolveURL(raw)
            .replacingOccurrences(of: "https://", with: "proxy-https://")
        guard let u = URL(string: url) else { errorMsg = "❌ Invalid URL"; return }
        errorMsg = nil; isLoading = true; isReaderMode = false; isDarkMode = false
        webView.load(URLRequest(url: u))
    }
    
    func reload()    { errorMsg = nil; isReaderMode = false; webView.reload() }
    func goBack()    { if canGoBack { webView.goBack()    } }
    func goForward() { if canGoFwd  { webView.goForward() } }
    func stop()      { webView.stopLoading(); isLoading = false }
    
    func toggleDarkMode() { isDarkMode.toggle(); webView.evaluateJavaScript(darkModeJS) { _, _ in } }
    func toggleReaderMode() {
        isReaderMode.toggle()
        if isReaderMode {
            webView.evaluateJavaScript(readerModeJS) { _, _ in }
        } else {
            reload()
        }
    }
    func findOnPage(_ term: String) { webView.evaluateJavaScript(findOnPageJS(term)) { _, _ in } }
    
    var cleanURL: String { currentURL.replacingOccurrences(of: "proxy-https://", with: "https://") }
    var isBookmarked: Bool { bookmarks.contains { $0.url == cleanURL } }
    
    func toggleBookmark() {
        if isBookmarked { bookmarks.removeAll { $0.url == cleanURL } }
        else if !currentURL.isEmpty {
            bookmarks.append(Bookmark(id: UUID(), title: pageTitle.isEmpty ? cleanURL : pageTitle, url: cleanURL))
        }
        savePersisted()
    }
    func removeBookmark(_ b: Bookmark) { bookmarks.removeAll { $0.id == b.id }; savePersisted() }
    
    func addHistory() {
        guard !currentURL.isEmpty, !isIncognito else { return }
        history.insert(HistoryItem(id: UUID(), title: pageTitle.isEmpty ? cleanURL : pageTitle, url: cleanURL, date: Date()), at: 0)
        if history.count > 200 { history = Array(history.prefix(200)) }
        savePersisted()
    }
    func clearHistory() { history = []; savePersisted() }
    
    private func savePersisted() {
        if let d = try? JSONEncoder().encode(bookmarks) { UserDefaults.standard.set(d, forKey: "orion_bookmarks") }
        if let d = try? JSONEncoder().encode(history)   { UserDefaults.standard.set(d, forKey: "orion_history")   }
    }
    private func loadPersisted() {
        if let d = UserDefaults.standard.data(forKey: "orion_bookmarks"),
           let b = try? JSONDecoder().decode([Bookmark].self,    from: d) { bookmarks = b }
        if let d = UserDefaults.standard.data(forKey: "orion_history"),
           let h = try? JSONDecoder().decode([HistoryItem].self, from: d) { history   = h }
    }
}

// MARK: - Nav Delegate
class NavDelegate: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    weak var store: BrowserStore?
    
    func webView(_ wv: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let pm = ProxyManager.shared
        if pm.isUsingWebProxyMode,
           let url = action.request.url,
           let scheme = url.scheme?.lowercased(),
           (scheme == "http" || scheme == "https") {
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            comps?.scheme = "proxy-https"
            if let proxied = comps?.url {
                wv.load(URLRequest(url: proxied))
                decisionHandler(.cancel)
                return
            }
        }
        decisionHandler(.allow)
    }
    
    func webView(_ wv: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
        store?.isLoading = true; store?.errorMsg = nil
    }
    func webView(_ wv: WKWebView, didFinish _: WKNavigation!) {
        store?.isLoading = false; store?.errorMsg = nil
        store?.addHistory()
        ProxyManager.shared.stopCycling()
        ProxyManager.shared.markWebProxySuccess()
        wv.evaluateJavaScript(pageFixJS) { _, _ in }
    }
    func webView(_ wv: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
        let c = (error as NSError).code
        if c == NSURLErrorCancelled { return }
        store?.isLoading = false
        let pm = ProxyManager.shared
        let proxyName = pm.activeWebProxyName
        if pm.workingProxies.count > 1 && !pm.isCycling {
            store?.errorMsg = "🔄 \(proxyName) failed — auto-trying others…"
            pm.startCycling { [weak self] in
                self?.store?.reload()
            }
        } else if pm.isCycling {
            store?.errorMsg = "🔄 Trying \(proxyName)…\n\(pm.currentProxyIndex + 1)/\(pm.workingProxies.count) services"
        } else if pm.scheduleWebProxyRetry(reloadAction: { [weak self] in
            guard let self, let store = self.store else { return }
            store.reload()
        }, onScheduled: { [weak self] message in
            self?.store?.errorMsg = message
        }) {
        } else {
            store?.errorMsg = "❌ \(proxyName) failed (error \(c))\nTap New Proxy to try again."
        }
    }
    func webView(_ wv: WKWebView, didFail _: WKNavigation!, withError error: Error) {
        let c = (error as NSError).code
        if c == NSURLErrorCancelled { return }
        store?.isLoading = false
        let detail = (error as NSError).localizedDescription
        store?.errorMsg = "❌ \(ProxyManager.shared.activeWebProxyName) failed\n\(detail)\nTap New Proxy to try again."
    }
    func webView(_ wv: WKWebView, createWebViewWith _: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures _: WKWindowFeatures) -> WKWebView? {
        if action.targetFrame == nil { wv.load(action.request) }
        return nil
    }
}

// MARK: - WebView Wrapper
struct WebViewWrapper: UIViewRepresentable {
    @ObservedObject var store: BrowserStore
    let nav: NavDelegate
    func makeUIView(context: Context) -> WKWebView {
        store.webView.navigationDelegate = nav
        store.webView.uiDelegate         = nav
        nav.store = store
        return store.webView
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
