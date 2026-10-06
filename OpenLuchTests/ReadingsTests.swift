import XCTest
@testable import OpenLuch

// Последние данные точки: разбор настоящих ответов my.lers.ru, названия и единицы параметров.
final class ReadingsTests: XCTestCase {

    private func decodeRecord(_ name: String) throws -> LastDataRecord {
        return try JSONDecoder().decode(LastDataRecord.self, from: try SampleFiles.data(named: name))
    }

    func testHeatConsumptionIsDecoded() throws {
        let record = try decodeRecord("consumption-last-heat")
        XCTAssertEqual(record.dataType, "Current")
        XCTAssertEqual(record.dataTypeTitle, "текущие")
        XCTAssertEqual(record.dateTime, "2026-10-03T00:31:23")
        let values = try XCTUnwrap(record.values)
        let outdoor = try XCTUnwrap(values.first { $0.dataParameter == "T_outdoor" })
        XCTAssertEqual(outdoor.isBad, true, "−60 °C на улице прибор пометил недостоверным")
    }

    func testEveryParameterInSamplesHasRussianTitle() throws {
        // Все параметры из настоящих ответов должны быть в справочнике, иначе пользователь увидит код.
        for name in ["consumption-last-heat", "totals-last-heat", "consumption-last-electricity", "totals-last-electricity"] {
            for value in try decodeRecord(name).values ?? [] {
                XCTAssertNotNil(DataParameterCatalog.info(for: value.dataParameter),
                                "Нет названия для \(value.dataParameter) (\(name))")
            }
        }
    }

    // MARK: - Выбранные для показа параметры

    func testOnlySelectedHeatParametersAreShownInSelectionOrder() throws {
        // Выбор точки 686 «Отопление и ГВС» с my.lers.ru (как в measurepoints.json).
        let selected = [1, 2, 47, 3, 4, 5, 6, 50, 9, 10, 11, 15]
        let values = try XCTUnwrap(try decodeRecord("consumption-last-heat").values)
        XCTAssertEqual(values.first?.dataParameterId, 1, "номер параметра приходит в ответе")

        let split = ParameterSelection.split(values, selectedIds: selected)
        // Разность температур — сразу после подачи и обратки, как выбрано в ЛЭРС (сервер присылает её в конце).
        XCTAssertEqual(split.shown.map { $0.dataParameter },
                       ["T_in", "T_out", "T_delta", "T_cw", "T_outdoor", "M_in", "M_out", "M_delta",
                        "Q_in", "Q_out", "Q_delta"])
        // Объёмы и давления не выбраны — скрыты, в порядке сервера.
        XCTAssertEqual(split.hidden.map { $0.dataParameter },
                       ["V_in", "V_out", "P_in", "P_out", "P_cw", "P_delta", "V_delta"])
    }

    func testOnlySelectedElectricityParametersAreShown() throws {
        // Выбор точки 3736 «Коттеджи, ввод 3»: Ap1, Ap2, Ap, Q, S, U, UA…UC, I, IA…IC, частота.
        let selected = [20, 24, 36, 67, 57, 73, 74, 75, 76, 77, 78, 79, 80, 87]
        let consumption = ParameterSelection.split(try decodeRecord("consumption-last-electricity").values ?? [],
                                                   selectedIds: selected)
        XCTAssertEqual(consumption.shown.count, 11)
        XCTAssertEqual(consumption.hidden.count, 21, "углы фаз, cos φ, мощности по фазам — скрыты")
        XCTAssertFalse(consumption.shown.contains { $0.dataParameter == "PhiUAB" })

        let totals = ParameterSelection.split(try decodeRecord("totals-last-electricity").values ?? [],
                                              selectedIds: selected)
        XCTAssertEqual(totals.shown.map { $0.dataParameter }, ["Ap1", "Ap2", "Ap"])
    }

    func testAllParametersAreShownWhenNothingIsSelected() throws {
        let values = try XCTUnwrap(try decodeRecord("totals-last-heat").values)
        for selected in [nil, [Int]()] {
            let split = ParameterSelection.split(values, selectedIds: selected)
            XCTAssertEqual(split.shown, values)
            XCTAssertTrue(split.hidden.isEmpty)
        }
    }

    func testValuesWithoutNumberFromOldCacheAreShown() throws {
        // В кэше прошлой версии у значений нет номера параметра — их не прячем.
        let old = DataValue(dataParameter: "T_in", dataParameterId: nil, value: 70, isBad: nil, isCalc: nil)
        let split = ParameterSelection.split([old], selectedIds: [2])
        XCTAssertEqual(split.shown, [old])
        XCTAssertTrue(split.hidden.isEmpty)
    }

