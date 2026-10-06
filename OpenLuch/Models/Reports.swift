import Foundation

// PDF-отчёты (ведомости параметров) точки учёта.
//
// Как это работает на сервере ЛЭРС (проверено на my.lers.ru 2026-10-03, подробности — docs/api-notes.md):
//   1. Какие отчёты можно формировать для точки, назначает администратор в ЛЭРС. Список приходит в
//      GET /api/v1/Core/MeasurePoints/{id}?getReports=true (поле reports). Ответ тяжёлый (~450 КБ),
//      поэтому список храним на телефоне (CachedPointReports) и обновляем редко.
//   2. POST /api/v1/Reporting/Generate/ParameterSheet/{reportId}/{dataType}/{start}/{end}?id={точка}
//      формирует отчёт и возвращает ссылку на файл (ReportFileLink).
//   3. GET по этой ссылке — сам PDF (~70–150 КБ на страницу-две).
// Этим запросом формируются только «ведомости параметров» (тип ParametersSheet). Акты и прочие
// отчёты сервер отвергает («Выбранный отчёт не является ведомостью параметров»), поэтому их не показываем.

/// Отчёт, назначенный точке в ЛЭРС, — например, «Посуточная ведомость учета параметров теплопотребления».
nonisolated struct PointReport: Codable, Hashable, Identifiable, Sendable {
    /// Идентификатор отчёта на сервере (reportId в запросе формирования).
    let id: Int
    let title: String
}

/// Сохранённый на телефоне список отчётов точки и время, когда он получен с сервера.
nonisolated struct CachedPointReports: Codable, Sendable {
    let savedAt: Date
    let reports: [PointReport]
    /// Размер ответа сервера — чтобы перед обновлением показать «≈ 450 КБ».
    let responseBytes: Int?
}

// MARK: - Тип данных отчёта

/// По каким записям строится отчёт: по часам, суткам или месяцам.
/// Другие типы (текущие, интеграторы) сервер для этого отчёта не принимает (ответ 400).
nonisolated enum ReportDataType: String, CaseIterable, Codable, Sendable {
    case hour = "Hour"
    case day = "Day"
    case month = "Month"

    /// Значение для адреса запроса: "Hour", "Day", "Month".
    var apiValue: String {
        return rawValue
    }

    var title: String {
        switch self {
        case .hour:
            return "Часовые"
        case .day:
            return "Суточные"
        case .month:
            return "Месячные"
        }
    }
}

// MARK: - Период отчёта

