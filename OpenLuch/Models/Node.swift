import Foundation

// Объект учёта (в API ЛЭРС он называется Node): здание, котельная, жилой дом и т.п.
// Приходит из GET /api/v1/Core/Nodes.
//
// Сервер присылает у объекта ~32 поля (~1,2 КБ). Здесь описаны только те, что нужны
// приложению, — остальные JSONDecoder просто пропускает.
//
// Эта же структура сохраняется в кэш на телефоне (поэтому Codable, а не только Decodable).
nonisolated struct Node: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    /// Наименование, например «ТСЖ "Семь ветров"». В swagger поле обязательное.
    let title: String
    /// Адрес. В swagger поле обязательное, но может быть пустой строкой.
    let address: String
    /// Тип объекта строкой: "Node", "House", "PowerSource", "None". См. `kind`.
    let type: String?
    /// Сводное состояние строкой: "Normal", "Error" и т.д. См. `itemState`.
    let state: String?

    // Сведения для карточки объекта. Они и так приходят в ответе сервера (лишнего трафика нет),
    // в кэше занимают немного. Все необязательные: кэш, сохранённый прошлой версией
    // приложения, без них тоже читается.

    /// Номер объекта в системе, например 727.
    let number: Int?
    let comment: String?
    /// Ответственное лицо. Телефон ответственного (`responsiblePhone`) сервер тоже присылает,
    /// но его сознательно не берём (решение владельца, 2026-10-03).
    let responsibleName: String?
    /// Текущий сезон строкой: "Summer", "Winter", "None". См. `seasonTitle`.
    let currentSeason: String?
    /// Подробное состояние: точки учёта, нештатные ситуации, работы, поверки.
    let compositeState: NodeCompositeState?
    /// Координаты — для кнопки «Открыть в Картах».
    let geoLocation: GeoLocation?

    /// Создание объекта вручную (в тестах). Сервер присылает объекты в JSON — их создаёт JSONDecoder.
    init(id: Int, title: String, address: String, type: String?, state: String?,
         number: Int? = nil, comment: String? = nil, responsibleName: String? = nil,
         currentSeason: String? = nil,
         compositeState: NodeCompositeState? = nil, geoLocation: GeoLocation? = nil) {
        self.id = id
        self.title = title
        self.address = address
        self.type = type
        self.state = state
        self.number = number
        self.comment = comment
        self.responsibleName = responsibleName
        self.currentSeason = currentSeason
        self.compositeState = compositeState
        self.geoLocation = geoLocation
    }

    var kind: NodeKind {
        return NodeKind(apiValue: type)
    }

    var itemState: ItemState {
        return ItemState(apiValue: state)
    }

    /// Сезон для пользователя — или nil, если сервер его не указал.
    var seasonTitle: String? {
        switch currentSeason {
        case "Summer":
            return "Летний"
        case "Winter":
            return "Отопительный"
        default:
            return nil
        }
    }

    /// Подпись сезона в фильтре: «Летний», «Отопительный», остальное — «Не задан».
    static func seasonTitle(_ season: String) -> String {
        switch season {
        case "Summer":
            return "Летний"
        case "Winter":
            return "Отопительный"
        default:
            return "Не задан"
        }
    }

    /// Координаты, если они заданы (нули означают «не заданы»).
    var mapLocation: GeoLocation? {
        guard let geoLocation, geoLocation.latitude != 0 || geoLocation.longitude != 0 else {
            return nil
        }
        return geoLocation
    }
}

/// Подробное состояние объекта: каждое значение — строка "Normal", "Warning", "Error", "NoData", "None".
nonisolated struct NodeCompositeState: Codable, Hashable, Sendable {
    let measurePointState: String?
    let incidentState: String?
    let jobState: String?
    let calibrationState: String?
}

/// Географические координаты.
nonisolated struct GeoLocation: Codable, Hashable, Sendable {
    let latitude: Double
    let longitude: Double
}

/// Тип объекта учёта — для подписи в списке.
nonisolated enum NodeKind: Equatable, Sendable {
    case regular       // "Node" — обычный объект учёта
    case house         // "House" — жилой дом (квартиры в нём не показываем, см. PLAN.md)
    case powerSource   // "PowerSource" — источник энергоснабжения (котельная и т.п.)
    case unknown

    init(apiValue: String?) {
        switch apiValue {
        case "Node":
            self = .regular
        case "House":
            self = .house
        case "PowerSource":
            self = .powerSource
        default:
            self = .unknown
        }
    }

    var title: String {
        switch self {
        case .regular:
            return "Объект учёта"
        case .house:
            return "Жилой дом"
        case .powerSource:
            return "Источник энергоснабжения"
        case .unknown:
            return "Объект"
        }
    }

    /// Значок SF Symbols для подписи типа.
    var symbolName: String {
        switch self {
        case .regular:
            return "building.2"
        case .house:
            return "house"
        case .powerSource:
            return "flame"
        case .unknown:
            return "building"
        }
    }
}

// MARK: - Группы объектов

/// Группа объектов учёта (в ЛЭРС их заводит администратор: «Котельные», «Район 1»…).
/// Приходит из GET /api/v1/Core/NodeGroups — список групп пользователя с номерами объектов
/// в каждой. Ответ крошечный (~0,1 КБ на группу), поэтому запрашиваем его вместе со списком объектов
/// и храним в том же файле кэша. По группе фильтруется вкладка «Объекты» — на телефоне, без запросов.
nonisolated struct NodeGroup: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let title: String
    /// Номера объектов (Node.id), входящих в группу.
    let memberIds: [Int]
}

/// Ответ GET /api/v1/Core/NodeGroups — массив таких записей.
nonisolated struct NodeGroupResponse: Decodable, Sendable {
    let nodeGroup: NodeGroupInfo?
    let members: [Int]?

    nonisolated struct NodeGroupInfo: Decodable, Sendable {
        let id: Int
        let title: String?
    }

    /// Группы для приложения: без пустых названий, по алфавиту.
    static func makeGroups(from response: [NodeGroupResponse]) -> [NodeGroup] {
        var groups: [NodeGroup] = []
        for item in response {
            guard let info = item.nodeGroup else {
                continue
            }
            let title = info.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            groups.append(NodeGroup(id: info.id, title: title.isEmpty ? "Группа № \(info.id)" : title,
                                    memberIds: item.members ?? []))
        }
        return groups.sorted { first, second in
            first.title.localizedStandardCompare(second.title) == .orderedAscending
        }
    }
}
