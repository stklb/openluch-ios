import Foundation

// Архив потребления точки учёта для экрана «Графики и архив»: часовые, суточные и месячные записи.
// Приходят из GET /api/v1/Data/MeasurePoints/{id}/Consumption/{start}/{end}?dataTypes=Hour|Day|Month
// (размеры ответов и поведение сервера — docs/api-notes.md, раздел «Потребление за период»).
//
// Архив НЕ сохраняется на телефоне (решение владельца 2026-10-11): прибор могут переопросить, и сервер
// заменит данные. Поэтому он живёт в памяти, только пока открыта карточка точки (см. PointArchiveModel).

/// Период архива: часы, сутки или месяцы.
nonisolated enum ArchivePeriod: String, CaseIterable, Identifiable, Hashable, Sendable {
    case hours
    case days
    case months

    var id: Self { self }

    var title: String {
        switch self {
        case .hours: return "Часы"
        case .days: return "Сутки"
        case .months: return "Месяцы"
        }
    }

    /// Тип данных в запросе к серверу (DeviceDataType).
    var serverDataType: String {
        switch self {
        case .hours: return "Hour"
        case .days: return "Day"
        case .months: return "Month"
        }
    }

    /// Шаг записей: одна запись — один час, одни сутки или один месяц.
    var calendarUnit: Calendar.Component {
        switch self {
        case .hours: return .hour
        case .days: return .day
        case .months: return .month
        }
    }

    /// Сколько записей запрашивать за раз — ровно один экран графика: сутки, две недели, год.
    /// Порция тепловой точки (20 параметров) — около 75, 42 и 38 КБ: на EDGE 3–5 секунд.
    var portionLength: Int {
        switch self {
        case .hours: return 24
        case .days: return 14
        case .months: return 12
        }
    }

    /// Насколько далеко назад можно листать график (в порциях): часы — 90 суток, сутки — около 3 лет,
    /// месяцы — 15 лет. С какой даты у точки есть данные, сервер не сообщает, поэтому границы
    /// графика задаём сразу и с запасом: если бы они росли с каждой порцией, Swift Charts сдвигал бы
    /// график (он держит расстояние от левого края, а не дату; проверено 2026-10-11).
    var maxPortions: Int {
        switch self {
        case .hours: return 90
        case .days: return 78
        case .months: return 15
        }
    }

    /// Сколько времени видно на экране графика сразу (остальное листается пальцем).
    var visibleSeconds: TimeInterval {
        switch self {
        case .hours: return 24 * 3600
        case .days: return 14 * 24 * 3600
        case .months: return 365 * 24 * 3600
        }
    }

    /// Начало часа, суток или месяца, в котором находится дата.
    func start(of date: Date, calendar: Calendar) -> Date {
        return calendar.dateInterval(of: calendarUnit, for: date)?.start ?? date
    }

    /// Дата, сдвинутая на `count` часов, суток или месяцев.
    func adding(_ count: Int, to date: Date, calendar: Calendar) -> Date {
        return calendar.date(byAdding: calendarUnit, value: count, to: date) ?? date
    }

}

