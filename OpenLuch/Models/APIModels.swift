import Foundation

// Тела запросов и ответов сервера ЛЭРС, кроме самих объектов и точек учёта.
// Подробное описание каждого запроса — в docs/api-notes.md.

/// Тело запроса POST /api/v1/Login.
nonisolated struct LoginRequest: Encodable, Sendable {
    let login: String
    let password: String
    /// Имя приложения. Сервер записывает его в токен (видимо, для списка сессий).
    let application: String
}

/// Ответ POST /api/v1/Login.
nonisolated struct LoginResponse: Decodable, Sendable {
    /// true — сервер требует одноразовый код. В первой версии это не поддерживаем.
    let oneTimePasswordRequired: Bool?
    /// Токен для всех следующих запросов (заголовок «Authorization: Bearer …»).
    let token: String?
    /// Когда токен перестанет действовать (обычно примерно через год).
    let tokenExpiration: Date?
}

/// Ответ GET /api/v1/Login/Current — сведения о вошедшем пользователе (~1,8 КБ на my.lers.ru).
/// Берём отображаемое имя, признак администратора и права (см. CurrentUser); группы и прочее не нужны.
nonisolated struct CurrentLoginResponse: Decodable, Sendable {
    let account: Account?
    let permissions: [String]?

    nonisolated struct Account: Decodable, Sendable {
        let displayName: String?
        let isAdmin: Bool?
    }

    func makeUser() -> CurrentUser {
        let name = account?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return CurrentUser(displayName: name.isEmpty ? nil : name,
                           isAdmin: account?.isAdmin ?? false,
                           permissions: permissions ?? [])
    }
}

/// Ответ GET /api/v1/ServerInfo (без авторизации) — сведения о сервере.
/// Например: {"type":"LersServer","version":"3.67.2","fullVersion":"3.67.2.36711", …}
/// Берём только версию — остальное (время сервера, ОС и т.п.) не нужно.
nonisolated struct ServerInfo: Decodable, Sendable {
    /// Версия для людей: «3.67.2».
    let version: String?
    /// Полная версия с номером сборки: «3.67.2.36711».
    let fullVersion: String?
}

/// Ответ GET /api/v1/Core/Nodes.
/// В ответе есть и другие поля (территории и т.д.) — они нам не нужны.
nonisolated struct NodeListResponse: Decodable, Sendable {
    let nodes: [Node]?
}

/// Ответ GET /api/v1/Core/MeasurePoints.
nonisolated struct MeasurePointListResponse: Decodable, Sendable {
    let measurePoints: [MeasurePoint]?
}

/// Тело ответа сервера с ошибкой (в swagger — ResponseParameters).
/// Например: {"errorMessage":"Имя входа или пароль указаны неверно","errorCode":2,"data":null}
nonisolated struct ServerErrorResponse: Decodable, Sendable {
    let errorMessage: String?
    let errorCode: Int?
}

/// Ответ на запуск ручного опроса (ManualPollResponseParameters_v1): номер сеанса опроса.
nonisolated struct ManualPollResponse: Decodable, Sendable {
    let pollSessionId: Int?
}
