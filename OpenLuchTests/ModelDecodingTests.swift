import XCTest
@testable import OpenLuch

// Проверяем, что настоящие ответы сервера правильно превращаются в наши модели.
final class ModelDecodingTests: XCTestCase {

    func testNodesAreDecoded() throws {
        let data = try SampleFiles.data(named: "nodes")
        let response = try ServerDateParser.makeDecoder().decode(NodeListResponse.self, from: data)
        let nodes = try XCTUnwrap(response.nodes)

        XCTAssertEqual(nodes.count, 2)

        let house = nodes[0]
        XCTAssertEqual(house.id, 1672)
        XCTAssertEqual(house.title, "ТСЖ \"Семь ветров\"")
        XCTAssertEqual(house.address, "Хабаровский Край, Город Хабаровск, Улица Тихоокеанская, 221б")
        XCTAssertEqual(house.kind, .house)
        XCTAssertEqual(house.itemState, .normal)

        // Сведения для карточки объекта.
        XCTAssertEqual(house.number, 727)
        XCTAssertEqual(house.comment, "демо-объект")
        XCTAssertEqual(house.responsibleName, "Иванов Иван Иванович")
        XCTAssertEqual(house.seasonTitle, "Летний")
        XCTAssertEqual(house.compositeState?.measurePointState, "Normal")
        XCTAssertEqual(house.compositeState?.incidentState, "None")
        XCTAssertNotNil(house.mapLocation)

        let boilerHouse = nodes[1]
        XCTAssertEqual(boilerHouse.kind, .regular)
        XCTAssertEqual(boilerHouse.itemState, .error)
    }

    func testMeasurePointsAreDecoded() throws {
        let data = try SampleFiles.data(named: "measurepoints")
        let response = try ServerDateParser.makeDecoder().decode(MeasurePointListResponse.self, from: data)
        let points = try XCTUnwrap(response.measurePoints)

        // В примере 5 точек; у каждой сервер прислал ~47 полей, а мы берём только нужные.
        XCTAssertEqual(points.count, 5)

        let first = points[0]
        XCTAssertFalse(first.title.isEmpty)
        XCTAssertFalse(first.fullTitle.isEmpty)
        XCTAssertNotNil(first.nodeId)

        let heating = try XCTUnwrap(points.first { $0.id == 686 })
        XCTAssertEqual(heating.commLinkTitle, "GPRS")
        // Устройство опроса — по нему карточка оборудования находит свою точку.
        XCTAssertEqual(heating.deviceId, 56)
        // Параметры, выбранные в ЛЭРС для показа: T_in, T_out, T_delta, T_cw… — в порядке выбора.
        XCTAssertEqual(heating.selectedParamsList, [1, 2, 47, 3, 4, 5, 6, 50, 9, 10, 11, 15])

        let states = points.map { $0.itemState }
        XCTAssertTrue(states.contains(.normal))
        XCTAssertTrue(states.contains(.error))
        XCTAssertTrue(states.contains(.noData))
        XCTAssertTrue(states.contains(.unknown))   // "None"
    }

    func testLoginResponseIsDecoded() throws {
        let data = try SampleFiles.data(named: "login-success")
        let response = try ServerDateParser.makeDecoder().decode(LoginResponse.self, from: data)

        XCTAssertEqual(response.oneTimePasswordRequired, false)
        XCTAssertNotNil(response.token)
        // Дата с 7 знаками долей секунды: "2027-10-09T21:38:19.3510055Z"
        XCTAssertNotNil(response.tokenExpiration)
    }

    func testUnknownValuesDoNotBreakDecoding() throws {
        // Сервер может прислать новое, незнакомое нам значение — разбор не должен падать.
        let json = """
        {"nodes": [{"id": 1, "title": "Новый объект", "address": "", "type": "Spaceship", "state": "Exploded"}]}
        """
        let response = try ServerDateParser.makeDecoder().decode(NodeListResponse.self, from: Data(json.utf8))
        let node = try XCTUnwrap(response.nodes?.first)

        XCTAssertEqual(node.kind, .unknown)
        XCTAssertEqual(node.itemState, .unknown)
    }
}
