import XCTest
@testable import OpenLuch

// Разбор работ на объектах (GET /api/v1/Core/NodeJobs). Пример — ответ my.lers.ru (имена заменены),
// вторая работа добавлена вручную: просроченная, без названия, точки и номера наряда.
final class NodeJobsTests: XCTestCase {

    func testDecodesJobs() throws {
        let data = try SampleFiles.data(named: "node-jobs")
        let jobs = try JSONDecoder().decode([NodeJobResponse].self, from: data).map { $0.makeJob() }

        XCTAssertEqual(jobs.count, 2)

        let first = jobs[0]
        XCTAssertEqual(first.nodeId, 1672)
        XCTAssertEqual(first.measurePointId, 686)
        XCTAssertEqual(first.displayTitle, "проверка")
        XCTAssertEqual(first.typeTitle, "Демонтаж")
        XCTAssertEqual(first.workOrderNumber, "1148")
        XCTAssertEqual(first.startDay, "2024-02-15")
        XCTAssertEqual(first.scheduledEndDay, "2024-03-20")
        // Пустые строки в конце описания убраны.
        XCTAssertEqual(first.description?.hasSuffix("м?/час"), true)
        XCTAssertFalse(first.isOverdue)

        let second = jobs[1]
        // Без названия — заголовок по типу работы; описание из одних переводов строки — как не указанное.
        XCTAssertEqual(second.displayTitle, "Ремонт")
        XCTAssertNil(second.measurePointId)
        XCTAssertNil(second.description)
        XCTAssertTrue(second.isOverdue)
    }

    /// Работы сохраняются вместе с объектами и читаются обратно.
    func testJobsAreSavedWithNodes() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let store = CacheStore(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }

        let job = NodeJob(id: 1, nodeId: 7, measurePointId: nil, title: "Проверка", typeTitle: nil,
                          workOrderNumber: nil, startDay: "2026-10-01", scheduledEndDay: "2026-10-20",
                          performerName: nil, description: nil, state: "Assigned")
        try await store.saveNodes([Node(id: 7, title: "Объект", address: "", type: nil, state: nil)], jobs: [job])

        let cached = await store.loadNodes()
        XCTAssertEqual(cached?.jobs, [job])
    }
}
