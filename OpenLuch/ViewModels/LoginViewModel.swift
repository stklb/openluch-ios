import Foundation
import Observation

// Модель экрана входа: что введено в поля, можно ли нажать «Войти», идёт ли вход, какая ошибка.
// Сам экран (LoginView) только показывает эти данные и передаёт сюда нажатия.
@Observable
final class LoginViewModel {

    // MARK: - Поля формы

    // Адрес сервера — тремя частями (решение владельца 2026-10-04): переключатель https/http,
    // имя сервера и порт. Так пользователю остаётся ввести только имя, а порт подставляется сам.

    /// true — https (соединение шифруется), false — http.
    var useHTTPS: Bool
    /// Имя сервера или IP-адрес, без протокола и порта: «my.lers.ru», «192.168.1.10».
    var hostText: String
    /// Порт строкой — как в поле ввода. При смене протокола стандартный порт меняется сам
    /// (443 ↔ 10000), а свой, введённый вручную, остаётся.
    var portText: String
    var login: String
    var password: String = ""

    // MARK: - Состояние входа

    private(set) var isLoggingIn = false
    /// true — интернета нет, запрос ждёт появления сети.
    private(set) var isWaitingForNetwork = false
    /// Текст ошибки последней попытки входа.
    private(set) var errorMessage: String?

    // MARK: - Проверка сервера (до входа)

    /// Результат проверки сервера, которая идёт, когда пользователь уходит из поля «Сервер».
    enum ServerCheckState: Equatable {
        /// Не проверяли (или адрес изменился после проверки).
        case notChecked
        /// Запрос отправлен, ждём ответа.
        case checking
        /// Сервер ответил — показываем его версию.
        case available(version: String)
        /// Сервер не ответил или ответил ошибкой — текст для пользователя.
        case unavailable(message: String)
    }

    private(set) var serverCheck: ServerCheckState = .notChecked
    /// Показывать ли ошибку в адресе. Показываем, только когда курсор ушёл из полей адреса:
    /// пока имя набирается («my.le…»), оно неправильное — краснеть на каждой букве незачем.
    private(set) var isAddressErrorVisible = false
    /// Какой адрес проверяли (или проверяем) — чтобы не проверять один и тот же дважды.
    private var checkedAddress: ServerAddress?

    private let session: AppSession
    private var loginTask: Task<Void, Never>?
    private var serverCheckTask: Task<Void, Never>?

    // Явно говорим: при удалении объекта из памяти ничего не нужно делать в главном потоке.
    // Без этого Swift (в режиме «по умолчанию всё в главном потоке») вставляет особую
    // «очистку в главном потоке», и на iOS 26 она падает с ошибкой памяти (проверено 2026-10-03).
    nonisolated deinit {}

    init(session: AppSession) {
        self.session = session

        // Заполняем адрес и логин с прошлого входа (пароль не храним).
        if let address = session.serverAddress {
            useHTTPS = address.useHTTPS
            hostText = address.host
            portText = String(address.port)
        } else {
            useHTTPS = true
            hostText = ""
            portText = String(ServerAddress.defaultHTTPSPort)
        }
        login = session.savedLogin
        // Если на экран входа попали не по своей воле (например, «Сессия истекла») — объясняем.
        errorMessage = session.logoutReason
    }

    // MARK: - Проверка введённого

    /// Что не так с адресом сервера (для текста под полями).
    private enum AddressProblem: Error {
        case emptyHost
        case badHost
        case badPort
    }

    /// Собирает адрес из переключателя, имени сервера и порта — или говорит, что не так.
    private func makeAddress() throws(AddressProblem) -> ServerAddress {
        let host = hostText.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.isEmpty {
            throw .emptyHost
        }
        // Только доменное имя или IP-адрес: «1» или «my» — не адрес, к ним даже не подключаемся.
        if !ServerAddress.isValidHost(host) {
            throw .badHost
        }
        // Порт: только цифры, от 1 до 65535.
        guard let port = Int(portText.trimmingCharacters(in: .whitespaces)), port >= 1, port <= 65535 else {
            throw .badPort
        }
        // Имя сервера проверяет тот же разборщик, что и адрес одной строкой: собираем строку
        // «https://имя:порт» и разбираем. Лишнее в имени («/путь», «:порт», пробелы) — ошибка.
        let scheme = useHTTPS ? "https" : "http"
        guard let address = try? ServerAddress(parsing: "\(scheme)://\(host):\(port)"),
              address.host.lowercased() == host.lowercased(),
              address.baseURL != nil else {
            throw .badHost
        }
        return address
    }

