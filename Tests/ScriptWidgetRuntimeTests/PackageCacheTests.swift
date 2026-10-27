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
//  These exercise the production cache implementation in a per-process test
//  directory, hosted on iOS/macOS. Actual signed App Group acceptance is separate.
//  Each test cleans up its uniquely-named package cache entry in tearDown.
//

import XCTest
import Darwin
@testable import ScriptWidget

final class PackageCacheTests: XCTestCase {

    func testInitialHostPackageDoesNotRequireBundledTemplates() {
        let package = globalScriptWidgetPackage
        XCTAssertTrue(package.readonly)
        XCTAssertNotNil(package.accessError)
        XCTAssertNil(package.readMainFile().0)
        XCTAssertNil(package.readMetadata())
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.path.path))
    }

    private var createdPackageNames: [String] = []
    private var sourceRoot: URL!
    private var sourceManager: ScriptManager!
    private var cacheManager: ScriptManager!

    override func setUpWithError() throws {
        try super.setUpWithError()
        sourceRoot = FileManager.default.temporaryDirectory.appendingPathComponent("PackageCacheSources-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)
        sourceManager = ScriptManager(isBuild: false, scriptDirectoryOverride: sourceRoot)
        cacheManager = ScriptManager(isBuild: true)
    }

    override func tearDown() {
        // Remove any build-cache entries this test created.
        if let buildDir = ScriptManager.getSandboxBuildDirectoryURL() {
            for name in createdPackageNames {
                try? FileManager.default.removeItem(at: buildDir.appendingPathComponent(name))
            }
        }
        createdPackageNames.removeAll()
        if let sourceRoot { try? FileManager.default.removeItem(at: sourceRoot) }
        sourceManager = nil; cacheManager = nil
        super.tearDown()
    }

    /// A throwaway, writable package in a unique temp directory whose cache
    /// entry will be cleaned up in tearDown.
    private func makeTempPackage() -> ScriptWidgetPackage {
        let name = "PkgCacheTests-\(UUID().uuidString)"
        let dir = sourceRoot.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        createdPackageNames.append(name)
        return ScriptWidgetPackage(path: dir, readonly: false)
    }

    /// Simulate iCloud eviction by removing the on-disk file.
    private func evict(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "precondition: file should be gone")
    }

    func testManifestLinksAndNonregularFilesNeverFallBackToLegacyOrCachedPermissions() throws {
        let package = makeTempPackage()
        XCTAssertTrue(package.writeMainFile(content: "LEGACY").0)
        let manifest = WidgetPackageManifest.newProject(name: package.name)
        XCTAssertTrue(package.writeManifest(manifest).0)
        let outside = makeTempPackage().path.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(manifest).write(to: outside)
        let missing = outside.deletingLastPathComponent().appendingPathComponent("missing")
        for target in [outside, missing] {
            try FileManager.default.removeItem(at: package.manifestPath)
            try FileManager.default.createSymbolicLink(at: package.manifestPath, withDestinationURL: target)
            XCTAssertTrue(package.hasManifest)
            XCTAssertNil(package.readManifest())
            XCTAssertNil(package.readMainFile().0)
            XCTAssertFalse(package.ensureManifest().0)
        }
        try FileManager.default.removeItem(at: package.manifestPath)
        try FileManager.default.createDirectory(at: package.manifestPath, withIntermediateDirectories: false)
        XCTAssertTrue(package.hasManifest)
        XCTAssertNil(package.readMainFile().0)
    }

    func testCachedManifestRejectsLinkedFileAndLinkedPackageDirectory() throws {
        let package = makeTempPackage()
        XCTAssertTrue(package.writeMainFile(content: "CACHED").0)
        var manifest = WidgetPackageManifest.newProject(name: package.name)
        manifest.minimumRuntimeVersion = "1.3"
        XCTAssertTrue(package.writeManifest(manifest).0)
        let root = try XCTUnwrap(ScriptManager.getSandboxBuildDirectoryURL())
        let cachedPackage = root.appendingPathComponent(package.name)
        let cachedManifest = cachedPackage.appendingPathComponent("widget.json")
        let outside = makeTempPackage().path
        try JSONEncoder().encode(manifest).write(to: outside.appendingPathComponent("widget.json"))
        evict(package.manifestPath)
        XCTAssertEqual(package.readManifest()?.minimumRuntimeVersion, "1.3")
        try FileManager.default.removeItem(at: cachedManifest)
        try FileManager.default.createSymbolicLink(at: cachedManifest, withDestinationURL: outside.appendingPathComponent("widget.json"))
        XCTAssertTrue(package.hasManifest)
        XCTAssertNil(package.readManifest())
        XCTAssertNil(package.readMainFile().0)
        try FileManager.default.removeItem(at: cachedPackage)
        try FileManager.default.createSymbolicLink(at: cachedPackage, withDestinationURL: outside)
        XCTAssertTrue(package.hasManifest)
        XCTAssertNil(package.readManifest())
        XCTAssertNil(package.readMainFile().0)
    }

    func testMinimumRuntimeRemainsAuthoritativeAfterEviction() throws {
        let package = makeTempPackage()
        XCTAssertTrue(package.writeMainFile(content: "MUST_NOT_EXECUTE").0)
        var manifest = WidgetPackageManifest.newProject(name: package.name)
        manifest.minimumRuntimeVersion = "1.999"
        // Deliberately bypass writeManifest's validator, as an untrusted import can.
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: package.manifestPath)
        XCTAssertNotNil(package.readFile(relativePath: "widget.json").0)
        evict(package.manifestPath)
        evict(package.path.appendingPathComponent("main.jsx"))
        XCTAssertTrue(package.hasManifest)
        XCTAssertEqual(package.readManifest()?.minimumRuntimeVersion, "1.999")
        XCTAssertNil(package.readMainFile().0)
        XCTAssertFalse(package.ensureManifest().0)
    }

    func testMetadataReaderBoundsSizeAndRejectsLinksAndFIFOWithoutBlocking() throws {
        let package = makeTempPackage()
        let outside = makeTempPackage().path.appendingPathComponent("meta.json")
        try Data("{\"description\":\"Outside\"}".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: package.metaPath, withDestinationURL: outside)
        XCTAssertNil(package.readMetadata())
        try FileManager.default.removeItem(at: package.metaPath)
        try Data(repeating: 32, count: ScriptWidgetMetadataFile.maximumBytes + 1).write(to: package.manifestPath)
        XCTAssertTrue(package.hasManifest)
        XCTAssertNil(package.readManifest())
        try FileManager.default.removeItem(at: package.manifestPath)
        XCTAssertEqual(mkfifo(package.manifestPath.path, 0o600), 0)
        XCTAssertTrue(package.hasManifest)
        XCTAssertNil(package.readManifest())
        XCTAssertFalse(package.ensureManifest().0)
    }

    func testFailedBuildPreservesLastWorkingPackage() throws {
        let package = makeTempPackage()
        XCTAssertTrue(package.writeMainFile(content: "WORKING").0)
        let build = sourceManager.buildScriptPackage(package: package)
        XCTAssertTrue(build.0, build.1)
        try FileManager.default.removeItem(at: package.path)
        XCTAssertFalse(sourceManager.buildScriptPackage(package: package).0)
        XCTAssertEqual(cacheManager.getScriptPackage(packageName: package.name).readMainFile().0, "WORKING")
    }

    func testBuildReplacesPackageAndRejectsIncompleteSnapshot() throws {
        let package = makeTempPackage()
        XCTAssertTrue(package.writeMainFile(content: "OLD").0)
        let build = sourceManager.buildScriptPackage(package: package)
        XCTAssertTrue(build.0, build.1)
        try "NEW".write(to: package.jsxPath, atomically: true, encoding: .utf8)
        let replacement = sourceManager.buildScriptPackage(package: package)
        XCTAssertTrue(replacement.0, replacement.1)
        XCTAssertEqual(cacheManager.getScriptPackage(packageName: package.name).readMainFile().0, "NEW")
        try Data().write(to: package.path.appendingPathComponent(".image.png.icloud"))
        try "INCOMPLETE".write(to: package.jsxPath, atomically: true, encoding: .utf8)
        XCTAssertFalse(sourceManager.buildScriptPackage(package: package).0)
        XCTAssertEqual(cacheManager.getScriptPackage(packageName: package.name).readMainFile().0, "NEW")
    }

    func testManifestEntrySurvivesEvictionAndMalformedManifestFailsClosed() throws {
        let package = makeTempPackage()
        XCTAssertTrue(package.writeFile(relativePath: "src/widget.jsx", content: "ENTRY").0)
        var manifest = WidgetPackageManifest.legacy(name: package.name, metadata: nil)
        manifest.entry = "src/widget.jsx"
        XCTAssertTrue(package.writeManifest(manifest).0)
        XCTAssertEqual(package.readMainFile().0, "ENTRY")
        evict(package.jsxPath)
        evict(package.manifestPath)
        XCTAssertEqual(package.readMainFile().0, "ENTRY")
        try "{invalid".write(to: package.manifestPath, atomically: true, encoding: .utf8)
        XCTAssertNil(package.readMainFile().0)
        XCTAssertFalse(package.ensureManifest().0)
        XCTAssertEqual(try String(contentsOf: package.manifestPath, encoding: .utf8), "{invalid")
    }

    func testNestedDownloadTraversalDoesNotCycleOrFollowSymlinks() throws {
        let package = makeTempPackage()
        let nested = package.path.appendingPathComponent("a/a")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data().write(to: nested.appendingPathComponent(".main.jsx.icloud"))
        try FileManager.default.createSymbolicLink(at: package.path.appendingPathComponent("loop"), withDestinationURL: package.path)
        let urls = package.downloadableFileURLs(in: package.path)
        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(urls.first?.lastPathComponent, "main.jsx")
        XCTAssertEqual(urls.first?.deletingLastPathComponent().resolvingSymlinksInPath().path,
                       nested.resolvingSymlinksInPath().path)
    }

    func testMigrationPreservesCollisionsAndFileExtensions() throws {
        let source = makeTempPackage()
        let destination = makeTempPackage()
        try "NEW".write(to: source.path.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try "OLD".write(to: destination.path.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try ScriptManager.migrateLocalItems(from: source.path, to: destination.path)
        XCTAssertEqual(try String(contentsOf: destination.path.appendingPathComponent("notes.txt"), encoding: .utf8), "OLD")
        XCTAssertEqual(try String(contentsOf: destination.path.appendingPathComponent("notes (1).txt"), encoding: .utf8), "NEW")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path.path))
    }

    func testMigrationListingFailureDoesNotDeleteSource() throws {
        final class FailingFileManager: FileManager, @unchecked Sendable {
            override func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?, options mask: FileManager.DirectoryEnumerationOptions = []) throws -> [URL] {
                throw CocoaError(.fileReadNoPermission)
            }
        }
        let package = makeTempPackage()
        XCTAssertTrue(package.writeMainFile(content: "KEEP").0)
        let destination = package.path.appendingPathComponent("destination")
        XCTAssertThrowsError(try ScriptManager.migrateLocalItems(from: package.path, to: destination, fileManager: FailingFileManager()))
        XCTAssertEqual(try String(contentsOf: package.jsxPath, encoding: .utf8), "KEEP")
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

    /// On devices, app and iCloud containers are reached through the
    /// `/var` -> `/private/var` symlink. An evicted file's path must still map
    /// to its build-cache copy (regression: the fallback served nothing there).
    func testReadFallsBackToBuildCacheThroughSymlinkedContainer() throws {
        let name = "PkgCacheTests-\(UUID().uuidString)"
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("PkgCacheSymlink-\(UUID().uuidString)")
        let real = base.appendingPathComponent("real", isDirectory: true)
        let alias = base.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: real.appendingPathComponent(name), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: base) }
        createdPackageNames.append(name)
        let pkg = ScriptWidgetPackage(path: alias.appendingPathComponent(name, isDirectory: true), readonly: false)

        XCTAssertTrue(pkg.writeMainFile(content: "THROUGH_SYMLINK").0)
        XCTAssertEqual(pkg.readMainFile().0, "THROUGH_SYMLINK")
        evict(pkg.jsxPath)
        let fallback = pkg.readMainFile()
        XCTAssertEqual(fallback.0, "THROUGH_SYMLINK", "status was: \(fallback.1)")
        XCTAssertTrue(fallback.1.contains("build cache"), "status was: \(fallback.1)")
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
        let cachedCount = sourceManager.precachePackageFiles(pkg)
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

    func testPrecacheKeepsPackageImageAvailableAfterEviction() throws {
        let pkg = makeTempPackage()
        XCTAssertTrue(pkg.writeMainFile(content: "ONLY_TEXT").0)
        try? FileManager.default.createDirectory(at: pkg.imagePath, withIntermediateDirectories: true)
        let imageURL = pkg.imagePath.appendingPathComponent("weather.png")
        let imageData = Data([0x89, 0x50, 0x4E, 0x47, 0x01, 0x02])
        try? imageData.write(to: imageURL)

        let cachedCount = sourceManager.precachePackageFiles(pkg)
        XCTAssertEqual(cachedCount, 2, "main.jsx and its package image should be cached")

        evict(imageURL)
        let cachedImage = try XCTUnwrap(pkg.getImage("weather"))
        XCTAssertEqual(try Data(contentsOf: cachedImage.path), imageData)
    }

    func testPrecacheKeepsPackageGifAvailableAfterEviction() throws {
        let pkg = makeTempPackage()
        try? FileManager.default.createDirectory(at: pkg.imagePath, withIntermediateDirectories: true)
        let gifURL = pkg.imagePath.appendingPathComponent("animation.gif")
        let gifData = Data("GIF89a".utf8)
        try? gifData.write(to: gifURL)

        XCTAssertEqual(sourceManager.precachePackageFiles(pkg), 1)
        evict(gifURL)

        let cachedGIF = try XCTUnwrap(pkg.getGifFile("animation.gif"))
        XCTAssertEqual(try Data(contentsOf: cachedGIF), gifData)
    }

    func testPrecacheCachesNestedFiles() {
        // The URL enumerator recurses, so imports in subdirectories are cached too.
        let pkg = makeTempPackage()
        XCTAssertTrue(pkg.writeMainFile(content: "MAIN").0)
        // writeFile doesn't create intermediate dirs, so make the subdir first.
        try? FileManager.default.createDirectory(at: pkg.path.appendingPathComponent("lib"),
                                                 withIntermediateDirectories: true)
        XCTAssertTrue(pkg.writeFile(relativePath: "lib/util.js", content: "UTIL").0)

        let cachedCount = sourceManager.precachePackageFiles(pkg)
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

final class PackageBoundaryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Boundary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testNamesPreserveUnicodeButRejectDirectoryAndCacheEscapes() {
        for name in ["", " ", ".", "..", "../outside", "/outside", "folder/child", "folder\\child", "__Build", "__BUILD", ".hidden", "name\0bad", "name\nbad", "C:relative", String(repeating: "a", count: 81), String(repeating: "😀", count: 61)] {
            XCTAssertFalse(ScriptWidgetPackageName.isValid(name), name)
            XCTAssertFalse(name.checkIfValidFileName(), name)
        }
        for name in ["My Widget", "阅读记录", "👩‍💻 Focus", String(repeating: "e\u{301}", count: 80), String(repeating: "😀", count: 60)] {
            XCTAssertTrue(ScriptWidgetPackageName.isValid(name), name)
        }
    }

    func testInvalidManagerNamesProduceExplicitUnavailablePackage() throws {
        let manager = ScriptManager(isBuild: true, scriptDirectoryOverride: root.appendingPathComponent("library"))
        let marker = root.appendingPathComponent("outside")
        try Data("preserved".utf8).write(to: marker)
        for name in ["../outside", "__Build", "/outside"] {
            XCTAssertNil(manager.getPackagePathFromPackageName(packageName: name))
            let package = manager.getScriptPackage(packageName: name)
            XCTAssertNotNil(package.accessError)
            XCTAssertTrue(package.readonly)
            XCTAssertTrue(package.hasManifest)
            XCTAssertNil(package.readMainFile().0)
            XCTAssertFalse(package.writeMainFile(content: "overwritten").0)
            XCTAssertFalse(package.delete())
        }
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "preserved")
    }

    func testDescriptorOperationsPreserveNestedResourcesAndRejectTraversal() throws {
        XCTAssertTrue(ScriptWidgetPackageFiles.write(Data("nested".utf8), root: root, relative: "src/阅读.txt"))
        XCTAssertEqual(ScriptWidgetPackageFiles.read(root: root, relative: "src/阅读.txt"), Data("nested".utf8))
        XCTAssertTrue(ScriptWidgetPackageFiles.move(root: root, source: "src/阅读.txt", destination: "src/renamed.txt"))
        XCTAssertNil(ScriptWidgetPackageFiles.read(root: root, relative: "src/阅读.txt"))
        for relative in ["../escape", "/escape", "src/../escape", "src\\escape"] {
            XCTAssertNil(ScriptWidgetPackageFiles.safeURL(root: root, relative: relative))
            XCTAssertFalse(ScriptWidgetPackageFiles.write(Data(), root: root, relative: relative))
        }
        XCTAssertTrue(ScriptWidgetPackageFiles.removeTree(root: root, relative: "src"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("src").path))
    }

    func testLinksHardlinksAndFIFOsCannotReadOrOverwriteOutsideData() throws {
        let outside = root.appendingPathComponent("outside")
        let packageRoot = root.appendingPathComponent("package")
        try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)
        try Data("private".utf8).write(to: outside)
        let link = packageRoot.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let hard = packageRoot.appendingPathComponent("hard")
        try FileManager.default.linkItem(at: outside, to: hard)
        let fifo = packageRoot.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        for name in ["link", "hard", "pipe"] {
            XCTAssertNil(ScriptWidgetPackageFiles.read(root: packageRoot, relative: name))
            XCTAssertFalse(ScriptWidgetPackageFiles.write(Data("bad".utf8), root: packageRoot, relative: name))
            XCTAssertNil(ScriptWidgetPackageFiles.safeURL(root: packageRoot, relative: name))
        }
        XCTAssertEqual(try Data(contentsOf: outside), Data("private".utf8))
        let linkedDirectory = packageRoot.appendingPathComponent("directory")
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: root)
        XCTAssertFalse(ScriptWidgetPackageFiles.write(Data(), root: packageRoot, relative: "directory/escape"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("escape").path))
        XCTAssertTrue(ScriptWidgetPackageFiles.removeTree(root: root, relative: "package"))
        XCTAssertEqual(try Data(contentsOf: outside), Data("private".utf8))
    }

    func testWrongCaseManifestNeverDowngradesToLegacyAndFullPathsStayInsidePackage() throws {
        let packageRoot = root.appendingPathComponent("CaseBoundary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)
        let package = ScriptWidgetPackage(path: packageRoot, readonly: true)
        try Data("$render(<text>must not run</text>);".utf8).write(to: packageRoot.appendingPathComponent("main.jsx"))
        try JSONEncoder().encode(WidgetPackageManifest.newProject(name: "Safe")).write(to: packageRoot.appendingPathComponent("Widget.json"))
        XCTAssertTrue(package.hasManifest)
        XCTAssertNil(package.readManifest())
        XCTAssertNil(package.readMainFile().0)
        let outside = root.appendingPathComponent("outside.txt")
        try Data("private".utf8).write(to: outside)
        XCTAssertNil(package.readFile(fullPath: outside).0)
        XCTAssertNil(package.locallyAvailableFileURL(fullPath: outside))
        XCTAssertFalse(package.writeFile(fullPath: outside, content: "bad").0)
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "private")
    }

    func testWrongCasePrimaryManifestCannotReusePreviouslyAuthorizedCache() throws {
        let packageRoot = root.appendingPathComponent("CaseCache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: packageRoot, withIntermediateDirectories: true)
        let package = ScriptWidgetPackage(path: packageRoot, readonly: false)
        let cache = try XCTUnwrap(ScriptManager.getSandboxBuildDirectoryURL())
        defer { _ = ScriptWidgetPackageFiles.removeTree(root: cache, relative: package.name) }
        let bytes = try JSONEncoder().encode(WidgetPackageManifest.newProject(name: "Safe"))
        XCTAssertTrue(ScriptWidgetPackageFiles.write(bytes, root: cache, relative: package.name + "/widget.json"))
        try bytes.write(to: packageRoot.appendingPathComponent("Widget.json"))
        try Data("$render(<text>must not run</text>);".utf8).write(to: packageRoot.appendingPathComponent("main.jsx"))
        XCTAssertTrue(package.hasManifest)
        XCTAssertNil(package.readManifest())
        XCTAssertNil(package.readMainFile().0)
    }

    func testConcurrentReadersObserveOnlyCompleteAtomicReplacements() {
        let first = Data(repeating: 65, count: 8192)
        let second = Data(repeating: 66, count: 8192)
        XCTAssertTrue(ScriptWidgetPackageFiles.write(first, root: root, relative: "atomic.txt"))
        let packageRoot = root!
        let writers = DispatchGroup()
        writers.enter()
        DispatchQueue.global().async {
            defer { writers.leave() }
            for index in 0..<100 {
                XCTAssertTrue(ScriptWidgetPackageFiles.write(index.isMultiple(of: 2) ? second : first, root: packageRoot, relative: "atomic.txt"))
            }
        }
        for _ in 0..<200 {
            let value = ScriptWidgetPackageFiles.read(root: packageRoot, relative: "atomic.txt")
            XCTAssertTrue(value == first || value == second, "Readers must never see missing or partial file bytes")
        }
        XCTAssertEqual(writers.wait(timeout: .now() + 10), .success)
    }

    func testCaseAliasesAndSizeBudgetsAreRejectedWithoutReplacingValidBytes() throws {
        XCTAssertTrue(ScriptWidgetPackageFiles.write(Data("safe".utf8), root: root, relative: "Resource.txt"))
        XCTAssertNil(ScriptWidgetPackageFiles.read(root: root, relative: "resource.txt"))
        XCTAssertFalse(ScriptWidgetPackageFiles.write(Data("bad".utf8), root: root, relative: "resource.txt"))
        XCTAssertNil(ScriptWidgetPackageFiles.read(root: root, relative: "Resource.txt", maximumBytes: 3))
        XCTAssertEqual(ScriptWidgetPackageFiles.read(root: root, relative: "Resource.txt"), Data("safe".utf8))
    }
}

