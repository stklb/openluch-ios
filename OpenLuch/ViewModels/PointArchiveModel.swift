import Foundation
import Observation

// Архив потребления одной точки для экрана «Графики и архив» (PointArchiveView).
//
// Как работает (по правилам «⚠️ ВАЖНО» из PLAN.md и решениям владельца 2026-10-11):
//   1. Ничего не сохраняем на телефоне: прибор могут переопросить, и сервер заменит данные.
//      Архив живёт в памяти, пока открыта карточка точки: модель создаёт карточка
//      (MeasurePointDetailView) и держит у себя. Ушли с карточки — модель и архив удаляются из памяти.
//      Поэтому при каждом новом открытии карточки данные запрашиваются заново — всегда свежие.
//   2. Сервер не сообщает, с какой даты у точки есть данные (а архив бывает с 2009 года — сотни КБ
//      и мегабайты). Поэтому грузим ПОРЦИЯМИ по одному экрану графика (ArchiveGrid) — только те,
//      что пользователь сейчас видит на графике (show). Пролистал далеко назад — промежуточные
//      порции не качаются.
//   3. Отдельный запрос на каждый период (часы, сутки, месяцы) и только когда пользователь его открыл:
//      объединить нельзя — период у запроса общий, и часовых пришло бы в десятки раз больше нужного.
//   4. Порции грузятся по одной (на EDGE параллельные запросы только мешают друг другу).
//      Загрузку не прерывает листание — только уход с экрана графиков (stop).
//   5. Ошибка не стирает загруженное; после ошибки сами не повторяем — кнопка «Повторить» (retry).
@Observable
final class PointArchiveModel {

    /// Архив одного периода (часов, суток или месяцев).
    struct PeriodArchive {
        /// Загруженные записи по возрастанию даты.
        var records: [ArchiveRecord] = []
        /// Номера уже загруженных порций (в том числе пустых — данных там нет).
        var loadedPortions: Set<Int> = []
        /// Порция, которая сейчас загружается.
        var loadingPortion: Int?
        /// Ход загрузки.
        var progress: DownloadProgress?
        /// Ошибка последней загрузки (загруженное при этом остаётся).
        var errorMessage: String?

        var isLoading: Bool {
            return loadingPortion != nil
        }
    }

    let pointId: Int

    private(set) var archives: [ArchivePeriod: PeriodArchive] = [:]
    /// Единицы измерения точки (приходят вместе с архивом).
    private(set) var units: ServerUnits?

    /// Сетки порций: создаются при первом обращении к периоду и не меняются, пока открыта карточка.
    @ObservationIgnored private var grids: [ArchivePeriod: ArchiveGrid] = [:]
    /// Что сейчас видно на графике: период и промежуток дат.
    @ObservationIgnored private var wanted: (period: ArchivePeriod, from: Date, to: Date)?
    /// Идущая загрузка (по одной порции за раз).
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    private let session: AppSession

    // Без этого на iOS 26 приложение падает при удалении объекта из памяти (см. CLAUDE.md).
    nonisolated deinit {}

    init(pointId: Int, session: AppSession) {
        self.pointId = pointId
        self.session = session
    }

    func archive(_ period: ArchivePeriod) -> PeriodArchive {
        return archives[period] ?? PeriodArchive()
    }

    /// Сетка порций периода.
    func grid(_ period: ArchivePeriod, now: Date = Date()) -> ArchiveGrid {
        if let grid = grids[period] {
            return grid
        }
        let grid = ArchiveGrid(period: period, now: now, calendar: ArchiveDates.calendar)
        grids[period] = grid
        return grid
    }

    /// На графике видны даты [from, to) — загрузить недостающие порции (по одной, сначала свежие).
    /// Экран вызывает это, когда график остановился (а не на каждом сдвиге пальца).
    func show(_ period: ArchivePeriod, from: Date, to: Date) {
        wanted = (period, from, to)
        startLoadingIfNeeded()
    }

    /// Ушли с экрана графиков — прервать загрузку (загруженное остаётся).
    func stop() {
        loadTask?.cancel()
        loadTask = nil
    }

