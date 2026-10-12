import XCTest
@testable import OpenLuch

// Архив потребления для экрана «Графики и архив»: разбор ответа сервера, порции, пункты меню.
final class ConsumptionArchiveTests: XCTestCase {

    private var calendar: Calendar {
        return ArchiveDates.calendar
    }

    private func date(_ text: String) throws -> Date {
        return try XCTUnwrap(ArchiveDates.parse(text))
    }

    // MARK: - Разбор ответа

    func testDaysAreDecoded() throws {
        // Настоящий ответ my.lers.ru (точка 686 «Отопление и ГВС», 2 суток; у вторых суток
        // для проверки добавлена пометка «IncompleteData»).
        let response = try JSONDecoder().decode(ArchiveResponse.self,
                                                from: try SampleFiles.data(named: "consumption-archive-days"))
        let records = response.records(for: .days)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].date, try date("2026-10-01T00:00:00"))
        XCTAssertFalse(records[0].isIncomplete)
        XCTAssertTrue(records[1].isIncomplete, "IncompleteData — неполная запись")
        XCTAssertEqual(records[0].values.count, 20, "у тепловой точки — 20 параметров")
        XCTAssertNotNil(records[0].value(of: "Q_delta"))
        // Других периодов в ответе нет — пустые массивы, а не ошибка.
        XCTAssertTrue(response.records(for: .hours).isEmpty)
        XCTAssertEqual(response.units.unitsByCategory["Heat"], "GigaCalorie")
    }

    func testEmptyResponseIsNotAnError() throws {
        // Так сервер отвечает, если у точки нет такого архива (у электрической 2781 нет часовых).
        let json = """
        {"pressureType":"Absolute","monthConsumption":[],"dayConsumption":[],"hourConsumption":[],
         "dataParametersUnit":[{"dataParameterCategory":"Time","unit":"Hour"}],"summary":null}
        """
        let response = try JSONDecoder().decode(ArchiveResponse.self, from: Data(json.utf8))
        XCTAssertTrue(response.records(for: .hours).isEmpty)
    }

    func testDatesKeepDeviceClockDigits() throws {
        // Время сервера — по часам точки, без пояса: туда и обратно цифры не меняются.
        let parsed = try date("2026-10-09T14:00:00")
        XCTAssertEqual(ArchiveDates.serverString(parsed), "2026-10-09T14:00:00")
        XCTAssertEqual(calendar.component(.hour, from: parsed), 14)
    }

    // MARK: - Порции

    func testDayPortionsCoverTwoWeeksBackToBack() throws {
        let grid = ArchiveGrid(period: .days, now: try date("2026-10-11T02:30:00"), calendar: calendar)
        // Порция 0 — последние 14 суток, включая сегодня (сервер вернёт то, что уже есть).
        XCTAssertEqual(grid.end, try date("2026-10-12T00:00:00"))
        XCTAssertEqual(grid.first(ofPortion: 0), try date("2026-09-28T00:00:00"))
        XCTAssertEqual(grid.last(ofPortion: 0), try date("2026-10-11T00:00:00"))
        // Порция 1 — сразу перед ней, без пропусков и наложений.
        XCTAssertEqual(grid.last(ofPortion: 1), try date("2026-09-27T00:00:00"))
        XCTAssertEqual(grid.first(ofPortion: 1), try date("2026-09-14T00:00:00"))
    }

    func testPortionOfDate() throws {
        let grid = ArchiveGrid(period: .days, now: try date("2026-10-11T02:30:00"), calendar: calendar)
        XCTAssertEqual(grid.portion(containing: try date("2026-10-11T23:00:00")), 0)
        XCTAssertEqual(grid.portion(containing: try date("2026-09-28T00:00:00")), 0)
        XCTAssertEqual(grid.portion(containing: try date("2026-09-27T12:00:00")), 1)
        XCTAssertNil(grid.portion(containing: try date("2026-10-12T00:00:00")), "будущее — вне графика")
        XCTAssertNil(grid.portion(containing: grid.start.addingTimeInterval(-1)), "раньше начала — вне графика")
    }

    func testVisibleScreenNeedsAtMostTwoPortions() throws {
        let grid = ArchiveGrid(period: .days, now: try date("2026-10-11T02:30:00"), calendar: calendar)
        // Экран ровно на порции 0 — грузим только её.
        XCTAssertEqual(grid.portions(from: grid.first(ofPortion: 0), to: grid.end), [0])
        // Экран на стыке — обе, сначала свежую.
        XCTAssertEqual(grid.portions(from: try date("2026-09-20T00:00:00"), to: try date("2026-10-04T00:00:00")),
                       [0, 1])
        // Пролистали далеко назад — промежуточные порции не нужны.
        XCTAssertEqual(grid.portions(from: grid.first(ofPortion: 10), to: grid.first(ofPortion: 9)), [10])
    }

    func testMonthAndHourPortions() throws {
        let now = try date("2026-10-11T02:30:00")
        let months = ArchiveGrid(period: .months, now: now, calendar: calendar)
        XCTAssertEqual(months.first(ofPortion: 0), try date("2025-11-01T00:00:00"))
        XCTAssertEqual(months.last(ofPortion: 0), try date("2026-10-01T00:00:00"), "текущий месяц — в порции")
        let hours = ArchiveGrid(period: .hours, now: now, calendar: calendar)
        XCTAssertEqual(hours.first(ofPortion: 0), try date("2026-10-10T03:00:00"))
        XCTAssertEqual(hours.last(ofPortion: 0), try date("2026-10-11T02:00:00"))
    }

    // MARK: - Склейка порций

    func testMergeReplacesSameDateAndSorts() throws {
        let old = [ArchiveRecord(date: try date("2026-10-02T00:00:00"), isIncomplete: true, values: []),
                   ArchiveRecord(date: try date("2026-10-03T00:00:00"), isIncomplete: false, values: [])]
        let new = [ArchiveRecord(date: try date("2026-10-01T00:00:00"), isIncomplete: false, values: []),
                   ArchiveRecord(date: try date("2026-10-02T00:00:00"), isIncomplete: false, values: [])]
        let merged = PointArchiveModel.merge(old, with: new)
        XCTAssertEqual(merged.map(\.date), [try date("2026-10-01T00:00:00"), try date("2026-10-02T00:00:00"),
                                            try date("2026-10-03T00:00:00")])
        XCTAssertFalse(merged[1].isIncomplete, "запись за ту же дату заменяется новой")
    }

    // MARK: - Меню «Параметр»

    private func record(_ values: [String: Double]) -> ArchiveRecord {
        let dataValues = values.map { DataValue(dataParameter: $0.key, dataParameterId: nil, value: $0.value,
                                                isBad: false, isCalc: false) }
        return ArchiveRecord(date: Date(), isIncomplete: false, values: dataValues)
    }

    func testHeatPointMetrics() throws {
        let response = try JSONDecoder().decode(ArchiveResponse.self,
                                                from: try SampleFiles.data(named: "consumption-archive-days"))
        let metrics = ArchiveMetrics.available(in: response.records(for: .days))
        XCTAssertEqual(metrics.map(\.title), ["Тепло", "Масса", "Объём", "Температуры", "Давление"])
        let heat = try XCTUnwrap(metrics.first)
        XCTAssertEqual(heat.mainCodes, ["Q_in", "Q_out"])
        XCTAssertEqual(heat.separateCodes, ["Q_delta"])
        let temperatures = try XCTUnwrap(metrics.first { $0.id == "temperatures" })
        // Порядок — T1, T2, ΔT, Tнв; Tхв у тепловой точки не показываем; ΔT — отдельным графиком.
        XCTAssertEqual(temperatures.codes, ["T_in", "T_out", "T_delta", "T_outdoor"])
        XCTAssertEqual(temperatures.mainCodes, ["T_in", "T_out", "T_outdoor"])
        XCTAssertEqual(temperatures.separateCodes, ["T_delta"])
        XCTAssertFalse(temperatures.isAccumulated, "для температур — средние, а не суммы")
    }

    func testColdWaterUsesColdWaterTemperature() {
        // Точка ХВС 3529 с my.lers.ru: подачи нет — температура и давление холодной воды.
        let metrics = ArchiveMetrics.available(in: [record(["T_cw": 5, "P_in": 6, "P_cw": 7, "V_in": 1, "V_delta": 0])])
        let temperatures = metrics.first { $0.id == "temperatures" }
        XCTAssertEqual(temperatures?.codes, ["T_cw"])
        let pressure = metrics.first { $0.id == "pressure" }
        XCTAssertEqual(pressure?.codes, ["P_in"], "есть P1 — Pхв не показываем")
    }

    func testOnlyDeltaGoesToMainChart() {
        let metrics = ArchiveMetrics.available(in: [record(["V_delta": 0.5])])
        XCTAssertEqual(metrics.first?.mainCodes, ["V_delta"])
        XCTAssertEqual(metrics.first?.separateCodes, [])
    }

    func testAlwaysZeroTariffsAreHidden() {
        // Электрическая точка 3736: тарифы 3 и 4 всегда нули.
        let metrics = ArchiveMetrics.available(in: [record(["Ap": 6.9, "Ap1": 2, "Ap2": 4.9, "Ap3": 0, "Ap4": 0])])
        XCTAssertEqual(metrics.first?.title, "Активная энергия")
        XCTAssertEqual(metrics.first?.codes, ["Ap", "Ap1", "Ap2"])
    }

    func testDeltaSymbols() {
        XCTAssertEqual(ArchiveMetrics.symbol(for: "Q_delta"), "ΔQ", "разность тепла — «ΔQ», как все разности")
        XCTAssertEqual(ArchiveMetrics.symbol(for: "M_delta"), "ΔM")
        XCTAssertEqual(ArchiveMetrics.legendTitle(for: "T_in"), "T1 подача")
        XCTAssertEqual(ArchiveMetrics.legendTitle(for: "Q_out"), "Q2 обратка")
        XCTAssertEqual(ArchiveMetrics.legendTitle(for: "T_outdoor"), "Tнв улица")
    }
}
