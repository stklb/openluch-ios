import Foundation
import Observation
import UIKit

// Хранилище списков объектов, точек учёта и оборудования для вкладок «Объекты», «Точки»,
// «Оборудование» и «Настройки».
// Один объект на время входа (создаётся в MainTabView, передаётся экранам через .environment).
//
// Главные правила (см. PLAN.md, «⚠️ ВАЖНО» и «Правила обновления кэша»):
//   • сначала показываем кэш с телефона — сразу, без сети; загрузка с сервера идёт в фоне;
//   • ошибка загрузки НЕ стирает показанные данные;
//   • одновременно загружается только один список (на 2G две загрузки мешали бы друг другу),
//     остальные ждут в очереди;
//   • автоматически — когда истёк срок годности списка для текущего подключения
//     (Wi-Fi и сотовая сеть — свои сроки, выбираются в «Настройках», см. CacheFreshness);
//   • первая загрузка (кэш пуст): по сотовой сети — только список открытой вкладки,
//     по Wi-Fi — все списки (сначала объекты, потом точки, потом оборудование);
//   • вручную — только через «Очистить кэш» в «Настройках» (кнопку «Обновить» убрали 2026-10-06;
//     жест «потянуть вниз» намеренно не делаем);
//   • сервер ответил 401 (сессия истекла) — возвращаемся на экран входа, кэш сохраняем.

/// Какой список.
enum ListKind: Equatable, Sendable {
    case nodes
    case measurePoints
    case equipment
}

/// Что сейчас происходит с одним списком.
enum ListLoadState: Equatable {
    /// Ничего не загружается.
    case idle
    /// Ждёт своей очереди: сейчас загружается другой список.
    case queued
    /// Загружается; в DownloadProgress — сколько уже получено.
    case loading(DownloadProgress)
    /// Последняя попытка не удалась. Старые данные (если были) по-прежнему показываются.
    case failed(message: String)
}

@Observable
final class DataStore {

    /// Как часто проверять тип подключения и не пора ли обновить списки.
    static let checkInterval: Duration = .seconds(15)

    /// Примерный размер одного объекта и одной точки в ответе сервера (замер на my.lers.ru,
    /// docs/api-notes.md) — чтобы оценить объём загрузки, если точный размер ещё неизвестен.
    static let approximateBytesPerNode = 1_300
    static let approximateBytesPerMeasurePoint = 2_000
    /// На оборудование — вместе с описаниями моделей, которые приходят в том же ответе
    /// (на my.lers.ru: 363 КБ на 64 единицы).
    static let approximateBytesPerEquipment = 5_700

    // MARK: - Данные для экранов

    /// Объекты учёта, отсортированные по названию.
    private(set) var nodes: [Node] = []
    /// Когда список объектов был получен с сервера. nil — ещё ни разу (кэш пуст).
    private(set) var nodesUpdatedAt: Date?
    private(set) var nodesState: ListLoadState = .idle
    /// Группы объектов (для выбора группы во вкладке «Объекты»). Пусто — групп нет или ещё не загружены.
    private(set) var nodeGroups: [NodeGroup] = []
    /// Незавершённые работы на объектах (карточка объекта, вкладка «Работы»). Приходят и обновляются вместе
    /// со списком объектов. nil — ещё ни разу не получали (кэш пуст или сохранён прошлой версией приложения).
    private(set) var nodeJobs: [NodeJob]?
    /// Потребители, указанные у объектов или точек, по названию — варианты фильтра «Потребитель».
    private(set) var customers: [Customer] = []

    /// Точки учёта, отсортированные по полному названию.
    private(set) var measurePoints: [MeasurePoint] = []
    private(set) var measurePointsUpdatedAt: Date?
    private(set) var measurePointsState: ListLoadState = .idle

    /// Оборудование, отсортированное по модели и заводскому номеру.
    private(set) var equipment: [Equipment] = []
    private(set) var equipmentUpdatedAt: Date?
    private(set) var equipmentState: ListLoadState = .idle

