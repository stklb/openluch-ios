import Foundation
import Observation

// Последние данные одной точки учёта для её карточки: текущие параметры и интеграторы.
//
// Как работает (по правилам «⚠️ ВАЖНО» из PLAN.md):
//   1. Сразу показываем сохранённые на телефоне данные (если есть) — без сети.
//   2. При КАЖДОМ открытии карточки загружаем свежие — всегда и при любой сети (решение
//      владельца, 2026-10-03): два маленьких запроса, 1–6 КБ вместе. Пока они идут, старые
//      значения остаются на экране, но помечены как устаревшие (см. isShowingStaleData).
//      (Списки по сотовой сети автоматически не обновляются — там мегабайты, здесь килобайты.)
//   3. Единицы измерения у каждой точки свои: запрашиваются один раз для точки (0,8 КБ),
//      ОДНОВРЕМЕННО с последними данными (лишнего ожидания на медленной связи нет)
//      и хранятся вместе с её данными.
//   4. Ошибка не стирает показанные данные. Ушли с карточки — загрузка отменяется.
//   5. Ответ 401 — сессия истекла: на экран входа.
@Observable
final class PointReadingsModel {

    let pointId: Int

    /// Сохранённые (или только что полученные) данные. nil — ещё ни разу не загружались.
    private(set) var readings: CachedReadings?

    /// Единицы измерения этой точки (из сохранённых данных) — nil, если ещё не получены.
    var units: ServerUnits? {
        return readings?.units
    }
    private(set) var isLoading = false
    /// true — у телефона нет сети, запрос ждёт её появления.
    private(set) var isWaitingForNetwork = false
    /// Ошибка последней загрузки (старые данные при этом остаются на экране).
    private(set) var errorMessage: String?
    /// false — кэш ещё читается (доли секунды).
    private(set) var isCacheLoaded = false
    /// true — данные на экране получены с сервера после открытия карточки (свежие).
    /// false — показаны сохранённые ранее (устаревшие), пока не придут новые.
    private(set) var isFresh = false

    /// Показаны старые сохранённые данные: идёт обновление или оно не удалось.
    var isShowingStaleData: Bool {
        return readings != nil && !isFresh
    }

    private let session: AppSession

    // Без этого на iOS 26 приложение падает при удалении объекта из памяти (см. CLAUDE.md).
    nonisolated deinit {}

    init(pointId: Int, session: AppSession) {
        self.pointId = pointId
        self.session = session
    }

    /// Карточка открылась: сразу показать кэш и всегда загрузить свежие данные.
    /// Вызывается из .task — если пользователь уйдёт с карточки, загрузка отменится сама.
    func start() async {
        if !isCacheLoaded {
            readings = await session.cacheStore.loadReadings(pointId: pointId)
            isCacheLoaded = true
        }
        await refresh()
    }

    /// Загрузить свежие данные (и единицы, если их ещё нет).
    func refresh() async {
        if isLoading {
            return
        }
        guard let client = session.makeAPIClient(), let token = session.token else {
            return
        }
        isLoading = true
        errorMessage = nil
        // Пока не придут новые данные, показанные считаются устаревшими (и при ручном обновлении тоже).
        isFresh = false

        // Пока ждём ответа, раз в секунду проверяем, есть ли у телефона сеть, —
        // чтобы честно написать «Нет сети, ждём подключения…».
        let networkWatcher = Task {
            while !Task.isCancelled {
                isWaitingForNetwork = !NetworkMonitor.shared.isNetworkAvailable
                try? await Task.sleep(for: .seconds(1))
            }
        }
        defer {
            networkWatcher.cancel()
            isLoading = false
            isWaitingForNetwork = false
        }

        do {
            // Все запросы — одновременно («async let»): на 2G каждый ответ ждём секунду и больше,
            // и три запроса подряд заняли бы втрое больше времени, чем вместе.
            // Единицы спрашиваем, только если у этой точки их ещё нет.
            let savedUnits = units
            let pointId = self.pointId
            async let consumptionRequest = client.fetchLastConsumption(pointId: pointId, token: token)
            async let totalsRequest = client.fetchLastTotals(pointId: pointId, token: token)
            async let unitsRequest = PointReadingsModel.fetchUnitsIfNeeded(savedUnits, client: client,
                                                                           pointId: pointId, token: token)
            let consumption = try await consumptionRequest
            let totals = try await totalsRequest
            let pointUnits = await unitsRequest
            let fresh = CachedReadings(savedAt: Date(), consumption: consumption, totals: totals,
                                       units: pointUnits)
            readings = fresh
            isFresh = true
            try? await session.cacheStore.saveReadings(fresh, pointId: pointId)
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

    /// Единицы точки: сохранённые — или запросить. Если запрос единиц не удался, не страшно:
    /// данные покажем без единиц, а единицы запросим при следующем открытии карточки.
    private nonisolated static func fetchUnitsIfNeeded(_ savedUnits: ServerUnits?, client: APIClient,
                                                       pointId: Int, token: String) async -> ServerUnits? {
        if let savedUnits {
            return savedUnits
        }
        return try? await client.fetchUnits(pointId: pointId, token: token)
    }
}