    /// Готовый адрес сервера — или nil, если что-то введено неправильно.
    var enteredAddress: ServerAddress? {
        return try? makeAddress()
    }

    /// Что не так с адресом сервера — или nil, если всё в порядке (или имя сервера пока пустое:
    /// на пустое поле не ругаемся, подсказка «Укажите адрес сервера» есть под кнопкой).
    var serverErrorMessage: String? {
        // «throws(AddressProblem)» — подсказка компилятору, что ошибка здесь может быть только
        // AddressProblem, поэтому в catch можно перечислить её варианты.
        do throws(AddressProblem) {
            _ = try makeAddress()
            return nil
        } catch .emptyHost {
            return nil
        } catch .badPort {
            return "Некорректный порт."
        } catch {
            return "Некорректный адрес сервера."
        }
    }

    /// Логин длиннее 30 символов (больше сервер не принимает) — текст ошибки под полями; иначе nil.
    var loginErrorMessage: String? {
        if login.trimmingCharacters(in: .whitespaces).count > 30 {
            return "Логин — не длиннее 30 символов."
        }
        return nil
    }

    /// Можно ли нажать «Войти»: адрес правильный, логин и пароль введены.
    /// Подсказок «Укажите адрес / логин / пароль» нет (решение владельца 2026-10-04):
    /// и так видно, что кнопка серая, пока поля не заполнены.
    var canLogIn: Bool {
        let cleanLogin = login.trimmingCharacters(in: .whitespaces)
        return enteredAddress != nil
            && !cleanLogin.isEmpty
            && loginErrorMessage == nil
            && !password.isEmpty
            && !isLoggingIn
    }

    // MARK: - Проверка сервера

    /// Курсор ушёл из полей «Сервер» и «Порт». Если адрес введён правильно — спрашиваем у сервера
    /// его версию (GET /api/v1/ServerInfo, без логина и пароля), чтобы сразу было видно,
    /// доступен ли сервер. Экран при этом не блокируется: можно вводить логин и пароль.
    func serverFieldDidLoseFocus() {
        // Пользователь закончил ввод — теперь можно показать, если в адресе ошибка.
        isAddressErrorVisible = true
        // Во время входа не проверяем: вход и так покажет, доступен ли сервер.
        if isLoggingIn {
            return
        }
        guard let address = enteredAddress, let baseURL = address.baseURL else {
            return
        }
        // Этот адрес уже проверяется или уже ответил — второй раз не спрашиваем:
        // на 2G каждый запрос стоит секунд. После ошибки — пробуем снова.
        if address == checkedAddress {
            switch serverCheck {
            case .checking, .available:
                return
            case .notChecked, .unavailable:
                break
            }
        }

        serverCheckTask?.cancel()
        checkedAddress = address
        serverCheck = .checking

        serverCheckTask = Task {
            do {
                // Проверка — быстрая проба: если сеть у телефона есть, а сервер не отвечает,
                // сдаёмся через 3 секунды (а не через 15, как при входе и загрузке списков).
                let client = APIClient(baseURL: baseURL, serverUnreachableDelay: 3)
                let info = try await client.fetchServerInfo(onProgress: { progress in
                    guard progress.isWaitingForNetwork else {
                        return
                    }
                    // У телефона нет сети. Запрос мог бы ждать её до 20 минут (так настроено
                    // для загрузки списков на 2G), но проверке ждать незачем — сразу сообщаем.
                    // (Сообщения о прогрессе приходят из фонового потока, а свойства экрана
                    // меняем только в главном.)
                    Task { @MainActor in
                        // Только если идёт именно эта проверка (адрес могли уже исправить).
                        if self.serverCheck == .checking && self.checkedAddress == address {
                            self.serverCheckTask?.cancel()
                            self.serverCheck = .unavailable(message: Self.noConnectionMessage)
                        }
                    }
                })
                // Проверку отменили (адрес изменился), а ответ всё же успел прийти — он уже не нужен.
                if Task.isCancelled {
                    return
                }
                serverCheck = .available(version: info.version ?? info.fullVersion ?? "")
            } catch {
                let apiError = APIError.from(error)
                if apiError == .cancelled || Task.isCancelled {
                    return
                }
                serverCheck = .unavailable(message: Self.serverCheckMessage(for: apiError))
            }
        }
    }

    /// Адрес изменился (протокол, имя или порт). Прежний результат проверки к нему
    /// не относится: убираем его и отменяем идущую проверку.
    func addressDidChange() {
        if enteredAddress != checkedAddress {
            cancelServerCheck()
        }
    }

