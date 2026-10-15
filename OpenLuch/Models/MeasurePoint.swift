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

    /// Создание точки вручную (в тестах). Сервер присылает точки в JSON — их создаёт JSONDecoder.
    init(id: Int, title: String, fullTitle: String, parentTitle: String?, address: String?, nodeId: Int?,
         systemType: String?, resourceKind: String?, state: String?,
         commLinkType: String? = nil, comment: String? = nil, deviceId: Int? = nil,
         selectedParamsList: [Int]? = nil, customerId: Int? = nil) {
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
        case "HotWater":
            return "Горячее водоснабжение"
        case "ColdWater":
            return "Холодное водоснабжение"
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
}
