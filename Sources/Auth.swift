import SwiftUI
import AuthenticationServices
import CryptoKit
import AppKit
import Security

// Whether THIS running build actually carries the restricted "Sign in with Apple"
// entitlement. Ad-hoc builds omit it (AMFI would SIGKILL the app), so we only show
// the Apple button when a Developer-ID build granted it — never a button that can't work.
enum AppleSignInSupport {
    static let available: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let val = SecTaskCopyValueForEntitlement(task, "com.apple.developer.applesignin" as CFString, nil)
        if let arr = val as? [String], !arr.isEmpty { return true }
        if let b = val as? Bool { return b }
        return val != nil
    }()
}

struct AuthView: View {
    @EnvironmentObject var session: Session
    @State private var creating = false
    @State private var email = ""
    @State private var pw = ""
    @State private var err = ""
    @Environment(\.blMotion) private var motion   // pauses ambient loops when app is backgrounded
    @State private var note = ""           // inline, non-crashing provider note (e.g. "add a client ID")
    @StateObject private var google = GoogleSignIn()

    var body: some View {
        ZStack {
            // Holographic first impression: living Aurora background + drifting particle motes.
            AuroraBackdrop()
            ParticleField()

            // The login panel can be taller than a short window (esp. once the Google/Apple inline
            // note appears). Centering an over-tall VStack pushed the BOTTOM control ("Continue as
            // guest") past the window's hittable bounds — it rendered but could never receive a click
            // (the dead-button bug). Wrapping the panel in a ScrollView guarantees EVERY control —
            // including the last one — is always reachable and hittable at any window size / display
            // scale. A GeometryReader sizes the scroll content to AT LEAST the viewport height so
            // the panel CENTERS when there's headroom and only SCROLLS when the window is too short.
            GeometryReader { geo in
            ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 18) {
                ZStack {
                    // Logo glow breathes via a pausable TimelineView (12fps is plenty for a 3s pulse);
                    // no repeatForever — a plain paused timeline provably stops ticking when backgrounded.
                    TimelineView(.animation(minimumInterval: 1.0 / 12.0, paused: !motion)) { tl in
                        let k = motion ? FXClock.easeInOut(FXClock.pingPong(tl.date, 3)) : 0
                        Circle().fill(BLTheme.gold.opacity(0.18)).frame(width: 150).blur(radius: 40).scaleEffect(0.85 + 0.25 * k)
                    }
                    Logo(size: 92).holoSheen()
                }
                VStack(spacing: 5) {
                    FoilText("Black Label Trading", size: 26, weight: .heavy, serif: false)
                    Text("A live signal dashboard with a real scoring engine, journal, and risk math.").font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundColor(BLTheme.sub).multilineTextAlignment(.center)
                }
                // Social sign-in — above email/password, like top apps. BOTH provider buttons ALWAYS
                // render (owner requirement). A button never no-ops: when a provider can't complete in
                // THIS build it still taps to a clear inline note that points to the fix (paste a Google
                // Desktop client ID in Settings, or build the signed app for Apple). When it CAN, it
                // does the real login. We never ship a dead button and never fake a login.
                VStack(spacing: 10) {
                    appleButton
                    googleButton
                }
                .frame(width: 330)

                // Inline, non-crashing provider note (only shown when a button needs setup).
                if !note.isEmpty {
                    Text(note)
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundColor(BLTheme.gold)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 330)
                        .transition(.opacity)
                }

                HStack(spacing: 10) {
                    Rectangle().fill(BLTheme.stroke).frame(height: 1)
                    Text("or").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
                    Rectangle().fill(BLTheme.stroke).frame(height: 1)
                }.frame(width: 330)

                HStack(spacing: 4) {
                    seg("Sign in", on: !creating) { creating = false; err = ""; note = "" }
                    seg("Create account", on: creating) { creating = true; err = ""; note = "" }
                }
                .padding(4).background(BLTheme.bg2).clipShape(Capsule()).overlay(Capsule().stroke(BLTheme.stroke, lineWidth: 1))

                VStack(spacing: 12) {
                    Field(title: "Email", text: $email, prompt: "you@trader.com")
                    Field(title: "Password", text: $pw, prompt: "••••••••", secure: true)
                    GoldButton(label: creating ? "Create account" : "Sign in", fill: true, icon: "arrow.right") { submit() }
                    if !err.isEmpty { Text(err).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundColor(BLTheme.red).multilineTextAlignment(.center) }
                    Button("Continue without an account") { enter(email: "guest", kind: .guest) }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
                }
                .frame(width: 330)
                // Return anywhere in the email/password form submits — the universal login gesture.
                .onSubmit { submit() }
            }
            .padding(38).frame(width: 410)
            // The holographic login panel — iridescent border + glow + pointer 3D tilt.
            .holoCard(radius: 26)
            // Vertical breathing room so the panel never sits flush against the window edges; the
            // ScrollView absorbs any overflow on short windows so no control is ever clipped/unhittable.
            .padding(.vertical, 28)
            // Fill AT LEAST the viewport so the panel centers vertically when the window is tall
            // enough; on a short window the natural (taller) content height wins and it scrolls.
            .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .center)
            }
            }
        }
        .frame(minWidth: 820, minHeight: 640)
    }
    // MARK: Social buttons — both ALWAYS render; behavior is runtime-gated, never a dead/no-op tap.

    /// Apple button. When this build carries the applesignin entitlement (the signed/provisioned
    /// build) we use the REAL `SignInWithAppleButton`. When it doesn't (adhoc/dev), we still SHOW a
    /// pixel-faithful Apple button, but tapping shows a clear, non-crashing note — never a fake login.
    @ViewBuilder private var appleButton: some View {
        if appleAvailable {
            SignInWithAppleButton(.signIn, onRequest: { req in
                req.requestedScopes = [.fullName, .email]
            }, onCompletion: { result in handleApple(result) })
            .signInWithAppleButtonStyle(.white)
            .frame(height: 44).clipShape(Capsule())
        } else {
            Button(action: {
                withAnimation { note = "Apple Sign-In activates in the signed build. Email, Google, or guest work now." }
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "applelogo").font(.system(size: 15, weight: .medium))
                    Text("Sign in with Apple")
                }
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(.black)
                .frame(maxWidth: .infinity).frame(height: 44)
                .background(Color.white)          // opaque, high-contrast — reads sharp
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Sign in with Apple")
        }
    }

    /// Google button — ALWAYS rendered. When a Desktop client ID is configured (Settings/UserDefaults)
    /// it runs the real PKCE login; otherwise it taps to an inline note pointing to Settings → Sign-in.
    @ViewBuilder private var googleButton: some View {
        Button(action: { startGoogle() }) {
            HStack(spacing: 8) {
                Image(systemName: "globe").font(.system(size: 14, weight: .bold))
                Text(google.busy ? "Connecting to Google…" : "Sign in with Google")
            }
            .font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
            .frame(maxWidth: .infinity).frame(height: 44)
            .background(BLTheme.panel)            // opaque reading surface — sharp text
            .clipShape(Capsule())
            .overlay(Capsule().stroke(BLTheme.stroke, lineWidth: 1))
        }
        .buttonStyle(.plain).disabled(google.busy)
        .accessibilityLabel("Sign in with Google")
    }

    @ViewBuilder private func seg(_ l: String, on: Bool, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            Text(l).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(on ? Color(hex: 0x1A1305) : BLTheme.sub)
                .padding(.vertical, 8).frame(maxWidth: .infinity)
                .background(on ? AnyShapeStyle(BLTheme.goldGrad) : AnyShapeStyle(Color.clear)).clipShape(Capsule())
        }.buttonStyle(.plain)
    }
    /// Apple sign-in runs for real only when this build actually carries the entitlement
    /// (the signed/provisioned build). The button still SHOWS when it doesn't — it just notes that.
    private var appleAvailable: Bool { AppleSignInSupport.available }
    private func submit() {
        let r = creating ? AccountStore.create(email, pw) : AccountStore.signIn(email, pw)
        switch r {
        case .success: enter(email: email, kind: .local)
        case .failure(let e): withAnimation { err = e.rawValue }
        }
    }
    private func enter(email: String, kind: AppSessionKind) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            session.begin(email: email, kind: kind)
        }
    }

    // MARK: Sign in with Apple
    private func handleApple(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let auth):
            if let cred = auth.credential as? ASAuthorizationAppleIDCredential {
                // Email is only returned on first authorization, or hidden via "Hide My Email".
                enter(email: cred.email ?? "apple-user", kind: .apple)
            } else {
                withAnimation { err = "Apple sign-in returned an unexpected credential." }
            }
        case .failure:
            // Includes user cancellation — keep it friendly.
            withAnimation { err = "Apple sign-in was cancelled or unavailable. Try again." }
        }
    }

    // MARK: Sign in with Google
    private func startGoogle() {
        err = ""; note = ""
        google.start { outcome in
            switch outcome {
            case .success(let mail): enter(email: mail, kind: .google)
            case .needsClientID:
                // Not an error — guide the user to the prominent Settings field. Never a dead tap.
                withAnimation { note = "To use Google: open Settings → Sign-in and paste a Google Desktop OAuth client ID. Email, Apple (signed build), or guest work now." }
            case .failure(let msg):  withAnimation { err = msg }
            }
        }
    }
}

