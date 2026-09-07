//
//  MCPOAuthProvider.swift
//  SwiftChatKit
//
//  A ready-made `MCPAuthorizationProvider`: OAuth 2.1 Authorization Code with
//  PKCE, dynamic client registration, and Keychain-backed tokens, as MCP's
//  authorization spec describes it.
//
//  The protocol stays the seam — a host with its own identity stack still
//  conforms to `MCPAuthorizationProvider` and never touches this type. This
//  exists because every host that *doesn't* have one would otherwise write the
//  same four hundred lines, and the parts worth getting right (PKCE, state
//  checking, refresh, not opening six browser windows at once) are the parts
//  easiest to get wrong.
//

import Foundation
import AuthenticationServices
import CryptoKit
import ChatCore

#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Configuration

public struct MCPOAuthConfiguration: Sendable {

    /// The custom URL scheme the host registers in its Info.plist under
    /// `CFBundleURLTypes`. Without that registration the callback never
    /// arrives and the flow hangs on a browser window that goes nowhere.
    public var callbackScheme: String

    /// Where the authorization server sends the browser back. Must use
    /// `callbackScheme` and must match what was registered.
    public var redirectURI: String

    /// Sent as `client_name` during dynamic registration, and shown to the user
    /// on the consent screen.
    public var clientName: String

    /// Used when the server offers no registration endpoint and so cannot mint
    /// a client id. Servers that expect a pre-registered id want this set.
    public var fallbackClientID: String

    /// Namespaces Keychain items, so two apps on one machine — or two builds of
    /// the same app — don't read each other's tokens.
    public var keychainService: String

    /// Whether the browser hand-off forgets its cookies afterwards. Off by
    /// default: reusing the session means an already-signed-in user is not
    /// asked to log in again for every server.
    public var prefersEphemeralSession: Bool

    /// Seconds shaved off a token's advertised lifetime before it counts as
    /// expired, covering the round trip that spends it.
    public var expiryLeeway: TimeInterval

    public init(callbackScheme: String,
                redirectURI: String,
                clientName: String,
                fallbackClientID: String = "",
                keychainService: String = "SwiftChatKit.MCP.OAuth",
                prefersEphemeralSession: Bool = false,
                expiryLeeway: TimeInterval = 30) {
        self.callbackScheme = callbackScheme
        self.redirectURI = redirectURI
        self.clientName = clientName
        self.fallbackClientID = fallbackClientID
        self.keychainService = keychainService
        self.prefersEphemeralSession = prefersEphemeralSession
        self.expiryLeeway = expiryLeeway
    }
}

// MARK: - Provider

@MainActor
public final class MCPOAuthProvider: NSObject, MCPAuthorizationProvider {

    private let configuration: MCPOAuthConfiguration
    private let store: MCPTokenStore
    private let urlSession: URLSession

    /// Supplies the window the browser sheet hangs off. Overridable because a
    /// host with several windows — or none — knows which one the user is
    /// looking at, and this type cannot.
    public var presentationAnchor: (@MainActor () -> ASPresentationAnchor)?

    /// Flows in progress, keyed by origin. Three servers behind one identity
    /// provider going through this at once should open one browser window and
    /// share its result, not race and open three.
    private var inFlight: [String: Task<String, Error>] = [:]

    public init(configuration: MCPOAuthConfiguration,
                urlSession: URLSession = .shared) {
        self.configuration = configuration
        self.store = MCPTokenStore(service: configuration.keychainService)
        self.urlSession = urlSession
        super.init()
    }

    // MARK: MCPAuthorizationProvider

    public func accessToken(for url: URL) async throws -> String {
        let key = url.oauthOrigin.absoluteString

        if let cached = store.token(for: key), !cached.isExpired {
            return cached.accessToken
        }

        if let existing = inFlight[key] {
            return try await existing.value
        }

        let task = Task<String, Error> { [weak self] in
            guard let self else { throw MCPBridgeError.notConnected }
            defer { self.inFlight[key] = nil }
            return try await self.obtainToken(for: url, key: key)
        }
        inFlight[key] = task
        return try await task.value
    }