    func testUnits() throws {
        let response = try JSONDecoder().decode(ConsumptionUnitsResponse.self,
                                                from: try SampleFiles.data(named: "system-units"))
        var unitsByCategory: [String: String] = [:]
        for pair in response.dataParametersUnit ?? [] {
            unitsByCategory[pair.dataParameterCategory] = pair.unit
        }
        let units = ServerUnits(unitsByCategory: unitsByCategory)

        XCTAssertEqual(DataParameterCatalog.unit(for: "T_in", serverUnits: units), "°C")
        XCTAssertEqual(DataParameterCatalog.unit(for: "P_in", serverUnits: units), "кгс/см²")
        XCTAssertEqual(DataParameterCatalog.unit(for: "M_in", serverUnits: units), "т")
        XCTAssertEqual(DataParameterCatalog.unit(for: "V_in", serverUnits: units), "м³")
        XCTAssertEqual(DataParameterCatalog.unit(for: "Q_delta", serverUnits: units), "Гкал")
        XCTAssertEqual(DataParameterCatalog.unit(for: "NormalOperationDuration", serverUnits: units), "ч")
        // Электрических единиц у сервера нет — стандартные.
        XCTAssertEqual(DataParameterCatalog.unit(for: "Ap1", serverUnits: units), "кВт·ч")
        XCTAssertEqual(DataParameterCatalog.unit(for: "UA", serverUnits: units), "В")
        // Единицы ещё не загружены — у теплового параметра единицы нет, у электрического есть.
        XCTAssertEqual(DataParameterCatalog.unit(for: "T_in", serverUnits: nil), "")
        XCTAssertEqual(DataParameterCatalog.unit(for: "Frequency", serverUnits: nil), "Гц")
        // Незнакомый параметр — код как есть, без единицы.
        XCTAssertEqual(DataParameterCatalog.title(for: "Something_New"), "Something_New")
        XCTAssertEqual(DataParameterCatalog.unit(for: "Something_New", serverUnits: units), "")
    }

    func testTariffTitles() {
        XCTAssertEqual(DataParameterCatalog.title(for: "Ap2"), "Активная энергия, приём, тариф 2")
        XCTAssertEqual(DataParameterCatalog.title(for: "Rn4"), "Реактивная энергия, отдача, тариф 4")
    }

    func testSymbols() {
        XCTAssertEqual(DataParameterCatalog.symbol(for: "T_in"), "T1")
        XCTAssertEqual(DataParameterCatalog.symbol(for: "M_out"), "M2")
        XCTAssertEqual(DataParameterCatalog.symbol(for: "Q_delta"), "Q")
        XCTAssertEqual(DataParameterCatalog.symbol(for: "Ap2"), "A+ Т2")
        // Незнакомый параметр — код как есть.
        XCTAssertEqual(DataParameterCatalog.symbol(for: "Something_New"), "Something_New")
    }

