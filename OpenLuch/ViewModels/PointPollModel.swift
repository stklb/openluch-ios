import Foundation
import Observation

// Ручной опрос прибора точки учёта («Опросить текущие» в карточке точки, вкладка «Данные»).
//
// Как работает:
//   1. POST …/Poll/MeasurePoints/{id}/Currents?once=true — сервер ЛЭРС сам связывается с прибором
//      и считывает текущие данные. Ответ — только номер сеанса опроса.
//   2. Узнать ход сеанса через REST API нельзя (такого запроса в API нет — docs/api-notes.md).
//      Поэтому ждём результат по-простому: каждые 20 секунд заново загружаем последние данные
//      точки (~3 КБ) и смотрим, появилась ли запись новее той, что была до опроса.
//      Ждём до 3 минут; потом пишем «новых данных пока нет» (опрос по GSM бывает дольше).
//   3. Если опрос запустить нельзя, сервер сразу отвечает понятным текстом
//      («Модем не подключен», «Порт опроса не настроен…») — его и показываем.
//   4. Ушли с карточки — ожидание прекращается (опрос на сервере при этом продолжается,
//      новые данные будут видны при следующем открытии карточки).
@Observable
final class PointPollModel {

    /// Как часто проверять, пришли ли новые данные, и сколько раз.
    static let checkInterval: Duration = .seconds(20)
    static let maxChecks = 9

    enum Status: Equatable {
        /// Опрос не запускали.
        case idle
        /// Отправляем серверу команду на опрос.
        case starting
        /// Сервер опрашивает прибор; ждём новую запись. `sessionId` — номер сеанса опроса.
        case waiting(sessionId: Int?, startedAt: Date)
        /// Пришли новые данные: время записи прибора (как прислал сервер).
        case succeeded(recordTime: String?)
        /// За время ожидания новых данных не появилось.
        case noNewData
        /// Опрос не запустился — текст ошибки (обычно от сервера).
        case failed(message: String)
    }

    let pointId: Int
    private(set) var status: Status = .idle

    /// Идёт опрос или ожидание его результата.
    var isBusy: Bool {
        switch status {
        case .starting, .waiting:
            return true
        default:
            return false
        }
    }

    private let session: AppSession

    // Без этого на iOS 26 приложение падает при удалении объекта из памяти (см. CLAUDE.md).
    nonisolated deinit {}

    init(pointId: Int, session: AppSession) {
        self.pointId = pointId
        self.session = session
    }

    /// Запустить опрос и дождаться новых данных. Новые данные показывает `readings`
    /// (та же модель, что и раздел «Последние данные»), так что они сразу появляются на экране.
    func poll(readings: PointReadingsModel) async {
        if isBusy {
            return
        }
        guard let client = session.makeAPIClient(), let token = session.token else {
            return
        }
        // Запись до опроса — с ней сравниваем.
        let recordBefore = readings.readings?.consumption?.dateTime
        status = .starting

        let sessionId: Int?
        do {
            sessionId = try await client.startCurrentsPoll(pointId: pointId, token: token)
        } catch {
            let apiError = APIError.from(error)
            if apiError == .cancelled {
                status = .idle
                return
            }
            if case .unauthorized = apiError {
                session.sessionExpired()
                return
            }
            status = .failed(message: apiError.errorDescription ?? "Не удалось запустить опрос.")
            return
        }

        status = .waiting(sessionId: sessionId, startedAt: Date())
        for _ in 0..<PointPollModel.maxChecks {
            do {
                try await Task.sleep(for: PointPollModel.checkInterval)
            } catch {
                // Ушли с карточки — перестаём ждать.
                status = .idle
                return
            }
            await readings.refresh()
            let recordNow = readings.readings?.consumption?.dateTime
            if PointPollModel.isNewRecord(recordNow, comparedTo: recordBefore) {
                status = .succeeded(recordTime: recordNow)
                return
            }
        }
        status = .noNewData
    }

    /// Появилась ли запись новее прежней (отдельной функцией — чтобы проверить тестами).
    /// Время записи сервер присылает строкой «2026-10-03T00:31:23» — такие строки можно сравнивать как текст.
    static func isNewRecord(_ recordNow: String?, comparedTo recordBefore: String?) -> Bool {
        guard let recordNow else {
            return false
        }
        guard let recordBefore else {
            return true
        }
        return recordNow > recordBefore
    }
}
