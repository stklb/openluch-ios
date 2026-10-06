import Foundation

// «Скачать список с сервера и сохранить на телефоне» — одно действие для двух мест:
//   • DataStore — когда приложение открыто (с полосой прогресса, очередью и т.п.);
//   • BackgroundRefresh — когда iOS будит приложение в фоне, чтобы обновить кэш.
// Здесь только загрузка, сортировка и запись в кэш; что показывать на экране, решает DataStore.

/// Что получено с сервера (уже отсортировано и сохранено в кэш).
/// У объектов заодно — имя и права пользователя (nil — запрос не удался, оставить прежние).
nonisolated enum ListDownloadResult: Sendable {
    case nodes([Node], groups: [NodeGroup], currentUser: CurrentUser?, savedAt: Date, responseBytes: Int)
    case measurePoints([MeasurePoint], savedAt: Date, responseBytes: Int)
    case equipment([Equipment], savedAt: Date, responseBytes: Int)
}

nonisolated enum ListRefresher {

    /// Скачать один список, отсортировать и сохранить в кэш.
    /// `previousGroups` — группы объектов, которые оставить, если запрос групп не удался.
    /// Ошибки — APIError (в т.ч. .cancelled, если задачу отменили).
    static func downloadAndSave(_ kind: ListKind, client: APIClient, token: String, cacheStore: CacheStore,
                                previousGroups: [NodeGroup] = [],
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
            // Имя и права учётной записи (Login/Current, ~1,8 КБ) — тоже следом: так изменения
            // учётной записи на сервере доходят до приложения вместе с автообновлением справочников.
            // Не получилось — не страшно, останутся прежние.
            let currentUser = try? await client.fetchCurrentUser(token: token)
            try Task.checkCancellation()
            let savedAt = Date()
            // Не получилось сохранить на телефон (например, нет места) — не беда:
            // список всё равно покажем, просто после перезапуска его не будет.
            try? await cacheStore.saveNodes(sorted, savedAt: savedAt, responseBytes: result.responseBytes,
                                            groups: groups)
            return .nodes(sorted, groups: groups, currentUser: currentUser, savedAt: savedAt,
                          responseBytes: result.responseBytes)

        case .measurePoints:
            let result = try await client.fetchMeasurePoints(token: token, onProgress: onProgress)
            try Task.checkCancellation()
            let sorted = result.measurePoints.sorted { first, second in
                first.fullTitle.localizedStandardCompare(second.fullTitle) == .orderedAscending
            }
            let savedAt = Date()
            try? await cacheStore.saveMeasurePoints(sorted, savedAt: savedAt, responseBytes: result.responseBytes)
            return .measurePoints(sorted, savedAt: savedAt, responseBytes: result.responseBytes)

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