    func testFormatting() throws {
        // Тысячи iOS отделяет неразрывным пробелом (\u{00A0}), чтобы число не разрывалось при переносе.
        XCTAssertEqual(TextFormatting.reading(708429.714).replacingOccurrences(of: "\u{00A0}", with: " "), "708 429,7")
        // От 10 и больше — один знак после запятой.
        XCTAssertEqual(TextFormatting.reading(24.979827880859375), "25,0")
        XCTAssertEqual(TextFormatting.reading(32.507), "32,5")
        XCTAssertEqual(TextFormatting.reading(10), "10,0")
        XCTAssertEqual(TextFormatting.reading(-60), "-60,0")
        // Меньше 10 — два знака.
        XCTAssertEqual(TextFormatting.reading(5), "5,00")
        XCTAssertEqual(TextFormatting.reading(3.6187), "3,62")
        XCTAssertEqual(TextFormatting.reading(0.0412), "0,04")
        XCTAssertEqual(TextFormatting.reading(0), "0,00")
        XCTAssertEqual(TextFormatting.reading(-0.4), "-0,40")
        // 9,996 после округления — уже 10: один знак, а не «10,00».
        XCTAssertEqual(TextFormatting.reading(9.996), "10,0")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 12)))
        // Время прибора показываем как есть, без пересчёта часовых поясов.
        XCTAssertEqual(TextFormatting.deviceDateTime("2026-10-03T00:31:23", now: now), "3 окт. в 00:31")
        XCTAssertEqual(TextFormatting.deviceDateTime("2026-10-03T00:31:23.5448755", now: now), "3 окт. в 00:31")
        XCTAssertTrue(TextFormatting.deviceDateTime("2017-04-25T00:00:00", now: now)?.contains("2017") == true)
        XCTAssertNil(TextFormatting.deviceDateTime("вчера", now: now))
    }

    func testReadingsCache() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "ReadingsTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = CacheStore(directory: directory)

        let readings = CachedReadings(savedAt: Date(timeIntervalSince1970: 1_790_000_000),
                                      consumption: try decodeRecord("consumption-last-heat"),
                                      totals: try decodeRecord("totals-last-heat"),
                                      units: ServerUnits(unitsByCategory: ["Temperature": "CelsiusDegree"]))
        try await cache.saveReadings(readings, pointId: 686)

        let loaded = await cache.loadReadings(pointId: 686)
        XCTAssertEqual(loaded?.consumption, readings.consumption)
        XCTAssertEqual(loaded?.totals, readings.totals)
        let otherPoint = await cache.loadReadings(pointId: 1)
        XCTAssertNil(otherPoint)
        // Единицы хранятся вместе с данными своей точки.
        XCTAssertEqual(loaded?.units?.unitsByCategory["Temperature"], "CelsiusDegree")

        // Файлы данных точек входят в размер кэша и удаляются вместе с ним.
        let size = await cache.totalSizeInBytes()
        XCTAssertGreaterThan(size, 1_000)
        try await cache.clear()
        let afterClear = await cache.loadReadings(pointId: 686)
        XCTAssertNil(afterClear)
    }

    // MARK: - Раскладка на экране: таблицы и одиночные значения

    func testHeatValuesGoToSupplyReturnDeltaTable() throws {
        let values = try XCTUnwrap(try decodeRecord("consumption-last-heat").values)
        let layout = ReadingsLayout(values: values)
        XCTAssertEqual(layout.tables.count, 1)
        let table = try XCTUnwrap(layout.tables.first)
        XCTAssertEqual(table.columnTitles, ["Подача", "Обратка", "Δ"])
        XCTAssertEqual(table.rows.map(\.symbol), ["T", "M", "V", "Q", "P"], "порядок — как пришли значения")
        let temperature = try XCTUnwrap(table.rows.first)
        XCTAssertEqual(temperature.cells.map { $0?.dataParameter }, ["T_in", "T_out", "T_delta"])
        // Остальное — по одному, в исходном порядке.
        XCTAssertEqual(layout.singles.map(\.dataParameter), ["T_cw", "T_outdoor", "P_cw"])
        // Ничего не потерялось и не задвоилось.
        let placed = table.rows.flatMap { $0.cells.compactMap { $0 } }.count + layout.singles.count
        XCTAssertEqual(placed, values.count)
    }

    func testDeltaWithoutSupplyAndReturnStaysSingle() throws {
        // Раскладка интеграторов (в карточке они без таблиц, но правило общее): M1, M2, V1, V2 — в таблицу;
        // Q (только разность) и ВНР — по одному.
        let layout = ReadingsLayout(values: try XCTUnwrap(try decodeRecord("totals-last-heat").values))
        let table = try XCTUnwrap(layout.tables.first)
        XCTAssertEqual(table.columnTitles, ["Подача", "Обратка"], "разностей нет — нет и столбца")
        XCTAssertEqual(table.rows.map(\.symbol), ["M", "V"])
        XCTAssertEqual(layout.singles.map(\.dataParameter), ["Q_delta", "NormalOperationDuration"])
    }

    func testElectricValuesGoToPhaseTable() throws {
        let values = try XCTUnwrap(try decodeRecord("consumption-last-electricity").values)
        let layout = ReadingsLayout(values: values)
        XCTAssertEqual(layout.tables.count, 1)
        let table = try XCTUnwrap(layout.tables.first)
        XCTAssertEqual(table.columnTitles, ["A", "B", "C"])
        XCTAssertEqual(table.rows.map(\.symbol), ["S", "P", "Q", "U", "I", "φ U–I", "cos φ"])
        // Суммы по фазам, частота и углы между фазами — по одному.
        XCTAssertEqual(layout.singles.map(\.dataParameter),
                       ["S", "ElectricCurrent_P", "Pp", "Q", "Qp", "U", "I", "PhiUAB", "PhiUAC", "PhiUBC", "Frequency"])
    }

    func testEnergyTotalsHaveNoTable() throws {
        let layout = ReadingsLayout(values: try XCTUnwrap(try decodeRecord("totals-last-electricity").values))
        XCTAssertTrue(layout.tables.isEmpty)
        XCTAssertEqual(layout.singles.count, 10)
    }
}
