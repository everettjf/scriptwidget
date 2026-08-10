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
}
