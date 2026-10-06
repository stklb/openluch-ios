import XCTest
@testable import OpenLuch

// Проверяем кэш на временной папке, чтобы не трогать настоящий кэш приложения.
final class CacheStoreTests: XCTestCase {

    private var temporaryDirectory: URL!
    private var store: CacheStore!

    override func setUp() {
        super.setUp()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: "CacheStoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        store = CacheStore(directory: temporaryDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        super.tearDown()
    }

    func testNodesAreSavedAndLoaded() async throws {
        let nodes = [
            Node(id: 1, title: "Котельная", address: "ул. Ленина, 1", type: "PowerSource", state: "Normal"),
            Node(id: 2, title: "Дом", address: "", type: "House", state: "Error")
        ]
        let savedAt = Date(timeIntervalSince1970: 1_790_000_000)

        try await store.saveNodes(nodes, savedAt: savedAt)
        let loaded = await store.loadNodes()
        let cached = try XCTUnwrap(loaded)

        XCTAssertEqual(cached.nodes, nodes)
        XCTAssertEqual(cached.savedAt, savedAt)
    }

    func testMeasurePointsAreSavedAndLoaded() async throws {
        // Берём настоящий ответ сервера, сохраняем и читаем обратно.
        let data = try SampleFiles.data(named: "measurepoints")
        let points = try XCTUnwrap(
            try ServerDateParser.makeDecoder().decode(MeasurePointListResponse.self, from: data).measurePoints
        )

        try await store.saveMeasurePoints(points)
        let loaded = await store.loadMeasurePoints()
        let cached = try XCTUnwrap(loaded)

        XCTAssertEqual(cached.measurePoints, points)

        // Кэш хранит только нужные поля — он должен быть намного меньше ответа сервера.
        let cacheSize = await store.totalSizeInBytes()
        XCTAssertGreaterThan(cacheSize, 0)
        XCTAssertLessThan(cacheSize, Int64(data.count) / 3)
    }

    func testCorruptedFileReturnsNil() async throws {
        try await store.saveNodes([Node(id: 1, title: "Объект", address: "", type: nil, state: nil)])
        // Портим файл, как будто запись оборвалась.
        try Data("{ это не JSON".utf8).write(to: temporaryDirectory.appending(path: "nodes.json"))

        let cached = await store.loadNodes()
        XCTAssertNil(cached)
    }

    func testClearRemovesEverything() async throws {
        try await store.saveNodes([Node(id: 1, title: "Объект", address: "", type: nil, state: nil)])
        try await store.saveMeasurePoints([])

        try await store.clear()

        let nodes = await store.loadNodes()
        let points = await store.loadMeasurePoints()
        let size = await store.totalSizeInBytes()
        XCTAssertNil(nodes)
        XCTAssertNil(points)
        XCTAssertEqual(size, 0)
    }

    func testClearOnEmptyCacheDoesNotFail() async throws {
        try await store.clear()
    }

    func testCacheIsExcludedFromBackup() async throws {
        try await store.saveNodes([])
        let values = try temporaryDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }
}
