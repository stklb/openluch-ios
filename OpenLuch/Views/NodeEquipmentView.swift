import SwiftUI

/// Переход из карточки объекта к экрану его оборудования (NavigationLink(value:)).
struct NodeEquipmentRoute: Hashable {
    let nodeId: Int
}

// Экран «Оборудование» объекта учёта (открывается из карточки объекта, решение владельца 2026-10-16).
// Приборы сгруппированы по точкам учёта, всё прочее — в группе «Остальное оборудование объекта»
// (как раскладываем — см. NodeEquipment). Всё из кэша: справочник оборудования и сохранённые датчики точек —
// новых запросов нет, работает без интернета. Нажатие на прибор — его карточка.
struct NodeEquipmentView: View {
    @Environment(DataStore.self) private var dataStore
    @Environment(AppSession.self) private var session

    let nodeId: Int

    /// Датчики точек объекта из кэша (Cache/sensors) — есть только у точек, где открывали вкладку «Датчики».
    /// Читаются с диска при открытии экрана (доли секунды).
    @State private var sensorsByPoint: [Int: [PointSensor]] = [:]

    var body: some View {
        let points = dataStore.measurePoints(ofNode: nodeId)
        let groups = NodeEquipment.groups(nodeId: nodeId, points: points, equipment: dataStore.equipment,
                                          sensorsByPoint: sensorsByPoint)
        let today = Equipment.calendarDay(of: Date())

        List {
            if dataStore.equipmentUpdatedAt == nil {
                Text("Справочник оборудования ещё не загружен. Он загрузится автоматически по Wi-Fi или при открытии вкладки «Оборудование».")
                    .foregroundStyle(.secondary)
            } else if groups.isEmpty {
                Text("На объекте нет оборудования.")
                    .foregroundStyle(.secondary)
            }
            ForEach(groups) { group in
                Section {
                    ForEach(group.items) { item in
                        NavigationLink(value: item.equipment) {
                            EquipmentRow(equipment: item.equipment, today: today,
                                         subtitle: item.role ?? item.equipment.kindTitle)
                        }
                    }
                } header: {
                    if let point = group.point {
                        Label(point.title, systemImage: point.systemSymbolName)
                    } else {
                        Text("Остальное оборудование объекта")
                    }
                } footer: {
                    // Объясняем, почему датчик может оказаться не у своей точки.
                    if group.point == nil && points.contains(where: { sensorsByPoint[$0.id] == nil }) {
                        Text("Датчики и расходомеры показываются у точки, только если в ней уже открывали вкладку «Датчики». Остальные — здесь.")
                    }
                }
            }
        }
        .listSectionSpacing(.compact)
        .navigationTitle("Оборудование")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadCachedSensors(points: points)
        }
    }

    /// Прочитать сохранённые датчики точек объекта (только кэш — сеть не трогаем).
    private func loadCachedSensors(points: [MeasurePoint]) async {
        var result: [Int: [PointSensor]] = [:]
        for point in points {
            if let cached = await session.cacheStore.loadSensors(pointId: point.id) {
                result[point.id] = cached.sensors
            }
        }
        sensorsByPoint = result
    }
}
