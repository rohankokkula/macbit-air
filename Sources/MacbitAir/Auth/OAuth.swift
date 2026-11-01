import AppKit
import CryptoKit
import Foundation
import Network

enum AuthError: LocalizedError {
    case notConfigured
    case notSignedIn
    case stateMismatch
    case denied(String)
    case timedOut
    case tokenEndpoint(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Add your OAuth client to config.json"
        case .notSignedIn: return "Sign in with Google"
        case .stateMismatch: return "Sign-in failed (state mismatch)"
        case .denied(let why): return "Sign-in denied: \(why)"
        case .timedOut: return "Sign-in timed out"
        case .tokenEndpoint(let msg): return "Token error: \(msg)"
        }
    }
}

/// Google OAuth 2.0 for installed apps: PKCE + loopback redirect (http://127.0.0.1:<port>).
@MainActor
final class GoogleAuth {
    /// Read-only scopes for the three data types we show.
    static let scopes = [
        "https://www.googleapis.com/auth/googlehealth.activity_and_fitness.readonly",      // steps
        "https://www.googleapis.com/auth/googlehealth.health_metrics_and_measurements.readonly", // heart rate
        "https://www.googleapis.com/auth/googlehealth.sleep.readonly",                     // sleep
    ]

    private static let authEndpoint = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    private static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    private(set) var tokens: TokenSet? = Keychain.load()
    private var refreshTask: Task<TokenSet, Error>?

    var isSignedIn: Bool { tokens != nil }

    var config: AppConfig? {
        guard let c = AppConfig.load(), c.isFilledIn else { return nil }
        return c
    }

    // MARK: Access token

