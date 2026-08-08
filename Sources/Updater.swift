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
//      (sha256 + exact product/bundle/build/team + strict code signature + Gatekeeper +
//      stapled notarization ticket), unzips, then a detached helper swaps the bundle and relaunches.
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

/// The published "latest version" descriptor. Extra wire keys are tolerated, but every
/// security-critical field is required so an incomplete release record fails closed at decode time.
struct UpdateManifest: Codable, Equatable {
    var product: String
    var latestBuild: Int
    var latestVersion: String?
    var downloadURL: String
    var sha256: String
    var notarized: Bool
    var teamID: String
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

/// Signed Info.plist identity fields checked before any staged app can cross the install boundary.
struct UpdateBundleMetadata: Equatable {
    var bundleIdentifier: String
    var displayName: String
    var bundleName: String
    var executableName: String
    var buildVersion: String
}

/// Durable handoff between the detached replacement helper and the newly launched app. The helper
/// owns automatic rollback; the app may clean a stranded backup only after proving the helper is
/// gone and applying the same build/backend acknowledgement policy.
struct UpdateRecoveryMarker: Codable, Equatable {
    var version: Int
    var helperPID: Int
    var watchdogPID: Int
    var statePath: String
    var backupPath: String
    var expectedBuild: Int
    var backendMode: String
    var backendPort: Int
}

enum UpdateRecoveryPolicy {
    static func mayDeleteBackup(marker: UpdateRecoveryMarker,
                                currentBuild: Int,
                                helperIsAlive: Bool,
                                watchdogIsAlive: Bool,
                                transactionCommitted: Bool,
                                backendAcknowledged: Bool) -> Bool {
        guard marker.version == 1,
              marker.helperPID > 1,
              marker.watchdogPID > 1,
              !marker.statePath.isEmpty,
              !marker.backupPath.isEmpty,
              marker.expectedBuild > 0,
              currentBuild == marker.expectedBuild,
              !helperIsAlive,
              !watchdogIsAlive,
              transactionCommitted,
              backendAcknowledged else {
            return false
        }
        switch marker.backendMode {
        case "bundled":
            return (1...65_535).contains(marker.backendPort)
        case "external":
            return marker.backendPort == 0
        default:
            return false
        }
    }
}

enum UpdaterError: LocalizedError {
    case badURL
    case transport(String)
    case http(Int)
    case decode(String)
    case manifest(String)
    case checksum(expected: String, got: String)
    case noAppInZip
    case bundle(String)
    case signature(String)
    case assessment(String)
    case unzip(String)
    case install(String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "The update location must be a valid HTTPS URL."
        case .transport(let m): return "Couldn't reach the update server (\(m))."
        case .http(let c): return "Update server returned HTTP \(c)."
        case .decode(let m): return "The update manifest wasn't understood (\(m))."
        case .manifest(let m): return "The update manifest failed its security checks (\(m)) — nothing was installed."
        case .checksum: return "The downloaded update failed its integrity check — nothing was installed."
        case .noAppInZip: return "The downloaded update didn't contain an app — nothing was installed."
        case .bundle(let m): return "The downloaded app wasn't the exact Black Label Trading build requested (\(m)) — nothing was installed."
        case .signature(let m): return "The update isn't a genuine, notarized Black Label build (\(m)) — nothing was installed."
        case .assessment(let m): return "macOS couldn't verify the update's notarization (\(m)) — nothing was installed."
        case .unzip(let m): return "Couldn't unpack the update (\(m))."
        case .install(let m): return "Couldn't install the update (\(m))."
        }
    }
}

/// URLSession follows redirects by default. This delegate authorizes every hop independently so an
/// HTTPS → HTTP → HTTPS chain cannot hide its insecure middle hop behind a secure final response.
final class HTTPSOnlyRedirectDelegate: NSObject, URLSessionTaskDelegate {
    static func redirectTargetIsAllowed(_ url: URL?) -> Bool {
        guard let url else { return false }
        return Updater.isHTTPSURL(url)
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(Self.redirectTargetIsAllowed(request.url) ? request : nil)
    }
}

// MARK: - Updater (pure core + side-effecting install)

