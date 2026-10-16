import Foundation

// Точка учёта (в API ЛЭРС — MeasurePoint): например, «Отопление» или «ГВС» на объекте.
// Приходит из GET /api/v1/Core/MeasurePoints?type=Regular (только обычные точки —
// квартирные мы не используем, см. PLAN.md).
//
// Сервер присылает у точки ~47 полей (~2 КБ). Здесь только нужные приложению —
// остальные JSONDecoder пропускает. В кэш на телефоне сохраняются тоже только они,
// поэтому кэш намного меньше ответа сервера.
nonisolated struct MeasurePoint: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    /// Короткое наименование, например «ГВС». В swagger поле обязательное.
    let title: String
    /// Полное наименование вместе с объектом, например «ТСЖ "Семь ветров" - ГВС».
    let fullTitle: String
    /// Наименование объекта учёта, к которому относится точка.
    let parentTitle: String?
    let address: String?
    /// Идентификатор объекта учёта (Node.id).
    let nodeId: Int?
    /// Инженерная система строкой: "Heat", "HotWater", "ColdWater" и т.д. См. `systemTitle`.
    let systemType: String?
    /// Вид ресурса строкой: "Water", "Electricity", "Gas", "None".
    let resourceKind: String?
    /// Состояние строкой: "Normal", "Error" и т.д. См. `itemState`.
    let state: String?
    /// Канал связи строкой: "Gprs", "Gsm", "Ip" и т.д. См. `commLinkTitle`.
    /// Необязательные поля — кэш прошлой версии приложения без них тоже читается.
    let commLinkType: String?
    let comment: String?
    /// Устройство опроса точки (вычислитель или счётчик) — номер в справочнике оборудования
    /// (Equipment.id). По нему карточка оборудования находит свою точку без запроса к серверу.
    let deviceId: Int?
    /// Параметры, которые в ЛЭРС выбраны для показа у этой точки («отображаемые по умолчанию
    /// в таблицах и графиках»), — номера параметров (DataValue.dataParameterId), в порядке показа.
    /// Настраиваются на сервере; nil или пустой список — показываем все параметры.
    let selectedParamsList: [Int]?
    /// Потребитель (Customer.id), если он указан у самой точки (обычно указывают у объекта). nil — не указан.
    let customerId: Int?

    // Для карточки точки (решение владельца 2026-10-16). Приходят в том же списке точек — трафика не добавляют.
    // Все необязательные: кэш прошлой версии приложения без них тоже читается.

    /// Пользовательские атрибуты точки — только код и значение (названий сервер у точек не присылает,
    /// они — в справочнике атрибутов, см. CachedMeasurePoints.attributeTitles).
    let attributes: [PointAttribute]?
    /// Расчётная точка: своего прибора нет, значения вычисляются из других точек.
    let isVirtual: Bool?
    /// Дата, до которой точка допущена в эксплуатацию, — как прислал сервер (без часового пояса).
    let admissionDate: String?
    /// Коэффициенты трансформации по току и напряжению (у электроснабжения), 1 — без трансформатора.
    let currentRatio: Double?
    let voltageRatio: Double?

    /// Создание точки вручную (в тестах). Сервер присылает точки в JSON — их создаёт JSONDecoder.
    init(id: Int, title: String, fullTitle: String, parentTitle: String?, address: String?, nodeId: Int?,
         systemType: String?, resourceKind: String?, state: String?,
         commLinkType: String? = nil, comment: String? = nil, deviceId: Int? = nil,
         selectedParamsList: [Int]? = nil, customerId: Int? = nil, attributes: [PointAttribute]? = nil,
         isVirtual: Bool? = nil, admissionDate: String? = nil, currentRatio: Double? = nil,
         voltageRatio: Double? = nil) {
        self.id = id
        self.title = title
        self.fullTitle = fullTitle
        self.parentTitle = parentTitle
        self.address = address
        self.nodeId = nodeId
        self.systemType = systemType
        self.resourceKind = resourceKind
        self.state = state
        self.commLinkType = commLinkType
        self.comment = comment
        self.deviceId = deviceId
        self.selectedParamsList = selectedParamsList
        self.customerId = customerId
        self.attributes = attributes
        self.isVirtual = isVirtual
        self.admissionDate = admissionDate
        self.currentRatio = currentRatio
        self.voltageRatio = voltageRatio
    }

    /// День «гггг-мм-дд», до которого точка допущена; nil — не указан (сервер может прислать «0001-01-01»).
    var admissionDay: String? {
        guard let admissionDate, admissionDate.count >= 10, !admissionDate.hasPrefix("0001-") else {
            return nil
        }
        return String(admissionDate.prefix(10))
    }

    /// Срок допуска истёк: день допуска уже прошёл (`today` — «гггг-мм-дд», см. Equipment.calendarDay(of:)).
    func isAdmissionExpired(today: String) -> Bool {
        guard let admissionDay else {
            return false
        }
        return admissionDay < today
    }

    /// Коэффициенты трансформации для показа — только у электроснабжения и только отличные от 1.
    var transformationRatios: (current: Double?, voltage: Double?) {
        guard systemType == "Electricity" else {
            return (nil, nil)
        }
        let current = currentRatio.flatMap { $0 != 1 && $0 > 0 ? $0 : nil }
        let voltage = voltageRatio.flatMap { $0 != 1 && $0 > 0 ? $0 : nil }
        return (current, voltage)
    }

    /// Атрибуты для показа: только со значением; название — из справочника атрибутов (`titles`: код → название),
    /// нет в справочнике — код. Как у объекта (Node.filledAttributes).
    func filledAttributes(titles: [String: String]) -> [(title: String, value: String)] {
        var result: [(title: String, value: String)] = []
        for attribute in attributes ?? [] {
            let value = (attribute.value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let code = attribute.code ?? ""
            let title = (titles[code] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let name = title.isEmpty ? code : title
            if !value.isEmpty && !name.isEmpty {
                result.append((title: name, value: value))
            }
        }
        return result
    }

    var itemState: ItemState {
        return ItemState(apiValue: state)
    }

    /// Название инженерной системы для пользователя.
    var systemTitle: String {
        return MeasurePoint.systemTitle(for: systemType)
    }

    /// Система строкой сервера ("Heat"…) → название. Отдельной функцией — нужна и в фильтре списка точек.
    static func systemTitle(for systemType: String?) -> String {
        switch systemType {
        case "Heat":
            return "Теплоснабжение"
        // Горячее и холодное водоснабжение — общепринятыми сокращениями ГВС и ХВС (решение владельца).
        case "HotWater":
            return "ГВС"
        case "ColdWater":
            return "ХВС"
        case "Steam":
            return "Пар"
        case "Gas":
            return "Газ"
        case "Electricity":
            return "Электроснабжение"
        case "Sewage":
            return "Водоотведение"
        case "Control":
            return "Контроль"
        default:
            return "Другое"
        }
    }

    /// Значок SF Symbols для инженерной системы (цвет — `systemColor` в ListComponents.swift).
    /// ⚠️ Временные значки из стандартного набора: владелец, возможно, нарисует свои (см. PLAN.md).
    /// ГВС и ХВС — одна капля, различаются цветом (оранжевая и синяя).
    var systemSymbolName: String {
        return MeasurePoint.systemSymbolName(for: systemType)
    }

    /// Значок системы по строке сервера ("Heat"…). Отдельной функцией — нужен и в фильтре списка точек.
    static func systemSymbolName(for systemType: String?) -> String {
        switch systemType {
        // Значки — как в официальной программе ЛЭРС, чтобы пользователи не путались
        // (решение владельца 2026-10-06): тепло — градусник, ГВС и ХВС — водопроводный кран
        // (красный и синий — цвет в ListComponents, `systemColor`).
        case "Heat":
            return "thermometer.medium"
        case "HotWater":
            return "spigot.fill"
        case "ColdWater":
            return "spigot.fill"
        case "Steam":
            return "cloud.fill"
        case "Gas":
            return "flame.fill"
        case "Electricity":
            return "bolt.fill"
        case "Sewage":
            return "water.waves"
        case "Control":
            return "gauge.with.needle"
        default:
            return "circle.dashed"
        }
    }

    /// Канал связи для пользователя — или nil, если не указан.
    var commLinkTitle: String? {
        return MeasurePoint.commLinkTitle(for: commLinkType)
    }

    /// Канал связи строкой сервера ("Gprs", "Ip"…) → название для пользователя.
    /// Отдельной функцией — нужна и в карточке оборудования.
    static func commLinkTitle(for commLinkType: String?) -> String? {
        switch commLinkType {
        case "Direct":
            return "Прямое подключение"
        case "Dialup":
            return "Коммутируемая линия"
        case "Gsm":
            return "GSM (CSD)"
        case "Gprs":
            return "GPRS"
        case "Ip":
            return "Ethernet / IP"
        case "Integration":
            return "Интеграция"
        default:
            return nil
        }
    }

    /// Значок канала связи — аналоги значков программы ЛЭРС для ПК из стандартного набора iOS
    /// (решение владельца 2026-10-16): прямое — разъём кабеля, коммутируемая линия — трубка с волнами,
    /// GSM (CSD) — кнопочный телефон, GPRS — вышка с радиоволнами, Ethernet / IP — глобус,
    /// интеграция — обмен в обе стороны; не указан — пунктирный кружок (как у неизвестной системы).
    static func commLinkSymbolName(for commLinkType: String?) -> String {
        switch commLinkType {
        case "Direct":
            return "cable.connector"
        case "Dialup":
            return "phone.connection"
        case "Gsm":
            return "candybarphone"
        case "Gprs":
            return "antenna.radiowaves.left.and.right"
        case "Ip":
            return "globe"
        case "Integration":
            return "arrow.left.arrow.right"
        default:
            return "circle.dashed"
        }
    }
}

/// Пользовательский атрибут точки: код и значение («DateLimitTo» = «04.06.2026»).
nonisolated struct PointAttribute: Codable, Hashable, Sendable {
    let code: String?
    let value: String?
}

/// Запись справочника пользовательских атрибутов (GET /api/v1/Inventory/CustomAttributes): код и название.
/// Нужен, потому что у точек сервер присылает только коды атрибутов. Лишние поля JSONDecoder пропускает.
nonisolated struct CustomAttributeResponse: Decodable, Sendable {
    let code: String?
    let title: String?

    /// Код → название (без пустых).
    static func makeTitles(from response: [CustomAttributeResponse]) -> [String: String] {
        var titles: [String: String] = [:]
        for item in response {
            let code = item.code ?? ""
            let title = (item.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !code.isEmpty && !title.isEmpty {
                titles[code] = title
            }
        }
        return titles
    }
}
