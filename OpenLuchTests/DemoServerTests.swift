import XCTest
@testable import OpenLuch

// Проверка на настоящем тестовом сервере разработчиков ЛЭРС: https://my.lers.ru (логин и пароль demo).
//
// Эти тесты ходят в интернет, поэтому по умолчанию ПРОПУСКАЮТСЯ — чтобы обычный запуск тестов
// не зависел от сети. Как включить:
//   • в Xcode: Product → Scheme → Edit Scheme… → Test → Arguments → Environment Variables:
//     добавить LERS_DEMO_TESTS = 1;
//   • из Терминала: TEST_RUNNER_LERS_DEMO_TESTS=1 xcodebuild test …
final class DemoServerTests: XCTestCase {

    private func makeClient() throws -> APIClient {
        guard ProcessInfo.processInfo.environment["LERS_DEMO_TESTS"] == "1" else {
            throw XCTSkip("Тесты с сервером my.lers.ru выключены (нужна переменная LERS_DEMO_TESTS=1)")
        }
        let address = ServerAddress(host: "my.lers.ru", port: 443, useHTTPS: true)
        return APIClient(baseURL: try XCTUnwrap(address.baseURL))
    }

    func testServerInfo() async throws {
        let info = try await makeClient().fetchServerInfo()
        XCTAssertNotNil(info.version)
    }

    func testWrongPassword() async throws {
        let client = try makeClient()
        do {
            _ = try await client.login(login: "demo", password: "wrong-password")
            XCTFail("Вход с неверным паролем должен завершиться ошибкой")
        } catch let error as APIError {
            XCTAssertEqual(error, .unauthorized(serverMessage: "Имя входа или пароль указаны неверно"))
        }
    }

    func testInvalidTokenGivesSessionExpired() async throws {
        let client = try makeClient()
        do {
            _ = try await client.fetchNodes(token: "not-a-real-token")
            XCTFail("Запрос с неверным токеном должен завершиться ошибкой")
        } catch let error as APIError {
            XCTAssertEqual(error, .unauthorized(serverMessage: nil))
        }
    }

    func testLoginAndLoadLists() async throws {
        let client = try makeClient()
        let token = try await client.login(login: "demo", password: "demo")
        XCTAssertFalse(token.isEmpty)

        // Объекты учёта — и запоминаем, как шёл прогресс.
        let progressLog = ProgressLog()
        let (nodes, nodesBytes) = try await client.fetchNodes(token: token, onProgress: { progress in
            progressLog.add(progress)
        })
        XCTAssertFalse(nodes.isEmpty)

        // Сервер сообщает размер ответа → последнее сообщение о прогрессе — «получено всё».
        let last = try XCTUnwrap(progressLog.last)
        XCTAssertNotNil(last.expectedBytes)
        XCTAssertEqual(last.receivedBytes, last.expectedBytes)
        XCTAssertEqual(last.fraction, 1.0)
        // Размер ответа, который запоминаем для подсказки «≈ X КБ», совпадает с полученным.
        XCTAssertEqual(Int64(nodesBytes), last.receivedBytes)

        // Последние данные точки «Отопление и ГВС» и единицы измерения сервера.
        let consumption = try await client.fetchLastConsumption(pointId: 686, token: token)
        XCTAssertFalse(consumption?.values?.isEmpty ?? true)
        let totals = try await client.fetchLastTotals(pointId: 686, token: token)
        XCTAssertFalse(totals?.values?.isEmpty ?? true)
        // Единицы у каждой точки свои: у тепловой — °C, у электрической — кВт·ч (и нет °C).
        let heatUnits = try await client.fetchUnits(pointId: 686, token: token)
        XCTAssertEqual(heatUnits.unitsByCategory["Temperature"], "CelsiusDegree")
        let electricityUnits = try await client.fetchUnits(pointId: 3736, token: token)
        XCTAssertEqual(electricityUnits.unitsByCategory["ActiveElectricalEnergy"], "KilowattHour")
        XCTAssertNil(electricityUnits.unitsByCategory["Temperature"])

        // Точки учёта: только обычные (квартирные сервер не присылает благодаря type=Regular).
        let (points, _) = try await client.fetchMeasurePoints(token: token)
        XCTAssertFalse(points.isEmpty)
        let nodeIds = Set(nodes.map { $0.id })
        for point in points {
            XCTAssertTrue(nodeIds.contains(point.nodeId ?? -1), "Точка \(point.id) не относится ни к одному объекту")
        }

        // Справочник оборудования: у каждой единицы есть модель, у установленной — название объекта.
        let (equipment, equipmentBytes) = try await client.fetchEquipment(token: token)
        XCTAssertFalse(equipment.isEmpty)
        XCTAssertGreaterThan(equipmentBytes, 0)
        XCTAssertFalse(equipment.contains { $0.modelTitle == "Модель не указана" })
        XCTAssertTrue(equipment.contains { !$0.places.isEmpty })

        // Датчики точки «Отопление и ГВС»: на подаче и обратке по три (температура, давление, объём).
        let (sensors, sensorsBytes) = try await client.fetchPointSensors(pointId: 686, token: token)
        XCTAssertEqual(sensors.filter { $0.pipe == .supply }.count, 3)
        XCTAssertEqual(sensors.filter { $0.pipe == .return }.count, 3)
        XCTAssertTrue(sensors.allSatisfy { $0.equipment != nil })
        XCTAssertGreaterThan(sensorsBytes, 0)
    }

