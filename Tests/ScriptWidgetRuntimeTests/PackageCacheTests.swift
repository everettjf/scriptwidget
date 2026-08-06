//
//  PackageCacheTests.swift
//  ScriptWidgetRuntimeTests
//
//  Coverage for the local build-cache fallback that keeps widgets rendering
//  when iCloud Drive is unavailable (GitHub issue #6):
//   - regression: ScriptWidgetPackage.readFile falls back to the build cache
//     when the primary file can't be read.
//   - hardening: ScriptManager.precachePackageFiles proactively populates that
//     cache, so a script that was never opened here still renders after the
//     system evicts its iCloud files.
//
//  These exercise the real app-group build cache, so they run hosted on the
//  app target (iOS + macOS). Each test uses a uniquely-named temp package and
//  cleans up its cache entry in tearDown.
//

import XCTest
@testable import ScriptWidget

final class PackageCacheTests: XCTestCase {

    private var createdPackageNames: [String] = []

    override func tearDown() {
        // Remove any build-cache entries this test created.
        if let buildDir = ScriptManager.getSandboxBuildDirectoryURL() {
            for name in createdPackageNames {
                try? FileManager.default.removeItem(at: buildDir.appendingPathComponent(name))
            }
        }
        createdPackageNames.removeAll()
        super.tearDown()
    }

    /// A throwaway, writable package in a unique temp directory whose cache
    /// entry will be cleaned up in tearDown.
    private func makeTempPackage() -> ScriptWidgetPackage {
        let name = "PkgCacheTests-\(UUID().uuidString)"
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        createdPackageNames.append(name)
        return ScriptWidgetPackage(path: dir, readonly: false)
    }

