//
//  AILocalOAuthServer.swift
//  ScriptWidget
//
//  Lightweight 127.0.0.1 HTTP server used to receive the OAuth
//  redirect from the system browser. Mirrors the Codex CLI pattern.
//

import Foundation
import Network

actor AILocalOAuthServer {
    private var listener: NWListener?
    private var continuation: CheckedContinuation<OAuthCallbackResult, any Error>?
    private let port: UInt16

    struct OAuthCallbackResult: Sendable {
        let code: String
        let state: String
    }

    enum ServerError: LocalizedError {
        case portUnavailable
        case serverFailed(String)
        case invalidRequest
        case missingParameters
        case timeout
        case oauthError(String)

        var errorDescription: String? {
            switch self {
            case .portUnavailable:
                return "OAuth callback port is unavailable."
            case .serverFailed(let reason):
                return "OAuth callback server failed: \(reason)"
            case .invalidRequest:
                return "Invalid OAuth callback request."
            case .missingParameters:
                return "OAuth callback missing code or state parameter."
            case .timeout:
                return "OAuth callback timed out."
            case .oauthError(let description):
                return "OAuth provider returned an error: \(description)"
            }
        }
    }

    init(port: UInt16 = 1455) {
        self.port = port
    }

    func waitForCallback(timeout: TimeInterval = 300) async throws -> OAuthCallbackResult {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<OAuthCallbackResult, any Error>) in
            self.continuation = cont
            do {
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                    cont.resume(throwing: ServerError.portUnavailable)
                    self.continuation = nil
                    return
                }
                let listener = try NWListener(using: params, on: nwPort)
                self.listener = listener

                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    if case .failed(let error) = state {
                        Task { await self.fail(with: .serverFailed(error.localizedDescription)) }
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self else { return }
                    Task { await self.handleConnection(connection) }
                }
                listener.start(queue: .global(qos: .userInitiated))

                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    await self?.fail(with: .timeout)
                }
            } catch {
                cont.resume(throwing: ServerError.portUnavailable)
                self.continuation = nil
            }
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else { return }
            Task { await self.processRequest(data: data, connection: connection) }
        }
    }

    private func processRequest(data: Data?, connection: NWConnection) {
        guard let data, let requestString = String(data: data, encoding: .utf8) else {
            sendResponse(connection: connection, statusCode: 400, body: "Bad Request")
            return
        }
        guard let firstLine = requestString.components(separatedBy: "\r\n").first,
              firstLine.hasPrefix("GET ") else {
            sendResponse(connection: connection, statusCode: 400, body: "Bad Request")
            return
        }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else {
            sendResponse(connection: connection, statusCode: 400, body: "Bad Request")
            return
        }
        let pathAndQuery = String(parts[1])
        guard pathAndQuery.hasPrefix("/auth/callback") else {
            sendResponse(connection: connection, statusCode: 404, body: "Not Found")
            return
        }
        guard let components = URLComponents(string: "http://localhost\(pathAndQuery)"),
              let queryItems = components.queryItems else {
            sendResponse(connection: connection, statusCode: 400, body: "Missing parameters")
            fail(with: .missingParameters)
            return
        }
        let params = Dictionary(queryItems.compactMap { item -> (String, String)? in
            guard let value = item.value else { return nil }
            return (item.name, value)
        }, uniquingKeysWith: { _, last in last })

        guard let code = params["code"], !code.isEmpty,
              let state = params["state"], !state.isEmpty else {
            if let errorMsg = params["error"] {
                let description = params["error_description"] ?? errorMsg
                sendResponse(connection: connection, statusCode: 200,
                             body: Self.errorHTML(message: description),
                             contentType: "text/html")
                fail(with: .oauthError(description))
            } else {
                sendResponse(connection: connection, statusCode: 400, body: "Missing code or state")
                fail(with: .missingParameters)
            }
            return
        }

        sendResponse(connection: connection, statusCode: 200,
                     body: Self.successHTML(),
                     contentType: "text/html")
        let result = OAuthCallbackResult(code: code, state: state)
        if let cont = continuation {
            continuation = nil
            cont.resume(returning: result)
        }
        stop()
    }

    private func sendResponse(connection: NWConnection, statusCode: Int, body: String, contentType: String = "text/plain") {
        let statusText: String
        switch statusCode {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        default:  statusText = "Error"
        }
        let response = """
        HTTP/1.1 \(statusCode) \(statusText)\r
        Content-Type: \(contentType); charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func fail(with error: ServerError) {
        if let cont = continuation {
            continuation = nil
            cont.resume(throwing: error)
        }
        stop()
    }

    private static func successHTML() -> String {
        """
        <!DOCTYPE html><html><head><meta charset="utf-8"><title>ScriptWidget</title>
        <style>body{font-family:-apple-system,sans-serif;display:flex;justify-content:center;align-items:center;height:100vh;margin:0;background:#f5f5f7}
        .card{text-align:center;padding:40px;background:#fff;border-radius:16px;box-shadow:0 2px 12px rgba(0,0,0,.1)}
        h1{font-size:24px;margin:0 0 8px}p{color:#666;margin:0}</style></head>
        <body><div class="card"><h1>Signed In</h1><p>You can close this page and return to ScriptWidget.</p></div></body></html>
        """
    }

    private static func errorHTML(message: String) -> String {
        let escaped = message
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
        <!DOCTYPE html><html><head><meta charset="utf-8"><title>ScriptWidget</title>
        <style>body{font-family:-apple-system,sans-serif;display:flex;justify-content:center;align-items:center;height:100vh;margin:0;background:#f5f5f7}
        .card{text-align:center;padding:40px;background:#fff;border-radius:16px;box-shadow:0 2px 12px rgba(0,0,0,.1)}
        h1{font-size:24px;margin:0 0 8px;color:#d00}p{color:#666;margin:0}</style></head>
        <body><div class="card"><h1>Sign-In Failed</h1><p>\(escaped)</p></div></body></html>
        """
    }
}