    /// Группы объектов, «О сервере», НС точки и ручной опрос (на demo опрос невозможен — проверяем текст отказа).
    func testGroupsServerDetailsIncidentsAndPoll() async throws {
        let client = try makeClient()
        let token = try await client.login(login: "demo", password: "demo")

        let groups = try await client.fetchNodeGroups(token: token)
        XCTAssertFalse(groups.isEmpty)
        XCTAssertTrue(groups.allSatisfy { !$0.memberIds.isEmpty })

        let user = try await client.fetchCurrentUser(token: token)
        XCTAssertEqual(user.displayName, "Гостевой пользователь")
        XCTAssertTrue(user.isAllowed(.manualPoll))
        XCTAssertTrue(user.isAllowed(.printReport))
        XCTAssertTrue(user.isAllowed(.viewIncident))

        // Имя и права приходят и вместе со списком объектов (автообновление справочников).
        let cacheDirectory = FileManager.default.temporaryDirectory.appending(path: "NodesUser-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: cacheDirectory)
        }
        let result = try await ListRefresher.downloadAndSave(.nodes, client: client, token: token,
                                                             cacheStore: CacheStore(directory: cacheDirectory))
        guard case .nodes(_, _, let userWithNodes, _, _) = result else {
            return XCTFail("ожидался список объектов")
        }
        XCTAssertEqual(userWithNodes, user)

        let details = try await client.fetchServerDetails(token: token)
        XCTAssertNotNil(details.version)
        XCTAssertNotNil(details.license?.nodesUsageText)

        // Активных НС на demo нет — пустой список разбирается.
        let incidents = try await client.fetchActiveIncidents(pointId: 686, token: token)
        XCTAssertNotNil(incidents)

        // У demo-приборов нет связи — сервер отказывает понятным текстом (его и покажем пользователю).
        do {
            _ = try await client.startCurrentsPoll(pointId: 686, token: token)
        } catch let error as APIError {
            guard case .serverError(let message) = error else {
                return XCTFail("Ожидался текст ошибки от сервера, а пришло: \(error)")
            }
            XCTAssertFalse(message.isEmpty)
        }
    }