    /// Simulate iCloud eviction by removing the on-disk file.
    private func evict(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "precondition: file should be gone")
    }

    // MARK: - Regression: read falls back to the build cache (issue #6 fix)

    func testReadFallsBackToBuildCacheWhenPrimaryMissing() {
        let pkg = makeTempPackage()

        // 1) Write + read once while "online" — this populates the build cache.
        XCTAssertTrue(pkg.writeMainFile(content: "RENDER_ME").0)
        let firstRead = pkg.readMainFile()
        XCTAssertEqual(firstRead.0, "RENDER_ME")
        XCTAssertEqual(firstRead.1, "succeed")

        // 2) Evict the primary file (as the system would on cellular w/o iCloud).
        evict(pkg.jsxPath)

        // 3) Reading again must serve the cached copy, not fail.
        let fallbackRead = pkg.readMainFile()
        XCTAssertEqual(fallbackRead.0, "RENDER_ME", "should read from build cache after eviction")
        XCTAssertTrue(fallbackRead.1.contains("build cache"), "status was: \(fallbackRead.1)")
    }

    func testReadReturnsNilWhenNeverCachedAndMissing() {
        // A file that was never successfully read has no cache to fall back to.
        let pkg = makeTempPackage()
        let result = pkg.readFile(relativePath: "main.jsx")
        XCTAssertNil(result.0, "no primary file and no cache -> nil (documents the pre-precache gap)")
    }

    // MARK: - Hardening: precache populates the cache for an unopened script

    func testPrecachePopulatesCacheSoEvictedFileStillReads() {
        let pkg = makeTempPackage()
        XCTAssertTrue(pkg.writeMainFile(content: "PRECACHED_MAIN").0)
        XCTAssertTrue(pkg.writeFile(relativePath: "lib.js", content: "PRECACHED_LIB").0)

        // Precache without ever "opening" the files in a runtime/editor.
        let cachedCount = sharedScriptManager.precachePackageFiles(pkg)
        XCTAssertGreaterThanOrEqual(cachedCount, 2, "main.jsx + lib.js should be cached")

        // Now evict both primary files.
        evict(pkg.jsxPath)
        evict(pkg.path.appendingPathComponent("lib.js"))

        // Both should still resolve from the cache populated by precache.
        let mainRead = pkg.readMainFile()
        XCTAssertEqual(mainRead.0, "PRECACHED_MAIN")
        XCTAssertTrue(mainRead.1.contains("build cache"), "status was: \(mainRead.1)")

        let libRead = pkg.readFile(relativePath: "lib.js")
        XCTAssertEqual(libRead.0, "PRECACHED_LIB")
        XCTAssertTrue(libRead.1.contains("build cache"), "status was: \(libRead.1)")
    }

    func testPrecacheSkipsBinaryAssets() {
        // Precache only caches text the runtime loads; a .png is left alone
        // (it would not be utf8-readable anyway) and is not counted.
        let pkg = makeTempPackage()
        XCTAssertTrue(pkg.writeMainFile(content: "ONLY_TEXT").0)
        // Drop a fake binary asset next to it.
        try? Data([0x89, 0x50, 0x4E, 0x47]).write(to: pkg.path.appendingPathComponent("image.png"))

        let cachedCount = sharedScriptManager.precachePackageFiles(pkg)
        XCTAssertEqual(cachedCount, 1, "only main.jsx should be cached, not image.png")
    }

    func testPrecacheCachesNestedFiles() {
        // The URL enumerator recurses, so imports in subdirectories are cached too.
        let pkg = makeTempPackage()
        XCTAssertTrue(pkg.writeMainFile(content: "MAIN").0)
        // writeFile doesn't create intermediate dirs, so make the subdir first.
        try? FileManager.default.createDirectory(at: pkg.path.appendingPathComponent("lib"),
                                                 withIntermediateDirectories: true)
        XCTAssertTrue(pkg.writeFile(relativePath: "lib/util.js", content: "UTIL").0)

        let cachedCount = sharedScriptManager.precachePackageFiles(pkg)
        XCTAssertEqual(cachedCount, 2, "main.jsx + lib/util.js should both be cached")

        evict(pkg.path.appendingPathComponent("lib/util.js"))
        let nested = pkg.readFile(relativePath: "lib/util.js")
        XCTAssertEqual(nested.0, "UTIL", "nested import should read from cache after eviction")
    }

    // MARK: - Status-aware read result (issue #6, surfaced to UI)

    func testReadFileResultReportsSourceFileOnPrimaryRead() {
        let pkg = makeTempPackage()
        XCTAssertTrue(pkg.writeMainFile(content: "HELLO").0)

        let result = pkg.readMainFileResult()
        XCTAssertEqual(result.content, "HELLO")
        XCTAssertEqual(result.source, .file)
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.message, "succeed")
    }

    func testReadFileResultReportsBuildCacheAfterEviction() {
        let pkg = makeTempPackage()
        XCTAssertTrue(pkg.writeMainFile(content: "CACHED").0)
        _ = pkg.readMainFile() // populate the build cache while "online"
        evict(pkg.jsxPath)

        let result = pkg.readMainFileResult()
        XCTAssertEqual(result.content, "CACHED")
        XCTAssertEqual(result.source, .buildCache, "served from local cache after eviction")
        XCTAssertTrue(result.succeeded)
    }

    func testReadFileResultReportsNotFoundWhenMissingAndUncached() {
        // A plain local temp file (not an iCloud item) that was never cached is a
        // real miss — not a transient "downloading" state.
        let pkg = makeTempPackage()
        let result = pkg.readMainFileResult()
        XCTAssertNil(result.content)
        XCTAssertNil(result.source)
        XCTAssertEqual(result.icloud, .notInICloud)
    }

    func testMainFileICloudStateIsLocalForPresentFile() {
        let pkg = makeTempPackage()
        XCTAssertTrue(pkg.writeMainFile(content: "X").0)
        XCTAssertEqual(pkg.mainFileICloudState(), .local)
    }

    func testICloudStateResolverCoversEveryVisibleState() {
        struct TestError: LocalizedError { var errorDescription: String? { "cloud unavailable" } }
        XCTAssertEqual(
            ICloudItemStateResolver.resolve(downloadError: TestError(), isDownloading: nil, downloadingStatus: nil, hasPlaceholder: false),
            .error("cloud unavailable")
        )
        XCTAssertEqual(
            ICloudItemStateResolver.resolve(downloadError: nil, isDownloading: true, downloadingStatus: nil, hasPlaceholder: false),
            .downloading
        )
        XCTAssertEqual(
            ICloudItemStateResolver.resolve(downloadError: nil, isDownloading: false, downloadingStatus: .current, hasPlaceholder: false),
            .downloaded
        )
        XCTAssertEqual(
            ICloudItemStateResolver.resolve(downloadError: nil, isDownloading: nil, downloadingStatus: nil, hasPlaceholder: true),
            .downloading
        )
        XCTAssertEqual(
            ICloudItemStateResolver.resolve(downloadError: nil, isDownloading: nil, downloadingStatus: nil, hasPlaceholder: false),
            .notInICloud
        )
    }

    func testICloudPlaceholderMapsToLogicalRuntimeFile() {
        let placeholder = URL(fileURLWithPath: "/tmp/package/.main.jsx.icloud")
        XCTAssertEqual(ScriptManager.logicalURL(for: placeholder).path, "/tmp/package/main.jsx")
        let nested = URL(fileURLWithPath: "/tmp/package/lib/.weather.json.icloud")
        XCTAssertEqual(ScriptManager.logicalURL(for: nested).path, "/tmp/package/lib/weather.json")
        let normal = URL(fileURLWithPath: "/tmp/package/main.jsx")
        XCTAssertEqual(ScriptManager.logicalURL(for: normal), normal)
    }
}

