import Foundation
import Security

// Talks to the user's own Supabase project (Phases 7-9) with plain URLSession: no extra library.
//
// What is stored where:
//   Keychain (encrypted by iOS, this device only): the project URL + publishable key, and the
//     sign-in session (access + refresh token).
//   Nowhere: the password. It is sent once to sign in and then forgotten.
//   Never in the app: the Anthropic key, the Strava secret, the service-role key. Those live on
//     the server (Supabase secrets).
//
// ⚠ Not run against a real project yet (none exists). The endpoints are Supabase's standard ones.

/// Small Keychain wrapper: one string per name.
enum Keychain {
    private static let service = "dev.pulse.app.cloud"

    static func set(_ value: String?, for name: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: name]
        SecItemDelete(query as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var item = query
        item[kSecValueData as String] = data
        // Readable only on this device, and only after it has been unlocked once since restart.
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func get(_ name: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: name,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

struct CloudConfig: Codable, Equatable {
    var projectURL: String          // https://xxxx.supabase.co
    var publishableKey: String      // the "anon" / publishable key: safe to ship, RLS protects the data

    /// Only https URLs are accepted, so tokens are never sent in the clear.
    var baseURL: URL? {
        guard let url = URL(string: projectURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host != nil else { return nil }
        return url
    }
}

struct CloudSession: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var email: String
}

enum CloudError: LocalizedError {
    case notConfigured
    case notSignedIn
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "Cloud isn't set up yet. Add your project URL and key first."
        case .notSignedIn: "Sign in first."
        case .server(let message): message
        }
    }
}

/// An actor, so two requests can never refresh the session at the same time.
actor CloudClient {
    static let shared = CloudClient()

    private var config: CloudConfig?
    private var session: CloudSession?
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init() {
        if let json = Keychain.get("config"), let data = json.data(using: .utf8) {
            config = try? decoder.decode(CloudConfig.self, from: data)
        }
        if let json = Keychain.get("session"), let data = json.data(using: .utf8) {
            session = try? decoder.decode(CloudSession.self, from: data)
        }
    }

    var currentConfig: CloudConfig? { config }
    var signedInEmail: String? { session?.email }

    func setConfig(_ new: CloudConfig?) {
        config = new
        Keychain.set(new.flatMap { try? encoder.encode($0) }.flatMap { String(data: $0, encoding: .utf8) }, for: "config")
        if new == nil { setSession(nil) }
    }

    private func setSession(_ new: CloudSession?) {
        session = new
        Keychain.set(new.flatMap { try? encoder.encode($0) }.flatMap { String(data: $0, encoding: .utf8) }, for: "session")
    }

    // MARK: - Sign in / out

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String
        let expires_in: Double
    }

    func signIn(email: String, password: String) async throws {
        let body = try encoder.encode(["email": email, "password": password])
        let token: TokenResponse = try await send(path: "auth/v1/token", query: [URLQueryItem(name: "grant_type", value: "password")],
                                                  body: body, authorized: false)
        setSession(CloudSession(accessToken: token.access_token, refreshToken: token.refresh_token,
                                expiresAt: Date().addingTimeInterval(token.expires_in), email: email))
    }

    func signOut() {
        setSession(nil)
    }

    /// A token that is valid for at least another minute (refreshing it if needed).
    private func validAccessToken() async throws -> String {
        guard let current = session else { throw CloudError.notSignedIn }
        if current.expiresAt.timeIntervalSinceNow > 60 { return current.accessToken }
        let body = try encoder.encode(["refresh_token": current.refreshToken])
        do {
            let token: TokenResponse = try await send(path: "auth/v1/token",
                                                      query: [URLQueryItem(name: "grant_type", value: "refresh_token")],
                                                      body: body, authorized: false)
            setSession(CloudSession(accessToken: token.access_token, refreshToken: token.refresh_token,
                                    expiresAt: Date().addingTimeInterval(token.expires_in), email: current.email))
            return token.access_token
        } catch {
            setSession(nil)         // the refresh token is no longer valid: the user must sign in again
            throw CloudError.notSignedIn
        }
    }

    // MARK: - Database and functions

    /// Inserts rows, or updates them if they already exist (matched on `onConflict` columns).
    func upsert<Row: Encodable>(_ rows: [Row], table: String, onConflict: String) async throws {
        // Small batches keep each request well under the server's size limit.
        for start in stride(from: 0, to: rows.count, by: 200) {
            let chunk = Array(rows[start..<min(start + 200, rows.count)])
            let _: Empty = try await send(path: "rest/v1/\(table)", query: [URLQueryItem(name: "on_conflict", value: onConflict)],
                                          body: try encoder.encode(chunk), authorized: true,
                                          extraHeaders: ["Prefer": "resolution=merge-duplicates,return=minimal"])
        }
    }

    /// Calls one of the project's edge functions as the signed-in user.
    func invoke<Body: Encodable, Reply: Decodable>(_ function: String, body: Body) async throws -> Reply {
        try await send(path: "functions/v1/\(function)", query: [], body: try encoder.encode(body), authorized: true)
    }

    private struct Empty: Decodable {}
    private struct ServerMessage: Decodable {
        let message: String?
        let msg: String?
        let error_description: String?
    }

    private func send<Reply: Decodable>(path: String, query: [URLQueryItem], body: Data, authorized: Bool,
                                        extraHeaders: [String: String] = [:]) async throws -> Reply {
        guard let config, let base = config.baseURL else { throw CloudError.notConfigured }
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw CloudError.notConfigured }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 120      // the coach can take a while to answer
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.publishableKey, forHTTPHeaderField: "apikey")
        var bearer = config.publishableKey
        if authorized { bearer = try await validAccessToken() }
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        for (name, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: name) }

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            // Show the server's own explanation when it sent one, otherwise the status code.
            let parsed = try? decoder.decode(ServerMessage.self, from: data)
            throw CloudError.server(parsed?.message ?? parsed?.msg ?? parsed?.error_description ?? "The server answered \(status).")
        }
        if Reply.self == Empty.self || data.isEmpty {
            guard let empty = Empty() as? Reply else { throw CloudError.server("The server sent an empty answer.") }
            return empty
        }
        return try decoder.decode(Reply.self, from: data)
    }
}