enum Updater {
    static let productSlug = "trading"
    static let bundleIdentifier = "com.blacklabel.trading"
    static let productName = "Black Label Trading"
    static let executableName = "Black Label Trading"
    /// The update bundle MUST be a Developer ID Application signed by this exact team.
    static let teamID = "745ZPGFRA5"
    /// UserDefaults override for the manifest URL (QA / local testing). Empty → the live default.
    static let manifestOverrideKey = "bltd.updateManifestURL"
    static let lastCheckKey = "bltd.updateLastCheckEpoch"

    static var manifestURL: URL {
        let raw = (UserDefaults.standard.string(forKey: manifestOverrideKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty, let u = URL(string: raw), isHTTPSURL(u) { return u }
        return URL(string: "https://blacklabelbots.com/api/version/trading")!
    }

    // MARK: Pure, unit-tested

    /// Strictly newer build number. Equal or older → no update. The single source of "is there an update".
    static func isNewer(latestBuild: Int, currentBuild: Int) -> Bool { latestBuild > currentBuild }

    /// Lowercase hex sha256 — used to verify the downloaded bytes match the manifest.
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Only authenticated HTTPS URLs with a real host are accepted. Embedded credentials are
    /// rejected because they can leak through logs, proxies, and redirect handling.
    static func isHTTPSURL(_ url: URL) -> Bool {
        url.scheme?.caseInsensitiveCompare("https") == .orderedSame
            && !(url.host ?? "").isEmpty
            && url.user == nil
            && url.password == nil
    }

    /// Returns a normalized digest only when the manifest supplied exactly 64 hexadecimal bytes.
    static func normalizedSHA256(_ raw: String) throws -> String {
        let hex = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        guard raw.count == 64,
              raw.unicodeScalars.allSatisfy({ hex.contains($0) }) else {
            throw UpdaterError.manifest("sha256 must be exactly 64 hexadecimal characters")
        }
        return raw.lowercased()
    }

    /// Semantic manifest gate. Decode success alone is never authorization to prompt or download.
    @discardableResult
    static func validateManifest(_ manifest: UpdateManifest) throws -> URL {
        guard manifest.product == productSlug else {
            throw UpdaterError.manifest("product must be exactly \(productSlug)")
        }
        guard manifest.latestBuild > 0 else {
            throw UpdaterError.manifest("latest_build must be a positive integer")
        }
        guard manifest.teamID == teamID else {
            throw UpdaterError.manifest("team_id must be exactly \(teamID)")
        }
        guard manifest.notarized else {
            throw UpdaterError.manifest("notarized must be true")
        }
        _ = try normalizedSHA256(manifest.sha256)
        guard manifest.downloadURL == manifest.downloadURL.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: manifest.downloadURL),
              isHTTPSURL(url) else {
            throw UpdaterError.badURL
        }
        return url
    }

    /// Installation authorization additionally requires a readable current build and a strict
    /// increase. This gate is repeated at stage and immediately before helper handoff.
    @discardableResult
    static func validateInstallCandidate(_ manifest: UpdateManifest,
                                         currentBuild: Int) throws -> URL {
        let url = try validateManifest(manifest)
        guard currentBuild > 0 else {
            throw UpdaterError.manifest("installed CFBundleVersion is missing or invalid")
        }
        guard isNewer(latestBuild: manifest.latestBuild, currentBuild: currentBuild) else {
            throw UpdaterError.manifest("latest_build must be newer than the installed build")
        }
        return url
    }

    /// The downloaded response body itself must match the required manifest digest.
    static func verifyChecksum(_ data: Data, against manifest: UpdateManifest) throws {
        let expected = try normalizedSHA256(manifest.sha256)
        let got = sha256Hex(data)
        guard got == expected else {
            throw UpdaterError.checksum(expected: expected, got: got)
        }
    }

    /// Attach a quarantine record before extraction/assessment and require it to remain present.
    /// The top-level app record survives the final rename and lets LaunchServices independently
    /// enforce Gatekeeper again at first launch.
    static func applyQuarantine(to url: URL, originURL: URL) throws {
        var values = URLResourceValues()
        values.quarantineProperties = [
            "LSQuarantineType": "LSQuarantineTypeOtherDownload",
            "LSQuarantineAgentName": productName,
            "LSQuarantineTimeStamp": Date(),
            "LSQuarantineOriginURL": originURL
        ]
        var mutableURL = url
        do { try mutableURL.setResourceValues(values) }
        catch { throw UpdaterError.assessment("couldn't attach quarantine metadata") }
        try requireQuarantine(at: url)
    }

    static func quarantineIsPresent(at url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.quarantinePropertiesKey]),
              let properties = values.quarantineProperties else {
            return false
        }
        return !properties.isEmpty
    }

    static func requireQuarantine(at url: URL) throws {
        guard quarantineIsPresent(at: url) else {
            throw UpdaterError.assessment("quarantine metadata is missing")
        }
    }

    /// Fixed, minimal environment for every release-integrity subprocess. This prevents caller
    /// variables such as DITTONORSRC, COPYFILE_DISABLE, DEVELOPER_DIR, SDKROOT, or DYLD_* from
    /// changing extraction or tool resolution.
    static func sanitizedToolEnvironment() -> [String: String] {
        let accountHome = FileManager.default.homeDirectoryForCurrentUser
            .standardizedFileURL.path
        return [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": accountHome.hasPrefix("/") ? accountHome : "/var/empty",
            "LC_ALL": "C",
            "LANG": "C"
        ]
    }

    /// Decode the manifest JSON, surfacing a clean error on malformed input (never crashes).
    static func decodeManifest(_ data: Data) throws -> UpdateManifest {
        do { return try JSONDecoder().decode(UpdateManifest.self, from: data) }
        catch { throw UpdaterError.decode(error.localizedDescription) }
    }

    /// This binary's build number (CFBundleVersion). Zero means unreadable and is rejected by the
    /// install-candidate gate.
    static func currentBuild() -> Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0
    }

    static func currentVersionString() -> String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "\(v) (build \(currentBuild()))"
    }

    // MARK: Network

    private static let redirectDelegate = HTTPSOnlyRedirectDelegate()
    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.waitsForConnectivity = false
        return URLSession(configuration: c, delegate: redirectDelegate, delegateQueue: nil)
    }()

    static func fetchManifest(from url: URL = manifestURL) async throws -> UpdateManifest {
        guard isHTTPSURL(url) else { throw UpdaterError.badURL }
        var req = URLRequest(url: url)
        req.setValue("BlackLabelTrading/\(currentBuild()) (macOS)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: req) }
        catch { throw UpdaterError.transport(error.localizedDescription) }
        guard let http = resp as? HTTPURLResponse else {
            throw UpdaterError.transport("update server returned a non-HTTP response")
        }
        guard (200...299).contains(http.statusCode) else { throw UpdaterError.http(http.statusCode) }
        guard let finalURL = http.url, isHTTPSURL(finalURL) else { throw UpdaterError.badURL }
        let manifest = try decodeManifest(data)
        try validateManifest(manifest)
        return manifest
    }

    /// Returns the manifest IFF it describes a strictly-newer build, else nil. Records the check time.
    static func checkForUpdate() async throws -> UpdateManifest? {
        let installedBuild = currentBuild()
        guard installedBuild > 0 else {
            throw UpdaterError.manifest("installed CFBundleVersion is missing or invalid")
        }
        let m = try await fetchManifest()
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
        return isNewer(latestBuild: m.latestBuild, currentBuild: installedBuild) ? m : nil
    }

    /// True if it's been >= 24h since the last successful check (drives the daily auto-check).
    static func dueForBackgroundCheck(now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        return last == 0 || (now - last) >= 24 * 3600
    }

    // MARK: Verify (security-critical)

    static func readBundleMetadata(appURL: URL) throws -> UpdateBundleMetadata {
        guard appURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame else {
            throw UpdaterError.bundle("payload is not an .app bundle")
        }
        let plistURL = appURL.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        let data: Data
        do { data = try Data(contentsOf: plistURL, options: [.mappedIfSafe]) }
        catch { throw UpdaterError.bundle("Info.plist unreadable") }
        let value: Any
        do { value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) }
        catch { throw UpdaterError.bundle("Info.plist malformed") }
        guard let plist = value as? [String: Any] else {
            throw UpdaterError.bundle("Info.plist root is not a dictionary")
        }
        func requiredString(_ key: String) throws -> String {
            guard let value = plist[key] as? String, !value.isEmpty else {
                throw UpdaterError.bundle("Info.plist \(key) missing")
            }
            return value
        }
        return try UpdateBundleMetadata(
            bundleIdentifier: requiredString("CFBundleIdentifier"),
            displayName: requiredString("CFBundleDisplayName"),
            bundleName: requiredString("CFBundleName"),
            executableName: requiredString("CFBundleExecutable"),
            buildVersion: requiredString("CFBundleVersion")
        )
    }

    /// Rejects sibling or replayed apps even when they carry a valid signature from our shared team.
    static func validateBundleMetadata(_ metadata: UpdateBundleMetadata,
                                       against manifest: UpdateManifest) throws {
        guard metadata.bundleIdentifier == bundleIdentifier else {
            throw UpdaterError.bundle("bundle id \(metadata.bundleIdentifier) != \(bundleIdentifier)")
        }
        guard metadata.displayName == productName,
              metadata.bundleName == productName,
              metadata.executableName == executableName else {
            throw UpdaterError.bundle("product identity does not equal \(productName)")
        }
        let expectedBuild = String(manifest.latestBuild)
        guard metadata.buildVersion == expectedBuild else {
            throw UpdaterError.bundle("CFBundleVersion \(metadata.buildVersion) != \(expectedBuild)")
        }
    }

    /// Strictly validates all architectures against an exact Developer ID Application requirement:
    /// our bundle identifier, our team, Apple's Developer ID intermediate, and the application OID.
    static func verifySignature(appURL: URL,
                                requiredTeamID: String = teamID,
                                requiredBundleIdentifier: String = bundleIdentifier) throws {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, SecCSFlags(rawValue: 0), &staticCode) == errSecSuccess,
              let code = staticCode else {
            throw UpdaterError.signature("unreadable signature")
        }
        let reqStr = """
        identifier "\(requiredBundleIdentifier)" and anchor apple generic \
        and certificate 1[field.1.2.840.113635.100.6.2.6] exists \
        and certificate leaf[field.1.2.840.113635.100.6.1.13] exists \
        and certificate leaf[subject.OU] = "\(requiredTeamID)"
        """ as CFString
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(reqStr, SecCSFlags(rawValue: 0), &requirement) == errSecSuccess,
              let req = requirement else {
            throw UpdaterError.signature("requirement build failed")
        }
        let strictFlags = SecCSFlags(
            rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode
        )
        let status = SecStaticCodeCheckValidity(code, strictFlags, req)
        guard status == errSecSuccess else {
            throw UpdaterError.signature("validity \(status)")
        }
    }

    struct AssessmentResult: Equatable {
        var status: Int32
        var output: String
    }

    static func gatekeeperAssessmentIsAccepted(_ result: AssessmentResult) -> Bool {
        result.status == 0 && assessmentLines(result.output).contains("source=Notarized Developer ID")
    }

    static func stapleValidationIsAccepted(_ result: AssessmentResult) -> Bool {
        result.status == 0 && assessmentLines(result.output).contains {
            $0.caseInsensitiveCompare("The validate action worked!") == .orderedSame
        }
    }

    private static func assessmentLines(_ output: String) -> [String] {
        output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private static func runAssessmentTool(_ executable: String,
                                          arguments: [String]) throws -> AssessmentResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = sanitizedToolEnvironment()
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do { try process.run() }
        catch { throw UpdaterError.assessment("couldn't launch \(executable): \(error.localizedDescription)") }
        // Drain while the tool runs so verbose output cannot fill the pipe and deadlock verification.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return AssessmentResult(
            status: process.terminationStatus,
            output: String(data: data, encoding: .utf8) ?? ""
        )
    }

    private static func assessmentDiagnostic(_ result: AssessmentResult) -> String {
        let compact = result.output
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return compact.isEmpty ? "exit \(result.status)" : String(compact.prefix(300))
    }

    /// A valid signature is necessary but not sufficient. Require a real Gatekeeper verdict whose
    /// source is Notarized Developer ID and require the app's stapled ticket to validate locally.
    static func verifyDistribution(appURL: URL, against manifest: UpdateManifest) throws {
        try requireQuarantine(at: appURL)
        guard appURL.lastPathComponent == "\(productName).app" else {
            throw UpdaterError.bundle("app name \(appURL.lastPathComponent) != \(productName).app")
        }
        let metadata = try readBundleMetadata(appURL: appURL)
        try validateBundleMetadata(metadata, against: manifest)
        try verifySignature(appURL: appURL)

        let gatekeeper = try runAssessmentTool(
            "/usr/sbin/spctl",
            arguments: ["--assess", "--type", "execute", "--verbose=4", appURL.path]
        )
        guard gatekeeperAssessmentIsAccepted(gatekeeper) else {
            throw UpdaterError.assessment("Gatekeeper: \(assessmentDiagnostic(gatekeeper))")
        }

        let staple = try runAssessmentTool(
            "/usr/bin/stapler",
            arguments: ["validate", "-v", appURL.path]
        )
        guard stapleValidationIsAccepted(staple) else {
            throw UpdaterError.assessment("staple: \(assessmentDiagnostic(staple))")
        }
        try requireQuarantine(at: appURL)
    }

    // MARK: Download + stage (returns the verified, unzipped .app ready to swap in)

    /// Downloads the update zip, verifies its exact response bytes, then verifies the extracted
    /// bundle's identity/signature/Gatekeeper/notarization/staple state. Nothing is installed here.
    static func stage(_ m: UpdateManifest) async throws -> URL {
        let installedBuild = currentBuild()
        let url = try validateInstallCandidate(m, currentBuild: installedBuild)
        var request = URLRequest(url: url)
        request.setValue("application/zip", forHTTPHeaderField: "Accept")
        request.setValue("BlackLabelTrading/\(installedBuild) (macOS)", forHTTPHeaderField: "User-Agent")
        let data: Data, resp: URLResponse
        do { (data, resp) = try await session.data(for: request) }
        catch { throw UpdaterError.transport(error.localizedDescription) }
        guard let http = resp as? HTTPURLResponse else {
            throw UpdaterError.transport("download server returned a non-HTTP response")
        }
        guard (200...299).contains(http.statusCode) else { throw UpdaterError.http(http.statusCode) }
        guard let finalURL = http.url, isHTTPSURL(finalURL) else { throw UpdaterError.badURL }
        try verifyChecksum(data, against: m)

        // Write + unzip into a private temp dir.
        let work = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("bltd-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: work.path)
        var preserveWork = false
        defer {
            if !preserveWork { try? FileManager.default.removeItem(at: work) }
        }
        let zipURL = work.appendingPathComponent("update.zip")
        try data.write(to: zipURL, options: [.atomic])
        // Re-read what ditto will consume; a partial/corrupt filesystem write cannot bypass the
        // response-byte proof merely because the in-memory Data was valid.
        try verifyChecksum(try Data(contentsOf: zipURL), against: m)
        try applyQuarantine(to: zipURL, originURL: url)
        let unzipDir = work.appendingPathComponent("unzipped", isDirectory: true)
        try FileManager.default.createDirectory(at: unzipDir, withIntermediateDirectories: true)
        try runDitto(extract: zipURL, to: unzipDir)
        let contents = (try? FileManager.default.contentsOfDirectory(at: unzipDir, includingPropertiesForKeys: nil)) ?? []
        let apps = contents.filter { $0.pathExtension.caseInsensitiveCompare("app") == .orderedSame }
        guard !apps.isEmpty else { throw UpdaterError.noAppInZip }
        guard apps.count == 1, let appURL = apps.first else {
            throw UpdaterError.bundle("archive must contain exactly one top-level app")
        }
        try applyQuarantine(to: appURL, originURL: url)
        try verifyDistribution(appURL: appURL, against: m)
        preserveWork = true
        return appURL
    }

    private static func runDitto(extract zip: URL, to dest: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["--rsrc", "--extattr", "--qtn", "--acl", "-x", "-k", zip.path, dest.path]
        p.environment = sanitizedToolEnvironment()
        let err = Pipe(); p.standardError = err
        do { try p.run() } catch { throw UpdaterError.unzip(error.localizedDescription) }
        // Drain concurrently with process execution; malformed archives must not deadlock on a full pipe.
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: errData, encoding: .utf8) ?? "ditto \(p.terminationStatus)"
            throw UpdaterError.unzip(msg)
        }
    }
}
