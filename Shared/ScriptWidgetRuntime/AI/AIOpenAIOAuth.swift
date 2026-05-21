//
//  AIOpenAIOAuth.swift
//  ScriptWidget
//
//  OpenAI OAuth (PKCE) sign-in for the AI Generate feature, ported
//  from OpenRocky.
//
//  Uses the Codex CLI public client_id; tokens are stored in the
//  Keychain (not UserDefaults) keyed by the JWT-embedded
//  chatgpt_account_id, and refreshed automatically when within
//  `leeway` seconds of expiry.
//

import CryptoKit
import Foundation
import Security
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

struct AIOpenAIOAuthCredential: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    var accountID: String
    var authorizedAt: Date

    var isExpired: Bool { expiresAt <= Date() }

    var maskedAccessToken: String {
        guard accessToken.count >= 12 else { return "••••" }
        return "\(accessToken.prefix(8))••••\(accessToken.suffix(4))"
    }
}

enum AIOpenAIOAuthError: LocalizedError {
    case invalidAuthorizeURL
    case invalidTokenURL
    case stateMismatch
    case missingAuthorizationCode
    case missingAccountID
    case invalidTokenResponse
    case randomGenerationFailed
    case browserOpenFailed
    case tokenExchangeFailed(statusCode: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidAuthorizeURL:        return "Invalid OpenAI authorize URL."
        case .invalidTokenURL:            return "Invalid OpenAI token URL."
        case .stateMismatch:              return "OpenAI OAuth state mismatch."
        case .missingAuthorizationCode:   return "OpenAI OAuth did not return an authorization code."
        case .missingAccountID:           return "OpenAI OAuth token is missing account information."
        case .invalidTokenResponse:       return "OpenAI OAuth returned an invalid token response."
        case .randomGenerationFailed:    return "Failed to generate secure random OAuth parameters."
        case .browserOpenFailed:          return "Could not open the system browser for sign-in."
        case let .tokenExchangeFailed(statusCode, message):
            return "OpenAI token exchange failed (\(statusCode)): \(message)"
        }
    }
}

@MainActor
enum AIOpenAIOAuthService {
    private static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private static let authorizeURL = "https://auth.openai.com/oauth/authorize"
    private static let tokenURL = "https://auth.openai.com/oauth/token"
    private static let redirectURI = "http://localhost:1455/auth/callback"
    private static let callbackPort: UInt16 = 1455
    private static let scope = "openid profile email offline_access api.connectors.read api.connectors.invoke"
    nonisolated private static let jwtAuthClaimPath = "https://api.openai.com/auth"

    static func signIn(originator: String = "scriptwidget") async throws -> AIOpenAIOAuthCredential {
        let flow = try makeAuthorizationFlow(originator: originator)
        let server = AILocalOAuthServer(port: callbackPort)

        guard let authURL = URL(string: flow.url) else {
            throw AIOpenAIOAuthError.invalidAuthorizeURL
        }

        let opened = await openInBrowser(authURL)
        guard opened else {
            await server.stop()
            throw AIOpenAIOAuthError.browserOpenFailed
        }

        let callback: AILocalOAuthServer.OAuthCallbackResult
        do {
            callback = try await server.waitForCallback(timeout: 300)
        } catch {
            await server.stop()
            throw error
        }

        guard callback.state == flow.state else {
            throw AIOpenAIOAuthError.stateMismatch
        }

        let token = try await exchangeAuthorizationCode(code: callback.code, verifier: flow.verifier)
        guard let accountID = extractAccountID(from: token.accessToken) else {
            throw AIOpenAIOAuthError.missingAccountID
        }
        return AIOpenAIOAuthCredential(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            expiresAt: Date().addingTimeInterval(Double(token.expiresIn)),
            accountID: accountID,
            authorizedAt: Date()
        )
    }

    static func refresh(_ credential: AIOpenAIOAuthCredential) async throws -> AIOpenAIOAuthCredential {
        let token = try await refreshAccessToken(refreshToken: credential.refreshToken)
        guard let accountID = extractAccountID(from: token.accessToken) else {
            throw AIOpenAIOAuthError.missingAccountID
        }
        return AIOpenAIOAuthCredential(
            accessToken: token.accessToken,
            refreshToken: token.refreshToken,
            expiresAt: Date().addingTimeInterval(Double(token.expiresIn)),
            accountID: accountID,
            authorizedAt: credential.authorizedAt
        )
    }

    static func refreshIfNeeded(
        _ credential: AIOpenAIOAuthCredential,
        leeway: TimeInterval = 60
    ) async throws -> AIOpenAIOAuthCredential {
        if credential.expiresAt.timeIntervalSinceNow > leeway {
            return credential
        }
        return try await refresh(credential)
    }

    nonisolated static func accountID(fromAccessToken accessToken: String) -> String? {
        extractAccountID(from: accessToken)
    }

    private static func openInBrowser(_ url: URL) async -> Bool {
        #if canImport(UIKit) && !os(watchOS)
        return await UIApplication.shared.open(url)
        #elseif canImport(AppKit)
        return NSWorkspace.shared.open(url)
        #else
        return false
        #endif
    }

