import Foundation

// «Скачать список с сервера и сохранить на телефоне» — одно действие для двух мест:
//   • DataStore — когда приложение открыто (с полосой прогресса, очередью и т.п.);
//   • BackgroundRefresh — когда iOS будит приложение в фоне, чтобы обновить кэш.
// Здесь только загрузка, сортировка и запись в кэш; что показывать на экране, решает DataStore.

/// Что получено с сервера (уже отсортировано и сохранено в кэш).
/// У объектов заодно — имя и права пользователя (nil — запрос не удался, оставить прежние).
nonisolated enum ListDownloadResult: Sendable {
    case nodes([Node], groups: [NodeGroup], customers: [Customer], jobs: [NodeJob]?, currentUser: CurrentUser?,
               savedAt: Date, responseBytes: Int)
    case measurePoints([MeasurePoint], customers: [Customer], savedAt: Date, responseBytes: Int)
    case equipment([Equipment], savedAt: Date, responseBytes: Int)
}

nonisolated enum ListRefresher {

    /// Скачать один список, отсортировать и сохранить в кэш.
    /// `previousGroups` и `previousJobs` — группы и работы, которые оставить, если их запрос не удался.
    /// Ошибки — APIError (в т.ч. .cancelled, если задачу отменили).
    static func downloadAndSave(_ kind: ListKind, client: APIClient, token: String, cacheStore: CacheStore,
                                previousGroups: [NodeGroup] = [],
                                previousJobs: [NodeJob]? = nil,
                                onProgress: @escaping @Sendable (DownloadProgress) -> Void = { _ in })
    async throws -> ListDownloadResult {
        switch kind {
        case .nodes:
            let result = try await client.fetchNodes(token: token, onProgress: onProgress)
            try Task.checkCancellation()
            let sorted = result.nodes.sorted { first, second in
                first.title.localizedStandardCompare(second.title) == .orderedAscending
            }
            // Группы — следом, тем же соединением (крошечный ответ). Не получилось — оставляем
            // прежние группы: список объектов важнее, из-за групп его не теряем.
            let groups = (try? await client.fetchNodeGroups(token: token)) ?? previousGroups
            try Task.checkCancellation()
            // Незавершённые работы на объектах (~1 КБ на работу) — тоже следом и с тем же сроком годности,
            // что у объектов: для карточки объекта и вкладки «Работы». Не получилось — оставляем прежние,
            // как группы (nil — работ ещё ни разу не получали).
            let jobs = (try? await client.fetchIncompleteNodeJobs(token: token)) ?? previousJobs
            try Task.checkCancellation()
            // Имя и права учётной записи (Login/Current, ~1,8 КБ) — тоже следом: так изменения
            // учётной записи на сервере доходят до приложения вместе с автообновлением справочников.
            // Не получилось — не страшно, останутся прежние.
            let currentUser = try? await client.fetchCurrentUser(token: token)
            try Task.checkCancellation()
            let savedAt = Date()
            // Не получилось сохранить на телефон (например, нет места) — не беда:
            // список всё равно покажем, просто после перезапуска его не будет.
            try? await cacheStore.saveNodes(sorted, savedAt: savedAt, responseBytes: result.responseBytes,
                                            groups: groups, customers: result.customers, jobs: jobs)
            return .nodes(sorted, groups: groups, customers: result.customers, jobs: jobs,
                          currentUser: currentUser, savedAt: savedAt, responseBytes: result.responseBytes)

        case .measurePoints:
            let result = try await client.fetchMeasurePoints(token: token, onProgress: onProgress)
            try Task.checkCancellation()
            let sorted = result.measurePoints.sorted { first, second in
                first.fullTitle.localizedStandardCompare(second.fullTitle) == .orderedAscending
            }
            let savedAt = Date()
            try? await cacheStore.saveMeasurePoints(sorted, savedAt: savedAt, responseBytes: result.responseBytes,
                                                    customers: result.customers)
            return .measurePoints(sorted, customers: result.customers, savedAt: savedAt,
                                  responseBytes: result.responseBytes)

        case .equipment:
            // Список уже отсортирован при разборе ответа (Equipment.makeList).
            let result = try await client.fetchEquipment(token: token, onProgress: onProgress)
            try Task.checkCancellation()
            let savedAt = Date()
            try? await cacheStore.saveEquipment(result.equipment, savedAt: savedAt,
                                                responseBytes: result.responseBytes)
            return .equipment(result.equipment, savedAt: savedAt, responseBytes: result.responseBytes)
        }
    }
}