    /// Discards a server's tokens, so the next call signs in again. For a host
    /// offering "disconnect" — revoking access at the provider is not something
    /// this type can do on the user's behalf.
    public func signOut(from url: URL) {
        store.clear(for: url.oauthOrigin.absoluteString)
    }

    // MARK: - Flow

    private func obtainToken(for url: URL, key: String) async throws -> String {
        let metadata = try await discoverAuthorizationServer(for: url)

        // Refresh before re-authorizing: a refresh is silent, where the full
        // flow puts a browser window in front of someone who is already signed in.
        if let cached = store.token(for: key), let refresh = cached.refreshToken {
            if let renewed = try? await exchange(
                grant: ["grant_type": "refresh_token", "refresh_token": refresh],
                clientID: store.clientID(for: key) ?? configuration.fallbackClientID,
                metadata: metadata,
                resource: url) {
                store.save(renewed, for: key)
                return renewed.accessToken
            }
        }

        let token = try await authorize(metadata: metadata, resource: url, key: key)
        store.save(token, for: key)
        return token.accessToken
    }

    private func authorize(metadata: AuthorizationServerMetadata,
                           resource: URL,
                           key: String) async throws -> StoredOAuthToken {
        let clientID = try await clientID(metadata: metadata, key: key)

        let verifier = Self.randomURLSafeString(64)
        let state = Self.randomURLSafeString(32)

        guard var components = URLComponents(url: metadata.authorizationEndpoint,
                                             resolvingAgainstBaseURL: false) else {
            throw MCPBridgeError.invalidResponse
        }
        // Merged rather than assigned: some authorization endpoints carry query
        // items of their own, and dropping them breaks the request.
        var items = components.queryItems ?? []
        items += [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI),
            URLQueryItem(name: "code_challenge", value: Self.codeChallenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "resource", value: resource.oauthOrigin.absoluteString),
        ]
        if let scope = metadata.scopesSupported?.joined(separator: " "), !scope.isEmpty {
            items.append(URLQueryItem(name: "scope", value: scope))
        }
        components.queryItems = items

        guard let authorizationURL = components.url else { throw MCPBridgeError.invalidResponse }
        let callback = try await presentBrowser(url: authorizationURL)

        let returned = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = returned.first(where: { $0.name == "error" })?.value {
            let description = returned.first { $0.name == "error_description" }?.value
            throw MCPBridgeError.serverError(code: 0, message: description ?? error)
        }
        // The state check is what makes this flow resistant to a callback the
        // user was tricked into opening; a mismatch is an attack, not a retry.
        guard returned.first(where: { $0.name == "state" })?.value == state,
              let code = returned.first(where: { $0.name == "code" })?.value else {
            throw MCPBridgeError.invalidResponse
        }