    func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let current = tokens else { throw AuthError.notSignedIn }
        if !forceRefresh, current.expiry > Date().addingTimeInterval(60) {
            return current.accessToken
        }
        // Coalesce concurrent refreshes (several fetches fire at once each minute).
        if let task = refreshTask { return try await task.value.accessToken }
        let task = Task { try await self.refresh(current) }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value.accessToken
    }

    private func refresh(_ current: TokenSet) async throws -> TokenSet {
        guard let config else { throw AuthError.notConfigured }
        let json = try await postForm(Self.tokenEndpoint, [
            "client_id": config.clientId,
            "client_secret": config.clientSecret,
            "refresh_token": current.refreshToken,
            "grant_type": "refresh_token",
        ])
        if let err = json["error"] as? String {
            if err == "invalid_grant" { signOut() }   // revoked or expired refresh token
            throw AuthError.tokenEndpoint(err)
        }
        guard let access = json["access_token"] as? String else {
            throw AuthError.tokenEndpoint("no access_token")
        }
        let expiresIn = (json["expires_in"] as? Double) ?? 3600
        let updated = TokenSet(accessToken: access,
                               refreshToken: (json["refresh_token"] as? String) ?? current.refreshToken,
                               expiry: Date().addingTimeInterval(expiresIn))
        tokens = updated
        Keychain.save(updated)
        return updated
    }

    // MARK: Sign in / out

    func signIn() async throws {
        guard let config else {
            AppConfig.ensureTemplate()
            throw AuthError.notConfigured
        }
        let verifier = Self.randomURLSafe(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
        let state = Self.randomURLSafe(24)

        let receiver = LoopbackReceiver()
        var redirectURI = ""
        let params = try await receiver.waitForRedirect { port in
            redirectURI = "http://127.0.0.1:\(port)"
            var comps = URLComponents(url: Self.authEndpoint, resolvingAgainstBaseURL: false)!
            comps.queryItems = [
                .init(name: "client_id", value: config.clientId),
                .init(name: "redirect_uri", value: redirectURI),
                .init(name: "response_type", value: "code"),
                .init(name: "scope", value: Self.scopes.joined(separator: " ")),
                .init(name: "code_challenge", value: challenge),
                .init(name: "code_challenge_method", value: "S256"),
                .init(name: "access_type", value: "offline"),
                .init(name: "prompt", value: "consent"),
                .init(name: "state", value: state),
            ]
            NSWorkspace.shared.open(comps.url!)
        }

        if let err = params["error"] { throw AuthError.denied(err) }
        guard params["state"] == state else { throw AuthError.stateMismatch }
        guard let code = params["code"] else { throw AuthError.denied("no code") }

        let json = try await postForm(Self.tokenEndpoint, [
            "client_id": config.clientId,
            "client_secret": config.clientSecret,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
        ])
        guard let access = json["access_token"] as? String,
              let refresh = json["refresh_token"] as? String else {
            throw AuthError.tokenEndpoint((json["error_description"] as? String)
                                          ?? (json["error"] as? String) ?? "bad response")
        }
        let expiresIn = (json["expires_in"] as? Double) ?? 3600
        let set = TokenSet(accessToken: access, refreshToken: refresh,
                           expiry: Date().addingTimeInterval(expiresIn))
        tokens = set
        Keychain.save(set)
    }

    func signOut() {
        if let t = tokens {
            // Best-effort revoke; ignore the result.
            var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke?token=\(t.refreshToken)")!)
            req.httpMethod = "POST"
            URLSession.shared.dataTask(with: req).resume()
        }
        tokens = nil
        Keychain.delete()
    }

    // MARK: Helpers

    private func postForm(_ url: URL, _ form: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "+&=/:?")
        req.httpBody = form.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }.joined(separator: "&").data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: req)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private static func randomURLSafe(_ bytes: Int) -> String {
        var buf = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &buf)
        return Data(buf).base64URLEncoded()
    }
}

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// One-shot HTTP listener on 127.0.0.1:<random port> that captures the OAuth redirect.
final class LoopbackReceiver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "macbitair.oauth.loopback")
    private var listener: NWListener?
    private var continuation: CheckedContinuation<[String: String], Error>?

    /// Starts listening, calls `onReady(port)` on the main thread (open the browser there),
    /// and returns the redirect's query parameters.
    func waitForRedirect(onReady: @escaping @MainActor (UInt16) -> Void) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { cont in
            queue.async {
                self.continuation = cont
                do {
                    let params = NWParameters.tcp
                    params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
                    let listener = try NWListener(using: params)
                    self.listener = listener
                    listener.stateUpdateHandler = { [weak self] state in
                        switch state {
                        case .ready:
                            if let port = listener.port?.rawValue {
                                DispatchQueue.main.async { MainActor.assumeIsolated { onReady(port) } }
                            }
                        case .failed(let error):
                            self?.finish(.failure(error))
                        default: break
                        }
                    }
                    listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
                    listener.start(queue: self.queue)
                    // Give up after 5 minutes.
                    self.queue.asyncAfter(deadline: .now() + 300) { [weak self] in
                        self?.finish(.failure(AuthError.timedOut))
                    }
                } catch {
                    self.finish(.failure(error))
                }
            }
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            // "GET /?code=...&state=... HTTP/1.1"
            let target = request.split(separator: " ", maxSplits: 2).dropFirst().first.map(String.init) ?? "/"
            let comps = URLComponents(string: "http://127.0.0.1\(target)")
            let items = comps?.queryItems ?? []

            guard comps?.path == "/" || comps?.path == "", !items.isEmpty else {
                self.respond(conn, status: "404 Not Found", body: "")
                return
            }
            var params: [String: String] = [:]
            for item in items { params[item.name] = item.value ?? "" }

            let ok = params["code"] != nil
            let html = """
            <html><body style="font-family:-apple-system;background:#000;color:#fff;display:flex;\
            align-items:center;justify-content:center;height:100vh;margin:0">
            <div style="text-align:center"><h2>\(ok ? "Macbit Air is connected" : "Sign-in failed")</h2>
            <p style="color:#888">You can close this tab.</p></div></body></html>
            """
            self.respond(conn, status: "200 OK", body: html)
            self.finish(.success(params))
        }
    }

    private func respond(_ conn: NWConnection, status: String, body: String) {
        let bytes = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n" +
                   "Content-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + bytes, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func finish(_ result: Result<[String: String], Error>) {
        guard let cont = continuation else { return }
        continuation = nil
        // Let the response flush before tearing the listener down.
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.listener?.cancel() }
        cont.resume(with: result)
    }
}
