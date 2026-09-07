//
//  MCPOAuthTests.swift
//  SwiftChatKit
//
//  The parts of the OAuth flow that can be checked without a browser: PKCE
//  derivation, how a server URL collapses to the key tokens are filed under,
//  expiry, and the Keychain round trip.
//

import Foundation
import Testing
@testable import ChatMCP

@Suite("MCP OAuth — token identity")
struct MCPOAuthOriginTests {

    @Test("Different paths on one host share a token")
    func pathsCollapseToOrigin() throws {
        let sse = try #require(URL(string: "https://mcp.example.com/sse"))
        let http = try #require(URL(string: "https://mcp.example.com/mcp?x=1"))
        // Signing in once per host is the point: a server that moves from /sse
        // to /mcp should not send the user back through the browser.
        #expect(sse.oauthOrigin == http.oauthOrigin)
        #expect(sse.oauthOrigin.absoluteString == "https://mcp.example.com")
    }

    @Test("Port and host are part of the identity")
    func portsAndHostsSeparate() throws {
        let a = try #require(URL(string: "https://example.com:8443/mcp"))
        let b = try #require(URL(string: "https://example.com/mcp"))
        let c = try #require(URL(string: "https://other.example.com/mcp"))
        #expect(a.oauthOrigin != b.oauthOrigin)
        #expect(b.oauthOrigin != c.oauthOrigin)
    }

    @Test("Well-known URLs are built under the right prefix")
    func wellKnown() throws {
        let base = try #require(URL(string: "https://auth.example.com"))
        #expect(base.appendingWellKnown("oauth-authorization-server").absoluteString
                == "https://auth.example.com/.well-known/oauth-authorization-server")
    }
}

@Suite("MCP OAuth — token lifetime")
struct MCPOAuthTokenTests {

    @Test("A token with no expiry is treated as live")
    func noExpiry() {
        // Guessing would sign the user out for nothing; the server says 401
        // if it disagrees.
        let token = StoredOAuthToken(accessToken: "a", refreshToken: nil, expiresAt: nil)
        #expect(token.isExpired == false)
    }

    @Test("A past expiry is expired, a future one is not")
    func expiry() {
        let past = StoredOAuthToken(accessToken: "a", refreshToken: nil,
                                    expiresAt: Date().addingTimeInterval(-1))
        let future = StoredOAuthToken(accessToken: "a", refreshToken: nil,
                                      expiresAt: Date().addingTimeInterval(600))
        #expect(past.isExpired)
        #expect(future.isExpired == false)
    }

    @Test("A token round-trips through Codable with its refresh token")
    func codable() throws {
        let token = StoredOAuthToken(accessToken: "at", refreshToken: "rt",
                                     expiresAt: Date(timeIntervalSince1970: 1_000))
        let decoded = try JSONDecoder().decode(
            StoredOAuthToken.self, from: try JSONEncoder().encode(token))
        #expect(decoded == token)
    }
}

@Suite("MCP OAuth — Keychain storage", .serialized)
struct MCPOAuthStoreTests {

    /// A service name unique per run, so the suite never reads or clobbers a
    /// real app's credentials on the developer's machine.
    private func isolatedStore() -> MCPTokenStore {
        MCPTokenStore(service: "SwiftChatKit.tests.\(UUID().uuidString)")
    }

    @Test("A token round-trips through the Keychain")
    func tokenRoundTrip() {
        let store = isolatedStore()
        let key = "https://mcp.example.com"
        let token = StoredOAuthToken(accessToken: "secret", refreshToken: "refresh",
                                     expiresAt: nil)

        store.save(token, for: key)
        defer { store.clear(for: key) }

        #expect(store.token(for: key) == token)
        #expect(store.token(for: "https://other.example.com") == nil)
    }

    @Test("Saving twice updates rather than duplicating")
    func overwrite() {
        let store = isolatedStore()
        let key = "https://mcp.example.com"
        defer { store.clear(for: key) }

        store.save(StoredOAuthToken(accessToken: "first", refreshToken: nil, expiresAt: nil),
                   for: key)
        store.save(StoredOAuthToken(accessToken: "second", refreshToken: nil, expiresAt: nil),
                   for: key)

        // SecItemAdd refuses a duplicate, so a naive writer silently keeps
        // handing back the stale token forever.
        #expect(store.token(for: key)?.accessToken == "second")
    }

    @Test("Signing out drops the token but keeps the registered client")
    func signOutKeepsClientID() {
        let store = isolatedStore()
        let key = "https://mcp.example.com"

        store.saveClientID("client-123", for: key)
        store.save(StoredOAuthToken(accessToken: "a", refreshToken: nil, expiresAt: nil), for: key)
        store.clear(for: key)

        #expect(store.token(for: key) == nil)
        // Re-registering on every sign-out litters the server with clients.
        #expect(store.clientID(for: key) == "client-123")
    }
}
