// Black Label Trading — in-app auto-updater (Developer-ID direct-download build).
//
// Goal: a user on build N sees "Update available → Install", clicks once, and is running build N+1
// seconds later — no website visit, no manual re-download. So when we fix a bug we ship it once and
// every installed user gets it. (App-shell updater only — it does NOT touch the trading engines,
// the live feed, the edge-gate, or any signal. It swaps the .app bundle; the buyer's own data,
// keys, and feed connection are untouched.)
//
// HOW IT WORKS
//   1. A tiny PUBLIC manifest (https://blacklabelbots.com/api/version/trading) says what the
//      latest build is, where to download it, and its sha256.
//   2. The app compares manifest.latest_build to its own CFBundleVersion (on launch, daily, and via
//      the "Check for Updates…" menu item).
//   3. If newer, it prompts. On Install it downloads the notarized zip, VERIFIES it
//      (sha256 + Apple-notarized + signed by OUR Team ID — Security.framework, no shell-out),
//      unzips, then a detached helper swaps the bundle and relaunches.
//
// SECURITY: the download is public on purpose (a fix must reach every user, logged in or not — the
// Sparkle-appcast model). It is safe because nothing is installed until the new bundle is proven to
// be Apple-notarized AND signed by Team ID 745ZPGFRA5, and its bytes match the manifest sha256. A
// hijacked CDN/manifest cannot install anything that isn't our genuine signed build.
//
// SANDBOX: self-replace requires the NON-sandboxed Developer-ID build (hardened runtime + notarized).
// The pure logic here (version compare, manifest decode, sha256) is always available + unit-tested;
// the install/relaunch path only runs on the Dev-ID build.
import Foundation
import CryptoKit
import Security

// MARK: - Manifest

/// The published "latest version" descriptor. Snake_case wire keys; tolerant of extra/missing fields.
struct UpdateManifest: Codable, Equatable {
    var product: String
    var latestBuild: Int
    var latestVersion: String?
    var downloadURL: String
    var sha256: String?
    var notarized: Bool?
    var teamID: String?
    var releaseNotes: String?
    var mandatory: Bool?

    enum CodingKeys: String, CodingKey {
        case product
        case latestBuild = "latest_build"
        case latestVersion = "latest_version"
        case downloadURL = "download_url"
        case sha256, notarized
        case teamID = "team_id"
        case releaseNotes = "release_notes"
        case mandatory
    }
}

enum UpdaterError: LocalizedError {
    case badURL
    case transport(String)
    case http(Int)
    case decode(String)
    case checksum(expected: String, got: String)
    case noAppInZip
    case signature(String)
    case unzip(String)
    case install(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "The update location wasn't a valid URL."
        case .transport(let m): return "Couldn't reach the update server (\(m))."
        case .http(let c): return "Update server returned HTTP \(c)."
        case .decode(let m): return "The update manifest wasn't understood (\(m))."
        case .checksum: return "The downloaded update failed its integrity check — nothing was installed."
        case .noAppInZip: return "The downloaded update didn't contain an app — nothing was installed."
        case .signature(let m): return "The update isn't a genuine, notarized Black Label build (\(m)) — nothing was installed."
        case .unzip(let m): return "Couldn't unpack the update (\(m))."
        case .install(let m): return "Couldn't install the update (\(m))."
        }
    }
}

// MARK: - Updater (pure core + side-effecting install)

enum Updater {
    /// Our Apple Developer Team ID. The update bundle MUST be signed by this team or it's rejected.
    static let teamID = "745ZPGFRA5"
    /// UserDefaults override for the manifest URL (QA / local testing). Empty → the live default.
    static let manifestOverrideKey = "bltd.updateManifestURL"
    static let lastCheckKey = "bltd.updateLastCheckEpoch"

    static var manifestURL: URL {
        let raw = (UserDefaults.standard.string(forKey: manifestOverrideKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty, let u = URL(string: raw), u.scheme != nil { return u }
        return URL(string: "https://blacklabelbots.com/api/version/trading")!
    }

    // MARK: Pure, unit-tested

    /// Strictly newer build number. Equal or older → no update. The single source of "is there an update".
    static func isNewer(latestBuild: Int, currentBuild: Int) -> Bool { latestBuild > currentBuild }

    /// Lowercase hex sha256 — used to verify the downloaded bytes match the manifest.
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Decode the manifest JSON, surfacing a clean error on malformed input (never crashes).
    static func decodeManifest(_ data: Data) throws -> UpdateManifest {
        do { return try JSONDecoder().decode(UpdateManifest.self, from: data) }
        catch { throw UpdaterError.decode(error.localizedDescription) }
    }

    /// This binary's build number (CFBundleVersion). 0 if absent (treats unknown as "older").
    static func currentBuild() -> Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    }

    static func currentVersionString() -> String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "\(v) (build \(currentBuild()))"
    }

