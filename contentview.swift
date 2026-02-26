import SwiftUI

struct ContentView: View {
    @StateObject    private var store = BrowserStore()
    @StateObject    private var nav   = NavDelegate()
    @ObservedObject private var proxy = ProxyManager.shared
    
    @State private var inputText      = ""
    @FocusState     private var focused: Bool
    @State private var showStart      = true
    @State private var showProxySheet = false
    @State private var showBookmarks  = false
    @State private var showHistory    = false
    @State private var showTabs       = false
    @State private var showFindBar    = false
    @State private var findText       = ""
    @State private var shareURL: URL? = nil
    @State private var showShare      = false
    
    var body: some View {
        ZStack {
            Color.oBG.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                ZStack {
                    Color.oBG
                    WebViewWrapper(store: store, nav: nav)
                        .ignoresSafeArea(edges: .bottom)
                        .opacity(showStart || store.errorMsg != nil ? 0 : 1)
                    if let err = store.errorMsg { errorScreen(err) }
                    if showStart {
                        if proxy.isReady { HomeScreen(onNavigate: { navigate(with: $0) }) }
                        else { StartupScreen(proxy: proxy) }
                    }
                }
                if showFindBar { findBar }
                bottomBar
            }
            if showProxySheet { proxySheet }
            if showBookmarks  { bookmarkSheet }
            if showHistory    { historySheet }
            if showTabs       { tabSheet }
        }
        .preferredColorScheme(.dark)
        .onAppear { ProxyManager.shared.findBestProxy() }
        .sheet(isPresented: $showShare) {
            if let u = shareURL { ShareSheet(url: u) }
        }
    }
    
    // MARK: - Top Bar
    var topBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    ZStack {
                        Circle().fill(Color.oAccent.opacity(0.18)).frame(width: 30, height: 30)
                        Image(systemName: "circle.hexagongrid.fill")
                            .foregroundColor(Color.oAccent).font(.system(size: 14, weight: .bold))
                    }
                    Text("Orion").font(.system(size: 17, weight: .bold, design: .rounded)).foregroundColor(Color.oText)
                    if store.isIncognito {
                        Text("Incognito").font(.system(size: 9, weight: .bold)).foregroundColor(.purple)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Color.purple.opacity(0.2)).clipShape(Capsule())
                    }
                }
                Spacer()
                Button { showTabs = true } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6).stroke(Color.oBorder, lineWidth: 1.5).frame(width: 26, height: 26)
                        Text("\(store.tabs.count)").font(.system(size: 11, weight: .bold)).foregroundColor(Color.oText)
                    }
                }
                Button { showProxySheet = true } label: {
                    HStack(spacing: 4) {
                        if proxy.isReady { Circle().fill(Color.oGreen).frame(width: 6, height: 6) }
                        else { ProgressView().progressViewStyle(CircularProgressViewStyle(tint: Color.oAccent)).scaleEffect(0.5) }
                        Text(proxy.isReady ? "Proxy ✓" : "Searching…")
                            .font(.system(size: 10, weight: .medium)).foregroundColor(Color.oMuted)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.oBorder.opacity(0.5)).clipShape(Capsule())
                }
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
            
            HStack(spacing: 6) {
                Button { store.goBack() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 14, weight: .semibold))
                        .foregroundColor(store.canGoBack ? Color.oAccent : Color.oMuted)
                }.frame(width: 30, height: 30).disabled(!store.canGoBack)
                
                Button { store.goForward() } label: {
                    Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold))
                        .foregroundColor(store.canGoFwd ? Color.oAccent : Color.oMuted)
                }.frame(width: 30, height: 30).disabled(!store.canGoFwd)
                
                HStack(spacing: 5) {
                    Image(systemName: "shield.fill").font(.system(size: 10))
                        .foregroundColor(proxy.isReady ? Color.oGreen : Color.oOrange)
                    TextField("Search or enter address…", text: $inputText)
                        .font(.system(size: 13)).foregroundColor(Color.oText)
                        .autocapitalization(.none).disableAutocorrection(true)
                        .keyboardType(.URL).focused($focused).onSubmit { navigate() }
                    if !inputText.isEmpty {
                        Button { inputText = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundColor(Color.oMuted).font(.system(size: 12))
                        }
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 7)
                .background(Color.oBG)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(focused ? Color.oAccent : Color.oBorder, lineWidth: 1))
                
                Button { store.isLoading ? store.stop() : navigate() } label: {
                    Image(systemName: store.isLoading ? "xmark.circle.fill" : "arrow.right.circle.fill")
                        .font(.system(size: 20)).foregroundColor(Color.oAccent)
                }
            }
            .padding(.horizontal, 10).padding(.bottom, 6)
            
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Color.oBorder.frame(height: 2)
                    Color.oAccent
                        .frame(width: store.isLoading ? geo.size.width * max(0.05, store.progress) : 0, height: 2)
                        .animation(.easeInOut(duration: 0.2), value: store.progress)
                }
            }.frame(height: 2)
            
            if !store.pageTitle.isEmpty && !showStart {
                Text(store.pageTitle).font(.system(size: 10)).foregroundColor(Color.oMuted).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 2)
            }
            Divider().background(Color.oBorder)
        }
        .background(Color.oCard)
    }
    
    // MARK: - Bottom Bar
    var bottomBar: some View {
        VStack(spacing: 0) {
            Divider().background(Color.oBorder)
            HStack(spacing: 0) {
                TBBtn(icon: store.isBookmarked ? "star.fill" : "star",
                      color: store.isBookmarked ? Color.oOrange : Color.oMuted) { store.toggleBookmark() }
                TBBtn(icon: "clock",
                      color: Color.oMuted) { showHistory = true }
                TBBtn(icon: store.isDarkMode   ? "moon.fill"     : "moon",
                      color: store.isDarkMode   ? Color.oAccent  : Color.oMuted) { store.toggleDarkMode() }
                TBBtn(icon: store.isReaderMode ? "doc.text.fill" : "doc.text",
                      color: store.isReaderMode ? Color.oAccent  : Color.oMuted) { store.toggleReaderMode() }
                TBBtn(icon: "magnifyingglass",
                      color: Color.oMuted) { withAnimation { showFindBar.toggle() } }
                TBBtn(icon: "square.and.arrow.up",
                      color: Color.oMuted) {
                    if let u = URL(string: store.cleanURL) { shareURL = u; showShare = true }
                }
                TBBtn(icon: store.isIncognito ? "eye.slash.fill" : "eye.slash",
                      color: store.isIncognito ? .purple : Color.oMuted) { store.isIncognito.toggle() }
                TBBtn(icon: "arrow.clockwise",
                      color: Color.oMuted) { store.reload() }
            }
            .padding(.horizontal, 4).padding(.vertical, 6)
        }
        .background(Color.oCard)
    }
    
    // MARK: - Find Bar
    var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundColor(Color.oMuted).font(.system(size: 13))
            TextField("Find on page…", text: $findText)
                .font(.system(size: 13)).foregroundColor(Color.oText)
                .autocapitalization(.none).disableAutocorrection(true)
                .onSubmit { store.findOnPage(findText) }
            if !findText.isEmpty {
                Button { store.findOnPage(findText) } label: {
                    Text("Find").font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color.oAccent).clipShape(Capsule())
                }
                Button { findText = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(Color.oMuted)
                }
            }
            Button { withAnimation { showFindBar = false; findText = "" } } label: {
                Text("Done").font(.system(size: 13)).foregroundColor(Color.oAccent)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.oCard)
        .overlay(Rectangle().frame(height: 1).foregroundColor(Color.oBorder), alignment: .top)
    }
    
    // MARK: - Error Screen
    func errorScreen(_ err: String) -> some View {
        VStack(spacing: 18) {
            Spacer()
            ZStack {
                Circle().fill(Color.oRed.opacity(0.12)).frame(width: 70, height: 70)
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28)).foregroundColor(Color.oRed)
            }
            Text("Page Failed to Load").font(.system(size: 18, weight: .bold)).foregroundColor(Color.oText)
            Text(err).font(.system(size: 13)).foregroundColor(Color.oMuted)
                .multilineTextAlignment(.center).padding(.horizontal, 30)
            HStack(spacing: 12) {
                ActionButton(label: "Retry",     icon: "arrow.clockwise",                  color: Color.oAccent)  { store.reload() }
                ActionButton(label: "New Proxy", icon: "antenna.radiowaves.left.and.right", color: Color.oOrange) { ProxyManager.shared.findBestProxy() }
            }
            Spacer()
        }
    }
    
    // MARK: - Proxy Sheet
    var proxySheet: some View {
        SheetOverlay { showProxySheet = false } content: {
            VStack(spacing: 14) {
                Text("Proxy Settings").font(.system(size: 17, weight: .bold)).foregroundColor(Color.oText)
                HStack(spacing: 6) {
                    Circle().fill(proxy.isReady ? Color.oGreen : Color.oOrange).frame(width: 8, height: 8)
                    Text(proxy.isReady ? "Connected" : "Searching…")
                        .font(.system(size: 13, weight: .semibold)).foregroundColor(Color.oText)
                }
                if let best = proxy.best {
                    Text(best.label).font(.system(size: 12, design: .monospaced)).foregroundColor(Color.oAccent)
                        .padding(8).background(Color.oBG).clipShape(RoundedRectangle(cornerRadius: 8))
                }
                Divider().background(Color.oBorder)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Country Filter").font(.system(size: 12, weight: .semibold)).foregroundColor(Color.oMuted)
                    Picker("Country", selection: $proxy.selectedCountry) {
                        ForEach(allCountries) { c in Text(c.name).tag(c.id) }
                    }
                    .pickerStyle(.menu).accentColor(Color.oAccent)
                    .padding(8).background(Color.oBG).clipShape(RoundedRectangle(cornerRadius: 8))
                    Button {
                        showProxySheet = false
                        ProxyManager.shared.findBestProxy()
                    } label: {
                        let name = allCountries.first { $0.id == proxy.selectedCountry }?.name ?? "All"
                        Label("Find Proxy for \(name)", systemImage: "arrow.clockwise")
                            .font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(Color.oAccent).clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
                Divider().background(Color.oBorder)
                CustomServerSection(proxy: proxy)
                Divider().background(Color.oBorder)
                if proxy.testedCount > 0 {
                    HStack(spacing: 20) {
                        StatBadge(value: "\(proxy.testedCount)",      label: "Tested",  color: Color.oAccent)
                        StatBadge(value: "\(proxy.workingCount)",     label: "Working", color: Color.oGreen)
                        StatBadge(value: "\(proxy.allProxies.count)", label: "Found",   color: Color.oOrange)
                    }
                }
                Button("Done") { showProxySheet = false }
                    .font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                    .padding(.horizontal, 30).padding(.vertical, 8)
                    .background(Color.oAccent).clipShape(Capsule())
            }
        }
    }
    
    // MARK: - Bookmark Sheet
    var bookmarkSheet: some View {
        SheetOverlay { showBookmarks = false } content: {
            VStack(spacing: 0) {
                SheetHeader(title: "Bookmarks") { showBookmarks = false }
                if store.bookmarks.isEmpty {
                    Text("No bookmarks yet.\nTap ★ to save a page.")
                        .font(.system(size: 13)).foregroundColor(Color.oMuted)
                        .multilineTextAlignment(.center).padding(.top, 20)
                } else {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(store.bookmarks) { b in
                                Button { navigate(with: b.url); showBookmarks = false } label: {
                                    HStack {
                                        Image(systemName: "star.fill")
                                            .foregroundColor(Color.oOrange).frame(width: 20)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(b.title).font(.system(size: 13, weight: .medium))
                                                .foregroundColor(Color.oText).lineLimit(1)
                                            Text(b.url).font(.system(size: 10))
                                                .foregroundColor(Color.oMuted).lineLimit(1)
                                        }
                                        Spacer()
                                        Button { store.removeBookmark(b) } label: {
                                            Image(systemName: "trash")
                                                .foregroundColor(Color.oRed).font(.system(size: 12))
                                        }
                                    }
                                    .padding(10).background(Color.oBG).clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                            }
                        }
                    }.frame(maxHeight: 300)
                }
            }
        }
    }
    
    // MARK: - History Sheet
    var historySheet: some View {
        SheetOverlay { showHistory = false } content: {
            VStack(spacing: 0) {
                HStack {
                    Text("History").font(.system(size: 17, weight: .bold)).foregroundColor(Color.oText)
                    Spacer()
                    Button { store.clearHistory() } label: {
                        Text("Clear").font(.system(size: 13)).foregroundColor(Color.oRed)
                    }
                    Button("Done") { showHistory = false }
                        .foregroundColor(Color.oAccent).padding(.leading, 8)
                }.padding(.bottom, 12)
                if store.history.isEmpty {
                    Text("No history yet.")
                        .font(.system(size: 13)).foregroundColor(Color.oMuted).padding(.top, 20)
                } else {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(store.history) { h in
                                Button { navigate(with: h.url); showHistory = false } label: {
                                    HStack {
                                        Image(systemName: "clock")
                                            .foregroundColor(Color.oMuted).frame(width: 20)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(h.title).font(.system(size: 13, weight: .medium))
                                                .foregroundColor(Color.oText).lineLimit(1)
                                            Text(h.url).font(.system(size: 10))
                                                .foregroundColor(Color.oMuted).lineLimit(1)
                                        }
                                        Spacer()
                                        Text(timeAgo(h.date)).font(.system(size: 10)).foregroundColor(Color.oMuted)
                                    }
                                    .padding(10).background(Color.oBG).clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                            }
                        }
                    }.frame(maxHeight: 320)
                }
            }
        }
    }
    
    // MARK: - Tab Sheet
    var tabSheet: some View {
        SheetOverlay { showTabs = false } content: {
            VStack(spacing: 0) {
                HStack {
                    Text("Tabs").font(.system(size: 17, weight: .bold)).foregroundColor(Color.oText)
                    Spacer()
                    Button {
                        store.tabs.append(BrowserTab(id: UUID(), title: "New Tab", url: "", isIncognito: false))
                        store.activeTabIndex = store.tabs.count - 1
                        showStart = true; showTabs = false
                    } label: {
                        Image(systemName: "plus.circle.fill").font(.system(size: 20)).foregroundColor(Color.oAccent)
                    }
                    Button("Done") { showTabs = false }
                        .foregroundColor(Color.oAccent).padding(.leading, 8)
                }.padding(.bottom, 12)
                
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(Array(store.tabs.enumerated()), id: \.element.id) { i, tab in
                            Button {
                                store.activeTabIndex = i
                                if !tab.url.isEmpty { navigate(with: tab.url) } else { showStart = true }
                                showTabs = false
                            } label: {
                                HStack {
                                    Image(systemName: tab.isIncognito ? "eye.slash" : "globe")
                                        .foregroundColor(i == store.activeTabIndex ? Color.oAccent : Color.oMuted)
                                        .frame(width: 20)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(tab.title).font(.system(size: 13, weight: .medium))
                                            .foregroundColor(Color.oText).lineLimit(1)
                                        Text(tab.url.isEmpty ? "New Tab" : tab.url).font(.system(size: 10))
                                            .foregroundColor(Color.oMuted).lineLimit(1)
                                    }
                                    Spacer()
                                    if store.tabs.count > 1 {
                                        Button {
                                            store.tabs.remove(at: i)
                                            if store.activeTabIndex >= store.tabs.count {
                                                store.activeTabIndex = store.tabs.count - 1
                                            }
                                        } label: {
                                            Image(systemName: "xmark").font(.system(size: 11)).foregroundColor(Color.oMuted)
                                        }
                                    }
                                }
                                .padding(10)
                                .background(i == store.activeTabIndex ? Color.oAccent.opacity(0.15) : Color.oBG)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8)
                                    .stroke(i == store.activeTabIndex ? Color.oAccent.opacity(0.5) : Color.clear, lineWidth: 1))
                            }
                        }
                    }
                }.frame(maxHeight: 280)
                
                Button {
                    store.tabs.append(BrowserTab(id: UUID(), title: "Incognito Tab", url: "", isIncognito: true))
                    store.activeTabIndex = store.tabs.count - 1
                    store.isIncognito = true; showStart = true; showTabs = false
                } label: {
                    HStack {
                        Image(systemName: "eye.slash.fill").foregroundColor(.purple)
                        Text("New Incognito Tab").font(.system(size: 14)).foregroundColor(.purple)
                    }
                    .frame(maxWidth: .infinity).padding(12)
                    .background(Color.purple.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }.padding(.top, 10)
            }
        }
    }
    
    // MARK: - Navigate
    func navigate(with url: String? = nil) {
        let raw = (url ?? inputText).trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        guard proxy.isReady else {
            store.errorMsg = "⏳ Still finding a proxy…\nPlease wait then try again."
            return
        }
        inputText = raw; focused = false; showStart = false
        if store.activeTabIndex < store.tabs.count {
            store.tabs[store.activeTabIndex].url   = raw
            store.tabs[store.activeTabIndex].title = raw
        }
        store.load(raw)
    }
    
    // MARK: - Time Ago
    func timeAgo(_ date: Date) -> String {
        let s = Int(-date.timeIntervalSinceNow)
        if s < 60    { return "just now" }
        if s < 3600  { return "\(s / 60)m ago" }
        if s < 86400 { return "\(s / 3600)h ago" }
        return "\(s / 86400)d ago"
    }
}