    /// Фоновое обновление (то, что запускает iOS): все три списка скачиваются и сохраняются в кэш.
    @MainActor
    func testBackgroundRefreshSavesAllLists() async throws {
        _ = try makeClient()
        let id = UUID().uuidString
        let keychain = KeychainTokenStore(service: "ru.stklb.luch.tests.\(id)")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "BackgroundRefreshTests-\(id)"))
        let cacheDirectory = FileManager.default.temporaryDirectory.appending(path: "Background-\(id)")
        defer {
            try? keychain.delete()
            try? FileManager.default.removeItem(at: cacheDirectory)
        }
        let session = AppSession(tokenStore: keychain, settingsStore: SettingsStore(defaults: defaults),
                                 cacheStore: CacheStore(directory: cacheDirectory))
        try await session.logIn(address: try ServerAddress(parsing: "https://my.lers.ru"),
                                login: "demo", password: "demo", onProgress: { _ in })

        // Сразу после входа приложение само запрашивает имя и права (без участия «Настроек»).
        for _ in 0..<50 where session.displayName == nil {
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertEqual(session.displayName, "Гостевой пользователь")

        await BackgroundRefresh.run(session: session, defaults: defaults, connection: .wifi)

        let nodes = await session.cacheStore.loadNodes()
        XCTAssertFalse(nodes?.nodes.isEmpty ?? true)
        XCTAssertFalse(nodes?.groups?.isEmpty ?? true, "группы сохраняются вместе с объектами")
        let points = await session.cacheStore.loadMeasurePoints()
        XCTAssertFalse(points?.measurePoints.isEmpty ?? true)
        let equipment = await session.cacheStore.loadEquipment()
        XCTAssertFalse(equipment?.equipment.isEmpty ?? true)
        XCTAssertNotNil(BackgroundRefresh.lastSuccessAt(defaults: defaults))
        XCTAssertNil(BackgroundRefresh.lastError(defaults: defaults))
        // Исход пробуждения записан (для «Настроек» и уведомления).
        let report = try XCTUnwrap(BackgroundRefresh.lastReport(defaults: defaults))
        XCTAssertTrue(report.hasPrefix("Обновлено. Wi-Fi. Обновлены: объекты, точки, оборудование."), report)

        // Второе пробуждение сразу следом — всё свежее, ничего не скачивается.
        await BackgroundRefresh.run(session: session, defaults: defaults, connection: .wifi)
        let secondReport = try XCTUnwrap(BackgroundRefresh.lastReport(defaults: defaults))
        XCTAssertTrue(secondReport.hasPrefix("Ничего не обновлено. Wi-Fi: списки ещё свежие."), secondReport)
    }

    /// PDF-отчёт точки «Отопление и ГВС»: список отчётов → формирование → скачивание PDF.
    func testReportGeneration() async throws {
        let client = try makeClient()
        let token = try await client.login(login: "demo", password: "demo")

        // Список отчётов: только ведомости (акты отброшены), датчики — в том же ответе.
        let (reports, sensors, bytes) = try await client.fetchPointReports(pointId: 686, token: token)
        XCTAssertTrue(reports.contains { $0.id == 38 }, "Системная ведомость параметров назначена точке")
        XCTAssertFalse(reports.contains { $0.id == 1 }, "Акты не показываем")
        XCTAssertFalse(sensors.isEmpty)
        XCTAssertGreaterThan(bytes, 0)

        // Суточная ведомость за неделю — даты так же, как их собирает окно отчёта.
        let calendar = ReportPeriod.calendar
        let period = try XCTUnwrap(ReportPeriod.make(.lastSevenDays, today: Date(), calendar: calendar))
        let dates = period.serverDates(for: .day, calendar: calendar)
        let link = try await client.generateReport(reportId: 38, dataType: .day, start: dates.start, end: dates.end,
                                                   pointId: 686, token: token)
        XCTAssertTrue(link.fileName?.hasSuffix(".pdf") ?? false)

        let progressLog = ProgressLog()
        let pdf = try await client.downloadReportFile(link: link, token: token, onProgress: { progress in
            progressLog.add(progress)
        })
        XCTAssertTrue(pdf.starts(with: Data("%PDF".utf8)))
        XCTAssertGreaterThan(pdf.count, 10_000)
        // Размер файла сервер сообщает заранее — значит, будет полоса «X КБ из Y КБ».
        XCTAssertEqual(progressLog.last?.expectedBytes, Int64(pdf.count))

        // Акт этим запросом не формируется — понятный текст ошибки от сервера.
        do {
            _ = try await client.generateReport(reportId: 1, dataType: .day, start: dates.start, end: dates.end,
                                                pointId: 686, token: token)
            XCTFail("Акт не должен формироваться как ведомость")
        } catch let error as APIError {
            XCTAssertEqual(error, .serverError(message: "Выбранный отчёт не является ведомостью параметров."))
        }
    }
}

