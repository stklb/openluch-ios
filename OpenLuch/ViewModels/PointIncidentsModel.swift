import Foundation
import Observation

// Активные нештатные ситуации одной точки — для экрана «Нештатные ситуации» (открывается из строки
// «Состояние» карточки точки при ошибке или предупреждении).
//
// Правила (как у последних данных — запрос маленький):
//   1. Сохранённые НС показываются сразу, без сети.
//   2. При каждом открытии экрана — загрузка свежих при любой сети.
//   3. Ошибка не стирает показанное; 401 — на экран входа.
@Observable
final class PointIncidentsModel {

    let pointId: Int

    /// Сохранённые (или только что полученные) НС. nil — ещё ни разу не загружались.
    private(set) var cached: CachedIncidents?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var isCacheLoaded = false

    private let session: AppSession

    // Без этого на iOS 26 приложение падает при удалении объекта из памяти (см. CLAUDE.md).
    nonisolated deinit {}

    init(pointId: Int, session: AppSession) {
        self.pointId = pointId
        self.session = session
    }

    /// Прочитать сохранённые НС (без сети).
    func loadCache() async {
        if isCacheLoaded {
            return
        }
        cached = await session.cacheStore.loadIncidents(pointId: pointId)
        isCacheLoaded = true
    }

    /// Загрузить с сервера сейчас (и кнопка «Повторить»).
    func refresh() async {
        if isLoading {
            return
        }
        guard let client = session.makeAPIClient(), let token = session.token else {
            return
        }
        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
        }
        do {
            let incidents = try await client.fetchActiveIncidents(pointId: pointId, token: token)
            let fresh = CachedIncidents(savedAt: Date(), incidents: PointIncidentsModel.sorted(incidents))
            cached = fresh
            try? await session.cacheStore.saveIncidents(fresh, pointId: pointId)
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

    /// Сначала критические, потом предупреждения, потом остальные; внутри — новые сверху.
    static func sorted(_ incidents: [Incident]) -> [Incident] {
        func rank(_ incident: Incident) -> Int {
            switch incident.importance {
            case "Critical":
                return 0
            case "Warning":
                return 1
            default:
                return 2
            }
        }
        return incidents.sorted { first, second in
            if rank(first) != rank(second) {
                return rank(first) < rank(second)
            }
            return (first.startDate ?? "") > (second.startDate ?? "")
        }
    }
}

/// Подробности одной НС и её журнал (экран подробностей): сохранённое — сразу, свежее — при открытии.
@Observable
final class IncidentDetailsModel {

    let incident: Incident
    private(set) var details: CachedIncidentDetails?
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private let session: AppSession

    // Без этого на iOS 26 приложение падает при удалении объекта из памяти (см. CLAUDE.md).
    nonisolated deinit {}

    init(incident: Incident, session: AppSession) {
        self.incident = incident
        self.session = session
    }

    func start() async {
        if details == nil {
            details = await session.cacheStore.loadIncidentDetails(incidentId: incident.id)
        }
        await refresh()
    }

    func refresh() async {
        if isLoading {
            return
        }
        guard let client = session.makeAPIClient(), let token = session.token else {
            return
        }
        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
        }
        do {
            let response = try await client.fetchIncidentDetails(incidentId: incident.id, token: token)
            // Журнал — по времени, новые записи сверху.
            let log = (response.log ?? []).sorted { ($0.date ?? "") > ($1.date ?? "") }
            let fresh = CachedIncidentDetails(savedAt: Date(), incident: response.incident, log: log)
            details = fresh
            try? await session.cacheStore.saveIncidentDetails(fresh, incidentId: incident.id)
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
