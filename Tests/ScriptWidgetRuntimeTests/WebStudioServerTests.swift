import XCTest
@testable import ScriptWidget

final class WebStudioServerTests: XCTestCase {
    func testParsesBoundedJSONRequest() throws {
        let payload = Data(#"{"code":"123456"}"#.utf8)
        var data = Data("POST /api/v1/pair HTTP/1.1\r\nHost: device\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\n\r\n".utf8)
        data.append(payload)

        let request = try XCTUnwrap(HTTPRequest.parse(data))
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/v1/pair")
        XCTAssertEqual(request.headers["host"], "device")
        XCTAssertEqual(request.json?["code"] as? String, "123456")
    }

    func testWaitsForCompleteBody() {
        let data = Data("PUT /api/v1/document HTTP/1.1\r\nContent-Length: 20\r\n\r\nshort".utf8)
        XCTAssertNil(HTTPRequest.parse(data))
    }

    func testRejectsNegativeContentLength() {
        let data = Data("POST /api/v1/pair HTTP/1.1\r\nContent-Length: -1\r\n\r\n".utf8)
        XCTAssertNil(HTTPRequest.parse(data))
    }

    func testUsesFirstDuplicateQueryValueWithoutCrashing() throws {
        let data = Data("GET /api/v1/document?path=main.jsx&path=other.jsx HTTP/1.1\r\n\r\n".utf8)
        let request = try XCTUnwrap(HTTPRequest.parse(data))
        XCTAssertEqual(request.query["path"], "main.jsx")
    }

    func testHTTPServerServesStudioAndAuthenticatedSession() async throws {
        let server = WebStudioServer(sessionLease: 5)
        await MainActor.run { server.start() }
        let port = try await waitForPort(server)
        defer { server.stop() }

        let (indexData, indexResponse) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/")!)
        XCTAssertEqual((indexResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: indexData, as: UTF8.self).contains("ScriptWidget Web Studio"))

        var pairRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/v1/pair")!)
        pairRequest.httpMethod = "POST"
        pairRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        pairRequest.httpBody = try JSONSerialization.data(withJSONObject: ["code": server.pairingCode])
        let (pairData, pairResponse) = try await URLSession.shared.data(for: pairRequest)
        XCTAssertEqual((pairResponse as? HTTPURLResponse)?.statusCode, 200)
        let token = try XCTUnwrap((try JSONSerialization.jsonObject(with: pairData) as? [String: Any])?["token"] as? String)
        XCTAssertFalse(server.diagnosticReport.contains(token))
        XCTAssertFalse(server.diagnosticReport.contains(server.pairingCode))

        let packageName = "WebStudio-P0-\(UUID().uuidString)"
        let initialSource = "const widget = <Text text=\"before\" />;"
        XCTAssertTrue(sharedScriptManager.saveScript(packageName: packageName, content: initialSource, imageCopyPath: nil).0)
        defer { _ = sharedScriptManager.deleteScript(packageName: packageName) }

        var packagesRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/v1/packages")!)
        packagesRequest.setValue(token, forHTTPHeaderField: "X-Studio-Token")
        let (packagesData, packagesResponse) = try await URLSession.shared.data(for: packagesRequest)
        XCTAssertEqual((packagesResponse as? HTTPURLResponse)?.statusCode, 200)
        let packagesObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: packagesData) as? [String: Any])
        let packages = try XCTUnwrap(packagesObject["packages"] as? [[String: Any]])
        XCTAssertTrue(packages.contains { $0["id"] as? String == packageName })

        let updatedSource = "const widget = <Text text=\"saved through Web Studio\" />;"
        var saveRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/v1/document")!)
        saveRequest.httpMethod = "PUT"
        saveRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        saveRequest.setValue(token, forHTTPHeaderField: "X-Studio-Token")
        saveRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "package": packageName,
            "path": "main.jsx",
            "content": updatedSource,
        ])
        let (_, saveResponse) = try await URLSession.shared.data(for: saveRequest)
        XCTAssertEqual((saveResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(sharedScriptManager.getScriptPackage(packageName: packageName).readMainFile().0, updatedSource)

        var sessionRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/v1/session")!)
        sessionRequest.setValue(token, forHTTPHeaderField: "X-Studio-Token")
        let (sessionData, sessionResponse) = try await URLSession.shared.data(for: sessionRequest)
        XCTAssertEqual((sessionResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: sessionData) as? [String: Any])?["connected"] as? Bool, true)

        sessionRequest.httpMethod = "DELETE"
        let (_, deleteResponse) = try await URLSession.shared.data(for: sessionRequest)
        XCTAssertEqual((deleteResponse as? HTTPURLResponse)?.statusCode, 200)

        sessionRequest.httpMethod = "GET"
        let (_, expiredResponse) = try await URLSession.shared.data(for: sessionRequest)
        XCTAssertEqual((expiredResponse as? HTTPURLResponse)?.statusCode, 401)
    }

    func testSessionLeaseReleasesClosedBrowser() async throws {
        let server = WebStudioServer(sessionLease: 0.25)
        await MainActor.run { server.start() }
        let port = try await waitForPort(server)
        defer { server.stop() }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/v1/pair")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["code": server.pairingCode])
        let (data, _) = try await URLSession.shared.data(for: request)
        let token = try XCTUnwrap((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["token"] as? String)

        try await Task.sleep(nanoseconds: 700_000_000)
        var session = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/v1/session")!)
        session.setValue(token, forHTTPHeaderField: "X-Studio-Token")
        let (_, response) = try await URLSession.shared.data(for: session)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401)
        XCTAssertEqual(server.connectedClientCount, 0)
    }

    func testHTTPServerRejectsOversizedRequestAndStaysAvailable() async throws {
        let server = WebStudioServer(sessionLease: 5)
        await MainActor.run { server.start() }
        let port = try await waitForPort(server)
        defer { server.stop() }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/v1/pair")!)
        request.httpMethod = "POST"
        request.httpBody = Data(repeating: 65, count: 2 * 1024 * 1024 + 1)
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 413)

        let (_, indexResponse) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/")!)
        XCTAssertEqual((indexResponse as? HTTPURLResponse)?.statusCode, 200)
    }

    private func waitForPort(_ server: WebStudioServer) async throws -> UInt16 {
        for _ in 0..<100 {
            let port = await MainActor.run { server.port }
            if port != 0 { return port }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Web Studio listener did not become ready")
        throw URLError(.cannotConnectToHost)
    }
}
