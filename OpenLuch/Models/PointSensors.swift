import Foundation

// Датчики точки учёта: какое оборудование что измеряет и на какой магистрали стоит
// (как раздел «Датчики» в программе ЛЭРС: «Подающая магистраль — Температура — КТСП-Р №2198»).
//
// Откуда: GET /api/v1/Core/MeasurePoints/{id}?getSensor=true → sensorList. Это единственное место
// в API, где есть связь «датчик → точка» (см. docs/api-notes.md). Ответ тяжёлый (~365 КБ на demo):
// сервер всегда прикладывает справочник оборудования объекта (nodeEquipment). Из него мы берём
// названия и номера приборов датчиков — так раздел не зависит от того, загружен ли справочник
// оборудования, и по каждому датчику можно открыть его карточку.

/// Один датчик точки.
nonisolated struct PointSensor: Codable, Hashable, Sendable {
    /// Параметр точки, который измеряет датчик: "T_in", "P_out", "V_in"…
    let parameter: String
    /// Порядковый номер (у нескольких датчиков одного параметра, например перепада давления).
    let order: Int?
    let equipmentId: Int
    /// Оборудование датчика (из того же ответа сервера). nil — сервер его не прислал.
    let equipment: Equipment?

    /// На какой магистрали стоит датчик.
    var pipe: SensorPipe {
        if parameter.hasSuffix("_in") {
            return .supply
        }
        if parameter.hasSuffix("_out") {
            return .return
        }
        return .other
    }

    /// Что измеряет — коротко, для строки внутри магистрали: «Температура», «Давление».
    /// Для датчиков вне магистралей — полное название параметра: «Температура холодной воды».
    var measuredTitle: String {
        if pipe != .other {
            switch parameter.prefix(1) {
            case "T":
                return "Температура"
            case "P":
                return "Давление"
            case "V":
                return "Объём"
            case "M":
                return "Масса"
            case "Q":
                return "Тепло"
            default:
                break
            }
        }
        return DataParameterCatalog.title(for: parameter)
    }

    /// Порядок строк внутри магистрали — как в программе ЛЭРС: температура, давление, объём, остальное.
    var sortRank: Int {
        switch parameter.prefix(1) {
        case "T":
            return 0
        case "P":
            return 1
        case "V":
            return 2
        case "M":
            return 3
        default:
            return 4
        }
    }

    /// «КТСП-Р № 2198» — или номер оборудования, если сервер его не прислал.
    var equipmentTitle: String {
        return equipment?.shortTitle ?? "Оборудование № \(equipmentId)"
    }
}

/// Магистраль, на которой стоит датчик.
nonisolated enum SensorPipe: CaseIterable, Sendable {
    case supply
    case `return`
    case other

    var title: String {
        switch self {
        case .supply:
            return "Подающая магистраль"
        case .return:
            return "Обратная магистраль"
        case .other:
            return "Прочие датчики"
        }
    }
}

/// Сохранённые датчики точки и время, когда они получены с сервера.
nonisolated struct CachedPointSensors: Codable, Sendable {
    let savedAt: Date
    let sensors: [PointSensor]
}

// MARK: - Ответ сервера GET /api/v1/Core/MeasurePoints/{id}?getSensor=true

/// Из большого ответа берём только датчики и справочник оборудования объекта
/// (остальное — сама точка, настройки опроса и т.п. — JSONDecoder пропускает).
nonisolated struct MeasurePointSensorsResponse: Decodable, Sendable {
    let sensorList: [SensorResponse]?
    let nodeEquipment: EquipmentListResponse?

    /// Датчики с подставленным оборудованием, в порядке: магистраль, что измеряет, номер.
    func makeSensors() -> [PointSensor] {
        var equipmentById: [Int: Equipment] = [:]
        if let nodeEquipment {
            for item in Equipment.makeList(from: nodeEquipment) {
                equipmentById[item.id] = item
            }
        }

        var sensors: [PointSensor] = []
        for sensor in sensorList ?? [] {
            guard let parameter = sensor.parameter, let equipmentId = sensor.equipmentId else {
                continue
            }
            sensors.append(PointSensor(parameter: parameter, order: sensor.order, equipmentId: equipmentId,
                                       equipment: equipmentById[equipmentId]))
        }
        sensors.sort { first, second in
            if first.sortRank != second.sortRank {
                return first.sortRank < second.sortRank
            }
            return (first.order ?? 0) < (second.order ?? 0)
        }
        return sensors
    }
}

nonisolated struct SensorResponse: Decodable, Sendable {
    let equipmentId: Int?
    let parameter: String?
    let order: Int?
}