    /// false — кэш с телефона ещё читается (доли секунды при запуске).
    private(set) var isCacheLoaded = false
    /// Тип подключения (обновляется раз в 15 секунд).
    private(set) var connection: ConnectionKind = .noNetwork
    /// Сколько места занимает кэш на телефоне.
    private(set) var cacheSizeBytes: Int64 = 0

    // MARK: - Внутреннее состояние

    private let session: AppSession
    private let cacheStore: CacheStore

    /// Потребители из ответов сервера: объектов и точек (сервер присылает их вместе со списками).
    private var nodeCustomers: [Customer] = []
    private var pointCustomers: [Customer] = []
    /// Названия пользовательских атрибутов точек: код → название (приходят вместе со списком точек).
    private(set) var pointAttributeTitles: [String: String] = [:]
    /// Для фильтра «Потребитель» в обе стороны (см. rebuildCustomerIndex):
    /// объект → потребители, указанные у него и у его точек; объект → его собственный потребитель.
    private var customerIdsByNode: [Int: Set<Int>] = [:]
    private var nodeCustomerById: [Int: Int] = [:]

    /// Размер ответа сервера при последней загрузке — для оценки «≈ X МБ».
    private var nodesResponseBytes: Int?
    private var measurePointsResponseBytes: Int?
    private var equipmentResponseBytes: Int?

    /// Когда последний раз пробовали загрузить (удачно или нет) — чтобы автообновление
    /// после неудачи не повторялось слишком часто (см. CacheFreshness.shouldRefresh).
    private var nodesLastAttemptAt: Date?
    private var measurePointsLastAttemptAt: Date?
    private var equipmentLastAttemptAt: Date?

    /// Очередь загрузок и загрузка, которая идёт сейчас.
    private var queue: [ListKind] = []
    private var currentKind: ListKind?
    private var currentTask: Task<Void, Never>?

    /// Список, который пользователь сейчас видит (для правила первой загрузки).
    private var visibleList: ListKind?

    private var isStarted = false
    /// Когда списки последний раз читались из кэша (чтобы понять, обновила ли их iOS в фоне).
    private var cacheReadAt = Date.distantPast
    /// true — пользователь вышел или сессия истекла: больше ничего не загружаем.
    private var isStopped = false
    /// true — идёт очистка кэша: новые загрузки не начинаем, пока она не закончится.
    private var isClearingCache = false

    /// «Дополнительное время» у iOS: пока идут загрузки, приложение просит не замораживать его
    /// сразу после ухода в другое приложение (обычно iOS даёт около 30 секунд, сколько — решает она).
    /// .invalid — сейчас не просим.
    private var backgroundTimeID = UIBackgroundTaskIdentifier.invalid
    /// true — время у iOS кончилось посреди загрузки: новые не начинаем, пока пользователь не вернётся.
    private var isPausedInBackground = false

    // Явно говорим: при удалении объекта из памяти ничего не нужно делать в главном потоке.
    // Без этого на iOS 26 приложение падает при удалении объекта (см. CLAUDE.md).
    nonisolated deinit {}

    init(session: AppSession) {
        self.session = session
        self.cacheStore = session.cacheStore
    }

    // MARK: - Запуск

    /// Вызывается один раз при появлении основного экрана: читает кэш, запускает
    /// автообновление и наблюдение за подключением.
    func start() async {
        if isStarted {
            return
        }
        isStarted = true
        connection = NetworkMonitor.shared.connectionKind

        // 1. Сразу показываем то, что сохранено на телефоне.
        await readCache()
        isCacheLoaded = true

        // 2. Если кэш открытой вкладки пуст — загружаем её список при любом подключении.
        if let visibleList {
            loadIfNeverLoaded(visibleList)
        }
        // 3. Обновляем то, у чего истёк срок годности для текущего подключения.
        autoRefreshIfNeeded()

        // 4. Дальше раз в 15 секунд проверяем подключение и не пора ли обновить.
        startPeriodicChecks()
    }

