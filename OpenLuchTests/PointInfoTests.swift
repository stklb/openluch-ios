import XCTest
@testable import OpenLuch

// Сведения в карточке точки: атрибуты с названиями из справочника, допуск, коэффициенты трансформации.
final class PointInfoTests: XCTestCase {

    func testPointFieldsDecodeFromServer() throws {
        // Фрагмент ответа my.lers.ru (Core/MeasurePoints?type=Regular).
        let json = #"""
        {"id": 3736, "title": "Коттеджи, ввод 3", "fullTitle": "", "systemType": "Electricity",
         "isVirtual": false, "admissionDate": "2026-06-04T00:00:00", "currentRatio": 30, "voltageRatio": 1,
         "attributes": [{"measurePointId": 3736, "code": "DateLimitTo", "value": "04.06.2026"},
                        {"measurePointId": 3736, "code": "Unknown", "value": "да"},
                        {"measurePointId": 3736, "code": "Empty", "value": ""}]}
        """#
        let point = try JSONDecoder().decode(MeasurePoint.self, from: Data(json.utf8))

        XCTAssertEqual(point.admissionDay, "2026-06-04")
        XCTAssertTrue(point.isAdmissionExpired(today: "2026-10-16"))
        XCTAssertFalse(point.isAdmissionExpired(today: "2026-06-04"), "в сам день допуска точка ещё допущена")

        // Ток ≠ 1 — показываем, напряжение = 1 — нет.
        XCTAssertEqual(point.transformationRatios.current, 30)
        XCTAssertNil(point.transformationRatios.voltage)

        // Название — из справочника; кода нет в справочнике — сам код; пустое значение — не показываем.
        let shown = point.filledAttributes(titles: ["DateLimitTo": "По какую дату допущен"])
        XCTAssertEqual(shown.map(\.title), ["По какую дату допущен", "Unknown"])
        XCTAssertEqual(shown.map(\.value), ["04.06.2026", "да"])
    }

    func testRatiosOnlyForElectricityAndEmptyAdmission() {
        let heat = MeasurePoint(id: 1, title: "", fullTitle: "", parentTitle: nil, address: nil, nodeId: nil,
                                systemType: "Heat", resourceKind: nil, state: nil,
                                admissionDate: "0001-01-01T00:00:00", currentRatio: 30)
        XCTAssertNil(heat.transformationRatios.current)
        XCTAssertNil(heat.admissionDay)
    }

    func testAttributeTitlesDirectory() throws {
        let json = #"""
        [{"id": 13, "title": "Дата приема на учет", "code": "InspectionDate", "comment": "", "entities": ["MeasurePoint"]},
         {"id": 14, "title": " ", "code": "NoTitle", "entities": ["MeasurePoint"]}]
        """#
        let response = try JSONDecoder().decode([CustomAttributeResponse].self, from: Data(json.utf8))
        XCTAssertEqual(CustomAttributeResponse.makeTitles(from: response), ["InspectionDate": "Дата приема на учет"])
    }

    func testPlainNumber() {
        XCTAssertEqual(TextFormatting.plainNumber(30), "30")
        XCTAssertEqual(TextFormatting.plainNumber(0.5), "0,5")
    }
}