/// Период отчёта: первый и последний день включительно (по календарю телефона).
/// Время внутри дня не важно — сервер получит начало дня (см. `serverDates`).
nonisolated struct ReportPeriod: Equatable, Sendable {
    var firstDay: Date
    var lastDay: Date

    /// Календарь для отчётов: всегда григорианский (даже если на телефоне выбран, например, буддийский —
    /// тогда год был бы другим), часовой пояс — телефона. Сервер ждёт обычные даты.
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        calendar.locale = TextFormatting.russian
        return calendar
    }

    /// Готовые варианты периода в окне отчёта.
    nonisolated enum Preset: String, CaseIterable, Sendable {
        case yesterday
        case lastSevenDays
        case thisMonth
        case lastMonth
        case thisYear
        /// Даты выбраны вручную.
        case custom

        var title: String {
            switch self {
            case .yesterday:
                return "Вчера"
            case .lastSevenDays:
                return "Последние 7 дней"
            case .thisMonth:
                return "Этот месяц"
            case .lastMonth:
                return "Прошлый месяц"
            case .thisYear:
                return "Этот год"
            case .custom:
                return "Свои даты"
            }
        }
    }

    /// Период для готового варианта. Сегодняшний день не берём: он ещё не закончился,
    /// и суточной записи за него на сервере пока нет. nil — для «Свои даты».
    static func make(_ preset: Preset, today: Date, calendar: Calendar) -> ReportPeriod? {
        let startOfToday = calendar.startOfDay(for: today)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday
        let startOfThisMonth = calendar.dateInterval(of: .month, for: startOfToday)?.start ?? startOfToday

        switch preset {
        case .yesterday:
            return ReportPeriod(firstDay: yesterday, lastDay: yesterday)
        case .lastSevenDays:
            let weekAgo = calendar.date(byAdding: .day, value: -7, to: startOfToday) ?? startOfToday
            return ReportPeriod(firstDay: weekAgo, lastDay: yesterday)
        case .thisMonth:
            // 1-го числа «вчера» — ещё прошлый месяц; тогда период — один сегодняшний день.
            return ReportPeriod(firstDay: startOfThisMonth, lastDay: max(startOfThisMonth, yesterday))
        case .lastMonth:
            let startOfLastMonth = calendar.date(byAdding: .month, value: -1, to: startOfThisMonth) ?? startOfThisMonth
            let endOfLastMonth = calendar.date(byAdding: .day, value: -1, to: startOfThisMonth) ?? startOfThisMonth
            return ReportPeriod(firstDay: startOfLastMonth, lastDay: endOfLastMonth)
        case .thisYear:
            let startOfYear = calendar.dateInterval(of: .year, for: startOfToday)?.start ?? startOfToday
            return ReportPeriod(firstDay: startOfYear, lastDay: max(startOfYear, yesterday))
        case .custom:
            return nil
        }
    }

    /// Первый день не позже последнего.
    func isValid(calendar: Calendar) -> Bool {
        return calendar.startOfDay(for: firstDay) <= calendar.startOfDay(for: lastDay)
    }

    /// Сколько дней в периоде (включительно).
    func dayCount(calendar: Calendar) -> Int {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: firstDay),
                                           to: calendar.startOfDay(for: lastDay)).day ?? 0
        return days + 1
    }

    /// Начало и конец периода для адреса запроса, например "2026-09-01T00:00:00".
    ///
    /// Сервер понимает конец периода как НАЧАЛО ПОСЛЕДНЕЙ ЗАПИСИ отчёта (проверено на my.lers.ru):
    ///   • часовые 02.10 00:00 → 02.10 23:00 — 24 часа за 2 октября;
    ///   • суточные 01.09 → 30.09 — 30 суток сентября;
    ///   • месячные 01.07 → 01.09 — июль, август и сентябрь.
    /// Поэтому для часовых конец — 23:00 последнего дня, для месячных — 1-е число месяцев.
    /// Часового пояса в строке нет: сервер считает время по часам точки учёта (как и в своих ответах).
    func serverDates(for dataType: ReportDataType, calendar: Calendar) -> (start: String, end: String) {
        var start = calendar.startOfDay(for: firstDay)
        var end = calendar.startOfDay(for: lastDay)
        switch dataType {
        case .hour:
            end = calendar.date(byAdding: .hour, value: 23, to: end) ?? end
        case .day:
            break
        case .month:
            start = calendar.dateInterval(of: .month, for: start)?.start ?? start
            end = calendar.dateInterval(of: .month, for: end)?.start ?? end
        }
        return (start: ReportPeriod.serverDateString(start, calendar: calendar),
                end: ReportPeriod.serverDateString(end, calendar: calendar))
    }

    /// Дата и время по календарю телефона без часового пояса: "2026-09-01T00:00:00".
    static func serverDateString(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d",
                      parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
                      parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    /// Подпись периода для пользователя: «01.09.2026 — 30.09.2026 (30 дн.)»,
    /// для месячных — «июль 2026 — сентябрь 2026».
    func summary(for dataType: ReportDataType, calendar: Calendar) -> String {
        if dataType == .month {
            let first = ReportPeriod.monthString(firstDay, calendar: calendar)
            let last = ReportPeriod.monthString(lastDay, calendar: calendar)
            return first == last ? first : "\(first) — \(last)"
        }
        let first = ReportPeriod.dayString(firstDay, calendar: calendar)
        let last = ReportPeriod.dayString(lastDay, calendar: calendar)
        let days = dayCount(calendar: calendar)
        let daysText = "\(days) " + TextFormatting.plural(days, one: "день", few: "дня", many: "дней")
        if first == last {
            return first
        }
        return "\(first) — \(last) (\(daysText))"
    }

    /// «сентябрь 2026» по календарю телефона. Названия — своей таблицей: системный формат
    /// добавляет «г.» и зависит от версии iOS, а здесь нужен предсказуемый текст.
    static func monthString(_ date: Date, calendar: Calendar) -> String {
        let names = ["январь", "февраль", "март", "апрель", "май", "июнь",
                     "июль", "август", "сентябрь", "октябрь", "ноябрь", "декабрь"]
        let parts = calendar.dateComponents([.year, .month], from: date)
        let month = parts.month ?? 1
        let name = (month >= 1 && month <= 12) ? names[month - 1] : "?"
        return "\(name) \(parts.year ?? 0)"
    }

    /// «01.09.2026» по календарю телефона.
    static func dayString(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%02d.%02d.%04d", parts.day ?? 0, parts.month ?? 0, parts.year ?? 0)
    }
}

// MARK: - Ответы сервера

/// Из ответа GET Core/MeasurePoints/{id}?getReports=true&getSensor=true берём список отчётов
/// и их типы. (Датчики из того же ответа разбирает MeasurePointSensorsResponse.)
nonisolated struct MeasurePointReportsResponse: Decodable, Sendable {
    /// Отчёты, назначенные точке.
    let reports: [AssignedReport]?
    /// Те же отчёты с подробностями — отсюда берём тип отчёта (ведомость, акт…).
    let reportsWithAvailableReportTemplates: [ReportDescription]?

    nonisolated struct AssignedReport: Decodable, Sendable {
        let reportId: Int?
        let reportTitle: String?
    }

    nonisolated struct ReportDescription: Decodable, Sendable {
        let id: Int
        /// "ParametersSheet" — ведомость параметров; "RaisingOn", "Check"… — акты.
        let reportType: String?
    }

    /// Отчёты точки, которые можно сформировать в приложении (только ведомости параметров),
    /// в порядке сервера, без повторов.
    func makeReports() -> [PointReport] {
        var typeById: [Int: String] = [:]
        for description in reportsWithAvailableReportTemplates ?? [] {
            if let reportType = description.reportType {
                typeById[description.id] = reportType
            }
        }

        var result: [PointReport] = []
        for assigned in reports ?? [] {
            guard let id = assigned.reportId else {
                continue
            }
            // Тип неизвестен (сервер его не прислал) — оставляем: если это не ведомость,
            // сервер при формировании сам скажет об этом понятным текстом.
            if let reportType = typeById[id], reportType != "ParametersSheet" {
                continue
            }
            if result.contains(where: { $0.id == id }) {
                continue
            }
            let title = assigned.reportTitle?.trimmingCharacters(in: .whitespaces) ?? ""
            result.append(PointReport(id: id, title: title.isEmpty ? "Отчёт № \(id)" : title))
        }
        return result
    }
}

/// Ответ на запрос формирования отчёта (DownloadFileResult): ссылка на файл и его имя.
nonisolated struct ReportFileLink: Decodable, Sendable {
    /// Например "/api/v1/Downloads/{ключ}/{имя файла}" — путь на том же сервере.
    let uri: String
    /// «Теплоснабжение (системная, одностраничная), ТСЖ Семь ветров - Отопление и ГВС c 26.09.2026 по 03.10.2026 (Суточные).pdf»
    let fileName: String?
}
