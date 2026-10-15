import Foundation
import Observation

// «Сессия» приложения: выполнен ли вход, на какой сервер и под каким логином.
// Один объект на всё приложение. Создаётся в OpenLuchApp и передаётся экранам через .environment.
//
// @Observable — когда меняются свойства (например, token), SwiftUI сам перерисует
// экраны, которые их используют. Так при входе экран входа сменяется основным, а при выходе — наоборот.
@Observable
final class AppSession {

    /// Токен текущего входа. nil — вход не выполнен.
    private(set) var token: String?
    /// Адрес сервера последнего входа (остаётся и после выхода — для экрана входа).
    private(set) var serverAddress: ServerAddress?
    /// Логин последнего входа (остаётся и после выхода — для экрана входа).
    private(set) var savedLogin: String
    /// Имя и права вошедшего пользователя (CurrentUser).
    /// nil — не получены. Приходят вместе со списком объектов (ListRefresher) — после входа
    /// и при каждом его обновлении, в том числе в фоне. Отдельного запроса при входе нет.
    private(set) var currentUser: CurrentUser?

    /// Отображаемое имя пользователя («Гостевой пользователь») — для «Настроек».
    var displayName: String? {
        return currentUser?.displayName
    }

    /// Разрешено ли пользователю действие. Права ещё не известны (не получены после входа
    /// или вход был в прошлой версии приложения) — разрешаем: решит сервер, как и раньше.
    func isAllowed(_ permission: UserPermission) -> Bool {
        return currentUser?.isAllowed(permission) ?? true
    }
    /// Почему пришлось войти заново (например, «Сессия истекла») — показывается на экране входа.
    /// nil — обычный выход или первый запуск.
    private(set) var logoutReason: String?

    private let tokenStore: KeychainTokenStore
    private let settingsStore: SettingsStore
    let cacheStore: CacheStore
    /// Сохранённые PDF-отчёты (документы пользователя, при выходе не удаляются — см. ReportStore).
    let reportStore: ReportStore

    /// Вход выполнен — есть и токен, и правильный адрес сервера.
    var isLoggedIn: Bool {
        return token != nil && serverAddress?.baseURL != nil
    }

    // Явно говорим: при удалении объекта из памяти ничего не нужно делать в главном потоке.
    // Без этого Swift (в режиме «по умолчанию всё в главном потоке») вставляет особую
    // «очистку в главном потоке», и на iOS 26 она падает с ошибкой памяти (проверено 2026-10-03).
    nonisolated deinit {}

    /// Хранилища можно подменить в тестах.
    init(tokenStore: KeychainTokenStore = KeychainTokenStore(),
         settingsStore: SettingsStore = SettingsStore(),
         cacheStore: CacheStore = CacheStore(),
         reportStore: ReportStore = ReportStore()) {
        self.tokenStore = tokenStore
        self.settingsStore = settingsStore
        self.cacheStore = cacheStore
        self.reportStore = reportStore

        // При запуске приложения вспоминаем прошлый вход — без обращения к серверу
        // (на плохой связи каждый лишний запрос стоит секунд, см. PLAN.md).
        self.serverAddress = settingsStore.loadServerAddress()
        self.savedLogin = settingsStore.loadLogin()
        self.currentUser = settingsStore.loadCurrentUser()
        self.token = tokenStore.load()
    }

    /// Клиент сервера для текущего входа (nil, если вход не выполнен).
    func makeAPIClient() -> APIClient? {
        guard isLoggedIn, let baseURL = serverAddress?.baseURL else {
            return nil
        }
        return APIClient(baseURL: baseURL)
    }

    /// Вход: запрос к серверу, сохранение токена в Keychain, адреса и логина — в настройки.
    /// При ошибке бросает APIError, и ничего не меняется.
    func logIn(address: ServerAddress, login: String, password: String,
               onProgress: @escaping @Sendable (DownloadProgress) -> Void) async throws {
        guard let baseURL = address.baseURL else {
            throw APIError.invalidServerAddress
        }

        let client = APIClient(baseURL: baseURL)
        let newToken = try await client.login(login: login, password: password, onProgress: onProgress)

        do {
            try tokenStore.save(newToken)
        } catch {
            throw APIError.other(message: error.localizedDescription)
        }

        // Если вошли на другой сервер или под другим логином — старый кэш, имя и права чужие, удаляем.
        // Кэш пуст — значит, список объектов загрузится сразу, а с ним придут новые имя и права
        // (отдельный запрос Login/Current при входе не нужен). Тот же пользователь — оставляем прежние:
        // кэш мог сохраниться («Сессия истекла»), и тогда объекты не перезагрузятся сразу.
        if address != serverAddress || login != savedLogin {
            try? await cacheStore.clear()
            settingsStore.saveCurrentUser(nil)
            currentUser = nil
        }

        settingsStore.saveServerAddress(address)
        settingsStore.saveLogin(login)
        serverAddress = address
        savedLogin = login
        logoutReason = nil
        token = newToken
    }

    /// Сохранить свежие имя и права пользователя (после входа или вместе со списком объектов).
    func updateCurrentUser(_ user: CurrentUser) {
        // Вход уже не выполнен (вышли, пока шёл запрос) — не сохраняем.
        guard token != nil else {
            return
        }
        if user != currentUser {
            settingsStore.saveCurrentUser(user)
            currentUser = user
        }
    }

    /// Выход: стираем токен и весь кэш. Адрес сервера и логин оставляем (решение владельца).
    func logOut() async {
        try? tokenStore.delete()
        try? await cacheStore.clear()
        logoutReason = nil
        token = nil
    }

    /// Сервер больше не принимает токен (ответ 401 — истёк срок или сессию закрыли на сервере).
    /// Стираем токен и возвращаемся на экран входа. **Кэш не стираем**: если пользователь войдёт
    /// снова на тот же сервер под тем же логином, сохранённые списки сразу пригодятся
    /// (при входе на другой сервер или под другим логином их сотрёт logIn).
    func sessionExpired() {
        try? tokenStore.delete()
        logoutReason = APIError.unauthorized(serverMessage: nil).errorDescription
        token = nil
    }
}