/// Сетка порций архива одного периода. Порция 0 — самая свежая (заканчивается текущим часом, сутками
/// или месяцем), порция 1 — перед ней, и так далее. Сетка неподвижна, пока открыта карточка точки:
/// так по дате на графике всегда понятно, какую порцию загружать.
nonisolated struct ArchiveGrid: Sendable {
    let period: ArchivePeriod
    /// Конец архива: начало часа (суток, месяца), следующего за текущим.
    let end: Date
    let calendar: Calendar

    init(period: ArchivePeriod, now: Date, calendar: Calendar) {
        self.period = period
        self.calendar = calendar
        self.end = period.adding(1, to: period.start(of: now, calendar: calendar), calendar: calendar)
    }

    /// Начало графика — начало самой ранней порции, до которой можно долистать.
    var start: Date {
        return first(ofPortion: period.maxPortions - 1)
    }

    /// Первая запись порции (начало её часа, суток или месяца).
    func first(ofPortion index: Int) -> Date {
        return period.adding(-(index + 1) * period.portionLength, to: end, calendar: calendar)
    }

    /// Последняя запись порции. Сервер включает в ответ оба конца периода (проверено, docs/api-notes.md).
    func last(ofPortion index: Int) -> Date {
        return period.adding(-index * period.portionLength - 1, to: end, calendar: calendar)
    }

    /// Номер порции, в которую попадает дата; nil — дата вне графика.
    func portion(containing date: Date) -> Int? {
        let unitStart = period.start(of: date, calendar: calendar)
        guard unitStart < end else {
            return nil
        }
        // Сколько часов (суток, месяцев) от этой даты до конца архива: 1 — последняя запись порции 0.
        let distance = calendar.dateComponents([period.calendarUnit], from: unitStart, to: end)
            .value(for: period.calendarUnit) ?? 0
        guard distance >= 1 else {
            return nil
        }
        let index = (distance - 1) / period.portionLength
        return index < period.maxPortions ? index : nil
    }

    /// Порции, которые попадают в промежуток [from, to) — сначала самые свежие.
    func portions(from: Date, to: Date) -> [Int] {
        guard from < to else {
            return []
        }
        // Последний момент промежутка — за секунду до его конца.
        let newest = portion(containing: min(to.addingTimeInterval(-1), end.addingTimeInterval(-1))) ?? 0
        let oldest = portion(containing: max(from, start)) ?? (period.maxPortions - 1)
        guard newest <= oldest else {
            return []
        }
        return Array(newest...oldest)
    }
}

/// Одна запись архива: значения параметров за час, сутки или месяц.
nonisolated struct ArchiveRecord: Hashable, Sendable {
    /// Начало часа, суток или месяца (по часам точки учёта — см. ArchiveDates).
    let date: Date
    /// true — запись неполная: период ещё идёт (например, текущий месяц), значения будут расти.
    let isIncomplete: Bool
    let values: [DataValue]

    /// Значение параметра по коду («T_in», «Q_delta»…) или nil, если прибор его не прислал.
    func value(of code: String) -> DataValue? {
        return values.first { $0.dataParameter == code }
    }
}

/// Одна загруженная порция архива.
nonisolated struct ArchivePortion: Sendable {
    let records: [ArchiveRecord]
    /// Единицы измерения точки (приходят в том же ответе).
    let units: ServerUnits
}

/// Даты архива. Сервер присылает время БЕЗ часового пояса — это время по часам точки учёта
/// («2026-10-09T14:00:00»). Разбираем и показываем его в поясе телефона: цифры при этом не меняются
/// («14:00» остаётся «14:00»), а Swift Charts делит время на часы и сутки как раз в поясе телефона —
/// так точки графика стоят ровно на своих часах и сутках.
nonisolated enum ArchiveDates {

    static var calendar: Calendar {
        return Calendar.current
    }

    /// «2026-10-09T14:00:00» → дата. Доли секунды и пояс (если вдруг есть) отбрасываем.
    static func parse(_ text: String) -> Date? {
        return makeFormatter().date(from: String(text.prefix(19)))
    }

    /// Дата → «2026-10-09T14:00:00» для адреса запроса.
    static func serverString(_ date: Date) -> String {
        return makeFormatter().string(from: date)
    }

    private static func makeFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }
}

