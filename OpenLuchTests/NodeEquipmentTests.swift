import XCTest
@testable import OpenLuch

// Оборудование объекта по точкам (NodeEquipment) и пользовательские атрибуты объекта.
final class NodeEquipmentTests: XCTestCase {

    private func equipment(_ id: Int, _ model: String, node: Int, modemId: Int? = nil) -> Equipment {
        var details: EquipmentDetails?
        if let modemId {
            details = EquipmentDetails(modelLongTitle: nil, calibrationIntervalYears: nil, sealNumber: nil,
                                       calibrationOrganization: nil, calibrationResult: nil,
                                       calibrationRegisterNumber: nil, calibrationSyncDay: nil,
                                       networkAddress: nil, firmwareVersion: nil, hardwareVersion: nil,
                                       batteryVolts: nil, isBatteryLow: false, comment: nil,
                                       connections: [EquipmentConnection(commLinkType: "Gprs",
                                                                         modemEquipmentId: modemId,
                                                                         modemTitle: nil)])
        }
        return Equipment(id: id, modelTitle: model, modelCapabilities: "Gauge", serialNumber: nil,
                         lastCalibrationDay: nil, nextCalibrationDay: nil,
                         places: [EquipmentPlace(nodeId: node, title: "Дом")], details: details)
    }

    func testGroupsByPoints() {
        let all = [
            equipment(1, "СПТ943", node: 7, modemId: 2),   // устройство опроса точки 100
            equipment(2, "Модем", node: 7),
            equipment(3, "КТСП-Р", node: 7),                // датчик точки 100 (из кэша датчиков)
            equipment(4, "ПРЭМ", node: 7),                  // связь неизвестна
            equipment(5, "Чужой", node: 8)                   // другой объект
        ]
        let points = [
            MeasurePoint(id: 100, title: "Отопление", fullTitle: "", parentTitle: nil, address: nil, nodeId: 7,
                         systemType: "Heat", resourceKind: nil, state: nil, deviceId: 1),
            MeasurePoint(id: 200, title: "ХВС", fullTitle: "", parentTitle: nil, address: nil, nodeId: 7,
                         systemType: "ColdWater", resourceKind: nil, state: nil)
        ]
        let sensors = [100: [PointSensor(parameter: "T_in", order: nil, equipmentId: 3, equipment: nil),
                             PointSensor(parameter: "T_out", order: nil, equipmentId: 3, equipment: nil)]]

        let groups = NodeEquipment.groups(nodeId: 7, points: points, equipment: all, sensorsByPoint: sensors)

        // Точка без известного оборудования (ХВС) не показывается; «Остальное» — последней.
        XCTAssertEqual(groups.map(\.id), [100, -1])
        XCTAssertEqual(groups[0].items.map(\.id), [1, 2, 3])
        XCTAssertEqual(groups[0].items.map(\.role),
                       ["Устройство опроса", "Модем", "Температура, подача; Температура, обратка"])
        XCTAssertEqual(groups[1].items.map(\.id), [4])
        XCTAssertNil(groups[1].items[0].role)
    }

    func testAttributes() throws {
        let json = #"""
        {"id": 1, "title": "Дом", "address": "", "attributes": [
          {"customAttributeId": 5, "nodeId": 1, "code": "ReportFormulaWinter", "value": "6", "title": "Формула (зима)"},
          {"customAttributeId": 6, "nodeId": 1, "code": "Empty", "value": " ", "title": "Пустой"},
          {"customAttributeId": 7, "nodeId": 1, "code": "NoTitle", "value": "да", "title": null}]}
        """#
        let node = try JSONDecoder().decode(Node.self, from: Data(json.utf8))
        let shown = node.filledAttributes
        XCTAssertEqual(shown.map(\.title), ["Формула (зима)", "NoTitle"])
        XCTAssertEqual(shown.map(\.value), ["6", "да"])
    }
}
