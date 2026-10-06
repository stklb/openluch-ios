import Foundation

// Последние данные точки учёта: текущие параметры (потребление) и интеграторы (накопленные значения счётчиков).
// Приходят из GET /api/v1/Data/MeasurePoints/{id}/Consumption/Last и …/Totals/Last
// (подробности и размеры ответов — в docs/api-notes.md).

/// Значение одного параметра, например «T_in = 24,98».
nonisolated struct DataValue: Codable, Hashable, Sendable {
    /// Код параметра: "T_in", "M_in", "Ap1"… Название для людей — в DataParameterCatalog.
    let dataParameter: String
    /// Номер параметра (1 — "T_in", 2 — "T_out"…). По нему сверяемся со списком выбранных
    /// для показа параметров точки (MeasurePoint.selectedParamsList). В кэше прошлой версии его нет.
    let dataParameterId: Int?
    let value: Double
    /// true — значение недостоверное (прибор сообщил ошибку).
    let isBad: Bool?
    /// true — значение рассчитано сервером, а не измерено прибором.
    let isCalc: Bool?
}

/// Какие значения показывать в карточке точки: выбранные в ЛЭРС для этой точки — сразу,
/// остальные — только по кнопке «Показать все параметры».
nonisolated enum ParameterSelection {

    /// Делит значения на выбранные (`shown`, в порядке выбора, как в ЛЭРС) и остальные (`hidden`,
    /// в порядке сервера). Если у точки ничего не выбрано — показываются все значения.
    /// Значение без номера параметра (из старого кэша) тоже показывается: проверить его нечем.
    static func split(_ values: [DataValue], selectedIds: [Int]?) -> (shown: [DataValue], hidden: [DataValue]) {
        guard let selectedIds, !selectedIds.isEmpty else {
            return (values, [])
        }
        // Сначала выбранные — в порядке выбора: он осмысленный (например, «подача, обратка, разность» рядом).
        var shown: [DataValue] = []
        for id in selectedIds {
            shown.append(contentsOf: values.filter { $0.dataParameterId == id })
        }
        // Значения без номера (из старого кэша) проверить нечем — показываем в конце.
        shown.append(contentsOf: values.filter { $0.dataParameterId == nil })
        // Остальные — в порядке сервера.
        let hidden = values.filter { value in
            guard let id = value.dataParameterId else {
                return false
            }
            return !selectedIds.contains(id)
        }
        return (shown, hidden)
    }
}

/// Последняя запись: время и значения параметров.
nonisolated struct LastDataRecord: Codable, Hashable, Sendable {
    /// Тип данных (только у потребления): "Current", "Hour", "Day", "Month"…
    let dataType: String?
    /// Время записи по часам точки учёта — БЕЗ часового пояса, например "2026-10-03T00:31:23".
    /// Поэтому храним строкой и показываем как есть (см. TextFormatting.deviceDateTime).
    let dateTime: String?
    let values: [DataValue]?

    /// Тип данных для пользователя.
    var dataTypeTitle: String? {
        switch dataType {
        case "Current":
            return "текущие"
        case "Hour":
            return "часовые"
        case "Day":
            return "суточные"
        case "Month":
            return "месячные"
        default:
            return nil
        }
    }
}

/// Сохранённые на телефоне последние данные одной точки — и её единицы измерения.
nonisolated struct CachedReadings: Codable, Sendable {
    /// Когда получены с сервера.
    let savedAt: Date
    let consumption: LastDataRecord?
    let totals: LastDataRecord?
    /// Единицы измерения ЭТОЙ точки. У каждой точки набор свой (у электрической — кВт·ч,
    /// у тепловой — °C, т, Гкал…), поэтому храним их вместе с её данными. Запрашиваются один раз;
    /// nil — ещё не получены (запросятся при следующем открытии карточки).
    let units: ServerUnits?
}

/// Единицы измерения точки учёта: категория параметра → единица,
/// например "Temperature" → "CelsiusDegree", "Heat" → "GigaCalorie".
nonisolated struct ServerUnits: Codable, Sendable {
    let unitsByCategory: [String: String]
}

/// Ответ запроса потребления за период — из него берём только список единиц.
nonisolated struct ConsumptionUnitsResponse: Decodable, Sendable {
    let dataParametersUnit: [UnitPair]?

    struct UnitPair: Decodable, Sendable {
        let dataParameterCategory: String
        let unit: String
    }
}
