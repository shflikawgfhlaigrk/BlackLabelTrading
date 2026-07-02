// Black Label Trading — broker-CSV journal import + seasonality/correlations. PURE MATH.
//
// HONEST FRAMING: imports the user's OWN broker/platform trade export (CSV). Maps common
// column headers (symbol, side, qty, entry/exit price, P&L, open/close time, MAE/MFE, tags)
// into neutral rows the journal can absorb. Seasonality + correlation operate ONLY on the
// user's own closed trades (TradeStat). Nothing is downloaded or invented; unmapped/garbage
// rows are skipped and counted so the UI is honest about what imported.
import Foundation

// A neutral imported row (decoupled from the SwiftUI `Trade` so it's headlessly testable).
struct ImportedTrade {
    var symbol: String = ""
    var isLong: Bool = true
    var qty: Double = 0
    var entry: Double = 0
    var exit: Double = 0
    var pnl: Double = 0
    var opened: Date? = nil
    var closed: Date? = nil
    var maeR: Double = 0
    var mfeR: Double = 0
    var tags: [String] = []
}

enum BrokerCSV {
    // Header aliases -> canonical field. Lowercased, punctuation-insensitive match.
    private static let aliases: [String: [String]] = [
        "symbol":  ["symbol", "ticker", "instrument", "contract", "market", "product"],
        "side":    ["side", "direction", "buy/sell", "buysell", "type", "action", "longshort", "l/s"],
        "qty":     ["qty", "quantity", "size", "shares", "contracts", "lots", "volume", "filledqty"],
        "entry":   ["entry", "entryprice", "openprice", "avgentry", "buyprice", "priceopen", "fillprice", "avgprice", "open"],
        "exit":    ["exit", "exitprice", "closeprice", "avgexit", "sellprice", "priceclose", "close"],
        "pnl":     ["pnl", "p/l", "p&l", "profit", "netpnl", "realizedpnl", "profitloss", "net", "gain", "realized"],
        "opened":  ["opened", "opentime", "entrytime", "entrydate", "datetimeopen", "boughttime", "timeopen", "openeddate"],
        "closed":  ["closed", "closetime", "exittime", "exitdate", "datetimeclose", "soldtime", "timeclose", "closeddate", "date", "time"],
        "mae":     ["mae", "maxadverse", "maer", "adverse", "drawdown"],
        "mfe":     ["mfe", "maxfavorable", "mfer", "favorable", "runup"],
        "tags":    ["tags", "tag", "setup", "strategy", "labels", "notes", "comment"],
    ]

    private static func norm(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    // Parse a broker CSV. Returns mapped rows + skipped count + the header mapping found
    // (canonical field -> column index) so the UI can show what it understood.
    static func parse(_ text: String) -> (rows: [ImportedTrade], skipped: Int, mapping: [String: Int]) {
        let lines = text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).map { String($0) }.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count >= 2 else { return ([], 0, [:]) }

        let header = splitCSVLine(lines[0])
        var mapping: [String: Int] = [:]
        for (i, raw) in header.enumerated() {
            let n = norm(raw)
            for (canon, aliasList) in aliases where mapping[canon] == nil {
                if aliasList.contains(where: { norm($0) == n }) { mapping[canon] = i }
            }
        }
        // Need at least a P&L OR an entry/exit pair to compute a result; else nothing maps.
        let hasPnL = mapping["pnl"] != nil
        let hasPrices = mapping["entry"] != nil && mapping["exit"] != nil
        guard hasPnL || hasPrices else { return ([], lines.count - 1, mapping) }

        var rows: [ImportedTrade] = []; var skipped = 0
        for line in lines.dropFirst() {
            let cols = splitCSVLine(line)
            func col(_ key: String) -> String? {
                guard let i = mapping[key], i < cols.count else { return nil }
                let v = cols[i].trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? nil : v
            }
            var t = ImportedTrade()
            t.symbol = (col("symbol") ?? "").uppercased()
            t.isLong = parseSide(col("side"))
            t.qty = num(col("qty")) ?? 0
            t.entry = num(col("entry")) ?? 0
            t.exit = num(col("exit")) ?? 0
            t.maeR = num(col("mae")) ?? 0
            t.mfeR = num(col("mfe")) ?? 0
            t.opened = parseDate(col("opened"))
            t.closed = parseDate(col("closed"))
            if let tg = col("tags") { t.tags = tg.split(whereSeparator: { $0 == ";" || $0 == "," || $0 == " " }).map { String($0).lowercased() }.filter { !$0.isEmpty } }

            if let p = num(col("pnl")) {
                t.pnl = p
            } else if hasPrices, t.entry > 0, t.exit > 0 {
                // Derive P&L from prices. The move is in POINTS — it must be multiplied by the
                // instrument's $/point to be honest dollars (a futures point is NOT $1). Mapped
                // futures use their real contract spec; a plain ticker (no dated-contract suffix)
                // is equity/cash where $/point = 1 (move × shares = dollars). A dated futures
                // contract with an UNKNOWN $/point can't be dollarized honestly — skip it.
                let perUnit = t.isLong ? (t.exit - t.entry) : (t.entry - t.exit)
                let qty = max(1, t.qty)
                if let pv = TradingSymbolScope.pointValue(for: t.symbol) {
                    t.pnl = perUnit * pv * qty
                } else if TradingSymbolScope.futuresRoot(t.symbol) == TradingSymbolScope.normalized(t.symbol) {
                    t.pnl = perUnit * qty                 // equity/cash: $/point = 1
                } else {
                    skipped += 1; continue                // dated futures, unknown $/pt → don't fabricate $
                }
            } else {
                skipped += 1; continue
            }
            rows.append(t)
        }
        return (rows, skipped, mapping)
    }

