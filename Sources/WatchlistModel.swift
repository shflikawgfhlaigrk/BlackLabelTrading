// Black Label Trading — watchlists + symbol snapshots. PURE Foundation/Combine (no SwiftUI).
//
// HONEST FRAMING: a watchlist holds symbols the user tracks. Each symbol carries an optional
// USER-ENTERED snapshot (last price, % change, RSI, relative volume, …). These are values the
// user types/imports themselves — this build wires NO live market feed, so nothing is invented.
// The screener and alert engines run over exactly these user-supplied snapshots. Empty fields
// simply don't match numeric filters (honest absence, never a fabricated value).
import Foundation
import Combine

// A user-tracked symbol with an optional self-entered metrics snapshot. All metrics are
// Optional so "unknown" is distinct from "zero" — the screener treats nil as no-data.
struct WatchSymbol: Identifiable, Codable, Hashable {
    var id = UUID()
    var symbol: String
    var note: String = ""
    var flagged: Bool = false

    // User-entered snapshot (optional — nil = unknown, never fabricated).
    var last: Double? = nil          // last price
    var changePct: Double? = nil     // % change on the session/day
    var volume: Double? = nil        // shares/contracts traded
    var relVolume: Double? = nil     // relative volume (x average)
    var rsi: Double? = nil           // RSI(14)
    var atr: Double? = nil           // ATR
    var marketCap: Double? = nil     // $ market cap (equities)
    var peRatio: Double? = nil       // P/E (equities)
    var sma50Rel: Double? = nil      // price relative to 50-day SMA, % (price/sma50 - 1)*100
    var sma200Rel: Double? = nil     // price relative to 200-day SMA, %
    var high52wRel: Double? = nil    // distance from 52-week high, % (<= 0)
    var sector: String = ""
    var updated: Date? = nil

    var display: String { symbol.uppercased() }
    var hasSnapshot: Bool {
        last != nil || changePct != nil || rsi != nil || relVolume != nil || volume != nil
    }
}

struct Watchlist: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var symbols: [WatchSymbol] = []
}

// Persistence — JSON in the app-support container (ship-no-data: starts empty).
final class WatchlistStore: ObservableObject {
    @Published var lists: [Watchlist] = [] { didSet { save() } }
    @Published var selectedID: UUID? = nil

    private let url: URL

    // `baseDir` defaults to the app-support container; tests pass a temp dir so they never
    // touch the user's real store.
    init(filename: String = "watchlists.json", baseDir: URL? = nil) {
        let base = baseDir ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BlackLabelTrading", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent(filename)
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Watchlist].self, from: data) else { return }
        lists = decoded
        selectedID = decoded.first?.id
    }
    private func save() {
        if let data = try? JSONEncoder().encode(lists) { try? data.write(to: url, options: .atomic) }
    }

    var selected: Watchlist? { lists.first { $0.id == selectedID } }
    var allSymbols: [WatchSymbol] { lists.flatMap { $0.symbols } }

    func addList(_ name: String) {
        let l = Watchlist(name: name.isEmpty ? "New list" : name)
        lists.insert(l, at: 0); selectedID = l.id
    }
    func renameList(_ id: UUID, to name: String) {
        guard let i = lists.firstIndex(where: { $0.id == id }) else { return }
        lists[i].name = name.isEmpty ? lists[i].name : name
    }
    func deleteList(_ id: UUID) {
        lists.removeAll { $0.id == id }
        if selectedID == id { selectedID = lists.first?.id }
    }
    func addSymbol(_ symbol: String, to listID: UUID) {
        let s = symbol.trimmingCharacters(in: .whitespaces).uppercased()
        guard !s.isEmpty, let i = lists.firstIndex(where: { $0.id == listID }) else { return }
        guard !lists[i].symbols.contains(where: { $0.symbol.uppercased() == s }) else { return }
        lists[i].symbols.insert(WatchSymbol(symbol: s), at: 0)
    }
    func upsertSymbol(_ sym: WatchSymbol, in listID: UUID) {
        guard let i = lists.firstIndex(where: { $0.id == listID }) else { return }
        if let j = lists[i].symbols.firstIndex(where: { $0.id == sym.id }) { lists[i].symbols[j] = sym }
        else { lists[i].symbols.insert(sym, at: 0) }
    }
    func removeSymbol(_ symID: UUID, from listID: UUID) {
        guard let i = lists.firstIndex(where: { $0.id == listID }) else { return }
        lists[i].symbols.removeAll { $0.id == symID }
    }
    func toggleFlag(_ symID: UUID, in listID: UUID) {
        guard let i = lists.firstIndex(where: { $0.id == listID }),
              let j = lists[i].symbols.firstIndex(where: { $0.id == symID }) else { return }
        lists[i].symbols[j].flagged.toggle()
    }
}
