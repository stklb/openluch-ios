import XCTest
@testable import OpenLuch

// Хранилище списков без сети: правило автообновления, чтение кэша, очистка, точки объекта.
final class DataStoreTests: XCTestCase {

    private var cacheDirectory: URL!

    override func setUp() {
        super.setUp()
        cacheDirectory = FileManager.default.temporaryDirectory.appending(path: "DataStoreTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: cacheDirectory)
        super.tearDown()
    }

    /// Сессия без входа (токена нет) — значит, хранилище ничего не будет загружать из сети.
    private func makeSession() throws -> AppSession {
        let id = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DataStoreTests-\(id)"))
        return AppSession(tokenStore: KeychainTokenStore(service: "ru.stklb.luch.tests.\(id)"),
                          settingsStore: SettingsStore(defaults: defaults),
                          cacheStore: CacheStore(directory: cacheDirectory))
    }

    // MARK: - Правило автообновления

    func testAutoRefreshRule() {
        let now = Date()
        let hour: TimeInterval = 60 * 60
        func rule(_ connection: ConnectionKind, lifetime: TimeInterval?, updatedAgo: TimeInterval?,
                  attemptAgo: TimeInterval? = nil) -> Bool {
            return CacheFreshness.shouldRefresh(connection: connection, lifetime: lifetime,
                                                updatedAt: updatedAgo.map { now.addingTimeInterval(-$0) },
                                                lastAttemptAt: attemptAgo.map { now.addingTimeInterval(-$0) },
                                                now: now)
        }

        // Без сети или «Никогда» — не обновляем, даже если списка нет.
        XCTAssertFalse(rule(.noNetwork, lifetime: nil, updatedAgo: nil))
        XCTAssertFalse(rule(.cellular, lifetime: nil, updatedAgo: 100 * hour))

        // Wi-Fi, срок час: списка нет — загружаем; свежий — нет; старше часа — да.
        XCTAssertTrue(rule(.wifi, lifetime: hour, updatedAgo: nil))
        XCTAssertFalse(rule(.wifi, lifetime: hour, updatedAgo: 10 * 60))
        XCTAssertTrue(rule(.wifi, lifetime: hour, updatedAgo: hour + 1))

        // Сотовая сеть, срок 12 часов: устаревшее обновляем, а пустой список сам не грузим
        // (по сотовой первым загружается только список открытой вкладки).
        XCTAssertFalse(rule(.cellular, lifetime: 12 * hour, updatedAgo: 11 * hour))
        XCTAssertTrue(rule(.cellular, lifetime: 12 * hour, updatedAgo: 13 * hour))
        XCTAssertFalse(rule(.cellular, lifetime: 12 * hour, updatedAgo: nil))

        // После неудачи повтор не раньше срока, но и не позже чем через час.
        XCTAssertFalse(rule(.wifi, lifetime: 15 * 60, updatedAgo: nil, attemptAgo: 5 * 60))
        XCTAssertTrue(rule(.wifi, lifetime: 15 * 60, updatedAgo: nil, attemptAgo: 16 * 60))
        XCTAssertFalse(rule(.cellular, lifetime: 12 * hour, updatedAgo: 13 * hour, attemptAgo: 30 * 60))
        XCTAssertTrue(rule(.cellular, lifetime: 12 * hour, updatedAgo: 13 * hour, attemptAgo: hour + 1))
    }

    func testCacheLifetimeSettings() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "FreshnessTests-\(UUID().uuidString)"))

        // По умолчанию: Wi-Fi — час, сотовая — 12 часов.
        XCTAssertEqual(CacheFreshness.lifetime(for: .wifi, defaults: defaults), 60 * 60)
        XCTAssertEqual(CacheFreshness.lifetime(for: .cellular, defaults: defaults), 12 * 60 * 60)
        XCTAssertNil(CacheFreshness.lifetime(for: .noNetwork, defaults: defaults))

        defaults.set(15, forKey: CacheFreshness.wifiKey)
        defaults.set(CacheFreshness.never, forKey: CacheFreshness.cellularKey)
        XCTAssertEqual(CacheFreshness.lifetime(for: .wifi, defaults: defaults), 15 * 60)
        XCTAssertNil(CacheFreshness.lifetime(for: .cellular, defaults: defaults), "«Никогда»")

        // У каждого варианта — своя подпись, а не запасная «Раз в N мин».
        for minutes in CacheFreshness.wifiOptions + CacheFreshness.cellularOptions {
            XCTAssertFalse(CacheFreshness.title(minutes: minutes).hasSuffix(" мин"), "\(minutes)")
        }
        XCTAssertEqual(CacheFreshness.title(minutes: 60), "Раз в час")
        XCTAssertEqual(CacheFreshness.title(minutes: CacheFreshness.never), "Никогда")
    }

    func testBackgroundWakeDate() {
        let now = Date()
        let hour: TimeInterval = 60 * 60

        // Wi-Fi 6 ч, сотовая 24 ч, списки обновлены 2 часа назад → будить через 4 часа.
        let updated = now.addingTimeInterval(-2 * hour)
        XCTAssertEqual(CacheFreshness.nextWakeDate(listsUpdatedAt: [updated, updated, updated],
                                                   wifiLifetime: 6 * hour, cellularLifetime: 24 * hour, now: now),
                       now.addingTimeInterval(4 * hour))

        // Сотовая «Никогда» — считаем только по Wi-Fi; Wi-Fi сутки → реже будим.
        XCTAssertEqual(CacheFreshness.nextWakeDate(listsUpdatedAt: [now, now, now],
                                                   wifiLifetime: 24 * hour, cellularLifetime: nil, now: now),
                       now.addingTimeInterval(24 * hour))

        // Что-то уже устарело или списка нет — не раньше чем через 15 минут (чаще iOS не будит).
        XCTAssertEqual(CacheFreshness.nextWakeDate(listsUpdatedAt: [now, nil, now],
                                                   wifiLifetime: hour, cellularLifetime: 12 * hour, now: now),
                       now.addingTimeInterval(15 * 60))
    }

    func testListFileDates() async throws {
        let store = CacheStore(directory: cacheDirectory)
        XCTAssertEqual(store.listFilesModifiedAt(), [nil, nil, nil])
        try await store.saveMeasurePoints([])
        let dates = store.listFilesModifiedAt()
        XCTAssertNil(dates[0])
        XCTAssertNotNil(dates[1])
        XCTAssertNil(dates[2])
    }

    // MARK: - Фильтр по состоянию

    func testStateFilter() {
        let states: [ItemState] = [.normal, .warning, .error, .noData, .unknown, .error]
        // Ничего не отмечено — подходят все.
        XCTAssertEqual(states.filter { StateFilter.matches($0, selected: []) }.count, 6)
        // Несколько вариантов сразу: «Ошибка» и «Предупреждение» — все проблемные.
        XCTAssertEqual(states.filter { StateFilter.matches($0, selected: [.error, .warning]) }.count, 3)
        XCTAssertEqual(states.filter { StateFilter.matches($0, selected: [.error]) }.count, 2)
        XCTAssertEqual(states.filter { StateFilter.matches($0, selected: [.noData]) }.count, 1)
        // «Не определено» — отдельно от «Нет данных» (сервер присылает "None", а не "NoData").
        XCTAssertEqual(states.filter { StateFilter.matches($0, selected: [.unknown]) }.count, 1)
        XCTAssertEqual(states.filter { StateFilter.matches($0, selected: [.normal]) }.count, 1)
        // Отмечены все варианты — подходит любая запись.
        XCTAssertEqual(states.filter { StateFilter.matches($0, selected: Set(StateFilter.allCases)) }.count, 6)
    }

    // MARK: - Кэш

    /// Фильтр «Потребитель» в обе стороны: потребитель объекта — у его точек, потребитель точки — у её объекта.
    func testCustomerFilterWorksBothWays() async throws {
        let cache = CacheStore(directory: cacheDirectory)
        // Объект 1 — потребитель указан у объекта; объект 2 — у одной из точек.
        try await cache.saveNodes([
            Node(id: 1, title: "Котельная", address: "", type: "Node", state: "Normal", customerId: 100),
            Node(id: 2, title: "Дом", address: "", type: "House", state: "Normal")
        ], customers: [Customer(id: 100, title: "ТСЖ Ромашка")])
        try await cache.saveMeasurePoints([
            MeasurePoint(id: 10, title: "Отопление", fullTitle: "", parentTitle: nil, address: nil, nodeId: 1,
                         systemType: "Heat", resourceKind: nil, state: "Normal"),
            MeasurePoint(id: 20, title: "ХВС", fullTitle: "", parentTitle: nil, address: nil, nodeId: 2,
                         systemType: "ColdWater", resourceKind: nil, state: "Normal", customerId: 200),
            MeasurePoint(id: 21, title: "ГВС", fullTitle: "", parentTitle: nil, address: nil, nodeId: 2,
                         systemType: "HotWater", resourceKind: nil, state: "Normal")
        ], customers: [Customer(id: 200, title: "ИП Иванов")])

        let store = DataStore(session: try makeSession())
        await store.start()
        XCTAssertEqual(store.customers.map(\.title), ["ИП Иванов", "ТСЖ Ромашка"])

        var nodeFilter = NodeFilter()
        nodeFilter.customerId = 200
        let nodes = store.nodes.filter {
            nodeFilter.matches($0, groupMembers: nil, customerIds: store.customerIds(ofNode: $0))
        }
        // Объект находится по потребителю своей точки.
        XCTAssertEqual(nodes.map(\.id), [2])

        var pointFilter = PointFilter()
        pointFilter.customerId = 100
        let points = store.measurePoints.filter {
            pointFilter.matches($0, groupMembers: nil, customerIds: store.customerIds(ofPoint: $0))
        }
        // Точка находится по потребителю своего объекта.
        XCTAssertEqual(points.map(\.id), [10])
        // У точки 21 потребителя нет ни у неё, ни у объекта (он указан только у соседней точки).
        XCTAssertEqual(store.customerIds(ofPoint: store.measurePoint(withId: 21)!), [])
    }

    func testStartShowsCacheAndClearCacheEmptiesIt() async throws {
        let cache = CacheStore(directory: cacheDirectory)
        let savedAt = Date(timeIntervalSince1970: 1_790_000_000)
        try await cache.saveNodes([Node(id: 1, title: "Дом", address: "ул. Мира, 1", type: "House", state: "Normal")],
                                  savedAt: savedAt, responseBytes: 1_234)
        try await cache.saveMeasurePoints([
            MeasurePoint(id: 10, title: "ХВС", fullTitle: "Дом - ХВС", parentTitle: "Дом", address: nil, nodeId: 1,
                         systemType: "ColdWater", resourceKind: "Water", state: "Normal"),
            MeasurePoint(id: 11, title: "Отопление", fullTitle: "Дом - Отопление", parentTitle: "Дом", address: nil,
                         nodeId: 1, systemType: "Heat", resourceKind: "Water", state: "Error", deviceId: 56),
            MeasurePoint(id: 12, title: "ГВС", fullTitle: "Другой - ГВС", parentTitle: "Другой", address: nil,
                         nodeId: 2, systemType: "HotWater", resourceKind: "Water", state: "Normal")
        ])

        try await cache.saveEquipment([
            Equipment(id: 56, modelTitle: "КМ-5-4", modelCapabilities: "Gauge", serialNumber: "018395",
                      lastCalibrationDay: "2024-07-02", nextCalibrationDay: "2027-07-01",
                      places: [EquipmentPlace(nodeId: 1, title: "Дом")],
                      details: EquipmentDetails(modelLongTitle: nil, calibrationIntervalYears: 4, sealNumber: nil,
                                                calibrationOrganization: nil, calibrationResult: nil,
                                                calibrationRegisterNumber: nil, calibrationSyncDay: nil,
                                                networkAddress: nil, firmwareVersion: nil, hardwareVersion: nil,
                                                batteryVolts: nil, isBatteryLow: false, comment: nil,
                                                connections: [EquipmentConnection(commLinkType: "Gprs",
                                                                                  modemEquipmentId: 8919,
                                                                                  modemTitle: "ЛЭРС GSM Lite № 10084")]))
        ], savedAt: savedAt, responseBytes: 363_340)

        let store = DataStore(session: try makeSession())
        await store.start()

        XCTAssertTrue(store.isCacheLoaded)
        XCTAssertEqual(store.equipment.map { $0.serialNumber }, ["018395"])
        XCTAssertEqual(store.equipmentUpdatedAt, savedAt)
        XCTAssertEqual(store.estimatedDownloadBytes(for: .equipment), 363_340)
        XCTAssertEqual(store.nodes.map { $0.id }, [1])
        XCTAssertEqual(store.nodesUpdatedAt, savedAt)
        XCTAssertEqual(store.measurePoints.count, 3)
        XCTAssertGreaterThan(store.cacheSizeBytes, 0)
        // Размер прошлой загрузки известен точно — его и показываем у кнопки «Обновить».
        XCTAssertEqual(store.estimatedDownloadBytes(for: .nodes), 1_234)
        // У точек размер не сохранён — оценка по количеству.
        XCTAssertEqual(store.estimatedDownloadBytes(for: .measurePoints),
                       Int64(3 * DataStore.approximateBytesPerMeasurePoint))

        // Точки объекта — из кэша, по алфавиту.
        XCTAssertEqual(store.measurePoints(ofNode: 1).map { $0.title }, ["Отопление", "ХВС"])
        XCTAssertEqual(store.node(withId: 1)?.title, "Дом")

        // Приборы модема — по подключениям; оборудование по номеру (всё из кэша).
        XCTAssertEqual(store.equipment(usingModem: 8919).map { $0.id }, [56])
        XCTAssertEqual(store.equipment(withId: 56)?.modelTitle, "КМ-5-4")

        await store.clearCache()
        XCTAssertTrue(store.nodes.isEmpty)
        XCTAssertTrue(store.measurePoints.isEmpty)
        XCTAssertTrue(store.equipment.isEmpty)
        XCTAssertNil(store.nodesUpdatedAt)
        XCTAssertNil(store.equipmentUpdatedAt)
        XCTAssertEqual(store.cacheSizeBytes, 0)
        let nodesAfterClear = await cache.loadNodes()
        XCTAssertNil(nodesAfterClear)
    }

    func testWithoutLoginNothingIsDownloaded() async throws {
        let store = DataStore(session: try makeSession())
        store.listDidAppear(.nodes)
        await store.start()
        // Кэш пуст и вкладка открыта, но входа нет — загружать нечем, очередь пуста.
        XCTAssertFalse(store.isLoadingAnything)
        XCTAssertEqual(store.state(for: .nodes), .idle)
    }

    // MARK: - Сессия истекла

    func testSessionExpiredKeepsCacheAndExplainsWhy() async throws {
        let cache = CacheStore(directory: cacheDirectory)
        try await cache.saveNodes([Node(id: 1, title: "Дом", address: "", type: nil, state: nil)])

        let session = try makeSession()
        session.sessionExpired()

        XCTAssertFalse(session.isLoggedIn)
        XCTAssertEqual(session.logoutReason, "Сессия истекла. Войдите заново.")
        // Кэш остался — после повторного входа на тот же сервер он сразу пригодится.
        let nodes = await cache.loadNodes()
        XCTAssertNotNil(nodes)
        // Экран входа объясняет, почему пришлось войти заново.
        let loginModel = LoginViewModel(session: session)
        XCTAssertEqual(loginModel.errorMessage, "Сессия истекла. Войдите заново.")
    }
}