    /// Прочитать все списки из кэша на телефоне.
    private func readCache() async {
        cacheReadAt = Date()
        if let cached = await cacheStore.loadNodes() {
            nodes = cached.nodes
            nodesUpdatedAt = cached.savedAt
            nodesResponseBytes = cached.responseBytes
            nodeGroups = cached.groups ?? []
            nodeJobs = cached.jobs
            nodeCustomers = cached.customers ?? []
        }
        if let cached = await cacheStore.loadMeasurePoints() {
            measurePoints = cached.measurePoints
            measurePointsUpdatedAt = cached.savedAt
            measurePointsResponseBytes = cached.responseBytes
            pointCustomers = cached.customers ?? []
            pointAttributeTitles = cached.attributeTitles ?? [:]
        }
        rebuildCustomerIndex()
        if let cached = await cacheStore.loadEquipment() {
            equipment = cached.equipment
            equipmentUpdatedAt = cached.savedAt
            equipmentResponseBytes = cached.responseBytes
        }
        cacheSizeBytes = await cacheStore.totalSizeInBytes()
    }

    /// Вернулись в приложение: если, пока оно было свёрнуто, iOS обновила кэш в фоне
    /// (BackgroundRefresh), — показываем обновлённые списки. Читаем кэш, только если обновление было.
    func reloadCacheIfUpdatedInBackground() async {
        guard isCacheLoaded, !isStopped, !isLoadingAnything else {
            return
        }
        guard let backgroundAt = BackgroundRefresh.lastSuccessAt(), backgroundAt > cacheReadAt else {
            return
        }
        await readCache()
    }