// MARK: - Google OAuth 2.0 + PKCE via ASWebAuthenticationSession
enum GoogleOutcome { case success(String), needsClientID, failure(String) }

final class GoogleSignIn: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    @Published var busy = false
    private var session: ASWebAuthenticationSession?
    private var verifier = ""

    private var clientID: String { AppSettingsStore.googleClientID }
    private let redirectScheme = "com.blacklabel.trading"
    private var redirectURI: String { "com.blacklabel.trading:/oauth2redirect" }

    func start(_ done: @escaping (GoogleOutcome) -> Void) {
        let cid = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cid.isEmpty else { done(.needsClientID); return }

        // PKCE: verifier + S256 challenge.
        verifier = Self.randomURLSafe(64)
        let challenge = Self.s256(verifier)
        let state = Self.randomURLSafe(24)

        var comp = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comp.queryItems = [
            .init(name: "client_id", value: cid),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: "openid email profile"),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state)
        ]
        guard let authURL = comp.url else { done(.failure("Could not build Google auth URL.")); return }

        busy = true
        let s = ASWebAuthenticationSession(url: authURL, callbackURLScheme: redirectScheme) { [weak self] callback, error in
            guard let self = self else { return }
            if let error = error {
                let cancelled = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                DispatchQueue.main.async {
                    self.busy = false
                    done(cancelled ? .failure("Google sign-in was cancelled.") : .failure("Google sign-in failed. Try again."))
                }
                return
            }
            guard let url = callback,
                  let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                  let code = items.first(where: { $0.name == "code" })?.value,
                  items.first(where: { $0.name == "state" })?.value == state else {
                DispatchQueue.main.async { self.busy = false; done(.failure("Google sign-in returned no authorization code.")) }
                return
            }
            self.exchange(code: code, clientID: cid, done: done)
        }
        s.presentationContextProvider = self
        s.prefersEphemeralWebBrowserSession = false
        self.session = s
        s.start()
    }

    // Exchange code for tokens, then read the user's email from the userinfo endpoint.
    private func exchange(code: String, clientID: String, done: @escaping (GoogleOutcome) -> Void) {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = [
            "code": code,
            "client_id": clientID,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": verifier
        ].map { "\($0.key)=\(Self.formEncode($0.value))" }.joined(separator: "&")
        req.httpBody = body.data(using: .utf8)

        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self = self else { return }
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let token = json["access_token"] as? String else {
                DispatchQueue.main.async { self.busy = false; done(.failure("Google token exchange failed.")) }
                return
            }
            self.fetchUserInfo(token: token, done: done)
        }.resume()
    }

    private func fetchUserInfo(token: String, done: @escaping (GoogleOutcome) -> Void) {
        var req = URLRequest(url: URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
            guard let self = self else { return }
            let email = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["email"] as? String)
            DispatchQueue.main.async {
                self.busy = false
                if let email = email { done(.success(email)) }
                else { done(.failure("Could not read your Google account email.")) }
            }
        }.resume()
    }

    // Present from the key window.
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
    }

    // PKCE helpers.
    private static func randomURLSafe(_ n: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: n)
        _ = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    private static func s256(_ verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    private static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