    /// Кнопка «Повторить» после ошибки.
    func retry(_ period: ArchivePeriod) {
        archives[period, default: PeriodArchive()].errorMessage = nil
        startLoadingIfNeeded()
    }

    /// Данных на экране нет — загрузить следующую, более раннюю порцию (кнопка «Искать раньше»).
    func loadEarlierPortion(_ period: ArchivePeriod) {
        let loaded = archive(period).loadedPortions
        let next = (loaded.max() ?? -1) + 1
        guard next < period.maxPortions else {
            return
        }
        let grid = grid(period)
        wanted = (period, grid.first(ofPortion: next), grid.first(ofPortion: next - 1))
        startLoadingIfNeeded()
    }

    // MARK: - Загрузка

    private func startLoadingIfNeeded() {
        if loadTask != nil {
            // Уже грузим — по окончании порции загрузка сама посмотрит, что видно теперь.
            return
        }
        loadTask = Task {
            await loadWantedPortions()
            loadTask = nil
        }
    }

    /// Грузим порции по одной, пока на графике видны незагруженные. После ошибки — стоп.
    private func loadWantedPortions() async {
        while !Task.isCancelled, let next = nextWantedPortion() {
            let isLoaded = await load(next.period, portion: next.index)
            if !isLoaded {
                return
            }
        }
    }

    /// Следующая незагруженная порция из видимых на графике — или nil, если грузить нечего.
    private func nextWantedPortion() -> (period: ArchivePeriod, index: Int)? {
        guard let wanted else {
            return nil
        }
        let state = archive(wanted.period)
        if state.errorMessage != nil {
            return nil
        }
        let portions = grid(wanted.period).portions(from: wanted.from, to: wanted.to)
        guard let index = portions.first(where: { !state.loadedPortions.contains($0) }) else {
            return nil
        }
        return (wanted.period, index)
    }

    /// Загрузить одну порцию. true — получилось (порция добавлена, пусть даже пустая).
    private func load(_ period: ArchivePeriod, portion index: Int) async -> Bool {
        guard let client = session.makeAPIClient(), let token = session.token else {
            return false
        }
        var state = archive(period)
        state.errorMessage = nil
        state.loadingPortion = index
        state.progress = DownloadProgress(receivedBytes: 0, expectedBytes: nil, isWaitingForNetwork: false)
        archives[period] = state
        defer {
            archives[period]?.loadingPortion = nil
            archives[period]?.progress = nil
        }

        // Сообщения о прогрессе приходят из фонового потока — свойство меняем в главном.
        let onProgress: @Sendable (DownloadProgress) -> Void = { newProgress in
            Task { @MainActor in
                // Сообщение могло опоздать (загрузка уже закончилась) — тогда не трогаем.
                if self.archives[period]?.progress != nil {
                    self.archives[period]?.progress = newProgress
                }
            }
        }

        let grid = grid(period)
        do {
            let result = try await client.fetchConsumptionArchive(pointId: pointId, period: period,
                                                                  first: grid.first(ofPortion: index),
                                                                  last: grid.last(ofPortion: index),
                                                                  token: token, onProgress: onProgress)
            units = result.units
            var updated = archive(period)
            updated.records = PointArchiveModel.merge(updated.records, with: result.records)
            updated.loadedPortions.insert(index)
            archives[period] = updated
            return true
        } catch {
            let apiError = APIError.from(error)
            if apiError == .cancelled {
                return false
            }
            if case .unauthorized = apiError {
                session.sessionExpired()
                return false
            }
            archives[period]?.errorMessage = apiError.errorDescription
            return false
        }
    }

    /// Добавить новые записи к загруженным. Запись за тот же час (сутки, месяц) заменяется новой.
    /// Отдельной функцией — чтобы проверить тестами.
    static func merge(_ old: [ArchiveRecord], with new: [ArchiveRecord]) -> [ArchiveRecord] {
        var byDate: [Date: ArchiveRecord] = [:]
        for record in old {
            byDate[record.date] = record
        }
        for record in new {
            byDate[record.date] = record
        }
        return byDate.values.sorted { $0.date < $1.date }
    }
}