    // Side parser: handles buy/sell, long/short, +/-, b/s, and broker tokens (IB SLD/BOT,
    // Sold/Bought). Returns true=long. Short tokens are matched explicitly BEFORE the default-long
    // fallthrough so an IB 'SLD' is not mis-classified as long (which would invert derived P&L).
    static func parseSide(_ s: String?) -> Bool {
        guard let v = s?.lowercased().trimmingCharacters(in: .whitespaces) else { return true }
        if v.contains("sell") || v.contains("sold") || v.contains("short")
            || v == "s" || v == "sld" || v == "sl" || v.hasPrefix("-") { return false }
        return true   // default long (buy/bought/bot/long/+ all fall through here)
    }

    static func num(_ s: String?) -> Double? {
        guard var v = s else { return nil }
        // Strip currency symbols, thousands separators, parentheses-as-negative.
        var negative = false
        v = v.trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("(") && v.hasSuffix(")") { negative = true; v = String(v.dropFirst().dropLast()) }
        v = v.replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: "%", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard let d = Double(v) else { return nil }
        return negative ? -abs(d) : d
    }

    private static let dateFormats = ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm",
                                      "yyyy-MM-dd", "MM/dd/yyyy HH:mm:ss", "MM/dd/yyyy HH:mm", "MM/dd/yyyy",
                                      "M/d/yyyy H:mm", "M/d/yyyy", "dd/MM/yyyy", "yyyy/MM/dd"]
    // d/m vs m/d slash dates are ambiguous. When a field is > 12 it can ONLY be the day, which
    // forces the order unambiguously — so we read that off the value first and parse with the
    // correct order, instead of blindly trying MM/dd first and silently mis-dating dd/MM exports.
    static func parseDate(_ s: String?) -> Date? {
        guard let raw = s?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: raw) { return d }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        // Disambiguate slash dates by the value itself when one field rules out month-first.
        let head = raw.split(separator: " ").first.map(String.init) ?? raw
        let parts = head.split(separator: "/").map { Int($0) }
        if parts.count == 3, let a = parts[0], let b = parts[1] {
            let timeSuffix = raw.dropFirst(head.count)
            if a > 12, b >= 1, b <= 12 {            // first field must be the day -> dd/MM
                for fmt in ["dd/MM/yyyy HH:mm:ss", "dd/MM/yyyy HH:mm", "dd/MM/yyyy", "d/M/yyyy H:mm", "d/M/yyyy"] {
                    f.dateFormat = fmt; if let d = f.date(from: raw) { return d }
                }
            } else if b > 12, a >= 1, a <= 12 {     // second field must be the day -> MM/dd
                for fmt in ["MM/dd/yyyy HH:mm:ss", "MM/dd/yyyy HH:mm", "MM/dd/yyyy", "M/d/yyyy H:mm", "M/d/yyyy"] {
                    f.dateFormat = fmt; if let d = f.date(from: raw) { return d }
                }
            }
            _ = timeSuffix
        }
        for fmt in dateFormats { f.dateFormat = fmt; if let d = f.date(from: raw) { return d } }
        return nil
    }

    // Minimal RFC-4180-ish CSV splitter (handles quoted fields with embedded commas).
    static func splitCSVLine(_ line: String) -> [String] {
        var out: [String] = []; var cur = ""; var inQuotes = false
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                if inQuotes && i + 1 < chars.count && chars[i+1] == "\"" { cur.append("\""); i += 1 }
                else { inQuotes.toggle() }
            } else if c == "," && !inQuotes {
                out.append(cur); cur = ""
            } else { cur.append(c) }
            i += 1
        }
        out.append(cur)
        return out.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

