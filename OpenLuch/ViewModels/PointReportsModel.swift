import Foundation
import Observation

// PDF-отчёты одной точки учёта для её карточки: какие отчёты можно сформировать, формирование
// и сохранённые на телефоне отчёты. Модели данных — Reports.swift, хранение PDF — ReportStore.
//
// Список отчётов («какие назначены точке») — тяжёлый запрос (~450 КБ), а меняется он редко
// (когда администратор назначит точке новый отчёт). Поэтому правила как у датчиков:
//   1. Сохранённый список показывается сразу — без сети.
//   2. Ни разу не загружался — загружается, когда пользователь открыл окно «Сформировать отчёт»
//      (при любой сети, с полосой «Получено X КБ из Y КБ»). Просто открытая карточка его НЕ качает.
//   3. Старше суток — обновляется при открытии окна, но только по Wi-Fi.
//      Вручную — кнопкой «Обновить список отчётов» в окне (при любой сети).
//   4. Ошибка не стирает показанный список. 401 — на экран входа.
// В том же ответе приходят датчики точки — их сразу отдаём PointSensorsModel (не придётся качать отдельно).
//
// Формирование отчёта (кнопка «Сформировать»):
//   сервер готовит отчёт (обычно 1–2 с) → скачиваем PDF (полоса «X КБ из Y КБ») → сохраняем
//   на телефоне (ReportStore) → окно показывает отчёт. «Отмена» или закрытие окна прерывают загрузку.
@Observable
final class PointReportsModel {

    /// Как часто обновлять сохранённый список отчётов (только по Wi-Fi).
    static let refreshInterval: TimeInterval = 24 * 60 * 60

    /// Этап формирования отчёта — для строки состояния в окне.
    enum GenerationStage: Equatable {
        /// Сервер готовит отчёт. true — у телефона нет сети, запрос ждёт её.
        case preparing(isWaitingForNetwork: Bool)
        /// Скачиваем готовый PDF.
        case downloading(DownloadProgress)
    }

    let pointId: Int

    /// Сохранённый (или только что полученный) список отчётов. nil — ещё ни разу не загружался.
    private(set) var cachedList: CachedPointReports?
    /// Идёт загрузка списка — сколько уже получено. nil — не загружается.
    private(set) var listProgress: DownloadProgress?
    /// Ошибка последней загрузки списка (сохранённый список при этом остаётся).
    private(set) var listErrorMessage: String?
    /// false — сохранённые данные ещё читаются (доли секунды).
    private(set) var isCacheLoaded = false

    /// Сохранённые на телефоне отчёты этой точки, новые сверху.
    private(set) var savedReports: [SavedReport] = []

    /// Идёт формирование отчёта — на каком этапе. nil — не идёт.
    private(set) var generationStage: GenerationStage?
    /// Ошибка последнего формирования.
    private(set) var generationErrorMessage: String?

    var isLoadingList: Bool {
        return listProgress != nil
    }

    var isGenerating: Bool {
        return generationStage != nil
    }

    private let session: AppSession
    /// Модель датчиков той же карточки: ей отдаём датчики, пришедшие вместе со списком отчётов.
    private let sensorsModel: PointSensorsModel?

    // Без этого на iOS 26 приложение падает при удалении объекта из памяти (см. CLAUDE.md).
    nonisolated deinit {}

    init(pointId: Int, session: AppSession, sensorsModel: PointSensorsModel? = nil) {
        self.pointId = pointId
        self.session = session
        self.sensorsModel = sensorsModel
    }

    // MARK: - Сохранённое на телефоне

    /// Прочитать сохранённый список отчётов и сохранённые PDF (вызывается при открытии карточки, без сети).
    func loadCache() async {
        if isCacheLoaded {
            return
        }
        cachedList = await session.cacheStore.loadReportList(pointId: pointId)
        await reloadSavedReports()
        isCacheLoaded = true
    }

    /// Перечитать список сохранённых PDF (например, после удаления в «Файлах» или в «Настройках»).
    func reloadSavedReports() async {
        guard let server = session.serverAddress?.displayText else {
            savedReports = []
            return
        }
        savedReports = await session.reportStore.load(pointId: pointId, server: server)
    }

    /// Удалить сохранённый отчёт (свайп в карточке точки).
    func delete(_ report: SavedReport) async {
        try? await session.reportStore.delete(report)
        await reloadSavedReports()
    }

    // MARK: - Список отчётов точки

    /// Загрузить список с сервера, если нужно (правила 2 и 3 в начале файла). Вызывает окно отчёта.
    func refreshListIfNeeded(now: Date = Date()) async {
        await loadCache()
        let shouldLoad = PointReportsModel.shouldLoadList(savedAt: cachedList?.savedAt,
                                                          connection: NetworkMonitor.shared.connectionKind,
                                                          now: now)
        if shouldLoad {
            await refreshList()
        }
    }