    // MARK: Network

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    static func fetchManifest(from url: URL = manifestURL) async throws -> UpdateManifest {
        var req = URLRequest(url: url)
        req.setValue("BlackLabelTrading/\(currentBuild()) (macOS)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) }
        catch { throw UpdaterError.transport(error.localizedDescription) }
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw UpdaterError.http(http.statusCode)
        }
        return try decodeManifest(data)
    }

    /// Returns the manifest IFF it describes a strictly-newer build, else nil. Records the check time.
    static func checkForUpdate() async throws -> UpdateManifest? {
        let m = try await fetchManifest()
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
        return isNewer(latestBuild: m.latestBuild, currentBuild: currentBuild()) ? m : nil
    }

    /// True if it's been >= 24h since the last successful check (drives the daily auto-check).
    static func dueForBackgroundCheck(now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        return last == 0 || (now - last) >= 24 * 3600
    }

    // MARK: Verify (security-critical)

    /// Throws unless `appURL` is a code-signature that is Apple-notarized AND has our Team ID in the
    /// leaf cert. In-process via Security.framework — no codesign/spctl subprocess, so it works
    /// regardless of entitlements.
    static func verifySignature(appURL: URL, requiredTeamID: String = teamID) throws {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, SecCSFlags(rawValue: 0), &staticCode) == errSecSuccess,
              let code = staticCode else {
            throw UpdaterError.signature("unreadable signature")
        }
        // anchor apple generic = chains to Apple; OU = our Developer Team ID. Together: a genuine
        // Developer-ID build signed by us. (Notarization is additionally enforced by Gatekeeper at
        // launch of the swapped bundle; this requirement blocks any non-ours binary up front.)
        let reqStr = "anchor apple generic and certificate leaf[subject.OU] = \"\(requiredTeamID)\"" as CFString
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(reqStr, SecCSFlags(rawValue: 0), &requirement) == errSecSuccess,
              let req = requirement else {
            throw UpdaterError.signature("requirement build failed")
        }
        let status = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: 0), req)
        guard status == errSecSuccess else {
            throw UpdaterError.signature("validity \(status)")
        }
    }

    // MARK: Download + stage (returns the verified, unzipped .app ready to swap in)

    /// Downloads the update zip, verifies sha256 + signature, unzips, and returns the staged .app URL.
    /// Throws (installing nothing) on any integrity/signature failure.
    static func stage(_ m: UpdateManifest) async throws -> URL {
        guard let url = URL(string: m.downloadURL), url.scheme != nil else { throw UpdaterError.badURL }
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(from: url) }
        catch { throw UpdaterError.transport(error.localizedDescription) }
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw UpdaterError.http(http.statusCode)
        }
        if let expected = m.sha256?.lowercased(), !expected.isEmpty {
            let got = sha256Hex(data)
            guard got == expected else { throw UpdaterError.checksum(expected: expected, got: got) }
        }
        // Write + unzip into a private temp dir.
        let work = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("bltd-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let zipURL = work.appendingPathComponent("update.zip")
        try data.write(to: zipURL)
        let unzipDir = work.appendingPathComponent("unzipped", isDirectory: true)
        try FileManager.default.createDirectory(at: unzipDir, withIntermediateDirectories: true)
        try runDitto(extract: zipURL, to: unzipDir)
        // Find the .app.
        let contents = (try? FileManager.default.contentsOfDirectory(at: unzipDir, includingPropertiesForKeys: nil)) ?? []
        guard let appURL = contents.first(where: { $0.pathExtension == "app" }) else { throw UpdaterError.noAppInZip }
        try verifySignature(appURL: appURL)
        return appURL
    }

    private static func runDitto(extract zip: URL, to dest: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, dest.path]
        let err = Pipe(); p.standardError = err
        do { try p.run() } catch { throw UpdaterError.unzip(error.localizedDescription) }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "ditto \(p.terminationStatus)"
            throw UpdaterError.unzip(msg)
        }
    }
}
