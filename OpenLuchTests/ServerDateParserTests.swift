import XCTest
@testable import OpenLuch

// Даты ЛЭРС бывают в нескольких вариантах — проверяем каждый.
final class ServerDateParserTests: XCTestCase {

    func testDateWithSevenFractionDigits() throws {
        // Так сервер пишет большинство дат.
        let date = try XCTUnwrap(ServerDateParser.date(from: "2026-10-02T21:27:34.9255229Z"))
        let expected = try XCTUnwrap(ServerDateParser.date(from: "2026-10-02T21:27:34Z"))
        XCTAssertEqual(date.timeIntervalSince(expected), 0.9255229, accuracy: 0.001)
    }

    func testDateWithTimeZoneOffset() throws {
        let local = try XCTUnwrap(ServerDateParser.date(from: "2026-10-02T21:27:34+10:00"))
        let utc = try XCTUnwrap(ServerDateParser.date(from: "2026-10-02T11:27:34Z"))
        XCTAssertEqual(local, utc)
    }

    func testDateWithoutTimeZoneIsNotParsed() {
        // Такие даты тоже встречаются у ЛЭРС (stability.calcDate) — их сознательно не разбираем.
        XCTAssertNil(ServerDateParser.date(from: "2026-10-02T14:45:11.5239277"))
        XCTAssertNil(ServerDateParser.date(from: "вчера"))
    }
}