    /// Изменилось имя сервера. Если вставили адрес целиком, как из браузера
    /// («https://my.lers.ru:8443/»), — раскладываем его по переключателю, имени и порту.
    func hostTextDidChange() {
        // Адрес снова редактируют — прячем ошибку до конца ввода.
        isAddressErrorVisible = false
        guard hostText.contains("://"), let address = try? ServerAddress(parsing: hostText) else {
            return
        }
        useHTTPS = address.useHTTPS
        hostText = address.host
        portText = String(address.port)
    }

    /// Изменилось поле порта: оставляем только цифры, не больше пяти (порт — до 65535).
    func portTextDidChange() {
        isAddressErrorVisible = false
        let digits = String(portText.filter { $0.isASCII && $0.isNumber }.prefix(5))
        // Присваиваем, только если что-то отрезали, — иначе изменение вызвало бы само себя снова.
        if digits != portText {
            portText = digits
        }
    }

    /// Переключили https/http. Если в поле порта стандартный порт прежнего протокола
    /// (или пусто) — ставим стандартный порт нового: 443 для https, 10000 для http (порт ЛЭРС).
    func protocolDidChange() {
        let oldDefaultPort = useHTTPS ? ServerAddress.defaultHTTPPort : ServerAddress.defaultHTTPSPort
        let newDefaultPort = useHTTPS ? ServerAddress.defaultHTTPSPort : ServerAddress.defaultHTTPPort
        let currentPort = portText.trimmingCharacters(in: .whitespaces)
        if currentPort.isEmpty || Int(currentPort) == oldDefaultPort {
            portText = String(newDefaultPort)
        }
    }

    /// Ссылка «Демо-доступ»: заполняет поля демо-сервером разработчика ЛЭРС
    /// (открыт для всех, учётная запись demo/demo) и сразу проверяет, отвечает ли он.
    func fillDemoAccess() {
        useHTTPS = true
        hostText = "my.lers.ru"
        portText = String(ServerAddress.defaultHTTPSPort)
        login = "demo"
        password = "demo"
        errorMessage = nil
        serverFieldDidLoseFocus()
    }

    private func cancelServerCheck() {
        serverCheckTask?.cancel()
        serverCheckTask = nil
        checkedAddress = nil
        serverCheck = .notChecked
    }

    /// У телефона нет сети — проверить сервер нельзя.
    private static let noConnectionMessage = "Нет соединения с интернетом."

    /// Текст под полем «Сервер», если сервер не ответил.
    private static func serverCheckMessage(for error: APIError) -> String {
        switch error {
        case .serverUnreachable:
            // Обычный текст этой ошибки и так начинается со слов «Сервер не найден или недоступен».
            return error.errorDescription ?? "Сервер недоступен."
        case .invalidResponse:
            return "По этому адресу отвечает не сервер ЛЭРС (или ответ не удалось разобрать)."
        case .unexpectedStatus(let code):
            // Кто-то по этому адресу отвечает, но не так, как сервер ЛЭРС (например, 404 — «нет такой страницы»).
            return "Сервер ответил ошибкой (код \(code)). Возможно, это не сервер ЛЭРС или неверный порт."
        default:
            return "Сервер недоступен. " + (error.errorDescription ?? "")
        }
    }

    // MARK: - Действия

    /// Нажата кнопка «Войти». Вход идёт в фоне — экран не блокируется, вход можно отменить.
    func logIn() {
        guard canLogIn, let address = enteredAddress else {
            return
        }
        let cleanLogin = login.trimmingCharacters(in: .whitespaces)
        let currentPassword = password

        // Если проверка сервера ещё идёт — отменяем: вход сам покажет, доступен ли сервер,
        // а два запроса одновременно на медленной связи мешают друг другу.
        if case .checking = serverCheck {
            cancelServerCheck()
        }

        isLoggingIn = true
        isWaitingForNetwork = false
        errorMessage = nil

        loginTask = Task {
            do {
                try await session.logIn(address: address, login: cleanLogin, password: currentPassword,
                                        onProgress: { progress in
                    // Сообщения о прогрессе приходят из фонового потока,
                    // а свойства экрана меняем только в главном.
                    Task { @MainActor in
                        self.isWaitingForNetwork = progress.isWaitingForNetwork
                    }
                })
                // Успех: AppSession сменит экран входа на основной сам.
                password = ""
            } catch {
                let apiError = APIError.from(error)
                if apiError != .cancelled {
                    errorMessage = apiError.errorDescription
                }
            }
            isLoggingIn = false
            isWaitingForNetwork = false
        }
    }

    /// Нажата кнопка «Отмена» во время входа.
    func cancelLogIn() {
        loginTask?.cancel()
    }
}