        return try await exchange(
            grant: ["grant_type": "authorization_code",
                    "code": code,
                    "redirect_uri": configuration.redirectURI,
                    "code_verifier": verifier],
            clientID: clientID,
            metadata: metadata,
            resource: resource)
    }

    // MARK: - Token endpoint

    private func exchange(grant: [String: String],
                          clientID: String,
                          metadata: AuthorizationServerMetadata,
                          resource: URL) async throws -> StoredOAuthToken {
        var parameters = grant
        // Sent on refresh as well as on the initial exchange: public clients
        // have no secret, so the id is the only thing identifying the caller,
        // and servers reject a refresh without it.
        parameters["client_id"] = clientID
        parameters["resource"] = resource.oauthOrigin.absoluteString

        var request = URLRequest(url: metadata.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.formEncoded(parameters)

        let (data, response) = try await urlSession.data(for: request)
        try Self.checkStatus(response, data: data)

        let payload = try JSONDecoder().decode(TokenResponse.self, from: data)
        return StoredOAuthToken(
            accessToken: payload.accessToken,
            // A server that rotates refresh tokens returns a new one; one that
            // doesn't returns none, and the old one stays valid.
            refreshToken: payload.refreshToken ?? grant["refresh_token"],
            expiresAt: payload.expiresIn.map {
                Date().addingTimeInterval(TimeInterval($0) - configuration.expiryLeeway)
            })
    }

    // MARK: - Discovery

    /// Follows the protected resource to its authorization server, per RFC 9728,
    /// falling back to the resource's own origin for servers that publish only
    /// the authorization-server document.
    private func discoverAuthorizationServer(
        for resource: URL
    ) async throws -> AuthorizationServerMetadata {
        let origin = resource.oauthOrigin
        var base = origin

        if let data = try? await fetch(origin.appendingWellKnown("oauth-protected-resource")),
           let metadata = try? JSONDecoder().decode(ProtectedResourceMetadata.self, from: data),
           let first = metadata.authorizationServers?.first {
            base = first
        }

        // Both spellings are in the wild: OAuth servers publish the first,
        // OpenID providers the second, and plenty of MCP servers are the latter.
        for suffix in ["oauth-authorization-server", "openid-configuration"] {
            if let data = try? await fetch(base.appendingWellKnown(suffix)),
               let metadata = try? JSONDecoder().decode(AuthorizationServerMetadata.self, from: data) {
                return metadata
            }
        }
        throw MCPBridgeError.authRequired(resource)
    }

    /// A registered client id, minted on first use and kept. Servers without a
    /// registration endpoint expect one to have been arranged out of band.
    private func clientID(metadata: AuthorizationServerMetadata, key: String) async throws -> String {
        if let existing = store.clientID(for: key) { return existing }

        guard let endpoint = metadata.registrationEndpoint else {
            guard !configuration.fallbackClientID.isEmpty else {
                throw MCPBridgeError.serverError(
                    code: 0,
                    message: """
                    This server supports neither dynamic client registration nor an anonymous \
                    client. Set `fallbackClientID` to a client id registered with it.
                    """)
            }
            return configuration.fallbackClientID
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ChatValue.object([
            "client_name": .string(configuration.clientName),
            "redirect_uris": .array([.string(configuration.redirectURI)]),
            "grant_types": .array([.string("authorization_code"), .string("refresh_token")]),
            "response_types": .array([.string("code")]),
            "token_endpoint_auth_method": .string("none"),
        ]))

        let (data, response) = try await urlSession.data(for: request)
        try Self.checkStatus(response, data: data)

        let registered = try JSONDecoder().decode(RegistrationResponse.self, from: data)
        store.saveClientID(registered.clientID, for: key)
        return registered.clientID
    }

    private func fetch(_ url: URL) async throws -> Data {
        let (data, response) = try await urlSession.data(from: url)
        try Self.checkStatus(response, data: data)
        return data
    }

    private static func checkStatus(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard !(200..<300).contains(http.statusCode) else { return }

        // Authorization servers report failures as a JSON body; surfacing it
        // beats a bare status code when a scope or redirect URI is wrong.
        let detail = (try? JSONDecoder().decode(OAuthErrorResponse.self, from: data))
            .map { $0.errorDescription ?? $0.error }
            ?? String(data: data.prefix(512), encoding: .utf8)
        throw MCPBridgeError.serverError(code: http.statusCode,
                                         message: detail ?? "Authorization request failed.")
    }

    // MARK: - Browser hand-off

    private func presentBrowser(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: configuration.callbackScheme
            ) { callbackURL, error in
                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else if let error = error as? ASWebAuthenticationSessionError,
                          error.code == .canceledLogin {
                    continuation.resume(throwing: MCPBridgeError.cancelled)
                } else {
                    continuation.resume(throwing: error ?? MCPBridgeError.invalidResponse)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = configuration.prefersEphemeralSession
            guard session.start() else {
                continuation.resume(throwing: MCPBridgeError.serverError(
                    code: 0,
                    message: "Couldn't open a browser for sign-in."))
                return
            }
        }
    }

    // MARK: - PKCE

    private static func randomURLSafeString(_ byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        if SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) != errSecSuccess {
            // Never silently fall back to something predictable: the verifier
            // and state are the whole security of this flow.
            bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max) }
        }
        return Data(bytes).base64URLEncoded()
    }

    private static func codeChallenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
    }

    private static func formEncoded(_ parameters: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        // `+` is a space to a form decoder, so a token containing one would
        // arrive corrupted without this.
        let encoded = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B") ?? ""
        return Data(encoded.utf8)
    }
}