// Вкладки после входа: хранилище списков загружает объекты, точки и оборудование с my.lers.ru
// и сохраняет их в кэш.
final class DemoServerDataStoreTests: XCTestCase {

    func testRefreshAllDownloadsAndCachesAllLists() async throws {
        guard ProcessInfo.processInfo.environment["LERS_DEMO_TESTS"] == "1" else {
            throw XCTSkip("Тесты с сервером my.lers.ru выключены (нужна переменная LERS_DEMO_TESTS=1)")
        }
        let id = UUID().uuidString
        let keychain = KeychainTokenStore(service: "ru.stklb.luch.tests.\(id)")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DemoServerDataStoreTests-\(id)"))
        let cacheDirectory = FileManager.default.temporaryDirectory.appending(path: "DemoDataStore-\(id)")
        defer {
            try? keychain.delete()
            try? FileManager.default.removeItem(at: cacheDirectory)
        }
        let session = AppSession(tokenStore: keychain, settingsStore: SettingsStore(defaults: defaults),
                                 cacheStore: CacheStore(directory: cacheDirectory))
        try await session.logIn(address: try ServerAddress(parsing: "https://my.lers.ru"),
                                login: "demo", password: "demo", onProgress: { _ in })

        let store = DataStore(session: session)
        await store.start()
        store.refreshAll()
        for _ in 0..<300 where store.isLoadingAnything {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(store.isLoadingAnything, "Загрузка не закончилась за 30 секунд")
        XCTAssertEqual(store.state(for: .nodes), .idle)
        XCTAssertEqual(store.state(for: .measurePoints), .idle)
        XCTAssertEqual(store.state(for: .equipment), .idle)
        XCTAssertFalse(store.nodes.isEmpty)
        XCTAssertFalse(store.measurePoints.isEmpty)
        XCTAssertFalse(store.equipment.isEmpty)
        XCTAssertNotNil(store.nodesUpdatedAt)
        XCTAssertNotNil(store.equipmentUpdatedAt)

        // Сохранено на телефоне вместе с размером ответа.
        let cached = await session.cacheStore.loadMeasurePoints()
        XCTAssertEqual(cached?.measurePoints.count, store.measurePoints.count)
        XCTAssertNotNil(cached?.responseBytes)
        await store.stop()
    }

    func testRejectedTokenReturnsToLoginAndKeepsCache() async throws {
        guard ProcessInfo.processInfo.environment["LERS_DEMO_TESTS"] == "1" else {
            throw XCTSkip("Тесты с сервером my.lers.ru выключены (нужна переменная LERS_DEMO_TESTS=1)")
        }
        let id = UUID().uuidString
        let keychain = KeychainTokenStore(service: "ru.stklb.luch.tests.\(id)")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DemoServerDataStoreTests-\(id)"))
        let cacheDirectory = FileManager.default.temporaryDirectory.appending(path: "DemoDataStore-\(id)")
        defer {
            try? keychain.delete()
            try? FileManager.default.removeItem(at: cacheDirectory)
        }
        // «Вход выполнен» с токеном, который сервер не знает (как будто срок токена истёк).
        try keychain.save("not-a-real-token")
        let settings = SettingsStore(defaults: defaults)
        settings.saveServerAddress(try ServerAddress(parsing: "https://my.lers.ru"))
        let cache = CacheStore(directory: cacheDirectory)
        try await cache.saveNodes([Node(id: 1, title: "Из кэша", address: "", type: nil, state: nil)])
        let session = AppSession(tokenStore: keychain, settingsStore: settings, cacheStore: cache)
        XCTAssertTrue(session.isLoggedIn)

        let store = DataStore(session: session)
        await store.start()
        store.refresh(.nodes)
        for _ in 0..<150 where session.isLoggedIn {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(session.isLoggedIn, "После ответа 401 должен открыться экран входа")
        XCTAssertEqual(session.logoutReason, "Сессия истекла. Войдите заново.")
        XCTAssertNil(keychain.load())
        let cachedNodes = await cache.loadNodes()
        XCTAssertEqual(cachedNodes?.nodes.first?.title, "Из кэша", "Кэш при истечении сессии сохраняется")
    }
}

// Вход и выход так же, как с экрана входа: LoginViewModel → AppSession → my.lers.ru.
// Отдельные «песочницы» для Keychain, настроек и кэша — настоящие данные приложения не трогаем.
// В конце модели удаляются из памяти — раньше именно здесь приложение падало
// (см. «nonisolated deinit» в LoginViewModel и AppSession).
@MainActor
final class DemoServerLoginScreenTests: XCTestCase {

    func testLogInAndLogOutLikeLoginScreen() async throws {
        guard ProcessInfo.processInfo.environment["LERS_DEMO_TESTS"] == "1" else {
            throw XCTSkip("Тесты с сервером my.lers.ru выключены (нужна переменная LERS_DEMO_TESTS=1)")
        }
        let id = UUID().uuidString
        let keychain = KeychainTokenStore(service: "ru.stklb.luch.tests.\(id)")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "DemoServerLoginScreenTests-\(id)"))
        let cacheDirectory = FileManager.default.temporaryDirectory.appending(path: "DemoLogin-\(id)")
        defer {
            try? keychain.delete()
            try? FileManager.default.removeItem(at: cacheDirectory)
        }

        var session: AppSession? = AppSession(tokenStore: keychain,
                                              settingsStore: SettingsStore(defaults: defaults),
                                              cacheStore: CacheStore(directory: cacheDirectory))
        var model: LoginViewModel? = LoginViewModel(session: try XCTUnwrap(session))

        // Заполняем форму, как пользователь, и нажимаем «Войти».
        // Ссылка «Демо-доступ» заполняет поля и сразу проверяет сервер — он должен ответить своей версией.
        model?.fillDemoAccess()
        XCTAssertEqual(model?.login, "demo")
        for _ in 0..<150 {
            if case .checking = model?.serverCheck {
                try await Task.sleep(for: .milliseconds(100))
            } else {
                break
            }
        }
        guard case .available(let version) = model?.serverCheck else {
            return XCTFail("Проверка сервера: \(String(describing: model?.serverCheck))")
        }
        XCTAssertFalse(version.isEmpty)
        model?.logIn()

        for _ in 0..<150 where model?.isLoggingIn == true {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(model?.isLoggingIn, false, "Вход не закончился за 15 секунд")
        XCTAssertNil(model?.errorMessage)
        XCTAssertEqual(session?.isLoggedIn, true)
        XCTAssertEqual(model?.password, "", "Пароль после входа должен стереться из формы")
        XCTAssertNotNil(keychain.load())

        // Выход: токен стёрт, адрес и логин остались.
        await session?.logOut()
        XCTAssertEqual(session?.isLoggedIn, false)
        XCTAssertNil(keychain.load())
        let loginAgain = LoginViewModel(session: try XCTUnwrap(session))
        XCTAssertEqual(loginAgain.enteredAddress, ServerAddress(host: "my.lers.ru", port: 443, useHTTPS: true))
        XCTAssertEqual(loginAgain.login, "demo")
        XCTAssertEqual(loginAgain.password, "")

        // Удаляем модели из памяти — здесь раньше было падение.
        model = nil
        session = nil
    }
}

/// Потокобезопасный журнал сообщений о прогрессе (они приходят из фонового потока).
private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [DownloadProgress] = []

    func add(_ progress: DownloadProgress) {
        lock.lock()
        items.append(progress)
        lock.unlock()
    }

    var last: DownloadProgress? {
        lock.lock()
        defer { lock.unlock() }
        return items.last
    }
}
