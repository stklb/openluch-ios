import XCTest
@testable import OpenLuch

// Доработки 2026-10-04: группы объектов, «О сервере» (ServerInfo/Extra), ручной опрос,
// нештатные ситуации точки. Примеры ответов — настоящие ответы my.lers.ru, кроме НС:
// на demo активных НС нет, пример incidents-active.json составлен по описанию в swagger.
final class ServerFeaturesTests: XCTestCase {

    // MARK: - Группы объектов

    func testNodeGroupsAreDecoded() throws {
        let response = try JSONDecoder().decode([NodeGroupResponse].self,
                                                from: try SampleFiles.data(named: "node-groups"))
        let groups = NodeGroupResponse.makeGroups(from: response)
        XCTAssertEqual(groups, [NodeGroup(id: 132, title: "Демо-объекты", memberIds: [1672])])
    }

    func testNodeGroupsAreSortedAndUntitledGetName() throws {
        let json = #"[{"nodeGroup":{"id":2,"title":"Котельные"},"members":[5,6]},{"nodeGroup":{"id":1,"title":"  "},"members":null},{"nodeGroup":{"id":3,"title":"Аптеки"},"members":[]}]"#
        let groups = NodeGroupResponse.makeGroups(from: try JSONDecoder().decode([NodeGroupResponse].self,
                                                                                 from: Data(json.utf8)))
        XCTAssertEqual(groups.map { $0.title }, ["Аптеки", "Группа № 1", "Котельные"])
        XCTAssertEqual(groups[1].memberIds, [])
    }

    // MARK: - О сервере

    func testServerDetailsAreBuiltFromExtraInfo() throws {
        let extra = try JSONDecoder().decode(ServerExtraInfoResponse.self,
                                             from: try SampleFiles.data(named: "server-extra"))
        let info = try JSONDecoder().decode(ServerInfo.self, from: try SampleFiles.data(named: "serverinfo"))
        let details = extra.makeDetails(serverInfo: info, savedAt: Date(timeIntervalSince1970: 1_790_000_000))

        XCTAssertNotNil(details.version)
        let license = try XCTUnwrap(details.license)
        XCTAssertEqual(license.typeTitle, "Корпоративная")
        XCTAssertEqual(license.owner, #"ООО "ЛЭРС""#)
        XCTAssertEqual(license.nodesUsageText, "556 из 600")
        XCTAssertNil(license.expireDay, "«0001-01-01» — бессрочная лицензия")
        XCTAssertEqual(license.subscriptionExpireDay, "2028-08-01")
        XCTAssertEqual(details.timeZoneTitle, "UTC+10")
        XCTAssertEqual(details.defaultTerritory, "Хабаровск")
    }

    func testTimeZoneTitle() {
        func details(offset: Int?) -> ServerDetails {
            return ServerDetails(savedAt: Date(), version: nil, fullVersion: nil, license: nil,
                                 timeZoneOffsetHours: offset, defaultTerritory: nil)
        }
        XCTAssertEqual(details(offset: -3).timeZoneTitle, "UTC−3")
        XCTAssertEqual(details(offset: 0).timeZoneTitle, "UTC")
        XCTAssertNil(details(offset: nil).timeZoneTitle)
    }

    // MARK: - Пользователь: имя и права

    func testCurrentLoginDisplayNameIsDecoded() throws {
        // Сокращённый настоящий ответ my.lers.ru (GET /api/v1/Login/Current).
        let json = #"{"account":{"login":"demo","displayName":"Гостевой пользователь","isAdmin":false,"eMail":""},"permissions":["ReadNode"],"accountGroups":[{"title":"Посетители"}]}"#
        let user = try JSONDecoder().decode(CurrentLoginResponse.self, from: Data(json.utf8)).makeUser()
        XCTAssertEqual(user.displayName, "Гостевой пользователь")
        XCTAssertFalse(user.isAdmin)
        XCTAssertEqual(user.permissions, ["ReadNode"])

        let empty = try JSONDecoder().decode(CurrentLoginResponse.self, from: Data(#"{"account":null}"#.utf8))
        XCTAssertEqual(empty.makeUser(), CurrentUser(displayName: nil, isAdmin: false, permissions: []))
    }

    func testPermissions() {
        let viewer = CurrentUser(displayName: nil, isAdmin: false, permissions: ["ViewData", "ViewIncident"])
        XCTAssertTrue(viewer.isAllowed(.viewIncident))
        XCTAssertFalse(viewer.isAllowed(.manualPoll))
        XCTAssertFalse(viewer.isAllowed(.printReport))

        // Администратору разрешено всё, даже если списка прав нет.
        let admin = CurrentUser(displayName: nil, isAdmin: true, permissions: [])
        XCTAssertTrue(admin.isAllowed(.manualPoll))
    }

    // MARK: - Ручной опрос

    func testNewRecordAfterPoll() {
        XCTAssertTrue(PointPollModel.isNewRecord("2026-10-04T10:05:00", comparedTo: "2026-10-04T09:00:00"))
        XCTAssertFalse(PointPollModel.isNewRecord("2026-10-04T09:00:00", comparedTo: "2026-10-04T09:00:00"))
        XCTAssertTrue(PointPollModel.isNewRecord("2026-10-04T09:00:00", comparedTo: nil), "раньше записей не было")
        XCTAssertFalse(PointPollModel.isNewRecord(nil, comparedTo: "2026-10-04T09:00:00"))
    }

    // MARK: - Нештатные ситуации

    func testIncidentsAreDecodedAndSorted() throws {
        let incidents = try JSONDecoder().decode([Incident].self, from: try SampleFiles.data(named: "incidents-active"))
        XCTAssertEqual(incidents.count, 2)

        let sorted = PointIncidentsModel.sorted(incidents)
        XCTAssertEqual(sorted.map { $0.id }, [502, 501], "критическая — первой")

        let warning = try XCTUnwrap(incidents.first { $0.id == 501 })
        XCTAssertEqual(warning.title, "Температура выше максимума")
        XCTAssertEqual(warning.importanceTitle, "Предупреждение")
        XCTAssertNil(warning.realEndDate, "«0001-01-01» — НС продолжается")

        let critical = try XCTUnwrap(incidents.first { $0.id == 502 })
        XCTAssertEqual(critical.title, "Получены недостоверные данные", "нет краткого описания — берём полное")
        XCTAssertEqual(critical.realEndDate, "2026-10-03T09:00:00")
    }
}
