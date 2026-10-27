import XCTest
import Foundation
@testable import ScriptWidget

final class SystemServiceTests: XCTestCase {
    func testNotificationNamesDatesAndUnknownFieldsFailClosed() throws {
        let valid: [String: Any] = ["key": "daily", "title": "Read", "body": "A chapter", "date": "2026-10-28T12:00:00Z"]
        let now = ISO8601DateFormatter().date(from: "2026-10-27T12:00:00Z")!
        XCTAssertEqual(try ScriptWidgetNotificationOptions(valid, now: now).key, "daily")
        for patch: [String: Any] in [["key":"../other"],["key":""],["date":"2020-01-01T00:00:00Z"],["title":"a\nprivate"],["url":"https://example.com"]] {
            XCTAssertThrowsError(try ScriptWidgetNotificationOptions(valid.merging(patch, uniquingKeysWith: { _, b in b }), now: now))
        }
    }
    func testCalendarMutationRequiresCanonicalIDAndBoundedDates() throws {
        let input: [String: Any] = ["requestID":"11111111-1111-4111-8111-111111111111", "calendarID":"calendar", "title":"Focus", "start":"2026-10-28T12:00:00Z", "end":"2026-10-28T13:00:00Z"]
        let first = try ScriptWidgetCalendarMutation(input, updating: false)
        XCTAssertEqual(first.listID, "calendar")
        XCTAssertThrowsError(try ScriptWidgetCalendarMutation(input, updating: true))
        for patch: [String: Any] in [["end":"2026-10-28T11:00:00Z"],["allDay":1],["requestID":"not-a-uuid"],["recurrence":"daily"]] {
            XCTAssertThrowsError(try ScriptWidgetCalendarMutation(input.merging(patch, uniquingKeysWith: { _,b in b }), updating: false))
        }
    }
    func testHealthHistoryBoundsAndTypes() throws {
        for metric in ScriptWidgetHealthHistoryOptions.metrics { XCTAssertEqual(try ScriptWidgetHealthHistoryOptions(["metric":metric]).days,7) }
        for input: [String: Any] in [["metric":"all"],["metric":"steps","days":true],["metric":"steps","days":32],["metric":"steps","days":1.5],["metric":"steps","rawSamples":true]] { XCTAssertThrowsError(try ScriptWidgetHealthHistoryOptions(input)) }
    }
    func testAlarmIDsAreStableAndIsolatedByOwner() throws {
        let a="11111111-1111-4111-8111-111111111111", b="22222222-2222-4222-8222-222222222222"
        XCTAssertEqual(try ScriptWidgetAlarmOptions.id(owner:a,key:"focus"),try ScriptWidgetAlarmOptions.id(owner:a,key:"focus"))
        XCTAssertNotEqual(try ScriptWidgetAlarmOptions.id(owner:a,key:"focus"),try ScriptWidgetAlarmOptions.id(owner:b,key:"focus"))
        XCTAssertThrowsError(try ScriptWidgetAlarmOptions(["key":"focus","title":"Focus","seconds":0]))
        XCTAssertThrowsError(try ScriptWidgetAlarmOptions(["key":"focus","title":"Focus","seconds":60,"date":"2026-11-01T12:00:00Z"]))
    }
    func testCSVQuotesRowsAndBinaryBounds() throws {
        let parsed=try ScriptWidgetDocumentData.csv(Data("name,value\r\n\"A,B\",\"quote \"\"here\"\"\"\r\n".utf8))
        XCTAssertEqual(parsed["headers"] as? [String],["name","value"])
        XCTAssertEqual(parsed["rows"] as? [[String]],[["A,B","quote \"here\""]])
        for text in ["a,a\n1,2", "a,b\n1", "a\n\"unclosed", "a\n\"closed\"x"] { XCTAssertThrowsError(try ScriptWidgetDocumentData.csv(Data(text.utf8))) }
        XCTAssertThrowsError(try ScriptWidgetDocumentData.csv(Data([0xff,0xfe])))
        XCTAssertThrowsError(try ScriptWidgetDocumentData.json(Data(repeating:32,count:262145)))
        XCTAssertThrowsError(try ScriptWidgetDocumentData.csv(Data(("a\n"+Array(repeating:"1",count:501).joined(separator:"\n")).utf8)))
    }
    func testWeatherCoordinatePrecisionAndMalformedResponses() throws {
        let options=try ScriptWidgetWeatherOptions(["latitude":37.33495,"longitude":-122.00902])
        XCTAssertEqual(options.latitude,37.33); XCTAssertEqual(options.longitude,-122.01)
        XCTAssertThrowsError(try ScriptWidgetWeatherOptions(["latitude":91,"longitude":0]))
        XCTAssertThrowsError(try ScriptWidgetWeatherOptions(["latitude":0,"longitude":0,"hours":true]))
        XCTAssertThrowsError(try ScriptWidgetWeatherOptions.normalize(Data("{}".utf8),options:options))
    }
    func testNativeGrantsCannotBeImportedOrInheritedByAnotherOwner() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("SystemGrantTests-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let a=ScriptWidgetSystemAccessStore(container:root,owner:UUID().uuidString.lowercased(),validate:{})
        let b=ScriptWidgetSystemAccessStore(container:root,owner:UUID().uuidString.lowercased(),validate:{})
        let before=try a.load();var grant=before;grant.permissions=["documents"]
        let id=UUID().uuidString.lowercased();let bytes=Data("{\"keep\":true}".utf8)
        grant.documents=[.init(id:id,name:"Data.json",type:"json",bytes:bytes.count)]
        XCTAssertTrue(ScriptWidgetPackageFiles.write(bytes,root:root,relative:a.directory+"/documents/"+id))
        try a.save(grant,expected:before)
        XCTAssertEqual(try a.readDocument(id,type:"json"),bytes)
        XCTAssertThrowsError(try b.readDocument(id,type:"json"))
        XCTAssertThrowsError(try a.readDocument("../private",type:"json"))
        XCTAssertThrowsError(try a.readDocument(id,type:"csv"))
        let current=try a.load();var revoked=current;revoked.permissions=[];try a.save(revoked,expected:current)
        XCTAssertThrowsError(try a.readDocument(id,type:"json"))
        XCTAssertEqual(ScriptWidgetPackageFiles.read(root:root,relative:a.directory+"/documents/"+id),bytes)
        XCTAssertThrowsError(try a.save(grant,expected:current))
    }
    func testNativeGrantUnknownFieldsAndLinksFailClosed() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("SystemGrantTests-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let store=ScriptWidgetSystemAccessStore(container:root,owner:UUID().uuidString.lowercased(),validate:{})
        let before=try store.load();var allowed=before;allowed.permissions=["contacts"];try store.save(allowed,expected:before)
        let bytes=try JSONEncoder().encode(store.load());var json=try JSONSerialization.jsonObject(with:bytes) as! [String:Any];json["grantEverything"]=true
        XCTAssertTrue(ScriptWidgetPackageFiles.write(try JSONSerialization.data(withJSONObject:json),root:root,relative:store.path))
        XCTAssertThrowsError(try store.load())
        try FileManager.default.removeItem(at:root.appendingPathComponent(store.path))
        let external=root.appendingPathComponent("outside.json");try bytes.write(to:external)
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent(store.path),withDestinationURL:external)
        XCTAssertThrowsError(try store.load())
    }
    func testNativeFileImportRejectsLinksAndPreservesOriginal() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("SystemImportTests-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let source=root.appendingPathComponent("Data.json"), bytes=Data("{\"keep\":true}".utf8)
        try bytes.write(to:source)
        XCTAssertEqual(try ScriptWidgetDocumentData.importedFile(source),bytes)
        let link=root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:source)
        XCTAssertThrowsError(try ScriptWidgetDocumentData.importedFile(link))
        let hardlink=root.appendingPathComponent("hardlink.json")
        try FileManager.default.linkItem(at:source,to:hardlink)
        XCTAssertThrowsError(try ScriptWidgetDocumentData.importedFile(source))
        XCTAssertEqual(try Data(contentsOf:source),bytes)
    }

    func testScriptStorageCannotForgeNativeReceiptsOrOwnedEventRegistry() throws {
        let owner=UUID().uuidString.lowercased(), domain="SystemPrivateKeys-"+UUID().uuidString
        let defaults=UserDefaults(suiteName:domain)!
        defer { defaults.removePersistentDomain(forName:domain) }
        let store=ScriptWidgetSystemAccessStore(container:FileManager.default.temporaryDirectory,owner:owner,validate:{})
        let prefix="ScriptWidgetStorage.v2:"+owner+":"
        let forged=Data("{\"formatVersion\":1,\"entries\":[]}".utf8)
        try defaults.writeValue(forged,forKey:prefix+"system.calendar.receipts.v1")
        try defaults.writeValue(["victim":"calendar"],forKey:prefix+"system.calendar.owned.v1")
        XCTAssertNil(try defaults.readValue(forKey:store.privateKey("calendarReceipts")))
        XCTAssertNil(try defaults.readValue(forKey:store.privateKey("ownedEvents")))
        XCTAssertFalse(store.privateKey("alarmKeys").hasPrefix(prefix))
    }

    func testDailyNotificationUsesOneRepeatingSlotAndStrictLocalClock() throws {
        let input: [String:Any] = ["key":"daily", "title":"Read", "body":"A chapter", "daily":["hour":20,"minute":0]]
        let parsed=try ScriptWidgetNotificationOptions(input)
        XCTAssertNil(parsed.date); XCTAssertEqual(parsed.dailyHour,20); XCTAssertEqual(parsed.dailyMinute,0)
        XCTAssertThrowsError(try ScriptWidgetNotificationOptions(input.merging(["date":"2026-11-01T00:00:00Z"],uniquingKeysWith:{_,b in b})))
        for daily: [String:Any] in [["hour":24,"minute":0],["hour":20,"minute":true],["hour":20,"minute":0,"weekday":1]] { XCTAssertThrowsError(try ScriptWidgetNotificationOptions(input.merging(["daily":daily],uniquingKeysWith:{_,b in b}))) }
    }

}