final class CloudJSONTests: XCTestCase {
    private var root: URL!
    private var cloud: URL!
    private var account = String(repeating: "a", count: 64)
    private var cloudAvailable = true
    private var active = true
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudJSONTests-" + UUID().uuidString)
        cloud = root.appendingPathComponent("Cloud")
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func device(_ name: String) throws -> ScriptWidgetCloudJSONStore {
        let local = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        return try ScriptWidgetCloudJSONStore(container: local, owner: UUID().uuidString.lowercased(), environment: { [self] in
            .init(account: account, documents: cloudAvailable ? cloud : nil)
        }, validate: { [self] in if !active { throw ScriptWidgetCloudJSONError.identityChanged } })
    }
    private func object(_ response: [String: Any]) throws -> [String: Any] { try XCTUnwrap(response["value"] as? [String: Any]) }
    func testLocalFirstOfflineCacheAndTwoDeviceRoundTrip() throws {
        let a = try device("A"), b = try device("B")
        XCTAssertThrowsError(try a.read("habits.json"))
        try a.connect(); try b.connect(existingStore: a.connection())
        cloudAvailable = false
        let written = try a.write("habits.json", value: ["read": ["2026-10-26"]], expected: "")
        XCTAssertEqual(written["state"] as? String, "pending")
        XCTAssertEqual(try object(a.read("habits.json"))["read"] as? [String], ["2026-10-26"])
        XCTAssertThrowsError(try a.synchronize())
        cloudAvailable = true
        _ = try a.synchronize(); _ = try b.synchronize()
        XCTAssertEqual(try object(b.read("habits.json"))["read"] as? [String], ["2026-10-26"])
        XCTAssertTrue(try a.status()["uploaded"] is NSNull)
    }
    func testDisconnectedWritersRetainBothVersionsAndExplicitResolution() throws {
        let a = try device("A"), b = try device("B")
        try a.connect(); try b.connect(existingStore: a.connection())
        let original = try a.write("habits.json", value: ["days": []], expected: "")
        _ = try a.synchronize(); _ = try b.synchronize()
        let base = try XCTUnwrap(original["revision"] as? String)
        cloudAvailable = false
        _ = try a.write("habits.json", value: ["days": ["2026-10-25"]], expected: base)
        _ = try b.write("habits.json", value: ["days": ["2026-10-26"]], expected: base)
        cloudAvailable = true
        _ = try a.synchronize(); _ = try b.synchronize(); _ = try a.synchronize()
        let conflict = try a.read("habits.json")
        XCTAssertEqual(conflict["state"] as? String, "conflict")
        XCTAssertEqual((conflict["conflicts"] as? [Any])?.count, 2)
        let revision = try XCTUnwrap(conflict["revision"] as? String)
        XCTAssertThrowsError(try a.write("habits.json", value: ["lost": true], expected: revision))
        XCTAssertThrowsError(try a.write("habits.json", value: [:], expected: base, resolving: true))
        _ = try a.write("habits.json", value: ["days": ["2026-10-25", "2026-10-26"]], expected: revision, resolving: true)
        _ = try a.synchronize(); _ = try b.synchronize()
        XCTAssertEqual((try object(b.read("habits.json"))["days"] as? [String])?.count, 2)
        let files = try FileManager.default.contentsOfDirectory(atPath: cloud.appendingPathComponent("WidgetData/\(try a.connection())/habits.json").path)
        XCTAssertEqual(files.count, 4, "Original, both branches and resolution must all remain")
    }
    func testNamesQuotasStaleWritesAndIdentityRetirement() throws {
        let a = try device("A"); try a.connect()
        for name in ["../x.json", "/x.json", "X.json", "a/b.json", "a\\b.json", "a.JSON", ".json"] {
            XCTAssertThrowsError(try a.write(name, value: [:], expected: ""), name)
        }
        let first = try a.write("note.json", value: ["keep": true], expected: "")
        XCTAssertThrowsError(try a.write("note.json", value: ["lost": true], expected: ""))
        XCTAssertThrowsError(try a.write("huge.json", value: ["huge": String(repeating: "日", count: 100_000)], expected: ""))
        XCTAssertEqual(try a.read("note.json")["revision"] as? String, first["revision"] as? String)
        active = false
        XCTAssertThrowsError(try a.read("note.json")); XCTAssertThrowsError(try a.synchronize())
    }
    func testAccountSwitchAndNewInstallationCannotReadOldCache() throws {
        let a = try device("A"); try a.connect(); _ = try a.write("private.json", value: ["keep": true], expected: "")
        let fresh = try device("A")
        XCTAssertThrowsError(try fresh.read("private.json"))
        account = String(repeating: "b", count: 64)
        XCTAssertThrowsError(try a.read("private.json")); XCTAssertThrowsError(try a.synchronize())
        account = String(repeating: "a", count: 64)
        XCTAssertEqual(try object(a.read("private.json"))["keep"] as? Bool, true)
    }
    func testTamperedRemoteRevisionAndSymlinkNeverOverwriteHistory() throws {
        let a = try device("A"); try a.connect(); _ = try a.write("note.json", value: ["keep": true], expected: ""); _ = try a.synchronize()
        let id = try a.connection()
        let directory = cloud.appendingPathComponent("WidgetData/\(id)/note.json")
        let revision = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let original = try Data(contentsOf: revision)
        try Data("{}".utf8).write(to: revision)
        XCTAssertThrowsError(try a.synchronize())
        XCTAssertEqual(try object(a.read("note.json"))["keep"] as? Bool, true)
        XCTAssertEqual(try Data(contentsOf: revision), Data("{}".utf8))
        try original.write(to: revision)
        try FileManager.default.removeItem(at: revision)
        let external = root.appendingPathComponent("outside.json"); try Data("private".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(at: revision, withDestinationURL: external)
        XCTAssertThrowsError(try a.synchronize()); XCTAssertEqual(try String(contentsOf: external, encoding: .utf8), "private")
    }
    func testCloudFolderRemovalDoesNotResurrectDeletedStore() throws {
        let a = try device("A"); try a.connect(); _ = try a.write("note.json", value: ["keep": true], expected: "")
        let folder = cloud.appendingPathComponent("WidgetData/\(try a.connection())")
        try FileManager.default.removeItem(at: folder)
        XCTAssertThrowsError(try a.synchronize())
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(try object(a.read("note.json"))["keep"] as? Bool, true)
    }
}


extension CloudJSONTests {
    func testDisconnectRevokesOnlyGrantAndReconnectionPreservesRecords() throws {
        let a = try device("A"); try a.connect()
        let id = try a.connection()
        _ = try a.write("note.json", value: ["keep": true], expected: "")
        _ = try a.synchronize()
        try a.disconnect()
        XCTAssertThrowsError(try a.read("note.json"))
        XCTAssertThrowsError(try a.write("note.json", value: [:], expected: ""))
        try a.connect(existingStore: id)
        XCTAssertEqual(try object(a.read("note.json"))["keep"] as? Bool, true)
    }
}


extension CloudJSONTests {
    func testEvictedLocalCacheIsRestoredFromCloudWithoutChangingGrant() throws {
        let a = try device("A"); try a.connect()
        _ = try a.write("note.json", value: ["keep": true], expected: "")
        _ = try a.synchronize()
        try FileManager.default.removeItem(at: root.appendingPathComponent("A/CloudJSON.v1/cache"))
        XCTAssertTrue(try a.read("note.json")["value"] is NSNull)
        _ = try a.synchronize()
        XCTAssertEqual(try object(a.read("note.json"))["keep"] as? Bool, true)
    }
    func testHardLinkedRevisionFailsClosedWithoutChangingExternalFile() throws {
        let a = try device("A"); try a.connect()
        _ = try a.write("note.json", value: ["keep": true], expected: "")
        _ = try a.synchronize()
        let directory = cloud.appendingPathComponent("WidgetData/\(try a.connection())/note.json")
        let revision = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let bytes = try Data(contentsOf: revision)
        let external = root.appendingPathComponent("hardlink.json")
        try FileManager.default.linkItem(at: revision, to: external)
        XCTAssertThrowsError(try a.synchronize())
        XCTAssertEqual(try Data(contentsOf: external), bytes)
        XCTAssertEqual(try object(a.read("note.json"))["keep"] as? Bool, true)
    }
    func testTwoNativeGrantsShareOneStoreLock() throws {
        let a = try device("A"), b = try device("A")
        try a.connect(); try b.connect(existingStore: a.connection())
        let container = root.appendingPathComponent("A")
        let id = try a.connection()
        let held = ScriptWidgetStorageLock.withExclusiveAccess(container: container, namespace: "CloudJSON.v1.store.\(account).\(id)") {
            let result = Result { try b.write("note.json", value: ["lost": true], expected: "") }
            if case .success = result { XCTFail("A second native grant must respect the shared store lock") }
            return true
        }
        XCTAssertEqual(held, true)
        _ = try a.write("note.json", value: ["keep": true], expected: "")
        XCTAssertThrowsError(try b.write("note.json", value: ["lost": true], expected: ""))
        XCTAssertEqual(try object(b.read("note.json"))["keep"] as? Bool, true)
    }
}


extension CloudJSONTests {
    func testFinderMetadataDoesNotBlockInspectableCloudFiles() throws {
        let a = try device("A"); try a.connect()
        _ = try a.write("note.json", value: ["keep": true], expected: "")
        _ = try a.synchronize()
        let directory = cloud.appendingPathComponent("WidgetData/\(try a.connection())")
        try Data([0, 1]).write(to: directory.appendingPathComponent(".DS_Store"))
        try Data([0, 1]).write(to: directory.appendingPathComponent("note.json/.DS_Store"))
        _ = try a.synchronize()
        XCTAssertEqual(try object(a.read("note.json"))["keep"] as? Bool, true)
    }
}
