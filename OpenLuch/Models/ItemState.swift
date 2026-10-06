import Foundation

// Состояние объекта учёта или точки учёта — то, что показываем цветом в списках.
//
// Сервер присылает состояние строкой: "Normal", "Warning", "Error", "NoData", "None".
// В моделях мы храним эту строку как есть (см. Node.state, MeasurePoint.state),
// а сюда переводим её только для отображения. Так, если сервер когда-нибудь
// пришлёт новое значение, разбор ответа не сломается — оно просто станет .unknown.
//
// `nonisolated` — тип можно использовать из любого потока, а не только из главного
// (в проекте по умолчанию всё привязано к главному потоку, см. PLAN.md).
nonisolated enum ItemState: Equatable, Sendable {
    case normal
    case warning
    case error
    case noData
    case unknown

    init(apiValue: String?) {
        switch apiValue {
        case "Normal":
            self = .normal
        case "Warning":
            self = .warning
        case "Error":
            self = .error
        case "NoData":
            self = .noData
        default:
            // "None", пустое значение и всё незнакомое
            self = .unknown
        }
    }

    /// Подпись для пользователя.
    var title: String {
        switch self {
        case .normal:
            return "Норма"
        case .warning:
            return "Предупреждение"
        case .error:
            return "Ошибка"
        case .noData:
            return "Нет данных"
        case .unknown:
            return "Не определено"
        }
    }
}
