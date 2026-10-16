import Foundation

// Клиент сервера ЛЭРС: вход, загрузка списков объектов, точек учёта и оборудования,
// данных точек и PDF-отчётов.
//
// Главная цель приложения — работа на медленной связи (EDGE/2G), см. «⚠️ ВАЖНО» в PLAN.md.
// Поэтому здесь:
//   • один общий URLSession на всё приложение — соединение с сервером переиспользуется,
//     а не устанавливается заново для каждого запроса (на 2G это экономит секунды);
//   • терпеливые тайм-ауты и ожидание сети вместо мгновенной ошибки;
//   • наблюдение за количеством принятых байтов, чтобы показывать прогресс «X КБ из Y КБ»;
//   • вся работа (ожидание сети, приём данных, разбор JSON) идёт НЕ в главном потоке,
//     поэтому интерфейс не подвисает даже на большом ответе.
//
// Что значат слова в объявлениях:
//   nonisolated — код можно выполнять в любом потоке (по умолчанию в проекте всё
//                 привязано к главному потоку, где рисуется интерфейс);
//   @concurrent — функция всегда выполняется в фоновом потоке, а не в том, откуда её вызвали;
//   async/await — функция может «подождать» (например, ответа сервера), не блокируя поток;
//   throws      — функция может завершиться ошибкой (у нас это всегда APIError).

/// Сколько данных уже получено — для полосы прогресса.
nonisolated struct DownloadProgress: Equatable, Sendable {
    /// Сколько байт уже пришло.
    var receivedBytes: Int64
    /// Полный размер ответа, если сервер его сообщил (заголовок Content-Length). nil — неизвестен.
    var expectedBytes: Int64?
    /// true — у телефона нет сети, запрос ждёт, когда она появится.
    /// (Если сеть есть, а сервер не отвечает, — здесь false: это не «нет сети».)
    var isWaitingForNetwork: Bool

    /// Доля загруженного от 0 до 1 — или nil, если полный размер неизвестен.
    var fraction: Double? {
        guard let expectedBytes, expectedBytes > 0 else {
            return nil
        }
        let value = Double(receivedBytes) / Double(expectedBytes)
        return min(value, 1.0)
    }
}