/// Ответ сервера с архивом. Ненужные массивы сервер присылает пустыми ([]), а не null.
nonisolated struct ArchiveResponse: Decodable, Sendable {
    let hourConsumption: [Record]?
    let dayConsumption: [Record]?
    let monthConsumption: [Record]?
    let dataParametersUnit: [ConsumptionUnitsResponse.UnitPair]?

    struct Record: Decodable, Sendable {
        let dateTime: String?
        let isEmpty: Bool?
        /// «IncompleteData» — запись неполная; остальные атрибуты («Calculated»…) нам не нужны.
        let attributes: [String]?
        let values: [Value]?
    }

    /// Значение параметра. value бывает пустым — такое значение просто пропускаем.
    struct Value: Decodable, Sendable {
        let dataParameter: String
        let dataParameterId: Int?
        let value: Double?
        let isBad: Bool?
        let isCalc: Bool?
    }

    /// Записи нужного периода, по возрастанию даты. Пустые записи и записи без даты пропускаем.
    func records(for period: ArchivePeriod) -> [ArchiveRecord] {
        let raw: [Record]
        switch period {
        case .hours: raw = hourConsumption ?? []
        case .days: raw = dayConsumption ?? []
        case .months: raw = monthConsumption ?? []
        }
        var result: [ArchiveRecord] = []
        for record in raw where record.isEmpty != true {
            guard let text = record.dateTime, let date = ArchiveDates.parse(text) else {
                continue
            }
            let values = (record.values ?? []).compactMap { value -> DataValue? in
                guard let number = value.value else {
                    return nil
                }
                return DataValue(dataParameter: value.dataParameter, dataParameterId: value.dataParameterId,
                                 value: number, isBad: value.isBad, isCalc: value.isCalc)
            }
            result.append(ArchiveRecord(date: date,
                                        isIncomplete: record.attributes?.contains("IncompleteData") ?? false,
                                        values: values))
        }
        return result.sorted { $0.date < $1.date }
    }

    /// Единицы измерения: категория → единица.
    var units: ServerUnits {
        var unitsByCategory: [String: String] = [:]
        for pair in dataParametersUnit ?? [] {
            unitsByCategory[pair.dataParameterCategory] = pair.unit
        }
        return ServerUnits(unitsByCategory: unitsByCategory)
    }
}

/// Что можно выбрать в меню «Параметр» на экране графиков: тепло, масса, температуры…
/// В каждом — параметры подачи и обратки на основном графике, а разность (Δ) — на отдельном
/// маленьком графике со своей шкалой (решения владельца 2026-10-11).
nonisolated struct ArchiveMetric: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    /// Все параметры по порядку — так они идут в шапке над графиком и в столбцах таблицы.
    let codes: [String]
    /// Параметры основного графика.
    let mainCodes: [String]
    /// Параметры, которые рисуются отдельно, каждый на своём маленьком графике (ΔQ, ΔM, ΔT…).
    let separateCodes: [String]
    /// true — величина накапливается за период (тепло, масса, объём, энергия): в шапке — сумма.
    /// false — мгновенная (температура, давление): в шапке — среднее.
    let isAccumulated: Bool
}

