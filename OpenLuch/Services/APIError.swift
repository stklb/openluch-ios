import Foundation

// Все ошибки, которые могут случиться при обращении к серверу, — с понятным
// пользователю текстом на русском (errorDescription).
nonisolated enum APIError: LocalizedError, Equatable, Sendable {
    /// Адрес сервера введён неправильно.
    case invalidServerAddress
    /// Нет интернета.
    case noConnection
    /// Связь прервалась посреди загрузки (частый случай на EDGE/2G).
    case connectionLost
    /// Сервер слишком долго молчал.
    case timedOut
    /// Сервер с таким адресом не найден или не отвечает.
    case serverUnreachable
    /// Не удалось установить защищённое соединение (https): например, самоподписанный сертификат.
    case secureConnectionFailed
    /// 401: неверный логин/пароль (тогда есть текст от сервера) или токен больше не действует.
    case unauthorized(serverMessage: String?)
    /// 403: у пользователя нет прав.
    case accessDenied
    /// Сервер сообщил об ошибке своим текстом (обычно код 422).
    case serverError(message: String)
    /// Другой неожиданный код ответа (500, 404 и т.п.).
    case unexpectedStatus(code: Int)
    /// Ответ пришёл, но разобрать его не получилось.
    case invalidResponse
    /// Сервер требует одноразовый код — в первой версии не поддерживаем.
    case oneTimePasswordNotSupported
    /// Загрузку отменили (пользователь ушёл с экрана или нажал «Отмена»).
    case cancelled
    /// Что-то другое — с системным текстом ошибки.
    case other(message: String)

    var errorDescription: String? {
        switch self {
        case .invalidServerAddress:
            return "Адрес сервера указан неверно."
        case .noConnection:
            return "Нет соединения с интернетом."
        case .connectionLost:
            return "Связь прервалась во время загрузки. Попробуйте ещё раз, когда связь станет лучше."
        case .timedOut:
            return "Сервер не ответил вовремя. Возможно, слишком медленная связь."
        case .serverUnreachable:
            return "Сервер не найден или недоступен. Проверьте адрес и порт."
        case .secureConnectionFailed:
            return "Не удалось установить защищённое соединение с сервером (https). Проверьте сертификат сервера."
        case .unauthorized(let serverMessage):
            if let serverMessage, !serverMessage.isEmpty {
                return serverMessage
            }
            return "Сессия истекла. Войдите заново."
        case .accessDenied:
            return "Недостаточно прав для этого действия."
        case .serverError(let message):
            return message
        case .unexpectedStatus(let code):
            return "Сервер вернул ошибку (код \(code))."
        case .invalidResponse:
            return "Сервер прислал ответ, который не удалось разобрать."
        case .oneTimePasswordNotSupported:
            return "Сервер требует одноразовый код. Вход с одноразовым кодом пока не поддерживается."
        case .cancelled:
            return "Загрузка отменена."
        case .other(let message):
            return message
        }
    }

    /// Проверяет код ответа сервера. Возвращает ошибку или nil, если всё хорошо (коды 200–299).
    /// `body` — тело ответа: в нём сервер может прислать текст ошибки.
    static func fromHTTPStatus(_ statusCode: Int, body: Data) -> APIError? {
        if statusCode >= 200 && statusCode < 300 {
            return nil
        }

        // Пробуем достать текст ошибки от сервера: {"errorMessage": "...", "errorCode": 2}
        var serverMessage: String? = nil
        if let parsed = try? JSONDecoder().decode(ServerErrorResponse.self, from: body) {
            serverMessage = parsed.errorMessage
        }

        switch statusCode {
        case 401:
            // Неверный пароль — 401 с текстом; истёкший токен — 401 с пустым телом.
            return .unauthorized(serverMessage: serverMessage)
        case 403:
            return .accessDenied
        default:
            if let serverMessage, !serverMessage.isEmpty {
                return .serverError(message: serverMessage)
            }
            return .unexpectedStatus(code: statusCode)
        }
    }

    /// Переводит любую ошибку загрузки (обычно системную URLError) в нашу APIError.
    static func from(_ error: Error) -> APIError {
        if let apiError = error as? APIError {
            return apiError
        }
        if error is CancellationError {
            return .cancelled
        }
        guard let urlError = error as? URLError else {
            return .other(message: error.localizedDescription)
        }

        switch urlError.code {
        case .cancelled:
            return .cancelled
        case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
            return .noConnection
        case .networkConnectionLost:
            return .connectionLost
        case .timedOut:
            return .timedOut
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return .serverUnreachable
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected:
            return .secureConnectionFailed
        default:
            return .other(message: urlError.localizedDescription)
        }
    }
}