    private static func makeAuthorizationFlow(originator: String) throws -> AuthorizationFlow {
        let verifierData = try randomData(count: 32)
        let verifier = base64URLEncoded(verifierData)
        let challenge = base64URLEncoded(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = try randomData(count: 16).map { String(format: "%02x", $0) }.joined()

        var components = URLComponents(string: authorizeURL)
        components?.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "audience", value: "https://api.openai.com/v1"),
            .init(name: "scope", value: scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "id_token_add_organizations", value: "true"),
            .init(name: "codex_cli_simplified_flow", value: "true"),
            .init(name: "originator", value: originator),
        ]
        guard let url = components?.url else {
            throw AIOpenAIOAuthError.invalidAuthorizeURL
        }
        return AuthorizationFlow(url: url.absoluteString, verifier: verifier, state: state)
    }

    private static func exchangeAuthorizationCode(code: String, verifier: String) async throws -> OpenAIOAuthTokenResponse {
        guard let url = URL(string: tokenURL) else {
            throw AIOpenAIOAuthError.invalidTokenURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = URLQueryEncoder.encode([
            "grant_type": "authorization_code",
            "client_id": clientID,
            "code": code,
            "code_verifier": verifier,
            "redirect_uri": redirectURI,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIOpenAIOAuthError.invalidTokenResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "unknown error"
            throw AIOpenAIOAuthError.tokenExchangeFailed(statusCode: http.statusCode, message: message)
        }
        let decoded = try JSONDecoder().decode(OpenAIOAuthTokenResponse.self, from: data)
        guard !decoded.accessToken.isEmpty, !decoded.refreshToken.isEmpty else {
            throw AIOpenAIOAuthError.invalidTokenResponse
        }
        return decoded
    }

    private static func refreshAccessToken(refreshToken: String) async throws -> OpenAIOAuthTokenResponse {
        guard let url = URL(string: tokenURL) else {
            throw AIOpenAIOAuthError.invalidTokenURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = URLQueryEncoder.encode([
            "grant_type": "refresh_token",
            "client_id": clientID,
            "refresh_token": refreshToken,
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AIOpenAIOAuthError.invalidTokenResponse
        }
        guard (200...299).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "unknown error"
            throw AIOpenAIOAuthError.tokenExchangeFailed(statusCode: http.statusCode, message: message)
        }
        let decoded = try JSONDecoder().decode(OpenAIOAuthTokenResponse.self, from: data)
        guard !decoded.accessToken.isEmpty, !decoded.refreshToken.isEmpty else {
            throw AIOpenAIOAuthError.invalidTokenResponse
        }
        return decoded
    }

    nonisolated private static func extractAccountID(from accessToken: String) -> String? {
        let segments = accessToken.split(separator: ".")
        guard segments.count == 3 else { return nil }
        guard let payloadData = decodeBase64URL(String(segments[1])),
              let root = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              let auth = root[jwtAuthClaimPath] as? [String: Any],
              let accountID = auth["chatgpt_account_id"] as? String,
              !accountID.isEmpty else {
            return nil
        }
        return accountID
    }

    private static func randomData(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { pointer in
            SecRandomCopyBytes(kSecRandomDefault, count, pointer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw AIOpenAIOAuthError.randomGenerationFailed
        }
        return data
    }

    private static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    nonisolated private static func decodeBase64URL(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64.append("=")
        }
        return Data(base64Encoded: base64)
    }

    private struct AuthorizationFlow {
        var url: String
        var verifier: String
        var state: String
    }

    private struct OpenAIOAuthTokenResponse: Decodable {
        var accessToken: String
        var refreshToken: String
        var expiresIn: Int

        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }
}

enum AIOpenAIOAuthVault {
    private static let keyPrefix = "scriptwidget.openai-oauth.account"
    private static let keychain = AIKeychain.live

    static func credential(for accountID: String) -> AIOpenAIOAuthCredential? {
        guard let json = keychain.value(for: accountKey(accountID: accountID)),
              let data = json.data(using: .utf8),
              let credential = try? JSONDecoder().decode(AIOpenAIOAuthCredential.self, from: data) else {
            return nil
        }
        return credential
    }

    static func save(_ credential: AIOpenAIOAuthCredential) {
        guard let data = try? JSONEncoder().encode(credential),
              let json = String(data: data, encoding: .utf8) else {
            return
        }
        keychain.set(json, for: accountKey(accountID: credential.accountID))
    }

    static func remove(accountID: String) {
        keychain.removeValue(for: accountKey(accountID: accountID))
    }

    /// Given a stored access token, look up the matching credential by
    /// account id, refresh if expired, persist any update, and return
    /// the live access token. Falls back to the input if the token has
    /// no resolvable account (e.g. plain API key passed by mistake).
    static func resolvedAccessToken(from rawCredential: String) async throws -> String {
        guard let accountID = AIOpenAIOAuthService.accountID(fromAccessToken: rawCredential),
              let stored = credential(for: accountID) else {
            return rawCredential
        }
        let updated = try await AIOpenAIOAuthService.refreshIfNeeded(stored)
        if updated != stored {
            save(updated)
        }
        return updated.accessToken
    }

    private static func accountKey(accountID: String) -> String {
        "\(keyPrefix).\(accountID)"
    }
}

private enum URLQueryEncoder {
    static func encode(_ values: [String: String]) -> Data {
        let query = values
            .map { key, value in
                "\(percentEncode(key))=\(percentEncode(value))"
            }
            .sorted()
            .joined(separator: "&")
        return Data(query.utf8)
    }

    private static func percentEncode(_ string: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":#[]@!$&'()*+,;=")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }
}
