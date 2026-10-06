import XCTest
@testable import OpenLuch

// Датчики точки учёта: разбор ответа, магистрали и подписи, правило загрузки.
final class PointSensorsTests: XCTestCase {

    /// Пример — настоящий ответ my.lers.ru по точке 686 «Отопление и ГВС», сокращённый:
    /// датчики и справочник только их приборов (без параметров опроса и описаний интерфейсов моделей).
    private func loadSensors() throws -> [PointSensor] {
        let data = try SampleFiles.data(named: "measurepoint-sensors")
        return try JSONDecoder().decode(MeasurePointSensorsResponse.self, from: data).makeSensors()
    }

    func testSensorsAreGroupedLikeInLersProgram() throws {
        let sensors = try loadSensors()
        XCTAssertEqual(sensors.count, 6)

        // Подающая магистраль: температура, давление, объём — как в программе ЛЭРС.
        let supply = sensors.filter { $0.pipe == .supply }
        XCTAssertEqual(supply.map { $0.measuredTitle }, ["Температура", "Давление", "Объём"])
        XCTAssertEqual(supply.map { $0.equipmentTitle },
                       ["КТСП-Р № 2198", "Sitrans P 7MF1563 № 2052161", "КМ-5-4 № 018395"])

        let returnPipe = sensors.filter { $0.pipe == .return }
        XCTAssertEqual(returnPipe.map { $0.measuredTitle }, ["Температура", "Давление", "Объём"])
        XCTAssertEqual(returnPipe.map { $0.equipmentTitle },
                       ["КТСП-Р № 2198", "Sitrans P 7MF1563 № 2052185", "ППС № 018826"])

        XCTAssertTrue(sensors.filter { $0.pipe == .other }.isEmpty)
    }

    func testSensorOutsidePipesUsesFullParameterTitle() {
        let sensor = PointSensor(parameter: "T_cw", order: 0, equipmentId: 1, equipment: nil)
        XCTAssertEqual(sensor.pipe, .other)
        XCTAssertEqual(sensor.measuredTitle, "Температура холодной воды")
        // Прибора нет в ответе — показываем хотя бы его номер.
        XCTAssertEqual(sensor.equipmentTitle, "Оборудование № 1")
    }

    func testLoadRule() {
        let now = Date()
        let day = PointSensorsModel.refreshInterval

        // Ни разу не загружались — при любой сети (иначе разделу нечего показать).
        XCTAssertTrue(PointSensorsModel.shouldLoad(savedAt: nil, connection: .cellular, now: now))
        XCTAssertTrue(PointSensorsModel.shouldLoad(savedAt: nil, connection: .wifi, now: now))

        // Сохранены — по сотовой сети не обновляем никогда, по Wi-Fi — раз в сутки.
        let old = now.addingTimeInterval(-day - 1)
        XCTAssertFalse(PointSensorsModel.shouldLoad(savedAt: old, connection: .cellular, now: now))
        XCTAssertTrue(PointSensorsModel.shouldLoad(savedAt: old, connection: .wifi, now: now))
        XCTAssertFalse(PointSensorsModel.shouldLoad(savedAt: now.addingTimeInterval(-60), connection: .wifi, now: now))
    }
}