nonisolated enum ArchiveMetrics {

    /// Описание пункта меню: какие параметры в него входят и в каком порядке.
    private struct Definition {
        let id: String
        let title: String
        let codes: [String]
        let separate: Set<String>
        let isAccumulated: Bool
        /// Параметр, который показываем, только если НЕТ другого (код → какого): у точки ХВС нет
        /// подачи (T1, P1), и её температура и давление — это Tхв и Pхв. У тепловой точки Tхв —
        /// справочная величина, на графике температур она не нужна.
        let onlyWithout: [String: String]
    }

    /// Тарифы электроэнергии, которые у точки всегда нули (в ЛЭРС настроены «на всякий случай»),
    /// на графике и в таблице не нужны — только мешают.
    private static let hiddenWhenZero: Set<String> = ["Ap3", "Ap4", "An1", "An2", "An3", "An4",
                                                       "Rp3", "Rp4", "Rn1", "Rn2", "Rn3", "Rn4"]

    private static let definitions: [Definition] = [
        Definition(id: "heat", title: "Тепло",
                   codes: ["Q_in", "Q_out", "Q_delta"],
                   separate: ["Q_delta"], isAccumulated: true, onlyWithout: [:]),
        Definition(id: "mass", title: "Масса",
                   codes: ["M_in", "M_out", "M_delta", "M"],
                   separate: ["M_delta"], isAccumulated: true, onlyWithout: [:]),
        Definition(id: "volume", title: "Объём",
                   codes: ["V_in", "V_out", "V_delta", "V"],
                   separate: ["V_delta"], isAccumulated: true, onlyWithout: [:]),
        // Порядок — как решил владелец: T1, T2, ΔT, Tнв (ΔT при этом рисуется отдельно).
        Definition(id: "temperatures", title: "Температуры",
                   codes: ["T_in", "T_out", "T_delta", "T_outdoor", "T_cw"],
                   separate: ["T_delta"], isAccumulated: false, onlyWithout: ["T_cw": "T_in"]),
        Definition(id: "pressure", title: "Давление",
                   codes: ["P_in", "P_out", "P_delta", "P_cw"],
                   separate: ["P_delta"], isAccumulated: false, onlyWithout: ["P_cw": "P_in"]),
        // Электроэнергия: сумма и тарифы — на одном графике.
        Definition(id: "activeEnergy", title: "Активная энергия",
                   codes: ["Ap", "Ap1", "Ap2", "Ap3", "Ap4", "An", "An1", "An2", "An3", "An4"],
                   separate: [], isAccumulated: true, onlyWithout: [:]),
        Definition(id: "reactiveEnergy", title: "Реактивная энергия",
                   codes: ["Rp", "Rp1", "Rp2", "Rp3", "Rp4", "Rn", "Rn1", "Rn2", "Rn3", "Rn4"],
                   separate: [], isAccumulated: true, onlyWithout: [:])
    ]

    /// Пункты меню, для которых в записях есть данные. Показываем все параметры, что прислал прибор
    /// (а не только выбранные в ЛЭРС): меню «Параметр» само служит выбором.
    static func available(in records: [ArchiveRecord]) -> [ArchiveMetric] {
        var present = Set<String>()
        var nonZero = Set<String>()
        for record in records {
            for value in record.values {
                present.insert(value.dataParameter)
                if value.value != 0 {
                    nonZero.insert(value.dataParameter)
                }
            }
        }
        var result: [ArchiveMetric] = []
        for definition in definitions {
            let codes = definition.codes.filter { code in
                guard present.contains(code) else {
                    return false
                }
                if hiddenWhenZero.contains(code) && !nonZero.contains(code) {
                    return false
                }
                if let other = definition.onlyWithout[code], present.contains(other) {
                    return false
                }
                return true
            }
            if codes.isEmpty {
                continue
            }
            var mainCodes = codes.filter { !definition.separate.contains($0) }
            var separateCodes = codes.filter { definition.separate.contains($0) }
            // Есть только разность (например, ΔV) — рисуем её на основном графике.
            if mainCodes.isEmpty {
                mainCodes = separateCodes
                separateCodes = []
            }
            result.append(ArchiveMetric(id: definition.id, title: definition.title, codes: codes,
                                        mainCodes: mainCodes, separateCodes: separateCodes,
                                        isAccumulated: definition.isAccumulated))
        }
        return result
    }

    /// Обозначение параметра на графиках: как в справочнике, но разность тепла — «ΔQ»
    /// (в справочнике это «Q» — «потреблённое тепло»), чтобы все разности выглядели одинаково.
    static func symbol(for code: String) -> String {
        if code == "Q_delta" {
            return "ΔQ"
        }
        return DataParameterCatalog.symbol(for: code)
    }

    /// Подпись в легенде графика: «T1 подача», «Q2 обратка», «Tнв улица».
    static func legendTitle(for code: String) -> String {
        let symbol = symbol(for: code)
        if code.hasSuffix("_in") {
            return "\(symbol) подача"
        }
        if code.hasSuffix("_out") {
            return "\(symbol) обратка"
        }
        if code == "T_outdoor" {
            return "\(symbol) улица"
        }
        return symbol
    }
}