// MARK: - Seasonality + correlations (over the user's own closed trades)
enum Seasonality {
    // Monthly performance buckets (1=Jan … 12=Dec). Only months with trades are non-zero.
    struct MonthBucket: Identifiable { let month: Int; let name: String; let trades: Int; let netPnL: Double; let winRate: Double; let expectancyR: Double; var id: Int { month } }
    static func byMonth(_ stats: [TradeStat], calendar: Calendar = .current) -> [MonthBucket] {
        let names = ["", "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return (1...12).map { m in
            let inM = stats.filter { calendar.component(.month, from: $0.date) == m }
            let decided = inM.filter { $0.pnl != 0 }
            let wr = decided.isEmpty ? 0 : Double(decided.filter { $0.pnl > 0 }.count) / Double(decided.count) * 100
            let exp = inM.isEmpty ? 0 : inM.reduce(0) { $0 + $1.r } / Double(inM.count)
            return MonthBucket(month: m, name: names[m], trades: inM.count, netPnL: inM.reduce(0) { $0 + $1.pnl }, winRate: wr, expectancyR: exp)
        }
    }

    // Hold-time vs outcome buckets — does the user do better on quick or slow trades?
    struct HoldBucket: Identifiable { let label: String; let lo: Double; let hi: Double; let trades: Int; let netPnL: Double; let winRate: Double; var id: String { label } }
    static func byHoldTime(_ stats: [TradeStat]) -> [HoldBucket] {
        let edges: [(String, Double, Double)] = [
            ("< 5m", 0, 5), ("5–15m", 5, 15), ("15–60m", 15, 60),
            ("1–4h", 60, 240), ("4h–1d", 240, 1440), ("> 1d", 1440, .infinity)
        ]
        return edges.map { (label, lo, hi) in
            let inB = stats.filter { $0.holdMinutes >= lo && $0.holdMinutes < hi }
            let decided = inB.filter { $0.pnl != 0 }
            let wr = decided.isEmpty ? 0 : Double(decided.filter { $0.pnl > 0 }.count) / Double(decided.count) * 100
            return HoldBucket(label: label, lo: lo, hi: hi, trades: inB.count, netPnL: inB.reduce(0) { $0 + $1.pnl }, winRate: wr)
        }
    }
}

enum Correlation {
    // Pearson correlation of two equal-length series. 0 when undefined.
    static func pearson(_ xs: [Double], _ ys: [Double]) -> Double {
        let n = min(xs.count, ys.count)
        guard n > 1 else { return 0 }
        let x = Array(xs.prefix(n)), y = Array(ys.prefix(n))
        let mx = x.reduce(0, +) / Double(n), my = y.reduce(0, +) / Double(n)
        var num = 0.0, dx = 0.0, dy = 0.0
        for i in 0..<n { let a = x[i] - mx, b = y[i] - my; num += a * b; dx += a * a; dy += b * b }
        let den = (dx * dy).squareRoot()
        return den > 0 ? num / den : 0
    }

    // Correlation matrix of per-symbol DAILY P&L across the user's trades. Symbols that never
    // share a trading day with another contribute 0 off-diagonal (honest — no overlap, no signal).
    // A pair needs at least this many SHARED trading days before a Pearson value is emitted: on 2
    // shared days correlation is always exactly ±1 (two points are collinear), which would read as
    // spurious "concentration risk". Below the floor the cell is 0 (no signal), per the convention above.
    static let minSharedDays = 3
    struct Matrix { let symbols: [String]; let values: [[Double]] }
    static func symbolDailyMatrix(_ stats: [TradeStat], calendar: Calendar = .current) -> Matrix {
        let syms = Array(Set(stats.map { $0.symbol.uppercased() }.filter { !$0.isEmpty })).sorted()
        guard syms.count >= 2 else { return Matrix(symbols: syms, values: syms.map { _ in [1.0] }) }
        // All distinct trading days (sorted).
        let days = Array(Set(stats.map { calendar.startOfDay(for: $0.date) })).sorted()
        // symbol -> [day -> netPnL], plus the set of days the symbol actually traded.
        var series: [String: [Double]] = [:]
        var traded: [String: Set<Date>] = [:]
        for s in syms {
            let bySym = stats.filter { $0.symbol.uppercased() == s }
            let dayMap = Dictionary(grouping: bySym) { calendar.startOfDay(for: $0.date) }
                .mapValues { $0.reduce(0) { $0 + $1.pnl } }
            series[s] = days.map { dayMap[$0] ?? 0 }
            traded[s] = Set(dayMap.keys)
        }
        var values = [[Double]](repeating: [Double](repeating: 0, count: syms.count), count: syms.count)
        for i in 0..<syms.count {
            for j in 0..<syms.count {
                if i == j { values[i][j] = 1.0; continue }
                let shared = (traded[syms[i]] ?? []).intersection(traded[syms[j]] ?? []).count
                values[i][j] = shared >= minSharedDays
                    ? pearson(series[syms[i]] ?? [], series[syms[j]] ?? [])
                    : 0.0   // too few shared days for an honest correlation
            }
        }
        return Matrix(symbols: syms, values: values)
    }
}
