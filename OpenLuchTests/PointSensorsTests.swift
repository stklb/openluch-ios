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

    /// Датчики и список отчётов точки — по срокам из «Настроек», только при открытии экрана.
    func testLoadOnOpenRule() {
        let now = Date()
        let hour: TimeInterval = 60 * 60

        // Ни разу не загружались — при любой сети и даже при «Никогда» (иначе экрану нечего показать).
        XCTAssertTrue(CacheFreshness.isStaleOnOpen(savedAt: nil, lifetime: nil, now: now))
        XCTAssertTrue(CacheFreshness.isStaleOnOpen(savedAt: nil, lifetime: hour, now: now))

        // Сохранены: устарели по сроку — перекачиваем, свежие — нет; «Никогда» (или нет сети) — не трогаем.
        let old = now.addingTimeInterval(-hour - 1)
        XCTAssertTrue(CacheFreshness.isStaleOnOpen(savedAt: old, lifetime: hour, now: now))
        XCTAssertFalse(CacheFreshness.isStaleOnOpen(savedAt: now.addingTimeInterval(-60), lifetime: hour, now: now))
        XCTAssertFalse(CacheFreshness.isStaleOnOpen(savedAt: old, lifetime: nil, now: now))
    }
}