nonisolated final class APIClient: Sendable {

    /// Имя приложения, которое сервер записывает в токен при входе.
    static let applicationName = "OpenLuch iOS"

    /// Общее на всё приложение «соединение» с настройками под медленную связь.
    static let sharedSession: URLSession = {
        let configuration = URLSessionConfiguration.default

        // Если сети нет — не падать сразу с ошибкой, а дождаться её появления.
        configuration.waitsForConnectivity = true

        // Сколько можно ждать очередную порцию данных, когда связь уже есть.
        // На 2G пинг больше секунды, а сервер на большом запросе думает пару секунд — 60 с с запасом.
        configuration.timeoutIntervalForRequest = 60

        // Сколько может длиться весь запрос целиком, включая ожидание сети.
        // Список из 1500+ точек (~3 МБ) по GPRS идёт больше 10 минут — даём 20.
        configuration.timeoutIntervalForResource = 20 * 60

        // Свой кэш мы ведём сами (CacheStore), системный HTTP-кэш не нужен:
        // сервер ЛЭРС всё равно не присылает заголовков для него.
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData

        return URLSession(configuration: configuration)
    }()

    /// Адрес сервера, например http://192.168.1.10:10000
    let baseURL: URL
    private let session: URLSession
    /// Сколько секунд ждать, если сеть у телефона есть, а соединиться с сервером не получается.
    /// После этого запрос прерывается с ошибкой «сервер недоступен» (а не ждёт сеть 20 минут).
    /// Запас нужен, чтобы на 2G не оборвать переподключение, когда сеть только что появилась.
    private let serverUnreachableDelay: TimeInterval

    init(baseURL: URL, session: URLSession = APIClient.sharedSession, serverUnreachableDelay: TimeInterval = 15) {
        self.baseURL = baseURL
        self.session = session
        self.serverUnreachableDelay = serverUnreachableDelay
    }

    // MARK: - Запросы к серверу

    /// Вход по логину и паролю: POST /api/v1/Login. Возвращает токен.
    /// Пароль никуда не сохраняется — дальше работаем только с токеном.
    @concurrent
    func login(login: String, password: String,
               onProgress: @escaping @Sendable (DownloadProgress) -> Void = { _ in }) async throws -> String {
        var request = URLRequest(url: makeURL(path: "api/v1/Login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let body = LoginRequest(login: login, password: password, application: APIClient.applicationName)
        request.httpBody = try JSONEncoder().encode(body)

        let data = try await download(request, onProgress: onProgress)

        let response: LoginResponse
        do {
            response = try ServerDateParser.makeDecoder().decode(LoginResponse.self, from: data)
        } catch {
            throw APIError.invalidResponse
        }

        if response.oneTimePasswordRequired == true {
            throw APIError.oneTimePasswordNotSupported
        }
        guard let token = response.token, !token.isEmpty else {
            throw APIError.invalidResponse
        }
        return token
    }

    /// Сведения о сервере: GET /api/v1/ServerInfo. Без авторизации, ответ ~0,2 КБ.
    /// Нужен на экране входа — проверить адрес сервера ещё до ввода логина и пароля.
    /// Заодно устанавливается соединение с сервером, и следующий запрос (вход) пройдёт быстрее.
    @concurrent
    func fetchServerInfo(onProgress: @escaping @Sendable (DownloadProgress) -> Void = { _ in }) async throws -> ServerInfo {
        var request = URLRequest(url: makeURL(path: "api/v1/ServerInfo"))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data = try await download(request, onProgress: onProgress)

        let info: ServerInfo
        do {
            info = try JSONDecoder().decode(ServerInfo.self, from: data)
        } catch {
            throw APIError.invalidResponse
        }
        // Без версии это, скорее всего, вообще не сервер ЛЭРС, а что-то другое на этом адресе.
        if info.version == nil && info.fullVersion == nil {
            throw APIError.invalidResponse
        }
        return info
    }

    /// Сведения о сервере для экрана «О сервере»: GET /api/v1/ServerInfo (версия, ~0,3 КБ)
    /// и GET /api/v1/ServerInfo/Extra (лицензия, контакты администратора, ~3 КБ) — одно соединение.
    @concurrent
    func fetchServerDetails(token: String) async throws -> ServerDetails {
        let info = try await fetchServerInfo()
        let request = makeAuthorizedGETRequest(path: "api/v1/ServerInfo/Extra", queryItems: [], token: token)
        let data = try await download(request, onProgress: { _ in })
        do {
            let extra = try JSONDecoder().decode(ServerExtraInfoResponse.self, from: data)
            return extra.makeDetails(serverInfo: info, savedAt: Date())
        } catch {
            throw APIError.invalidResponse
        }
    }

    /// Список объектов учёта: GET /api/v1/Core/Nodes?getCustomers=true&getAttributes=true.
    /// Из дополнительных данных — потребители (для фильтра «Потребитель» и карточки объекта): сервер
    /// присылает лишь тех, на кого ссылаются объекты, ~0,3 КБ на потребителя; и пользовательские атрибуты
    /// объектов (~0,1 КБ на атрибут) — для карточки объекта (см. docs/api-notes.md).
    /// Возвращает объекты, потребителей и размер ответа в байтах (его запоминаем, чтобы в следующий раз
    /// заранее показать, сколько придётся скачать).
    @concurrent
    func fetchNodes(token: String,
                    onProgress: @escaping @Sendable (DownloadProgress) -> Void = { _ in })
    async throws -> (nodes: [Node], customers: [Customer], responseBytes: Int) {
        let request = makeAuthorizedGETRequest(path: "api/v1/Core/Nodes",
                                               queryItems: [URLQueryItem(name: "getCustomers", value: "true"),
                                                            URLQueryItem(name: "getAttributes", value: "true")],
                                               token: token)
        let data = try await download(request, onProgress: onProgress)

        do {
            let response = try ServerDateParser.makeDecoder().decode(NodeListResponse.self, from: data)
            return (nodes: response.nodes ?? [], customers: response.customers ?? [], responseBytes: data.count)
        } catch {
            throw APIError.invalidResponse
        }
    }

    /// Вошедший пользователь — имя и права: GET /api/v1/Login/Current (~1,8 КБ).
    @concurrent
    func fetchCurrentUser(token: String) async throws -> CurrentUser {
        let request = makeAuthorizedGETRequest(path: "api/v1/Login/Current", queryItems: [], token: token)
        let data = try await download(request, onProgress: { _ in })
        let response: CurrentLoginResponse
        do {
            response = try JSONDecoder().decode(CurrentLoginResponse.self, from: data)
        } catch {
            throw APIError.invalidResponse
        }
        return response.makeUser()
    }

    /// Группы объектов учёта: GET /api/v1/Core/NodeGroups. Ответ крошечный (~0,1 КБ на группу).
    @concurrent
    func fetchNodeGroups(token: String) async throws -> [NodeGroup] {
        let request = makeAuthorizedGETRequest(path: "api/v1/Core/NodeGroups", queryItems: [], token: token)
        let data = try await download(request, onProgress: { _ in })
        do {
            let response = try JSONDecoder().decode([NodeGroupResponse].self, from: data)
            return NodeGroupResponse.makeGroups(from: response)
        } catch {
            throw APIError.invalidResponse
        }
    }

    /// Незавершённые работы на всех объектах: GET /api/v1/Core/NodeJobs?incomplete=true (~1 КБ на работу).
    /// Фильтра по объекту в API нет (nodeId сервер молча игнорирует), поэтому берём все сразу.
    @concurrent
    func fetchIncompleteNodeJobs(token: String) async throws -> [NodeJob] {
        let request = makeAuthorizedGETRequest(path: "api/v1/Core/NodeJobs",
                                               queryItems: [URLQueryItem(name: "incomplete", value: "true")],
                                               token: token)
        let data = try await download(request, onProgress: { _ in })
        do {
            let response = try JSONDecoder().decode([NodeJobResponse].self, from: data)
            return response.map { $0.makeJob() }
        } catch {
            throw APIError.invalidResponse
        }
    }

    /// Список обычных точек учёта: GET /api/v1/Core/MeasurePoints?type=Regular&getCustomers=true.
    /// type=Regular — сервер не присылает квартирные точки (их в приложении нет, см. PLAN.md).
    /// getCustomers=true — потребители, указанные у самих точек (как у fetchNodes).
    /// Возвращает точки, потребителей и размер ответа в байтах (как fetchNodes).
    @concurrent
    func fetchMeasurePoints(token: String,
                            onProgress: @escaping @Sendable (DownloadProgress) -> Void = { _ in })
    async throws -> (measurePoints: [MeasurePoint], customers: [Customer], responseBytes: Int) {
        let request = makeAuthorizedGETRequest(
            path: "api/v1/Core/MeasurePoints",
            queryItems: [URLQueryItem(name: "type", value: "Regular"),
                         URLQueryItem(name: "getCustomers", value: "true")],
            token: token
        )
        let data = try await download(request, onProgress: onProgress)

        do {
            let response = try ServerDateParser.makeDecoder().decode(MeasurePointListResponse.self, from: data)
            return (measurePoints: response.measurePoints ?? [], customers: response.customers ?? [],
                    responseBytes: data.count)
        } catch {
            throw APIError.invalidResponse
        }
    }

    /// Справочник пользовательских атрибутов: GET /api/v1/Inventory/CustomAttributes (~2,4 КБ на весь сервер).
    /// Нужен только ради названий атрибутов точек (у точек сервер присылает лишь коды).
    /// Возвращает «код → название».
    @concurrent
    func fetchAttributeTitles(token: String) async throws -> [String: String] {
        let request = makeAuthorizedGETRequest(path: "api/v1/Inventory/CustomAttributes", queryItems: [], token: token)
        let data = try await download(request, onProgress: { _ in })
        do {
            let response = try JSONDecoder().decode([CustomAttributeResponse].self, from: data)
            return CustomAttributeResponse.makeTitles(from: response)
        } catch {
            throw APIError.invalidResponse
        }
    }

    /// Справочник оборудования: GET /api/v1/Core/Equipment (без параметров — весь список).
    /// Ответ тяжёлый (на my.lers.ru 64 прибора — 363 КБ, три четверти — описания моделей),
    /// более лёгкого способа получить список в API нет (см. docs/api-notes.md).
    /// Возвращает оборудование (только нужные поля) и размер ответа в байтах (как fetchNodes).
    @concurrent
    func fetchEquipment(token: String,
                        onProgress: @escaping @Sendable (DownloadProgress) -> Void = { _ in })
    async throws -> (equipment: [Equipment], responseBytes: Int) {
        let request = makeAuthorizedGETRequest(path: "api/v1/Core/Equipment", queryItems: [], token: token)
        let data = try await download(request, onProgress: onProgress)

        do {
            let response = try JSONDecoder().decode(EquipmentListResponse.self, from: data)
            return (equipment: Equipment.makeList(from: response), responseBytes: data.count)
        } catch {
            throw APIError.invalidResponse
        }
    }

    // MARK: - Последние данные точки учёта

    /// Последнее потребление (текущие параметры): GET /api/v1/Data/MeasurePoints/{id}/Consumption/Last.
    /// Ответ маленький (0,8–4,5 КБ). nil — у точки нет данных.
    @concurrent
    func fetchLastConsumption(pointId: Int, token: String) async throws -> LastDataRecord? {
        let request = makeAuthorizedGETRequest(path: "api/v1/Data/MeasurePoints/\(pointId)/Consumption/Last",
                                               queryItems: [], token: token)
        let data = try await download(request, onProgress: { _ in })
        return try decodeOptionalRecord(data)
    }

    /// Последние интеграторы (накопленные значения счётчиков): GET /api/v1/Data/MeasurePoints/{id}/Totals/Last.
    /// Ответ 0,2–1,4 КБ. nil — у точки нет данных.
    @concurrent
    func fetchLastTotals(pointId: Int, token: String) async throws -> LastDataRecord? {
        let request = makeAuthorizedGETRequest(path: "api/v1/Data/MeasurePoints/\(pointId)/Totals/Last",
                                               queryItems: [], token: token)
        let data = try await download(request, onProgress: { _ in })
        return try decodeOptionalRecord(data)
    }

    /// Единицы измерения точки (°C, т, Гкал…). Отдельного запроса для них в API нет, а в ответах
    /// …/Last их нет. Поэтому спрашиваем потребление точки за ПУСТОЙ период (послезавтра — данных
    /// там быть не может): сервер присылает только список единиц этой точки, 0,8 КБ.
    /// Подробности — docs/api-notes.md.
    @concurrent
    func fetchUnits(pointId: Int, token: String) async throws -> ServerUnits {
        let dayAfterTomorrow = Date().addingTimeInterval(2 * 24 * 60 * 60)
        let day = dayAfterTomorrow.formatted(.iso8601.year().month().day())
        let request = makeAuthorizedGETRequest(
            path: "api/v1/Data/MeasurePoints/\(pointId)/Consumption/\(day)/\(day)",
            queryItems: [URLQueryItem(name: "dataTypes", value: "Month"),
                         URLQueryItem(name: "units", value: "SystemUnits")],
            token: token
        )
        let data = try await download(request, onProgress: { _ in })
        let response: ConsumptionUnitsResponse
        do {
            response = try JSONDecoder().decode(ConsumptionUnitsResponse.self, from: data)
        } catch {
            throw APIError.invalidResponse
        }
        var unitsByCategory: [String: String] = [:]
        for pair in response.dataParametersUnit ?? [] {
            unitsByCategory[pair.dataParameterCategory] = pair.unit
        }
        return ServerUnits(unitsByCategory: unitsByCategory)
    }

    /// Архив потребления точки за период: часовые, суточные или месячные записи с `first` по `last`
    /// включительно (сервер включает оба конца). GET /api/v1/Data/MeasurePoints/{id}/Consumption/{start}/{end}.
    /// ⚠️ Ответ тяжёлый: до 3 КБ на запись (выбрать параметры в запросе нельзя), поэтому запрашиваем
    /// порциями по одному экрану графика (см. ArchivePeriod.portionLength и docs/api-notes.md).
    /// Единицы — системные, как у последних данных (fetchUnits), чтобы числа на графике и в карточке совпадали.
    @concurrent
    func fetchConsumptionArchive(pointId: Int, period: ArchivePeriod, first: Date, last: Date, token: String,
                                 onProgress: @escaping @Sendable (DownloadProgress) -> Void = { _ in })
    async throws -> ArchivePortion {
        let start = ArchiveDates.serverString(first)
        let end = ArchiveDates.serverString(last)
        let request = makeAuthorizedGETRequest(
            path: "api/v1/Data/MeasurePoints/\(pointId)/Consumption/\(start)/\(end)",
            queryItems: [URLQueryItem(name: "dataTypes", value: period.serverDataType),
                         URLQueryItem(name: "units", value: "SystemUnits")],
            token: token
        )
        let data = try await download(request, onProgress: onProgress)
        do {
            let response = try JSONDecoder().decode(ArchiveResponse.self, from: data)
            return ArchivePortion(records: response.records(for: period), units: response.units)
        } catch {
            throw APIError.invalidResponse
        }
    }

    // MARK: - Датчики точки учёта

    /// Датчики точки: GET /api/v1/Core/MeasurePoints/{id}?getSensor=true.
    /// ⚠️ Ответ тяжёлый (~365 КБ на demo): сервер всегда прикладывает справочник оборудования
    /// объекта точки, отключить нельзя (см. docs/api-notes.md). Поэтому датчики храним в кэше
    /// и запрашиваем редко (см. PointSensorsModel). Возвращает датчики и размер ответа.
    @concurrent
    func fetchPointSensors(pointId: Int, token: String,
                           onProgress: @escaping @Sendable (DownloadProgress) -> Void = { _ in })
    async throws -> (sensors: [PointSensor], responseBytes: Int) {
        let request = makeAuthorizedGETRequest(path: "api/v1/Core/MeasurePoints/\(pointId)",
                                               queryItems: [URLQueryItem(name: "getSensor", value: "true")],
                                               token: token)
        let data = try await download(request, onProgress: onProgress)
        do {
            let response = try JSONDecoder().decode(MeasurePointSensorsResponse.self, from: data)
            return (sensors: response.makeSensors(), responseBytes: data.count)
        } catch {
            throw APIError.invalidResponse
        }
    }

    // MARK: - Нештатные ситуации

    /// Активные нештатные ситуации точки: GET /api/v1/Incidents/Active/MeasurePoint/{id}.
    /// Ответ маленький (пустой список — 2 байта; одна НС — около 1 КБ).
    @concurrent
    func fetchActiveIncidents(pointId: Int, token: String) async throws -> [Incident] {
        let request = makeAuthorizedGETRequest(path: "api/v1/Incidents/Active/MeasurePoint/\(pointId)",
                                               queryItems: [], token: token)
        let data = try await download(request, onProgress: { _ in })
        do {
            return try JSONDecoder().decode([Incident].self, from: data)
        } catch {
            throw APIError.invalidResponse
        }
    }

    /// Одна нештатная ситуация и её журнал: GET /api/v1/Incidents/{id}.
    @concurrent
    func fetchIncidentDetails(incidentId: Int, token: String) async throws -> IncidentDetailsResponse {
        let request = makeAuthorizedGETRequest(path: "api/v1/Incidents/\(incidentId)", queryItems: [], token: token)
        let data = try await download(request, onProgress: { _ in })
        do {
            return try JSONDecoder().decode(IncidentDetailsResponse.self, from: data)
        } catch {
            throw APIError.invalidResponse
        }
    }

    // MARK: - Ручной опрос прибора

    /// Запустить разовый опрос текущих данных точки: POST /api/v1/Poll/MeasurePoints/{id}/Currents?once=true
    /// (once=true — один опрос, а не постоянный мониторинг). Сервер сам связывается с прибором;
    /// ответ — только номер сеанса опроса. ⚠️ Узнать ход сеанса через REST API нельзя (такого запроса нет),
    /// поэтому результат проверяем по времени последней записи (см. PointPollModel).
    /// Если опрос запустить нельзя («Модем не подключен», «Порт опроса не настроен…»), сервер отвечает 422
    /// понятным текстом — он придёт как APIError.serverError.
    @concurrent
    func startCurrentsPoll(pointId: Int, token: String) async throws -> Int? {
        var url = makeURL(path: "api/v1/Poll/MeasurePoints/\(pointId)/Currents")
        url = url.appending(queryItems: [URLQueryItem(name: "once", value: "true")])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Тела нет, но сервер требует Content-Length (иначе «411 Length Required», как у отчётов).
        request.httpBody = Data()
        request.setValue("0", forHTTPHeaderField: "Content-Length")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let data = try await download(request, onProgress: { _ in })
        return (try? JSONDecoder().decode(ManualPollResponse.self, from: data))?.pollSessionId
    }

    // MARK: - Отчёты точки учёта (PDF)

    /// Отчёты, назначенные точке: GET /api/v1/Core/MeasurePoints/{id}?getReports=true&getSensor=true.
    /// ⚠️ Ответ тяжёлый (~450 КБ на demo): как и у датчиков, сервер всегда прикладывает справочник
    /// оборудования объекта, плюс ~80 КБ шаблонов отчётов. Поэтому список храним в кэше и запрашиваем
    /// редко (см. PointReportsModel). Датчики просим в том же запросе — это почти бесплатно (+0,5 КБ),
    /// зато потом не придётся отдельно качать для них те же ~365 КБ.
    /// Возвращает отчёты (только ведомости параметров), датчики и размер ответа.
    @concurrent
    func fetchPointReports(pointId: Int, token: String,
                           onProgress: @escaping @Sendable (DownloadProgress) -> Void = { _ in })
    async throws -> (reports: [PointReport], sensors: [PointSensor], responseBytes: Int) {
        let request = makeAuthorizedGETRequest(path: "api/v1/Core/MeasurePoints/\(pointId)",
                                               queryItems: [URLQueryItem(name: "getReports", value: "true"),
                                                            URLQueryItem(name: "getSensor", value: "true")],
                                               token: token)
        let data = try await download(request, onProgress: onProgress)
        do {
            // Один и тот же ответ разбираем двумя «шаблонами»: отчёты и датчики (так проще читать).
            let reports = try JSONDecoder().decode(MeasurePointReportsResponse.self, from: data)
            let sensors = try JSONDecoder().decode(MeasurePointSensorsResponse.self, from: data)
            return (reports: reports.makeReports(), sensors: sensors.makeSensors(), responseBytes: data.count)
        } catch {
            throw APIError.invalidResponse
        }
    }

    /// Сформировать отчёт: POST /api/v1/Reporting/Generate/ParameterSheet/{reportId}/{dataType}/{start}/{end}?id={точка}.
    /// Ответ маленький (~0,8 КБ) — ссылка на готовый файл (PDF — формат по умолчанию).
    /// Даты — строки без часового пояса, см. ReportPeriod.serverDates.
    @concurrent
    func generateReport(reportId: Int, dataType: ReportDataType, start: String, end: String, pointId: Int,
                        token: String,
                        onProgress: @escaping @Sendable (DownloadProgress) -> Void = { _ in }) async throws -> ReportFileLink {
        var url = makeURL(path: "api/v1/Reporting/Generate/ParameterSheet/\(reportId)/\(dataType.apiValue)/\(start)/\(end)")
        url = url.appending(queryItems: [URLQueryItem(name: "id", value: String(pointId)),
                                         URLQueryItem(name: "format", value: "Pdf")])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // Тела у запроса нет, но сервер требует заголовок Content-Length,
        // иначе отвечает «411 Length Required» (проверено на my.lers.ru).
        request.httpBody = Data()
        request.setValue("0", forHTTPHeaderField: "Content-Length")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // Большой отчёт сервер может готовить дольше минуты, ничего не присылая. Обычные 60 с
        // ожидания тут мало — даём 5 минут (ход ожидания виден на экране, есть кнопка «Отмена»).
        request.timeoutInterval = 5 * 60

        // Прогресс здесь нужен только для «Нет сети, ждём подключения…»: сам ответ крошечный.
        let data = try await download(request, onProgress: onProgress)
        do {
            return try JSONDecoder().decode(ReportFileLink.self, from: data)
        } catch {
            throw APIError.invalidResponse
        }
    }

    /// Скачать готовый файл отчёта по ссылке из generateReport (GET /api/v1/Downloads/{ключ}/{имя}).
    /// Размер известен заранее (Content-Length), поэтому идёт полоса «X КБ из Y КБ».
    @concurrent
    func downloadReportFile(link: ReportFileLink, token: String,
                            onProgress: @escaping @Sendable (DownloadProgress) -> Void = { _ in }) async throws -> Data {
        guard let url = APIClient.downloadURL(baseURL: baseURL, uri: link.uri) else {
            throw APIError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/pdf", forHTTPHeaderField: "Accept")
        // Ссылка открывается и без токена, но передаём его — на других серверах может быть иначе.
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let data = try await download(request, onProgress: onProgress)
        // Настоящий PDF всегда начинается с «%PDF». Иначе сервер прислал что-то другое (например, страницу ошибки).
        guard data.starts(with: Data("%PDF".utf8)) else {
            throw APIError.invalidResponse
        }
        return data
    }

    /// Полный адрес файла: сервер присылает путь вида «/api/v1/Downloads/…» (уже с %-кодированием
    /// русских букв), его нужно приписать к адресу сервера. Если пришёл полный адрес — берём как есть.
    static func downloadURL(baseURL: URL, uri: String) -> URL? {
        if uri.hasPrefix("http://") || uri.hasPrefix("https://") {
            return URL(string: uri)
        }
        var base = baseURL.absoluteString
        while base.hasSuffix("/") {
            base.removeLast()
        }
        let path = uri.hasPrefix("/") ? uri : "/" + uri
        return URL(string: base + path)
    }

    /// Пустой ответ или «null» — данных нет; иначе — запись.
    private func decodeOptionalRecord(_ data: Data) throws -> LastDataRecord? {
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text == "null" {
            return nil
        }
        do {
            return try JSONDecoder().decode(LastDataRecord.self, from: data)
        } catch {
            throw APIError.invalidResponse
        }
    }

    // MARK: - Вспомогательное

    private func makeURL(path: String) -> URL {
        return baseURL.appending(path: path)
    }

    private func makeAuthorizedGETRequest(path: String, queryItems: [URLQueryItem], token: String) -> URLRequest {
        var url = makeURL(path: path)
        if !queryItems.isEmpty {
            url = url.appending(queryItems: queryItems)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Так сервер ЛЭРС принимает токен (проверено на my.lers.ru, см. docs/api-notes.md).
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    /// Выполняет запрос, пока он идёт — сообщает о прогрессе. Возвращает тело ответа или бросает APIError.
    ///
    /// Как считается прогресс: ответ принимает стандартный быстрый `session.data(for:)`, а рядом
    /// работает маленькая фоновая задача, которая 4 раза в секунду смотрит, сколько байт уже пришло,
    /// и сообщает об этом. (Принимать ответ побайтно и считать самим — слишком медленно:
    /// замер показал ~20 с процессорного времени на 3 МБ.)
    private func download(_ request: URLRequest,
                          onProgress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> Data {
        let observer = NetworkTaskObserver()
        let unreachableDelay = serverUnreachableDelay
        let startedAt = Date()

        // Фоновая задача-«наблюдатель» за прогрессом. Работает, пока её не остановят (cancel).
        // Заодно следит, не пора ли сдаться: сеть у телефона есть, а сервер так и не отвечает.
        let progressReporter = Task {
            var isSilenceReported = false
            while !Task.isCancelled {
                onProgress(observer.currentProgress())
                observer.giveUpIfServerUnreachable(after: unreachableDelay)
                // Сервер молчит 2 секунды — пусть ConnectionProblemDetector выяснит почему.
                // Сам запрос при этом продолжает ждать по своим правилам.
                if !isSilenceReported && !observer.hasServerAnswered
                    && Date().timeIntervalSince(startedAt) >= ConnectionProblemDetector.serverSilenceDelay {
                    isSilenceReported = true
                    APIClient.reportServerSilence()
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }

        // Сам запрос: ждём, пока придёт весь ответ.
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: observer)
        } catch {
            progressReporter.cancel()
            // Запрос прервал наш «наблюдатель», потому что сервер недоступен (а не пользователь).
            let apiError = observer.didGiveUp ? APIError.serverUnreachable : APIError.from(error)
            // Сообщаем ConnectionProblemDetector, чтобы он выяснил причину.
            switch apiError {
            case .serverUnreachable, .timedOut, .noConnection:
                // Сервер так и не ответил — если интернет есть, покажем «сервер не отвечает».
                APIClient.reportServerFailure()
            case .connectionLost, .secureConnectionFailed, .other:
                // Сервер мог и отвечать (обрыв посреди загрузки, сертификат) — только проверяем,
                // нет ли проблем с интернетом, но «сервер не отвечает» не утверждаем.
                APIClient.reportServerSilence()
            default:
                break
            }
            throw apiError
        }
        progressReporter.cancel()
        onProgress(observer.currentProgress())

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        // Сервер ответил (неважно, каким кодом) — строка о проблеме со связью больше не нужна.
        Task { @MainActor in
            ConnectionProblemDetector.shared.serverDidRespond()
        }
        // Проверяем код ответа (401, 422, 500…). Тело уже есть — в нём может быть текст ошибки.
        if let error = APIError.fromHTTPStatus(httpResponse.statusCode, body: data) {
            throw error
        }
        return data
    }

    /// Сообщить ConnectionProblemDetector, что сервер молчит (он работает в главном потоке, а мы — в фоновом).
    private static func reportServerSilence() {
        Task { @MainActor in
            ConnectionProblemDetector.shared.serverIsSilent()
        }
    }

    /// Сообщить ConnectionProblemDetector, что запрос к серверу завершился ошибкой связи.
    private static func reportServerFailure() {
        Task { @MainActor in
            ConnectionProblemDetector.shared.serverRequestFailed()
        }
    }
}

/// «Наблюдатель» за запросом. Система сообщает ему:
///   • что запрос создан — запоминаем его, чтобы смотреть счётчик принятых байтов;
///   • что запрос ждёт появления сети (так бывает при waitsForConnectivity, когда интернета нет —
///     или когда интернет есть, но сервер не отвечает; различаем через NetworkMonitor).
///
/// Сообщения приходят из одного потока, а читаем мы их из другого, поэтому доступ к полям
/// защищён замком (NSLock): одновременно с полями работает только один поток.
/// `@unchecked Sendable` — «я сам отвечаю за безопасность между потоками» (как раз через замок).
private nonisolated final class NetworkTaskObserver: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var isWaitingForNetwork = false
    /// Когда система сообщила, что запрос ждёт сеть.
    private var waitingStartedAt: Date?
    private var gaveUp = false

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        lock.lock()
        self.task = task
        lock.unlock()
    }

    func urlSession(_ session: URLSession, taskIsWaitingForConnectivity task: URLSessionTask) {
        lock.lock()
        isWaitingForNetwork = true
        waitingStartedAt = Date()
        lock.unlock()
    }

    /// true — сервер уже начал отвечать (пришли заголовки или первые байты).
    var hasServerAnswered: Bool {
        lock.lock()
        let task = self.task
        lock.unlock()
        guard let task else {
            return false
        }
        return task.response != nil || task.countOfBytesReceived > 0
    }

    /// true — запрос прерван нами, потому что сервер недоступен.
    var didGiveUp: Bool {
        lock.lock()
        defer { lock.unlock() }
        return gaveUp
    }

    /// Прерывает запрос, если он «ждёт сеть», хотя сеть у телефона есть уже `delay` секунд.
    /// Значит, дело не в сети, а в сервере: неверный адрес или порт, сервер выключен.
    /// Если сети действительно нет — ничего не делаем: запрос дождётся её (это нужно на 2G).
    func giveUpIfServerUnreachable(after delay: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }

        guard !gaveUp, let task, let waitingStartedAt else {
            return
        }
        // Сервер уже начал отвечать — всё в порядке.
        if task.response != nil || task.countOfBytesReceived > 0 {
            return
        }
        guard let networkSince = NetworkMonitor.shared.networkAvailableSince else {
            return
        }
        // Отсчёт — от более позднего из двух моментов: «запрос стал ждать» и «появилась сеть».
        // Так, если сеть только что вернулась, у запроса есть время спокойно переподключиться.
        let countFrom = max(waitingStartedAt, networkSince)
        if Date().timeIntervalSince(countFrom) >= delay {
            gaveUp = true
            task.cancel()
        }
    }

    /// Текущее состояние загрузки для экрана.
    func currentProgress() -> DownloadProgress {
        lock.lock()
        let task = self.task
        let waiting = isWaitingForNetwork
        lock.unlock()

        guard let task else {
            return DownloadProgress(receivedBytes: 0, expectedBytes: nil, isWaitingForNetwork: waiting)
        }

        let received = task.countOfBytesReceived
        let hasResponse = task.response != nil

        // Полный размер ответа — из заголовка Content-Length (0 или -1, если неизвестен).
        // Если сервер сжимает ответ (gzip), «X из Y» может получиться неправдой
        // (сжатые и распакованные байты считаются по-разному) — тогда считаем размер неизвестным.
        var expected: Int64? = nil
        let httpResponse = task.response as? HTTPURLResponse
        let isCompressed = httpResponse?.value(forHTTPHeaderField: "Content-Encoding") != nil
        if task.countOfBytesExpectedToReceive > 0 && !isCompressed {
            expected = task.countOfBytesExpectedToReceive
        }

        // «Ждём сеть» — пока система так сообщила, сервер ещё ничего не ответил
        // и у телефона действительно нет сети (иначе это «сервер не отвечает», а не «нет сети»).
        let stillWaiting = waiting && !hasResponse && received == 0 && !NetworkMonitor.shared.isNetworkAvailable

        return DownloadProgress(receivedBytes: received, expectedBytes: expected, isWaitingForNetwork: stillWaiting)
    }
}
