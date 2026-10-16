import XCTest
@testable import OpenLuch

// PDF-отчёты: разбор ответов сервера, период отчёта (что уходит на сервер), хранение PDF на телефоне.
// Примеры ответов — настоящие ответы my.lers.ru (точка 686 «Отопление и ГВС»).
final class ReportsTests: XCTestCase {

    // MARK: - Ответы сервера

    func testOnlyParameterSheetsAreOffered() throws {
        let data = try SampleFiles.data(named: "measurepoint-reports")
        let response = try JSONDecoder().decode(MeasurePointReportsResponse.self, from: data)

        // Точке назначено 11 отчётов: 7 актов и 4 ведомости. Запросом формирования делаются только ведомости.
        XCTAssertEqual(response.reports?.count, 11)
        let reports = response.makeReports()
        XCTAssertEqual(reports.map { $0.id }, [38, 126, 127, 111], "в порядке сервера")
        XCTAssertEqual(reports.first?.title, "Ведомость параметров для точек учета (системный)")
    }

    func testSensorsComeInTheSameResponse() throws {
        // Список отчётов запрашивается вместе с датчиками (getSensor=true) — тот же ответ разбирается и для них.
        let data = try SampleFiles.data(named: "measurepoint-reports")
        let sensors = try JSONDecoder().decode(MeasurePointSensorsResponse.self, from: data).makeSensors()
        XCTAssertEqual(sensors.filter { $0.pipe == .supply }.count, 3)
        XCTAssertEqual(sensors.filter { $0.pipe == .return }.count, 3)
    }

    func testReportWithUnknownTypeIsKept() throws {
        // Тип отчёта сервер не прислал — оставляем (если это не ведомость, сервер сам скажет при формировании).
        // Повтор одного отчёта и запись без номера — пропускаем.
        let json = """
        {"reports": [{"reportId": 5, "reportTitle": " Ведомость "}, {"reportId": 5, "reportTitle": "Повтор"},
                     {"reportId": null, "reportTitle": "Без номера"}, {"reportId": 7, "reportTitle": ""}]}
        """
        let response = try JSONDecoder().decode(MeasurePointReportsResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.makeReports(), [PointReport(id: 5, title: "Ведомость"),
                                                PointReport(id: 7, title: "Отчёт № 7")])
    }

    func testDownloadURL() throws {
        let uri = "/api/v1/Downloads/abc/%D0%A2%D0%B5%D1%81%D1%82%20(1).pdf"
        // Путь приписывается к адресу сервера как есть (русские буквы уже закодированы сервером).
        let url = APIClient.downloadURL(baseURL: try XCTUnwrap(URL(string: "https://my.lers.ru")), uri: uri)
        XCTAssertEqual(url?.absoluteString, "https://my.lers.ru/api/v1/Downloads/abc/%D0%A2%D0%B5%D1%81%D1%82%20(1).pdf")
        // Порт и лишняя «/» в конце адреса.
        let withPort = APIClient.downloadURL(baseURL: try XCTUnwrap(URL(string: "http://10.0.0.5:10000/")), uri: uri)
        XCTAssertEqual(withPort?.absoluteString, "http://10.0.0.5:10000" + uri)
        // Полный адрес — как есть.
        let absolute = APIClient.downloadURL(baseURL: try XCTUnwrap(URL(string: "https://my.lers.ru")),
                                             uri: "https://files.example.com/report.pdf")
        XCTAssertEqual(absolute?.absoluteString, "https://files.example.com/report.pdf")
    }

    // MARK: - Период отчёта