    /// Правило загрузки списка (отдельной функцией — чтобы проверить тестами).
    static func shouldLoadList(savedAt: Date?, connection: ConnectionKind, now: Date) -> Bool {
        // Ни разу не загружался — загружаем при любой сети: без списка отчёт не сформировать.
        guard let savedAt else {
            return true
        }
        // Обновлять — только по Wi-Fi и не чаще раза в сутки.
        guard connection == .wifi else {
            return false
        }
        return now.timeIntervalSince(savedAt) >= refreshInterval
    }

    /// Загрузить список отчётов с сервера сейчас (кнопки «Обновить список отчётов» и «Повторить»).
    func refreshList() async {
        if isLoadingList {
            return
        }
        guard let client = session.makeAPIClient(), let token = session.token else {
            return
        }
        listErrorMessage = nil
        listProgress = DownloadProgress(receivedBytes: 0, expectedBytes: nil, isWaitingForNetwork: false)
        defer {
            listProgress = nil
        }

        // Сообщения о прогрессе приходят из фонового потока — свойство меняем в главном.
        let onProgress: @Sendable (DownloadProgress) -> Void = { newProgress in
            Task { @MainActor in
                // Сообщение могло опоздать (загрузка уже закончилась) — тогда не трогаем.
                if self.listProgress != nil {
                    self.listProgress = newProgress
                }
            }
        }

        do {
            let result = try await client.fetchPointReports(pointId: pointId, token: token, onProgress: onProgress)
            let fresh = CachedPointReports(savedAt: Date(), reports: result.reports, responseBytes: result.responseBytes)
            cachedList = fresh
            try? await session.cacheStore.saveReportList(fresh, pointId: pointId)

            // Датчики из того же ответа — модели датчиков (она покажет и сохранит их).
            if let sensorsModel {
                await sensorsModel.useSensorsLoadedElsewhere(result.sensors)
            } else {
                try? await session.cacheStore.saveSensors(CachedPointSensors(savedAt: Date(), sensors: result.sensors),
                                                          pointId: pointId)
            }
        } catch {
            let apiError = APIError.from(error)
            if apiError == .cancelled {
                return
            }
            if case .unauthorized = apiError {
                session.sessionExpired()
                return
            }
            listErrorMessage = apiError.errorDescription
        }
    }

    // MARK: - Формирование отчёта

    /// Сформировать отчёт, скачать PDF и сохранить на телефоне.
    /// Возвращает сохранённый отчёт; nil — ошибка (текст — в generationErrorMessage) или отмена.
    func generate(report: PointReport, dataType: ReportDataType, period: ReportPeriod) async -> SavedReport? {
        if isGenerating {
            return nil
        }
        guard let client = session.makeAPIClient(), let token = session.token,
              let server = session.serverAddress?.displayText else {
            return nil
        }
        generationErrorMessage = nil
        generationStage = .preparing(isWaitingForNetwork: false)
        defer {
            generationStage = nil
        }

        let calendar = ReportPeriod.calendar
        let dates = period.serverDates(for: dataType, calendar: calendar)

        // Пока сервер готовит отчёт, следим только за «нет сети».
        let onPreparingProgress: @Sendable (DownloadProgress) -> Void = { progress in
            Task { @MainActor in
                if case .preparing = self.generationStage {
                    self.generationStage = .preparing(isWaitingForNetwork: progress.isWaitingForNetwork)
                }
            }
        }
        // При скачивании PDF — полоса «X КБ из Y КБ».
        let onDownloadProgress: @Sendable (DownloadProgress) -> Void = { progress in
            Task { @MainActor in
                if case .downloading = self.generationStage {
                    self.generationStage = .downloading(progress)
                }
            }
        }

        do {
            let link = try await client.generateReport(reportId: report.id, dataType: dataType,
                                                       start: dates.start, end: dates.end, pointId: pointId,
                                                       token: token, onProgress: onPreparingProgress)
            generationStage = .downloading(DownloadProgress(receivedBytes: 0, expectedBytes: nil,
                                                            isWaitingForNetwork: false))
            let pdf = try await client.downloadReportFile(link: link, token: token, onProgress: onDownloadProgress)

            // Имя файла сервер придумывает сам по шаблону отчёта («…, ТСЖ … - Отопление c 01.09.2026 по 30.09.2026 (Суточные).pdf»).
            let fileName = link.fileName ?? "\(report.title) \(dates.start.prefix(10)) — \(dates.end.prefix(10))"
            let saved = try await session.reportStore.save(pdf: pdf, suggestedFileName: fileName, pointId: pointId,
                                                           server: server, reportTitle: report.title,
                                                           dataType: dataType,
                                                           periodText: period.summary(for: dataType, calendar: calendar))
            await reloadSavedReports()
            return saved
        } catch {
            let apiError = APIError.from(error)
            if apiError == .cancelled {
                return nil
            }
            if case .unauthorized = apiError {
                session.sessionExpired()
                return nil
            }
            generationErrorMessage = apiError.errorDescription
            return nil
        }
    }
}
