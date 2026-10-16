import Foundation

// Фильтры списков «Объекты», «Точки», «Оборудование» (решения владельца 2026-10-15).
//
// Как работают:
//   • у каждого списка свой набор фильтров (структура ниже); выбранные фильтры действуют ВМЕСТЕ —
//     показываются записи, подходящие под все сразу;
//   • в каждом фильтре — один вариант (nil — «Все»), кроме «Состояния», «Системы» и «Типа связи»:
//     там можно отметить несколько вариантов сразу (пустой набор — все);
//   • фильтры работают на телефоне, по кэшу — трафика не тратят и работают без интернета;
//   • выбор запоминается между запусками (JSON в настройках приложения, см. `encoded` и `decode`).
// Окно с фильтрами — FiltersSheet.swift.

/// Вариант фильтра «Состояние» — все состояния, что бывают у объектов и точек, чтобы любая запись
/// попадала в какой-нибудь вариант. Можно отметить несколько: «Ошибка» и «Предупреждение» — все проблемные.
nonisolated enum StateFilter: String, CaseIterable, Identifiable, Codable, Sendable {
    case normal
    case error
    case warning
    case noData
    /// Сервер прислал "None" (обычно у расчётных точек без своего прибора) или незнакомое значение.
    case unknown

    var id: String { rawValue }

    /// Подпись — как у состояния в карточках («Норма», «Не определено»…).
    var title: String {
        return itemState.title
    }

    /// Состояние записи, которое отбирает этот вариант.
    var itemState: ItemState {
        switch self {
        case .normal:
            return .normal
        case .error:
            return .error
        case .warning:
            return .warning
        case .noData:
            return .noData
        case .unknown:
            return .unknown
        }
    }

    /// Подходит ли состояние записи под отмеченные варианты (ничего не отмечено — подходит любое).
    static func matches(_ state: ItemState, selected: Set<StateFilter>) -> Bool {
        return selected.isEmpty || selected.contains { $0.itemState == state }
    }
}

/// Сохранение фильтра в настройках приложения (переживает перезапуск).
nonisolated protocol SavedFilter: Codable, Equatable {
    init()
}

nonisolated extension SavedFilter {
    /// Фильтр строкой JSON — для @AppStorage.
    var encoded: Data {
        return (try? JSONEncoder().encode(self)) ?? Data()
    }

    /// Сохранённый фильтр; нет или не читается (например, сохранён прошлой версией) — пустой.
    static func decode(_ data: Data) -> Self {
        return (try? JSONDecoder().decode(Self.self, from: data)) ?? Self()
    }

    /// Выбран ли хоть один фильтр.
    var isActive: Bool {
        return self != Self()
    }
}

// MARK: - Объекты

nonisolated struct NodeFilter: SavedFilter {
    /// Состояния; можно несколько, пусто — все.
    var states: Set<StateFilter> = []
    /// Группа объектов (NodeGroup.id).
    var groupId: Int?
    /// Тип объекта — как присылает сервер (Node.type: "Node", "House", "PowerSource").
    var kind: String?
    /// Сезон (Node.currentSeason: "Summer", "Winter").
    var season: String?
    /// Потребитель (Customer.id) — указанный у объекта или у любой его точки.
    var customerId: Int?
    /// «Есть работы» — только объекты с незавершёнными работами. true — включён, nil — выключен
    /// (не false: так фильтр, сохранённый прошлой версией приложения без этого поля, читается как есть).
    var withJobs: Bool?

    /// `groupMembers` — объекты выбранной группы (nil — группа не выбрана или удалена на сервере).
    /// `customerIds` — потребители объекта и его точек (DataStore.customerIds(ofNode:)).
    /// `hasJobs` — есть ли у объекта незавершённые работы (DataStore.nodeIdsWithJobs).
    func matches(_ node: Node, groupMembers: Set<Int>?, customerIds: Set<Int> = [], hasJobs: Bool = false) -> Bool {
        if let groupMembers, !groupMembers.contains(node.id) {
            return false
        }
        if withJobs == true && !hasJobs {
            return false
        }
        if let customerId, !customerIds.contains(customerId) {
            return false
        }
        if let kind, (node.type ?? "") != kind {
            return false
        }
        if let season, (node.currentSeason ?? "") != season {
            return false
        }
        return StateFilter.matches(node.itemState, selected: states)
    }
}