    /// Григорианский календарь с постоянным часовым поясом — чтобы тест не зависел от настроек Mac.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Vladivostok")!
        return calendar
    }

    private func day(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func periodText(_ preset: ReportPeriod.Preset, today: Date) -> String? {
        guard let period = ReportPeriod.make(preset, today: today, calendar: calendar) else {
            return nil
        }
        return ReportPeriod.dayString(period.firstDay, calendar: calendar) + " — "
            + ReportPeriod.dayString(period.lastDay, calendar: calendar)
    }

    func testPresets() {
        // «Сегодня» — 3 октября 2026, 14:00. Сегодняшний день в отчёт не берём: суточной записи за него ещё нет.
        let today = day(2026, 10, 3, hour: 14)
        XCTAssertEqual(periodText(.yesterday, today: today), "02.10.2026 — 02.10.2026")
        XCTAssertEqual(periodText(.lastSevenDays, today: today), "26.09.2026 — 02.10.2026")
        XCTAssertEqual(periodText(.thisMonth, today: today), "01.10.2026 — 02.10.2026")
        XCTAssertEqual(periodText(.lastMonth, today: today), "01.09.2026 — 30.09.2026")
        XCTAssertEqual(periodText(.thisYear, today: today), "01.01.2026 — 02.10.2026")
        XCTAssertNil(periodText(.custom, today: today))
    }

    func testPresetsOnFirstDayOfMonthAndYear() {
        // 1-го числа «этот месяц» — один сегодняшний день (а не «с 1-го по вчера», что было бы наоборот).
        let firstOfOctober = day(2026, 10, 1, hour: 9)
        XCTAssertEqual(periodText(.thisMonth, today: firstOfOctober), "01.10.2026 — 01.10.2026")
        XCTAssertEqual(periodText(.lastMonth, today: firstOfOctober), "01.09.2026 — 30.09.2026")
        // 1 января: прошлый месяц — декабрь прошлого года.
        let newYear = day(2027, 1, 1, hour: 9)
        XCTAssertEqual(periodText(.lastMonth, today: newYear), "01.12.2026 — 31.12.2026")
        XCTAssertEqual(periodText(.thisYear, today: newYear), "01.01.2027 — 01.01.2027")
        // Февраль невисокосного года.
        XCTAssertEqual(periodText(.lastMonth, today: day(2027, 3, 10)), "01.02.2027 — 28.02.2027")
    }

    func testServerDates() {
        // Сервер понимает конец периода как начало последней записи (проверено на my.lers.ru).
        let october2 = ReportPeriod(firstDay: day(2026, 10, 2, hour: 15), lastDay: day(2026, 10, 2, hour: 8))
        let hours = october2.serverDates(for: .hour, calendar: calendar)
        XCTAssertEqual(hours.start, "2026-10-02T00:00:00")
        XCTAssertEqual(hours.end, "2026-10-02T23:00:00", "24 часа: последний — с 23:00")

        let september = ReportPeriod(firstDay: day(2026, 9, 1), lastDay: day(2026, 9, 30, hour: 18))
        let days = september.serverDates(for: .day, calendar: calendar)
        XCTAssertEqual(days.start, "2026-09-01T00:00:00")
        XCTAssertEqual(days.end, "2026-09-30T00:00:00", "30 сентября включительно")

        // Месяцы — 1-е числа: июль, август, сентябрь.
        let summer = ReportPeriod(firstDay: day(2026, 7, 15), lastDay: day(2026, 9, 10))
        let months = summer.serverDates(for: .month, calendar: calendar)
        XCTAssertEqual(months.start, "2026-07-01T00:00:00")
        XCTAssertEqual(months.end, "2026-09-01T00:00:00")
    }

    func testPeriodCheckAndSummary() {
        let september = ReportPeriod(firstDay: day(2026, 9, 1), lastDay: day(2026, 9, 30))
        XCTAssertTrue(september.isValid(calendar: calendar))
        XCTAssertEqual(september.dayCount(calendar: calendar), 30)
        XCTAssertEqual(september.summary(for: .day, calendar: calendar), "01.09.2026 — 30.09.2026 (30 дней)")
        XCTAssertEqual(september.summary(for: .month, calendar: calendar), "сентябрь 2026")

        let summer = ReportPeriod(firstDay: day(2026, 7, 15), lastDay: day(2026, 9, 10))
        XCTAssertEqual(summer.summary(for: .month, calendar: calendar), "июль 2026 — сентябрь 2026")

        let oneDay = ReportPeriod(firstDay: day(2026, 10, 2, hour: 10), lastDay: day(2026, 10, 2))
        XCTAssertTrue(oneDay.isValid(calendar: calendar), "один и тот же день в разное время — правильный период")
        XCTAssertEqual(oneDay.summary(for: .hour, calendar: calendar), "02.10.2026")

        let reversed = ReportPeriod(firstDay: day(2026, 10, 2), lastDay: day(2026, 10, 1))
        XCTAssertFalse(reversed.isValid(calendar: calendar))
    }

    // MARK: - Хранение на телефоне

    private func makeReportStore() -> (store: ReportStore, folder: URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "ReportStoreTests-\(UUID().uuidString)")
        let store = ReportStore(directory: folder.appending(path: "Отчёты"),
                                indexFile: folder.appending(path: "reports-index.json"))
        return (store, folder)
    }

    private let pdf = Data("%PDF-1.4 тестовый файл".utf8)

    func testSaveListAndDeleteReports() async throws {
        let (store, folder) = makeReportStore()
        defer {
            try? FileManager.default.removeItem(at: folder)
        }

        let first = try await store.save(pdf: pdf, suggestedFileName: "Отчёт за сентябрь.pdf", pointId: 686,
                                         server: "https://my.lers.ru", reportTitle: "Ведомость", dataType: .day,
                                         periodText: "01.09.2026 — 30.09.2026 (30 дней)",
                                         createdAt: Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(first.fileName, "Отчёт за сентябрь.pdf")
        XCTAssertEqual(first.sizeBytes, pdf.count)
        XCTAssertEqual(first.dataTypeTitle, "Суточные")
        XCTAssertEqual(try Data(contentsOf: store.fileURL(for: first)), pdf)

        let second = try await store.save(pdf: pdf, suggestedFileName: "Отчёт за август.pdf", pointId: 686,
                                          server: "https://my.lers.ru", reportTitle: "Ведомость", dataType: .month,
                                          periodText: "август 2026", createdAt: Date(timeIntervalSince1970: 1_790_000_100))
        // Другая точка и другой сервер — в карточке точки 686 не показываются.
        _ = try await store.save(pdf: pdf, suggestedFileName: "Чужая точка.pdf", pointId: 811,
                                 server: "https://my.lers.ru", reportTitle: "Ведомость", dataType: .day, periodText: "")
        _ = try await store.save(pdf: pdf, suggestedFileName: "Другой сервер.pdf", pointId: 686,
                                 server: "http://10.0.0.5", reportTitle: "Ведомость", dataType: .day, periodText: "")

        let forPoint = await store.load(pointId: 686, server: "https://my.lers.ru")
        XCTAssertEqual(forPoint.map { $0.fileName }, [second.fileName, first.fileName], "новые сверху")
        let all = await store.loadAll()
        XCTAssertEqual(all.count, 4)

        // Тот же отчёт за тот же период сформирован заново — файл заменяется, а не копится.
        _ = try await store.save(pdf: Data("%PDF-1.4 новее".utf8), suggestedFileName: "Отчёт за сентябрь.pdf",
                                 pointId: 686, server: "https://my.lers.ru", reportTitle: "Ведомость", dataType: .day,
                                 periodText: "01.09.2026 — 30.09.2026 (30 дней)")
        let afterRepeat = await store.loadAll()
        XCTAssertEqual(afterRepeat.count, 4)
        XCTAssertEqual(try Data(contentsOf: store.fileURL(for: first)), Data("%PDF-1.4 новее".utf8))

        // Удаление одного отчёта.
        try await store.delete(second)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL(for: second).path(percentEncoded: false)))
        let afterDelete = await store.load(pointId: 686, server: "https://my.lers.ru")
        XCTAssertEqual(afterDelete.map { $0.fileName }, [first.fileName])

        // Файл удалили через приложение «Файлы» — из списка он тоже пропадает.
        try FileManager.default.removeItem(at: store.fileURL(for: first))
        let afterExternalDelete = await store.load(pointId: 686, server: "https://my.lers.ru")
        XCTAssertTrue(afterExternalDelete.isEmpty)

        // «Удалить все отчёты».
        try await store.deleteAll()
        let afterDeleteAll = await store.loadAll()
        XCTAssertTrue(afterDeleteAll.isEmpty)
    }

    func testSafeFileName() {
        XCTAssertEqual(ReportStore.safeFileName("Отопление: ввод 1/2.pdf"), "Отопление- ввод 1-2.pdf")
        XCTAssertEqual(ReportStore.safeFileName("Без расширения"), "Без расширения.pdf")
        XCTAssertEqual(ReportStore.safeFileName("  "), "Отчёт.pdf")
        XCTAssertEqual(ReportStore.safeFileName(".скрытый.PDF"), "скрытый.pdf")
        // Длинное имя укорачивается (на iPhone имя файла — не больше 255 байт, русская буква — 2 байта).
        let long = ReportStore.safeFileName(String(repeating: "Ж", count: 300))
        XCTAssertLessThanOrEqual(long.utf8.count, 255)
        XCTAssertTrue(long.hasSuffix(".pdf"))

        // Длинное имя от сервера: период и тип данных в конце должны уцелеть,
        // иначе отчёт за сентябрь затёр бы отчёт за август.
        let head = "Теплоснабжение (системная, одностраничная), Товарищество собственников жилья «Семь ветров», "
            + "дом 5 корпус 2 - Отопление и ГВС, ввод 1"
        let august = ReportStore.safeFileName(head + " c 01.08.2026 по 31.08.2026 (Суточные).pdf")
        let september = ReportStore.safeFileName(head + " c 01.09.2026 по 30.09.2026 (Суточные).pdf")
        XCTAssertNotEqual(august, september)
        XCTAssertTrue(september.hasSuffix("c 01.09.2026 по 30.09.2026 (Суточные).pdf"))
        XCTAssertTrue(september.hasPrefix("Теплоснабжение"))
        XCTAssertLessThanOrEqual(september.utf8.count, 255)
    }
}
