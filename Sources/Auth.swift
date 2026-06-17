import SwiftUI
import AuthenticationServices
import CryptoKit
import AppKit

struct AuthView: View {
    @EnvironmentObject var session: Session
    @State private var creating = false
    @State private var email = ""
    @State private var pw = ""
    @State private var err = ""
    @State private var glow = false
    @State private var orb = false
    @StateObject private var google = GoogleSignIn()

    var body: some View {
        ZStack {
            RadialGradient(colors: [Color(hex: 0x1A160B), BLTheme.bg2], center: .top, startRadius: 0, endRadius: 850).ignoresSafeArea()
            // Slow drifting gold orbs for depth + life.
            Circle().fill(BLTheme.gold.opacity(0.18)).frame(width: 360).blur(radius: 140)
                .offset(x: orb ? -160 : -240, y: orb ? -160 : -220).scaleEffect(glow ? 1.18 : 0.9)
            Circle().fill(BLTheme.goldDim.opacity(0.12)).frame(width: 300).blur(radius: 150)
                .offset(x: orb ? 230 : 280, y: orb ? 240 : 300).scaleEffect(glow ? 1.1 : 0.85)

            VStack(spacing: 18) {
                ZStack {
                    Circle().fill(BLTheme.gold.opacity(0.18)).frame(width: 150).blur(radius: 40).scaleEffect(glow ? 1.1 : 0.85)
                    Logo(size: 92)
                }
                VStack(spacing: 5) {
                    Text("Black Label Trading").font(.system(size: 26, weight: .heavy, design: .rounded)).foregroundStyle(BLTheme.goldGrad)
                    Text("A live signal dashboard with a real scoring engine, journal, and risk math.").font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundColor(BLTheme.sub).multilineTextAlignment(.center)
                }
                // Social sign-in — above email/password, like top apps.
                // Google is shown only when a client ID is configured, so we never present a button that can't work.
                VStack(spacing: 10) {
                    SignInWithAppleButton(.signIn, onRequest: { req in
                        req.requestedScopes = [.fullName, .email]
                    }, onCompletion: { result in handleApple(result) })
                    .signInWithAppleButtonStyle(.white)
                    .frame(height: 44).clipShape(Capsule())

                    if googleConfigured {
                        Button(action: { startGoogle() }) {
                            HStack(spacing: 8) {
                                Image(systemName: "globe").font(.system(size: 14, weight: .bold))
                                Text(google.busy ? "Connecting to Google…" : "Sign in with Google")
                            }
                            .font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.text)
                            .frame(maxWidth: .infinity).frame(height: 44)
                            .background(BLTheme.bg2).clipShape(Capsule())
                            .overlay(Capsule().stroke(BLTheme.stroke, lineWidth: 1))
                        }.buttonStyle(.plain).disabled(google.busy)
                    }
                }
                .frame(width: 330)

                HStack(spacing: 10) {
                    Rectangle().fill(BLTheme.stroke).frame(height: 1)
                    Text("or").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
                    Rectangle().fill(BLTheme.stroke).frame(height: 1)
                }.frame(width: 330)

                HStack(spacing: 4) {
                    seg("Sign in", on: !creating) { creating = false; err = "" }
                    seg("Create account", on: creating) { creating = true; err = "" }
                }
                .padding(4).background(BLTheme.bg2).clipShape(Capsule()).overlay(Capsule().stroke(BLTheme.stroke, lineWidth: 1))

                VStack(spacing: 12) {
                    Field(title: "Email", text: $email, prompt: "you@trader.com")
                    Field(title: "Password", text: $pw, prompt: "••••••••")
                    GoldButton(label: creating ? "Create account" : "Sign in", fill: true, icon: "arrow.right") { submit() }
                    if !err.isEmpty { Text(err).font(.system(size: 12, weight: .medium, design: .rounded)).foregroundColor(BLTheme.red).multilineTextAlignment(.center) }
                    Button("Continue as guest") { session.email = "guest"; enter() }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(BLTheme.sub)
                }
                .frame(width: 330)
            }
            .padding(38).frame(width: 410)
            .background(BLTheme.panel.opacity(0.85)).clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(BLTheme.gold.opacity(0.22), lineWidth: 1))
            .shadow(color: BLTheme.gold.opacity(0.15), radius: 60, y: 12)
        }
        .frame(minWidth: 820, minHeight: 640)
        .onAppear {
            withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) { glow = true }
            withAnimation(.easeInOut(duration: 7).repeatForever(autoreverses: true)) { orb = true }
        }
    }
    @ViewBuilder private func seg(_ l: String, on: Bool, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            Text(l).font(.system(size: 13, weight: .bold, design: .rounded)).foregroundColor(on ? Color(hex: 0x1A1305) : BLTheme.sub)
                .padding(.vertical, 8).frame(maxWidth: .infinity)
                .background(on ? AnyShapeStyle(BLTheme.goldGrad) : AnyShapeStyle(Color.clear)).clipShape(Capsule())
        }.buttonStyle(.plain)
    }
    /// True only when a real Google OAuth client ID is present in Info.plist — gates the Google button
    /// so review never sees a sign-in option that can't complete.
    private var googleConfigured: Bool {
        !((Bundle.main.object(forInfoDictionaryKey: "GoogleClientID") as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private func submit() {
        let r = creating ? AccountStore.create(email, pw) : AccountStore.signIn(email, pw)
        switch r { case .success: session.email = email; enter(); case .failure(let e): withAnimation { err = e.rawValue } }
    }
    private func enter() { withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { session.signedIn = true } }

    // MARK: Sign in with Apple
    private func handleApple(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let auth):
            if let cred = auth.credential as? ASAuthorizationAppleIDCredential {
                // Email is only returned on first authorization, or hidden via "Hide My Email".
                session.email = cred.email ?? "apple-user"
                enter()
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
        err = ""
        google.start { outcome in
            switch outcome {
            case .success(let mail): session.email = mail; enter()
            case .needsClientID:     withAnimation { err = "Add your Google client ID in settings to enable Google sign-in." }
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

    private var clientID: String { (Bundle.main.object(forInfoDictionaryKey: "GoogleClientID") as? String) ?? "" }
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