    /// Периодическая проверка, пока приложение открыто (когда оно свёрнуто, iOS его
    /// приостанавливает — и проверка тоже останавливается, это нормально).
    private func startPeriodicChecks() {
        // [weak self] — проверка не держит хранилище в памяти: после выхода оно удалится,
        // а цикл сам завершится на следующем шаге.
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: DataStore.checkInterval)
                guard let self, !self.isStopped else {
                    return
                }
                self.connection = NetworkMonitor.shared.connectionKind
                self.autoRefreshIfNeeded()
            }
        }
    }

    // MARK: - Когда загружать

    /// Пользователь открыл вкладку со списком.
    func listDidAppear(_ kind: ListKind) {
        visibleList = kind
        loadIfNeverLoaded(kind)
    }

    /// Первая загрузка: кэш списка пуст и в этот запуск его ещё не пробовали загрузить —
    /// загружаем при любом подключении (иначе пользователю нечего показать).
    private func loadIfNeverLoaded(_ kind: ListKind) {
        guard isCacheLoaded, !isStopped else {
            return
        }
        if updatedAt(for: kind) == nil && lastAttemptAt(for: kind) == nil && state(for: kind) == .idle {
            enqueue(kind, first: true)
        }
    }

    /// Автообновление: то, у чего истёк срок годности для текущего подключения (CacheFreshness).
    /// Вызывается при запуске, раз в 15 секунд и при возвращении в приложение.
    func autoRefreshIfNeeded(now: Date = Date()) {
        guard isCacheLoaded, !isStopped else {
            return
        }
        // Срок читаем каждый раз заново: пользователь мог поменять его в «Настройках».
        let lifetime = CacheFreshness.lifetime(for: connection)
        // Сначала объекты (они легче), потом точки, потом оборудование.
        for kind in [ListKind.nodes, ListKind.measurePoints, ListKind.equipment] {
            if CacheFreshness.shouldRefresh(connection: connection, lifetime: lifetime,
                                            updatedAt: updatedAt(for: kind),
                                            lastAttemptAt: lastAttemptAt(for: kind),
                                            now: now) {
                enqueue(kind)
            }
        }
    }

    // MARK: - Ручные действия

    /// Обновить все списки, при любом подключении. Кнопки «Обновить» в «Настройках» больше нет
    /// (решение владельца 2026-10-06) — сейчас вызывается только из тестов.
    func refreshAll() {
        enqueue(.nodes)
        enqueue(.measurePoints)
        enqueue(.equipment)
    }

    /// Загрузить один список сейчас (кнопки «Загрузить» / «Повторить» на пустом экране).
    func refresh(_ kind: ListKind) {
        enqueue(kind, first: true)
    }

    /// Отменить загрузку одного списка (или убрать его из очереди).
    func cancel(_ kind: ListKind) {
        if currentKind == kind {
            currentTask?.cancel()
        } else if queue.contains(kind) {
            queue.removeAll { $0 == kind }
            setState(.idle, for: kind)
        }
    }

    /// Отменить всё: очередь и текущую загрузку.
    func cancelAll() {
        for kind in queue {
            setState(.idle, for: kind)
        }
        queue.removeAll()
        currentTask?.cancel()
    }

    /// Кнопка «Очистить кэш». После очистки — как после установки приложения:
    /// по Wi-Fi списки загрузятся сразу, по сотовой сети — когда пользователь откроет вкладку.
    func clearCache() async {
        isClearingCache = true
        cancelAll()
        // Ждём, пока отменённая загрузка завершится, — иначе она успела бы записать кэш заново.
        await currentTask?.value

        try? await cacheStore.clear()
        nodes = []
        nodesUpdatedAt = nil
        nodesResponseBytes = nil
        nodesLastAttemptAt = nil
        nodesState = .idle
        nodeGroups = []
        nodeJobs = nil
        measurePoints = []
        measurePointsUpdatedAt = nil
        measurePointsResponseBytes = nil
        measurePointsLastAttemptAt = nil
        measurePointsState = .idle
        equipment = []
        equipmentUpdatedAt = nil
        equipmentResponseBytes = nil
        equipmentLastAttemptAt = nil
        equipmentState = .idle
        nodeCustomers = []
        pointCustomers = []
        pointAttributeTitles = [:]
        rebuildCustomerIndex()
        cacheSizeBytes = await cacheStore.totalSizeInBytes()

        isClearingCache = false
        autoRefreshIfNeeded()
    }

    /// Перед выходом из учётной записи: всё останавливаем и ждём завершения загрузки,
    /// чтобы она не записала кэш после того, как выход его сотрёт.
    func stop() async {
        isStopped = true
        cancelAll()
        await currentTask?.value
    }

    // MARK: - Очередь загрузок

    private func enqueue(_ kind: ListKind, first: Bool = false) {
        if isStopped || isClearingCache || currentKind == kind || queue.contains(kind) {
            return
        }
        if first {
            queue.insert(kind, at: 0)
        } else {
            queue.append(kind)
        }
        setState(.queued, for: kind)
        startNextIfIdle()
    }

    private func startNextIfIdle() {
        guard currentKind == nil else {
            return
        }
        guard !isStopped, !isPausedInBackground, !queue.isEmpty else {
            // Загружать больше нечего (или нельзя) — дополнительное время у iOS больше не нужно.
            endBackgroundTime()
            return
        }
        guard let client = session.makeAPIClient(), let token = session.token else {
            // Вход не выполнен — загружать нечем.
            cancelAll()
            endBackgroundTime()
            return
        }
        // Если пользователь уйдёт из приложения посреди загрузки — пусть iOS даст её доделать.
        requestBackgroundTimeIfNeeded()

        let kind = queue.removeFirst()
        currentKind = kind
        setLastAttemptAt(Date(), for: kind)
        setState(.loading(DownloadProgress(receivedBytes: 0, expectedBytes: nil, isWaitingForNetwork: false)),
                 for: kind)

        currentTask = Task {
            await download(kind, client: client, token: token)
            currentKind = nil
            currentTask = nil
            startNextIfIdle()
        }
    }

    /// Загружает один список с сервера и сохраняет его в кэш.
    private func download(_ kind: ListKind, client: APIClient, token: String) async {
        // Сообщения о прогрессе приходят из фонового потока — свойства меняем в главном.
        let onProgress: @Sendable (DownloadProgress) -> Void = { progress in
            Task { @MainActor in
                // Сообщение могло опоздать (загрузка уже закончилась) — тогда не трогаем.
                if case .loading = self.state(for: kind) {
                    self.setState(.loading(progress), for: kind)
                }
            }
        }

        do {
            let result = try await ListRefresher.downloadAndSave(kind, client: client, token: token,
                                                                 cacheStore: cacheStore,
                                                                 previousGroups: nodeGroups,
                                                                 previousJobs: nodeJobs,
                                                                 onProgress: onProgress)
            if isStopped {
                return
            }
            apply(result)
            setState(.idle, for: kind)
            cacheSizeBytes = await cacheStore.totalSizeInBytes()
        } catch {
            let apiError = APIError.from(error)
            if apiError == .cancelled {
                if isPausedInBackground && !isStopped {
                    // Отменили не мы, а кончилось время у iOS: список — снова в начало очереди,
                    // загрузка начнётся заново, когда пользователь вернётся в приложение.
                    queue.insert(kind, at: 0)
                    setState(.queued, for: kind)
                } else {
                    setState(.idle, for: kind)
                }
                return
            }
            if case .unauthorized = apiError {
                // Токен больше не действует — на экран входа (кэш сохраняется).
                isStopped = true
                queue.removeAll()
                setState(.idle, for: kind)
                session.sessionExpired()
                return
            }
            setState(.failed(message: apiError.errorDescription ?? "Не удалось загрузить список."), for: kind)
        }
    }

    // MARK: - Дополнительное время у iOS

    // Когда пользователь уходит из приложения, iOS через несколько секунд его «замораживает»,
    // и начатая загрузка обрывается. Чтобы этого не было, на время загрузок просим у iOS
    // дополнительное время (beginBackgroundTask) — никаких разрешений для этого не нужно.
    // Обязательно сообщаем iOS «закончили» (endBackgroundTask): и когда очередь опустела,
    // и когда время вышло. Если забыть — iOS принудительно закроет приложение.

    private func requestBackgroundTimeIfNeeded() {
        guard backgroundTimeID == .invalid else {
            return
        }
        backgroundTimeID = UIApplication.shared.beginBackgroundTask(withName: "Загрузка списков") { [weak self] in
            // iOS вызывает это в главном потоке, когда время почти вышло.
            MainActor.assumeIsolated {
                self?.backgroundTimeDidExpire()
            }
        }
    }

    private func endBackgroundTime() {
        guard backgroundTimeID != .invalid else {
            return
        }
        UIApplication.shared.endBackgroundTask(backgroundTimeID)
        backgroundTimeID = .invalid
    }

    /// Время у iOS вышло, а загрузка не закончилась: останавливаем её (уже сохранённые списки
    /// не пропадут) и ставим на паузу до возвращения пользователя (resumeAfterBackground).
    private func backgroundTimeDidExpire() {
        isPausedInBackground = true
        currentTask?.cancel()
        endBackgroundTime()
    }

    /// Пользователь вернулся в приложение: если iOS прервала загрузку, продолжаем очередь.
    func resumeAfterBackground() {
        guard isPausedInBackground else {
            return
        }
        isPausedInBackground = false
        startNextIfIdle()
    }

    /// Показать на экране список, полученный с сервера.
    private func apply(_ result: ListDownloadResult) {
        switch result {
        case .nodes(let newNodes, let groups, let newCustomers, let jobs, let currentUser, let savedAt,
                    let responseBytes):
            if let currentUser {
                session.updateCurrentUser(currentUser)
            }
            nodes = newNodes
            nodeGroups = groups
            nodeJobs = jobs
            nodeCustomers = newCustomers
            nodesUpdatedAt = savedAt
            nodesResponseBytes = responseBytes
            rebuildCustomerIndex()
        case .measurePoints(let newPoints, let newCustomers, let attributeTitles, let savedAt, let responseBytes):
            pointAttributeTitles = attributeTitles ?? [:]
            measurePoints = newPoints
            pointCustomers = newCustomers
            measurePointsUpdatedAt = savedAt
            measurePointsResponseBytes = responseBytes
            rebuildCustomerIndex()
        case .equipment(let newEquipment, let savedAt, let responseBytes):
            equipment = newEquipment
            equipmentUpdatedAt = savedAt
            equipmentResponseBytes = responseBytes
        }
    }

    /// Пересчитать размер кэша (например, при открытии «Настроек»: данные точек сохраняются
    /// в кэш из карточек, и хранилище списков об этом не знает).
    func refreshCacheSize() async {
        cacheSizeBytes = await cacheStore.totalSizeInBytes()
    }

    // MARK: - Сведения для экранов

    func state(for kind: ListKind) -> ListLoadState {
        switch kind {
        case .nodes:
            return nodesState
        case .measurePoints:
            return measurePointsState
        case .equipment:
            return equipmentState
        }
    }

    func updatedAt(for kind: ListKind) -> Date? {
        switch kind {
        case .nodes:
            return nodesUpdatedAt
        case .measurePoints:
            return measurePointsUpdatedAt
        case .equipment:
            return equipmentUpdatedAt
        }
    }

    func itemCount(for kind: ListKind) -> Int {
        switch kind {
        case .nodes:
            return nodes.count
        case .measurePoints:
            return measurePoints.count
        case .equipment:
            return equipment.count
        }
    }

    /// Идёт ли сейчас какая-нибудь загрузка (или есть очередь).
    var isLoadingAnything: Bool {
        return currentKind != nil || !queue.isEmpty
    }

    /// Сколько примерно придётся скачать, чтобы обновить список. nil — неизвестно
    /// (список ещё ни разу не загружался).
    func estimatedDownloadBytes(for kind: ListKind) -> Int64? {
        switch kind {
        case .nodes:
            if let nodesResponseBytes {
                return Int64(nodesResponseBytes)
            }
            if nodesUpdatedAt != nil {
                return Int64(nodes.count * DataStore.approximateBytesPerNode)
            }
        case .measurePoints:
            if let measurePointsResponseBytes {
                return Int64(measurePointsResponseBytes)
            }
            if measurePointsUpdatedAt != nil {
                return Int64(measurePoints.count * DataStore.approximateBytesPerMeasurePoint)
            }
        case .equipment:
            if let equipmentResponseBytes {
                return Int64(equipmentResponseBytes)
            }
            if equipmentUpdatedAt != nil {
                return Int64(equipment.count * DataStore.approximateBytesPerEquipment)
            }
        }
        return nil
    }

    /// Точки учёта одного объекта — из кэша, без запроса к серверу.
    func measurePoints(ofNode nodeId: Int) -> [MeasurePoint] {
        return measurePoints
            .filter { $0.nodeId == nodeId }
            .sorted { first, second in
                first.title.localizedStandardCompare(second.title) == .orderedAscending
            }
    }

    /// Номера объектов, у которых есть незавершённые работы, — для фильтра «Есть работы».
    var nodeIdsWithJobs: Set<Int> {
        return Set((nodeJobs ?? []).map(\.nodeId))
    }

    /// Незавершённые работы на объекте — из кэша, сначала те, что раньше должны закончиться.
    func jobs(ofNode nodeId: Int) -> [NodeJob] {
        return (nodeJobs ?? [])
            .filter { $0.nodeId == nodeId }
            .sorted { first, second in
                (first.scheduledEndDay ?? "") < (second.scheduledEndDay ?? "")
            }
    }

    /// Объект учёта по номеру — из кэша.
    func node(withId nodeId: Int) -> Node? {
        return nodes.first { $0.id == nodeId }
    }

    /// Номера объектов группы — для фильтров списков. nil — группа не выбрана или её больше нет на сервере
    /// (тогда фильтр по группе не действует).
    func nodeIds(inGroup groupId: Int?) -> Set<Int>? {
        guard let groupId, let group = nodeGroups.first(where: { $0.id == groupId }) else {
            return nil
        }
        return Set(group.memberIds)
    }

    // MARK: - Потребители (фильтр в обе стороны)

    // В ЛЭРС потребитель указывается либо у объекта, либо у его точек (сервер не даёт указать в обоих
    // местах сразу). Чтобы фильтр «Потребитель» работал на обеих вкладках, объект подходит, если
    // потребитель указан у него или у любой его точки, а точка — если у неё или у её объекта.
    // Если вдруг указан в обоих местах — подходит по любому (решение владельца 2026-10-16).

    /// Потребители объекта: свой и всех его точек.
    func customerIds(ofNode node: Node) -> Set<Int> {
        return customerIdsByNode[node.id] ?? []
    }

    /// Потребители точки: свой и её объекта.
    func customerIds(ofPoint point: MeasurePoint) -> Set<Int> {
        var ids = Set<Int>()
        if let customerId = point.customerId {
            ids.insert(customerId)
        }
        if let nodeId = point.nodeId, let nodeCustomer = nodeCustomerById[nodeId] {
            ids.insert(nodeCustomer)
        }
        return ids
    }

    /// Пересчитать связь «объект ↔ потребители» после загрузки или чтения списков: один проход
    /// по объектам и точкам, чтобы фильтр не перебирал все точки для каждого объекта.
    private func rebuildCustomerIndex() {
        var byNode: [Int: Set<Int>] = [:]
        var ownByNode: [Int: Int] = [:]
        var usedIds = Set<Int>()
        for node in nodes {
            if let customerId = node.customerId {
                byNode[node.id, default: []].insert(customerId)
                ownByNode[node.id] = customerId
                usedIds.insert(customerId)
            }
        }
        for point in measurePoints {
            if let customerId = point.customerId {
                usedIds.insert(customerId)
                if let nodeId = point.nodeId {
                    byNode[nodeId, default: []].insert(customerId)
                }
            }
        }
        customerIdsByNode = byNode
        nodeCustomerById = ownByNode

        var titles: [Int: Customer] = [:]
        for customer in nodeCustomers + pointCustomers {
            titles[customer.id] = customer
        }
        customers = usedIds
            .map { titles[$0] ?? Customer(id: $0, title: "Потребитель № \($0)") }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Точка учёта по номеру — из кэша.
    func measurePoint(withId pointId: Int) -> MeasurePoint? {
        return measurePoints.first { $0.id == pointId }
    }

    /// Оборудование по номеру — из кэша.
    func equipment(withId equipmentId: Int) -> Equipment? {
        return equipment.first { $0.id == equipmentId }
    }

    /// Приборы, которые опрашиваются через этот модем — из кэша.
    func equipment(usingModem modemId: Int) -> [Equipment] {
        return equipment.filter { item in
            let connections = item.details?.connections ?? []
            return connections.contains { $0.modemEquipmentId == modemId }
        }
    }

    // MARK: - Вспомогательное

    private func setState(_ newState: ListLoadState, for kind: ListKind) {
        switch kind {
        case .nodes:
            nodesState = newState
        case .measurePoints:
            measurePointsState = newState
        case .equipment:
            equipmentState = newState
        }
    }

    private func lastAttemptAt(for kind: ListKind) -> Date? {
        switch kind {
        case .nodes:
            return nodesLastAttemptAt
        case .measurePoints:
            return measurePointsLastAttemptAt
        case .equipment:
            return equipmentLastAttemptAt
        }
    }

    private func setLastAttemptAt(_ date: Date, for kind: ListKind) {
        switch kind {
        case .nodes:
            nodesLastAttemptAt = date
        case .measurePoints:
            measurePointsLastAttemptAt = date
        case .equipment:
            equipmentLastAttemptAt = date
        }
    }
}
