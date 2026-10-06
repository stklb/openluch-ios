import XCTest
@testable import OpenLuch

final class TextFormattingTests: XCTestCase {

    func testBytes() {
        XCTAssertEqual(TextFormatting.bytes(0), "0 Б")
        XCTAssertEqual(TextFormatting.bytes(850), "850 Б")
        XCTAssertEqual(TextFormatting.bytes(12 * 1024), "12 КБ")
        XCTAssertEqual(TextFormatting.bytes(2_831_155), "2,7 МБ")
    }

    func testDownloadProgress() {
        let known = DownloadProgress(receivedBytes: 120 * 1024, expectedBytes: 2_831_155, isWaitingForNetwork: false)
        XCTAssertEqual(TextFormatting.downloadProgress(known), "Получено 120 КБ из 2,7 МБ")
        let unknown = DownloadProgress(receivedBytes: 120 * 1024, expectedBytes: nil, isWaitingForNetwork: false)
        XCTAssertEqual(TextFormatting.downloadProgress(unknown), "Получено 120 КБ")
    }

    func testPlural() {
        let forms = [1: "объект", 2: "объекта", 4: "объекта", 5: "объектов", 11: "объектов", 12: "объектов",
                     14: "объектов", 21: "объект", 22: "объекта", 25: "объектов", 111: "объектов", 0: "объектов"]
        for (count, expected) in forms {
            XCTAssertEqual(TextFormatting.plural(count, one: "объект", few: "объекта", many: "объектов"),
                           expected, "для числа \(count)")
        }
        XCTAssertEqual(TextFormatting.measurePointsCount(1550), "1550 точек учёта")
        XCTAssertEqual(TextFormatting.measurePointsCount(3), "3 точки учёта")
        XCTAssertEqual(TextFormatting.equipmentCount(1), "1 единица оборудования")
        XCTAssertEqual(TextFormatting.equipmentCount(64), "64 единицы оборудования")
        XCTAssertEqual(TextFormatting.equipmentCount(11), "11 единиц оборудования")
        XCTAssertEqual(TextFormatting.years(4), "4 года")
        XCTAssertEqual(TextFormatting.years(16), "16 лет")
        XCTAssertEqual(TextFormatting.years(1), "1 год")
    }

    func testUpdatedAt() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 15, minute: 0)))
        let today = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 14, minute: 5)))
        let yesterday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 9, minute: 30)))
        let earlier = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 18, minute: 0)))
        let lastYear = try XCTUnwrap(calendar.date(from: DateComponents(year: 2025, month: 12, day: 12, hour: 18, minute: 0)))

        XCTAssertEqual(TextFormatting.updatedAt(today, now: now), "сегодня в 14:05")
        XCTAssertEqual(TextFormatting.updatedAt(yesterday, now: now), "вчера в 09:30")
        XCTAssertEqual(TextFormatting.updatedAt(earlier, now: now), "1 окт. в 18:00")
        XCTAssertTrue(TextFormatting.updatedAt(lastYear, now: now).contains("2025"))
    }

    func testSearchMatches() {
        let text = "Котельная №1 Хабаровск, Улица Тихоокеанская, 221б"
        XCTAssertTrue(TextFormatting.matches(text, query: "котельная"))
        // Слова в любом порядке, регистр не важен.
        XCTAssertTrue(TextFormatting.matches(text, query: "тихоокеанская КОТЕЛЬНАЯ"))
        XCTAssertFalse(TextFormatting.matches(text, query: "котельная ленина"))
        // «е» и «ё» — одно и то же.
        XCTAssertTrue(TextFormatting.matches("Узел учёта", query: "учет"))
        XCTAssertTrue(TextFormatting.matches("Узел учета", query: "учёт"))
    }
}