final class ICloudContainerIntegrationTests: XCTestCase {
    private func integrationContainer() throws -> URL {
        try XCTUnwrap(
            FileManager.default.url(forUbiquityContainerIdentifier: "iCloud.ScriptWidget"),
            "The test was explicitly enabled, but the iCloud container is unavailable"
        )
    }

    func testRealICloudContainerRoundTripWhenEnabled() throws {
        guard ProcessInfo.processInfo.environment["SCRIPTWIDGET_ICLOUD_INTEGRATION"] == "1" else {
            throw XCTSkip("Set SCRIPTWIDGET_ICLOUD_INTEGRATION=1 on a signed-in device to run real iCloud I/O")
        }
        let container = try integrationContainer()
        let directory = container.appendingPathComponent("Documents/Automation", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("roundtrip-\(UUID().uuidString).txt")
        let payload = "ScriptWidget iCloud automation \(Date().timeIntervalSince1970)"
        defer { try? FileManager.default.removeItem(at: url) }

        try payload.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), payload)
        let values = try url.resourceValues(forKeys: [.isUbiquitousItemKey])
        XCTAssertEqual(values.isUbiquitousItem, true)
    }

    func testCrossDeviceConvergenceWhenConfigured() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SCRIPTWIDGET_ICLOUD_INTEGRATION"] == "1",
              let role = environment["SCRIPTWIDGET_ICLOUD_ROLE"],
              let token = environment["SCRIPTWIDGET_ICLOUD_SHARED_TOKEN"],
              !token.isEmpty else {
            throw XCTSkip("Configure iCloud role and shared token for a two-device convergence test")
        }
        let directory = try integrationContainer().appendingPathComponent("Documents/Automation", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("cross-device-\(token).txt")

        if role == "writer" {
            try token.write(to: url, atomically: true, encoding: .utf8)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), token)
            return
        }
        guard role == "reader" else { return XCTFail("Unknown iCloud test role: \(role)") }
        defer { try? FileManager.default.removeItem(at: url) }
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            if (try? String(contentsOf: url, encoding: .utf8)) == token { return }
            Thread.sleep(forTimeInterval: 1)
        }
        XCTFail("The writer's iCloud file did not converge to the reader within 60 seconds")
    }
}
