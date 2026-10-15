import XCTest
@testable import OpenLuch

// Фильтры списков: несколько фильтров вместе, группы, несколько систем, поверка, сохранение.
final class ListFiltersTests: XCTestCase {

    func testNodeFiltersCombine() {
        let boiler = Node(id: 1, title: "Котельная", address: "", type: "PowerSource", state: "Error",
                          currentSeason: "Winter")
        let house = Node(id: 2, title: "Дом", address: "", type: "House", state: "Error", currentSeason: "Summer")
        let office = Node(id: 3, title: "Офис", address: "", type: "Node", state: "Normal")

        var filter = NodeFilter()
        XCTAssertFalse(filter.isActive)
        filter.state = .error
        XCTAssertEqual([boiler, house, office].filter { filter.matches($0, groupMembers: nil) }.map(\.id), [1, 2])
        // Состояние И группа: в группе только дом и офис.
        XCTAssertEqual([boiler, house, office].filter { filter.matches($0, groupMembers: [2, 3]) }.map(\.id), [2])
        filter.season = "Winter"
        XCTAssertEqual([boiler, house, office].filter { filter.matches($0, groupMembers: nil) }.map(\.id), [1])
        filter.kind = "House"
        XCTAssertTrue([boiler, house, office].filter { filter.matches($0, groupMembers: nil) }.isEmpty)
    }

    func testPointSystemsAllowSeveral() {
        func point(_ id: Int, _ system: String, node: Int, link: String? = nil) -> MeasurePoint {
            return MeasurePoint(id: id, title: "", fullTitle: "", parentTitle: nil, address: nil, nodeId: node,
                                systemType: system, resourceKind: nil, state: "Normal", commLinkType: link)
        }
        let points = [point(1, "Heat", node: 10, link: "Gprs"), point(2, "HotWater", node: 10),
                      point(3, "ColdWater", node: 20, link: "Gprs")]

        var filter = PointFilter()
        filter.systems = ["Heat", "HotWater"]
        XCTAssertEqual(points.filter { filter.matches($0, groupMembers: nil) }.map(\.id), [1, 2])
        // Группа объектов — через объект точки.
        XCTAssertEqual(points.filter { filter.matches($0, groupMembers: [20]) }.map(\.id), [])
        filter.systems = []
        filter.commLink = "Gprs"
        XCTAssertEqual(points.filter { filter.matches($0, groupMembers: [20]) }.map(\.id), [3])
    }

    func testCalibrationFilter() {
        func item(_ id: Int, next: String?, capabilities: String = "Gauge", node: Int = 1) -> Equipment {
            return Equipment(id: id, modelTitle: "ТВ7", modelCapabilities: capabilities, serialNumber: nil,
                             lastCalibrationDay: nil, nextCalibrationDay: next,
                             places: [EquipmentPlace(nodeId: node, title: "")])
        }
        let overdue = item(1, next: "2026-09-01")
        let soon = item(2, next: "2027-03-01")
        let later = item(3, next: "2030-01-01")
        let noDate = item(4, next: nil)
        let modem = item(5, next: nil, capabilities: "CommunicationDevice", node: 2)
        let all = [overdue, soon, later, noDate, modem]
        let today = "2026-10-15"

        var filter = EquipmentFilter()
        filter.calibration = .overdue
        XCTAssertEqual(all.filter { filter.matches($0, groupMembers: nil, today: today) }.map(\.id), [1])
        // «Нужно поверить до» — вместе с уже просроченными; срок в сам выбранный день тоже попадает.
        filter.calibration = .dueBefore
        filter.dueBeforeDay = "2027-03-01"
        XCTAssertEqual(all.filter { filter.matches($0, groupMembers: nil, today: today) }.map(\.id), [1, 2])
        // «Дата не указана» — только средства измерения: у модема поверки нет.
        filter.calibration = .noDate
        XCTAssertEqual(all.filter { filter.matches($0, groupMembers: nil, today: today) }.map(\.id), [4])
        // Группа — по объектам, где установлено оборудование.
        filter.calibration = .all
        filter.dueBeforeDay = nil
        filter.groupId = 7
        XCTAssertEqual(all.filter { filter.matches($0, groupMembers: [2], today: today) }.map(\.id), [5])
    }

    func testFiltersAreSavedAndRestored() {
        var filter = PointFilter()
        filter.state = .problems
        filter.systems = ["Heat", "Electricity"]
        filter.groupId = 3
        XCTAssertEqual(PointFilter.decode(filter.encoded), filter)
        // Пусто или испорчено — фильтров нет, а не ошибка.
        XCTAssertEqual(PointFilter.decode(Data()), PointFilter())
        XCTAssertEqual(PointFilter.decode(Data("{".utf8)), PointFilter())
    }
}
