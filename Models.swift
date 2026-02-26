import SwiftUI

// MARK: - Colours
extension Color {
    static let oBG     = Color(red: 0.06, green: 0.06, blue: 0.10)
    static let oCard   = Color(red: 0.11, green: 0.11, blue: 0.16)
    static let oAccent = Color(red: 0.42, green: 0.56, blue: 1.00)
    static let oBorder = Color(red: 0.20, green: 0.20, blue: 0.28)
    static let oText   = Color(red: 0.92, green: 0.92, blue: 0.96)
    static let oMuted  = Color(red: 0.50, green: 0.50, blue: 0.62)
    static let oRed    = Color(red: 1.00, green: 0.30, blue: 0.30)
    static let oGreen  = Color(red: 0.20, green: 0.85, blue: 0.50)
    static let oOrange = Color(red: 1.00, green: 0.65, blue: 0.20)
}

// MARK: - Models
struct ProxyEntry: Codable, Identifiable {
    var id: String { label }
    let ip: String
    let port: Int
    var label: String { "\(ip):\(port)" }
}

struct CustomServer: Identifiable, Codable {
    let id: UUID
    var name: String
    var ip: String
    var port: Int
    var label: String { "\(ip):\(port)" }
}

struct Bookmark: Identifiable, Codable {
    let id: UUID
    var title: String
    var url: String
}

struct HistoryItem: Identifiable, Codable {
    let id: UUID
    var title: String
    var url: String
    var date: Date
}

struct BrowserTab: Identifiable {
    let id: UUID
    var title: String
    var url: String
    var isIncognito: Bool
}

struct ProxyCountry: Identifiable {
    let id: String
    let name: String
}

let allCountries: [ProxyCountry] = [
    ProxyCountry(id: "ALL", name: "🌍 All Countries"),
    ProxyCountry(id: "US",  name: "🇺🇸 United States"),
    ProxyCountry(id: "GB",  name: "🇬🇧 United Kingdom"),
    ProxyCountry(id: "DE",  name: "🇩🇪 Germany"),
    ProxyCountry(id: "FR",  name: "🇫🇷 France"),
    ProxyCountry(id: "NL",  name: "🇳🇱 Netherlands"),
    ProxyCountry(id: "CA",  name: "🇨🇦 Canada"),
    ProxyCountry(id: "AU",  name: "🇦🇺 Australia"),
    ProxyCountry(id: "JP",  name: "🇯🇵 Japan"),
    ProxyCountry(id: "SG",  name: "🇸🇬 Singapore"),
    ProxyCountry(id: "IN",  name: "🇮🇳 India"),
    ProxyCountry(id: "BR",  name: "🇧🇷 Brazil"),
    ProxyCountry(id: "RU",  name: "🇷🇺 Russia"),
    ProxyCountry(id: "CN",  name: "🇨🇳 China"),
    ProxyCountry(id: "KR",  name: "🇰🇷 South Korea"),
    ProxyCountry(id: "ID",  name: "🇮🇩 Indonesia"),
    ProxyCountry(id: "TR",  name: "🇹🇷 Turkey"),
    ProxyCountry(id: "MX",  name: "🇲🇽 Mexico"),
    ProxyCountry(id: "PL",  name: "🇵🇱 Poland"),
    ProxyCountry(id: "UA",  name: "🇺🇦 Ukraine"),
    ProxyCountry(id: "ZA",  name: "🇿🇦 South Africa"),
    ProxyCountry(id: "AR",  name: "🇦🇷 Argentina"),
    ProxyCountry(id: "IT",  name: "🇮🇹 Italy"),
    ProxyCountry(id: "ES",  name: "🇪🇸 Spain"),
    ProxyCountry(id: "SE",  name: "🇸🇪 Sweden"),
    ProxyCountry(id: "CH",  name: "🇨🇭 Switzerland"),
    ProxyCountry(id: "NO",  name: "🇳🇴 Norway"),
    ProxyCountry(id: "FI",  name: "🇫🇮 Finland"),
    ProxyCountry(id: "HK",  name: "🇭🇰 Hong Kong"),
    ProxyCountry(id: "TH",  name: "🇹🇭 Thailand"),
    ProxyCountry(id: "VN",  name: "🇻🇳 Vietnam"),
    ProxyCountry(id: "PH",  name: "🇵🇭 Philippines"),
    ProxyCountry(id: "BD",  name: "🇧🇩 Bangladesh"),
    ProxyCountry(id: "PK",  name: "🇵🇰 Pakistan"),
    ProxyCountry(id: "NG",  name: "🇳🇬 Nigeria"),
    ProxyCountry(id: "EG",  name: "🇪🇬 Egypt"),
    ProxyCountry(id: "IL",  name: "🇮🇱 Israel"),
    ProxyCountry(id: "SA",  name: "🇸🇦 Saudi Arabia"),
    ProxyCountry(id: "AE",  name: "🇦🇪 UAE"),
    ProxyCountry(id: "PT",  name: "🇵🇹 Portugal"),
    ProxyCountry(id: "CZ",  name: "🇨🇿 Czech Republic"),
    ProxyCountry(id: "RO",  name: "🇷🇴 Romania"),
    ProxyCountry(id: "HU",  name: "🇭🇺 Hungary"),
    ProxyCountry(id: "MY",  name: "🇲🇾 Malaysia"),
    ProxyCountry(id: "CL",  name: "🇨🇱 Chile"),
    ProxyCountry(id: "CO",  name: "🇨🇴 Colombia"),
    ProxyCountry(id: "PE",  name: "🇵🇪 Peru"),
]
