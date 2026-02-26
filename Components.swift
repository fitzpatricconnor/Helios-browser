import SwiftUI

// MARK: - Toolbar Button
struct TBBtn: View {
    let icon: String; let color: Color; let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 16)).foregroundColor(color)
                .frame(maxWidth: .infinity).frame(height: 36)
        }
    }
}

// MARK: - Stat Badge
struct StatBadge: View {
    let value: String; let label: String; let color: Color
    var body: some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 20, weight: .bold)).foregroundColor(color)
            Text(label).font(.system(size: 10)).foregroundColor(Color.oMuted)
        }
    }
}

// MARK: - Action Button
struct ActionButton: View {
    let label: String; let icon: String?; let color: Color; let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon) }
                Text(label)
            }
            .font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(color).clipShape(Capsule())
        }
    }
}

// MARK: - Sheet Header
struct SheetHeader: View {
    let title: String; let onDone: () -> Void
    var body: some View {
        HStack {
            Text(title).font(.system(size: 17, weight: .bold)).foregroundColor(Color.oText)
            Spacer()
            Button("Done", action: onDone).foregroundColor(Color.oAccent)
        }.padding(.bottom, 12)
    }
}

// MARK: - Sheet Overlay
struct SheetOverlay<Content: View>: View {
    let onDismiss: () -> Void
    @ViewBuilder let content: () -> Content
    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea().onTapGesture { onDismiss() }
            ScrollView {
                VStack { content() }
                    .padding(22).background(Color.oCard)
                    .clipShape(RoundedRectangle(cornerRadius: 22)).padding(24)
            }
        }
    }
}

// MARK: - Share Sheet
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Proxy Text Field
struct ProxyTextField: View {
    let placeholder: String
    @Binding var text: String
    var body: some View {
        TextField(placeholder, text: $text)
            .font(.system(size: 13)).foregroundColor(Color.oText)
            .autocapitalization(.none).disableAutocorrection(true)
            .padding(9).background(Color.oCard)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.oBorder, lineWidth: 1))
    }
}

// MARK: - Custom Server Section
struct CustomServerSection: View {
    @ObservedObject var proxy: ProxyManager
    @State private var showAdd = false
    @State private var newName = ""
    @State private var newIP   = ""
    @State private var newPort = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Custom Servers").font(.system(size: 12, weight: .semibold)).foregroundColor(Color.oMuted)
                Spacer()
                Button { withAnimation { showAdd.toggle() } } label: {
                    Image(systemName: showAdd ? "minus.circle.fill" : "plus.circle.fill")
                        .foregroundColor(Color.oAccent).font(.system(size: 18))
                }
            }
            if showAdd {
                VStack(spacing: 8) {
                    ProxyTextField(placeholder: "Name (e.g. My Server)", text: $newName)
                    ProxyTextField(placeholder: "IP Address (e.g. 1.2.3.4)", text: $newIP)
                    ProxyTextField(placeholder: "Port (e.g. 3128)", text: $newPort)
                    Button {
                        guard !newIP.isEmpty, let port = Int(newPort) else { return }
                        let name = newName.isEmpty ? "\(newIP):\(port)" : newName
                        proxy.addCustomServer(name: name, ip: newIP, port: port)
                        if let last = proxy.customServers.last { proxy.useCustomServer(last) }
                        newName = ""; newIP = ""; newPort = ""
                        withAnimation { showAdd = false }
                    } label: {
                        Text("Add & Connect")
                            .font(.system(size: 13, weight: .semibold)).foregroundColor(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 9)
                            .background(Color.oGreen).clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(10).background(Color.oBG).clipShape(RoundedRectangle(cornerRadius: 10))
            }
            if proxy.customServers.isEmpty {
                Text("No custom servers.\nTap + to add your own.")
                    .font(.system(size: 11)).foregroundColor(Color.oMuted)
                    .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.vertical, 4)
            } else {
                VStack(spacing: 6) {
                    ForEach(proxy.customServers) { s in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.name).font(.system(size: 13, weight: .medium)).foregroundColor(Color.oText)
                                Text(s.label).font(.system(size: 10, design: .monospaced)).foregroundColor(Color.oMuted)
                            }
                            Spacer()
                            Button { proxy.useCustomServer(s) } label: {
                                Text("Use").font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(Color.oAccent).clipShape(Capsule())
                            }
                            Button { proxy.removeCustomServer(s) } label: {
                                Image(systemName: "trash").foregroundColor(Color.oRed).font(.system(size: 12))
                            }.padding(.leading, 6)
                        }
                        .padding(10).background(Color.oBG).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }
}

