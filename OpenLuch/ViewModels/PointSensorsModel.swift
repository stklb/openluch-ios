import Foundation
import Observation

// Датчики одной точки учёта для её карточки (раздел «Датчики»: подающая и обратная магистраль).
//
// Запрос тяжёлый (~365 КБ, см. PointSensors.swift), а привязки датчиков меняются редко
// (только при замене или перестановке приборов). Поэтому правила другие, чем у показаний:
//   1. Сразу показываем сохранённые на телефоне датчики — без сети.
//   2. Ни разу не загружались — загружаем при открытии карточки, при любой сети
//      (без датчиков разделу нечего показать). Идёт полоса «Получено X КБ из Y КБ».
//   3. Сохранённые устарели — перекачиваем при открытии вкладки. Срок — из «Настроек» («Автообновление
//      справочников»), свой для Wi-Fi и сотовой сети (CacheFreshness.isStaleOnOpen). В фоне — никогда.
//   4. Ошибка не стирает показанные датчики. Ушли с карточки — загрузка отменяется.
//   5. Ответ 401 — сессия истекла: на экран входа.
@Observable
final class PointSensorsModel {

    let pointId: Int

    /// Сохранённые (или только что полученные) датчики. nil — ещё ни разу не загружались.
    private(set) var cached: CachedPointSensors?
    /// Идёт загрузка — сколько уже получено. nil — не загружается.
    private(set) var progress: DownloadProgress?
    /// Ошибка последней загрузки (сохранённые датчики при этом остаются на экране).
    private(set) var errorMessage: String?
    /// false — кэш ещё читается (доли секунды).
    private(set) var isCacheLoaded = false

    var isLoading: Bool {
        return progress != nil
    }

    private let session: AppSession

    // Без этого на iOS 26 приложение падает при удалении объекта из памяти (см. CLAUDE.md).
    nonisolated deinit {}

    init(pointId: Int, session: AppSession) {
        self.pointId = pointId
        self.session = session
    }

    /// Показать сохранённые датчики (вызывается сразу при открытии карточки, до любых запросов).
    func loadCache() async {
        if isCacheLoaded {
            return
        }
        cached = await session.cacheStore.loadSensors(pointId: pointId)
        isCacheLoaded = true
    }

    /// Загрузить с сервера, если нужно (правила 2 и 3 в начале файла).
    /// Карточка вызывает это ПОСЛЕ маленьких запросов показаний — чтобы на 2G
    /// большой ответ не задерживал показания.
    func refreshIfNeeded(now: Date = Date()) async {
        await loadCache()
        let lifetime = CacheFreshness.lifetime(for: NetworkMonitor.shared.connectionKind)
        let shouldLoad = CacheFreshness.isStaleOnOpen(savedAt: cached?.savedAt, lifetime: lifetime, now: now)
        if shouldLoad {
            await refresh()
        }
    }

    /// Датчики пришли в другом запросе (вместе со списком отчётов — PointReportsModel):
    /// показываем и сохраняем их, как будто загрузили сами. Так не придётся отдельно
    /// качать те же ~365 КБ, когда пользователь откроет вкладку «Датчики».
    func useSensorsLoadedElsewhere(_ sensors: [PointSensor], savedAt: Date = Date()) async {
        let fresh = CachedPointSensors(savedAt: savedAt, sensors: sensors)
        cached = fresh
        isCacheLoaded = true
        errorMessage = nil
        try? await session.cacheStore.saveSensors(fresh, pointId: pointId)
    }

    /// Загрузить датчики с сервера сейчас (также кнопка «Повторить» после ошибки).
    func refresh() async {
        if isLoading {
            return
        }
        guard let client = session.makeAPIClient(), let token = session.token else {
            return
        }
        errorMessage = nil
        progress = DownloadProgress(receivedBytes: 0, expectedBytes: nil, isWaitingForNetwork: false)
        defer {
            progress = nil
        }

        // Сообщения о прогрессе приходят из фонового потока — свойство меняем в главном.
        let onProgress: @Sendable (DownloadProgress) -> Void = { newProgress in
            Task { @MainActor in
                // Сообщение могло опоздать (загрузка уже закончилась) — тогда не трогаем.
                if self.progress != nil {
                    self.progress = newProgress
                }
            }
        }

        do {
            let result = try await client.fetchPointSensors(pointId: pointId, token: token, onProgress: onProgress)
            let fresh = CachedPointSensors(savedAt: Date(), sensors: result.sensors)
            cached = fresh
            try? await session.cacheStore.saveSensors(fresh, pointId: pointId)
        } catch {
            let apiError = APIError.from(error)
            if apiError == .cancelled {
                return
            }
            if case .unauthorized = apiError {
                session.sessionExpired()
                return
            }
            errorMessage = apiError.errorDescription
        }
    }
}