// MARK: - Точки учёта

nonisolated struct PointFilter: SavedFilter {
    /// Состояния; можно несколько, пусто — все.
    var states: Set<StateFilter> = []
    /// Системы (MeasurePoint.systemType: "Heat", "HotWater"…). Можно несколько; пусто — все.
    var systems: Set<String> = []
    /// Группа объектов: точки объектов этой группы.
    var groupId: Int?
    /// Типы связи (MeasurePoint.commLinkType: "Gprs", "Ip"…; не указан — ""). Можно несколько; пусто — все.
    var commLinks: Set<String> = []
    /// Потребитель (Customer.id) — указанный у точки или у её объекта.
    var customerId: Int?

    /// `customerIds` — потребители точки и её объекта (DataStore.customerIds(ofPoint:)).
    func matches(_ point: MeasurePoint, groupMembers: Set<Int>?, customerIds: Set<Int> = []) -> Bool {
        if let groupMembers, !groupMembers.contains(point.nodeId ?? -1) {
            return false
        }
        if let customerId, !customerIds.contains(customerId) {
            return false
        }
        if !systems.isEmpty && !systems.contains(point.systemType ?? "") {
            return false
        }
        if !commLinks.isEmpty && !commLinks.contains(point.commLinkType ?? "") {
            return false
        }
        return StateFilter.matches(point.itemState, selected: states)
    }
}

// MARK: - Оборудование

/// Фильтр по поверке (только для средств измерения: у модемов поверки нет).
nonisolated enum CalibrationFilter: String, CaseIterable, Codable, Sendable {
    case all
    /// Срок поверки уже истёк.
    case overdue
    /// Нужно поверить до выбранной даты — в том числе уже просроченные.
    case dueBefore
    /// Дата следующей поверки в ЛЭРС не заполнена.
    case noDate

    var title: String {
        switch self {
        case .all:
            return "Все"
        case .overdue:
            return "Истекла"
        case .dueBefore:
            return "Нужно поверить до…"
        case .noDate:
            return "Дата не указана"
        }
    }
}

nonisolated struct EquipmentFilter: SavedFilter {
    var calibration: CalibrationFilter = .all
    /// Дата для «Нужно поверить до…» в виде «гггг-мм-дд». nil — не выбрана (по умолчанию — через 3 месяца).
    var dueBeforeDay: String?
    /// Тип оборудования (Equipment.kindTitle: «Прибор учёта», «Коммуникационное оборудование»…).
    var kind: String?
    /// Группа объектов: оборудование, установленное хотя бы на одном объекте группы.
    var groupId: Int?

    /// Дата «Нужно поверить до…» по умолчанию — через 3 месяца от сегодня.
    static func defaultDueBeforeDay(today: Date = Date()) -> String {
        let date = Calendar.current.date(byAdding: .month, value: 3, to: today) ?? today
        return Equipment.calendarDay(of: date)
    }

    /// `today` — сегодняшний день «гггг-мм-дд» (Equipment.calendarDay(of:)): считается один раз на список.
    func matches(_ item: Equipment, groupMembers: Set<Int>?, today: String) -> Bool {
        if let groupMembers, !item.places.contains(where: { groupMembers.contains($0.nodeId) }) {
            return false
        }
        if let kind, item.kindTitle != kind {
            return false
        }
        switch calibration {
        case .all:
            return true
        case .overdue:
            return item.isCalibrationOverdue(today: today)
        case .dueBefore:
            // Даты «гггг-мм-дд» сравниваются как строки. Срок в сам выбранный день тоже попадает.
            let limit = dueBeforeDay ?? EquipmentFilter.defaultDueBeforeDay()
            guard let next = item.nextCalibrationDay else {
                return false
            }
            return next <= limit
        case .noDate:
            return item.isMeasuringInstrument && item.nextCalibrationDay == nil
        }
    }
}