// MARK: - Presentation anchor

extension MCPOAuthProvider: ASWebAuthenticationPresentationContextProviding {
    public func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if let presentationAnchor { return presentationAnchor() }
        #if canImport(AppKit)
        return NSApplication.shared.keyWindow
            ?? NSApplication.shared.windows.first
            ?? ASPresentationAnchor()
        #elseif canImport(UIKit)
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        return scene?.keyWindow ?? ASPresentationAnchor()
        #else
        return ASPresentationAnchor()
        #endif
    }
}

// MARK: - Wire types

private struct ProtectedResourceMetadata: Decodable {
    let authorizationServers: [URL]?

    enum CodingKeys: String, CodingKey {
        case authorizationServers = "authorization_servers"
    }
}

private struct AuthorizationServerMetadata: Decodable {
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    let registrationEndpoint: URL?
    let scopesSupported: [String]?

    enum CodingKeys: String, CodingKey {
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case registrationEndpoint = "registration_endpoint"
        case scopesSupported = "scopes_supported"
    }
}

private struct TokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

private struct RegistrationResponse: Decodable {
    let clientID: String
    enum CodingKeys: String, CodingKey { case clientID = "client_id" }
}

private struct OAuthErrorResponse: Decodable {
    let error: String
    let errorDescription: String?
    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

// MARK: - Storage

/// What is kept for a server between launches.
public struct StoredOAuthToken: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date?

    public init(accessToken: String, refreshToken: String?, expiresAt: Date?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    /// A token with no stated expiry is treated as live: the server will say so
    /// with a 401 if it isn't, and guessing would sign the user out for nothing.
    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() >= expiresAt
    }
}

/// Keychain-backed token and client-id storage, scoped by service name.
struct MCPTokenStore {

    let service: String

    func token(for key: String) -> StoredOAuthToken? {
        Keychain.read(service: service, account: "token:\(key)")
            .flatMap { try? JSONDecoder().decode(StoredOAuthToken.self, from: $0) }
    }

    func save(_ token: StoredOAuthToken, for key: String) {
        guard let data = try? JSONEncoder().encode(token) else { return }
        Keychain.write(data, service: service, account: "token:\(key)")
    }

    func clientID(for key: String) -> String? {
        Keychain.read(service: service, account: "client:\(key)")
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    func saveClientID(_ id: String, for key: String) {
        Keychain.write(Data(id.utf8), service: service, account: "client:\(key)")
    }

    /// Drops the token but keeps the client id: the registration is still valid,
    /// and re-registering on every sign-out litters the server with clients.
    func clear(for key: String) {
        Keychain.delete(service: service, account: "token:\(key)")
    }
}

private enum Keychain {

    static func read(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func write(_ data: Data, service: String, account: String) {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Update in place when it exists; SecItemAdd fails with a duplicate
        // otherwise, and delete-then-add loses the item if the add fails.
        let update: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(identity as CFDictionary, update as CFDictionary) == errSecSuccess { return }

        var attributes = identity
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func delete(service: String, account: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ] as CFDictionary)
    }
}

// MARK: - URL

extension URL {
    /// Scheme, host and port only. Tokens are issued per server, not per
    /// endpoint, so `/mcp` and `/sse` on one host must resolve to one entry —
    /// otherwise the user signs in again every time the path changes.
    var oauthOrigin: URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = port
        return components.url ?? self
    }

    func appendingWellKnown(_ suffix: String) -> URL {
        appendingPathComponent(".well-known").appendingPathComponent(suffix)
    }
}

private extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