// MARK: - Startup Screen
struct StartupScreen: View {
    @ObservedObject var proxy: ProxyManager
    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            ZStack {
                Circle().fill(Color.oAccent.opacity(0.07)).frame(width: 140, height: 140)
                Circle().fill(Color.oAccent.opacity(0.13)).frame(width: 110, height: 110)
                Image(systemName: "circle.hexagongrid.fill").font(.system(size: 48)).foregroundColor(Color.oAccent)
            }
            Text("Orion Browser").font(.system(size: 26, weight: .bold, design: .rounded)).foregroundColor(Color.oText)
            VStack(spacing: 10) {
                ProgressView().progressViewStyle(CircularProgressViewStyle(tint: Color.oAccent)).scaleEffect(1.3)
                Text(proxy.status).font(.system(size: 13)).foregroundColor(Color.oMuted)
                    .multilineTextAlignment(.center).padding(.horizontal, 40)
            }
            if proxy.testedCount > 0 {
                HStack(spacing: 24) {
                    StatBadge(value: "\(proxy.testedCount)",  label: "Tested",  color: Color.oAccent)
                    StatBadge(value: "\(proxy.workingCount)", label: "Working", color: Color.oGreen)
                }
                .padding(16).background(Color.oCard).clipShape(RoundedRectangle(cornerRadius: 14))
            }
            Button { ProxyManager.shared.findBestProxy() } label: {
                Label("Retry", systemImage: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(Color.oAccent)
            }
            Spacer()
        }
    }
}

// MARK: - Home Screen
struct HomeScreen: View {
    let onNavigate: (String) -> Void
    let links: [(String, String, String, Color)] = [
        ("globe",           "Wikipedia",  "https://en.wikipedia.org", .blue),
        ("newspaper.fill",  "BBC News",   "https://bbc.com/news",     Color.oRed),
        ("magnifyingglass", "DuckDuckGo", "https://duckduckgo.com",   Color.oOrange),
        ("video.fill",      "YouTube",    "https://youtube.com",      Color.oRed),
        ("bag.fill",        "Amazon",     "https://amazon.com",       Color.oOrange),
        ("person.2.fill",   "Reddit",     "https://reddit.com",       .orange),
        ("network",         "GitHub",     "https://github.com",       .purple),
        ("doc.text.fill",   "Example",    "https://example.com",      .gray)
    ]
    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 24) {
                Spacer(minLength: 10)
                VStack(spacing: 8) {
                    ZStack {
                        Circle().fill(Color.oAccent.opacity(0.07)).frame(width: 110, height: 110)
                        Circle().fill(Color.oAccent.opacity(0.13)).frame(width: 85, height: 85)
                        Image(systemName: "circle.hexagongrid.fill").font(.system(size: 38)).foregroundColor(Color.oAccent)
                    }
                    Text("Orion Browser").font(.system(size: 24, weight: .bold, design: .rounded)).foregroundColor(Color.oText)
                    Text("Fast · Private · Proxy-Powered").font(.system(size: 12)).foregroundColor(Color.oMuted)
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(links, id: \.2) { icon, label, url, color in
                        Button { onNavigate(url) } label: {
                            HStack(spacing: 10) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.15)).frame(width: 30, height: 30)
                                    Image(systemName: icon).font(.system(size: 13)).foregroundColor(color.opacity(0.9))
                                }
                                Text(label).font(.system(size: 13, weight: .medium)).foregroundColor(Color.oText)
                                Spacer()
                            }
                            .padding(12).background(Color.oCard)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.oBorder, lineWidth: 1))
                        }
                    }
                }
                .padding(.horizontal, 14)
                Spacer(minLength: 10)
            }
        }
    }
}
