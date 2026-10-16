import Foundation

// Оборудование объекта учёта, разложенное по точкам — для экрана «Оборудование» из карточки объекта
// (решение владельца 2026-10-16). Всё — из кэша, новых запросов нет.
//
// Что известно о связи прибора с точкой (docs/api-notes.md, «Справочник оборудования»):
//   • устройство опроса точки — точно: у точки есть deviceId;
//   • модем — из каналов связи устройства опроса (EquipmentDetails.connections);
//   • датчики и расходомеры — только у точек, где уже открывали вкладку «Датчики» (их ответ ~365 КБ
//     на точку, сохраняется в Cache/sensors). У остальных точек связь есть лишь в тяжёлых запросах.
// Всё прочее оборудование объекта — в группе «Остальное оборудование объекта». Это НЕ значит
// «не привязано к точкам»: там могут быть датчики точек, где вкладку «Датчики» не открывали.

/// Один прибор в группе и его роль в точке («Устройство опроса», «Модем», «Температура, подача»).
nonisolated struct NodeEquipmentItem: Identifiable, Hashable, Sendable {
    let equipment: Equipment
    /// Роль в точке; nil — в группе «Остальное», роль неизвестна.
    let role: String?

    var id: Int { equipment.id }
}

/// Группа: оборудование одной точки (point != nil) или остальное оборудование объекта (point == nil).
nonisolated struct NodeEquipmentGroup: Identifiable, Hashable, Sendable {
    let point: MeasurePoint?
    let items: [NodeEquipmentItem]

    /// −1 — группа «Остальное» (у точек номера положительные).
    var id: Int { point?.id ?? -1 }
}

nonisolated enum NodeEquipment {

    /// Оборудование, установленное на объекте (по справочнику оборудования).
    static func installed(onNode nodeId: Int, in equipment: [Equipment]) -> [Equipment] {
        return equipment.filter { item in
            item.places.contains { $0.nodeId == nodeId }
        }
    }

    /// Разложить оборудование объекта по точкам.
    /// `points` — точки объекта (в нужном порядке); `equipment` — весь справочник;
    /// `sensorsByPoint` — датчики точек из кэша (есть не у всех точек).
    /// Точки без известного оборудования не показываются; группа «Остальное» — последней, если не пустая.
    static func groups(nodeId: Int, points: [MeasurePoint], equipment: [Equipment],
                       sensorsByPoint: [Int: [PointSensor]]) -> [NodeEquipmentGroup] {
        var equipmentById: [Int: Equipment] = [:]
        for item in equipment {
            equipmentById[item.id] = item
        }

        var groups: [NodeEquipmentGroup] = []
        var usedIds = Set<Int>()

        for point in points {
            // Роли по порядку: устройство опроса, его модемы, датчики. Один прибор может встретиться
            // несколько раз (расходомер измеряет и объём, и массу) — тогда роли через «; ».
            var order: [Int] = []
            var roles: [Int: [String]] = [:]
            var found: [Int: Equipment] = [:]

            func add(_ item: Equipment, role: String) {
                if found[item.id] == nil {
                    order.append(item.id)
                    found[item.id] = item
                }
                if !(roles[item.id] ?? []).contains(role) {
                    roles[item.id, default: []].append(role)
                }
            }

            if let deviceId = point.deviceId, let device = equipmentById[deviceId] {
                add(device, role: "Устройство опроса")
                for connection in device.details?.connections ?? [] {
                    if let modemId = connection.modemEquipmentId, let modem = equipmentById[modemId] {
                        add(modem, role: "Модем")
                    }
                }
            }

            let sensors = (sensorsByPoint[point.id] ?? []).sorted { first, second in
                if pipeRank(first.pipe) != pipeRank(second.pipe) {
                    return pipeRank(first.pipe) < pipeRank(second.pipe)
                }
                return first.sortRank < second.sortRank
            }
            for sensor in sensors {
                // Сначала — из справочника (там свежее), иначе — сохранённое вместе с датчиками.
                guard let item = equipmentById[sensor.equipmentId] ?? sensor.equipment else {
                    continue
                }
                add(item, role: sensorRole(sensor))
            }

            if order.isEmpty {
                continue
            }
            let items = order.compactMap { id -> NodeEquipmentItem? in
                guard let item = found[id] else {
                    return nil
                }
                return NodeEquipmentItem(equipment: item, role: roles[id]?.joined(separator: "; "))
            }
            usedIds.formUnion(order)
            groups.append(NodeEquipmentGroup(point: point, items: items))
        }

        let rest = installed(onNode: nodeId, in: equipment)
            .filter { !usedIds.contains($0.id) }
            .map { NodeEquipmentItem(equipment: $0, role: nil) }
        if !rest.isEmpty {
            groups.append(NodeEquipmentGroup(point: nil, items: rest))
        }
        return groups
    }

    /// Роль датчика: «Температура, подача», «Давление, обратка» или название параметра.
    static func sensorRole(_ sensor: PointSensor) -> String {
        switch sensor.pipe {
        case .supply:
            return "\(sensor.measuredTitle), подача"
        case .return:
            return "\(sensor.measuredTitle), обратка"
        case .other:
            return sensor.measuredTitle
        }
    }

    /// Порядок магистралей: подача, обратка, прочие — как на вкладке «Датчики».
    private static func pipeRank(_ pipe: SensorPipe) -> Int {
        switch pipe {
        case .supply:
            return 0
        case .return:
            return 1
        case .other:
            return 2
        }
    }
}
